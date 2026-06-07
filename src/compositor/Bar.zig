//! Configurable dual status bar for the miozu compositor.
//!
//! Renders top and/or bottom bars as wlr_scene_buffers. Each bar has
//! left/center/right sections containing parsed widget format strings.
//! Widgets are evaluated from compositor state (workspaces, title, etc.)
//! or from cached shell command output ({exec:N:cmd}).
//!
//! Config (teru.conf):
//!   [bar.top]
//!   left = {workspaces}
//!   center = {title}
//!   right = {clock}
//!
//!   [bar.bottom]
//!   left = {exec:2:sensors | grep Tctl}
//!   center = {panes}
//!   right = {mem}

const std = @import("std");
const posix = std.posix;
const teru = @import("teru");
const SoftwareRenderer = teru.render.SoftwareRenderer;
const BarWidget = teru.render.BarWidget;
const BarRenderer = teru.render.BarRenderer;
const BarData = BarRenderer.BarData;
const LayoutEngine = teru.LayoutEngine;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const Bar = @This();

const max_pending_execs = 8;

const PendingExec = struct {
    fd: posix.fd_t = -1,
    pid: i32 = 0,
    widget: *BarWidget.Widget,
    event_source: ?*wlr.wl_event_source = null,
};

const Section = struct {
    widgets: BarWidget.WidgetList = .{},
};

const BarInstance = struct {
    renderer: SoftwareRenderer,
    pixel_buffer: *wlr.wlr_buffer,
    scene_buffer: *wlr.wlr_scene_buffer,
    left: Section = .{},
    center: Section = .{},
    right: Section = .{},
    enabled: bool = false,
};

top: BarInstance,
bottom: BarInstance,
bar_height: u32,
output_width: u32,
output_height: u32,

/// Last-render signature — render() skips the SIMD blit + buffer
/// commit when nothing user-visible has changed. Call sites
/// (focus-change, ws-switch, push-widget update) each invoked
/// render() multiple times per action; perf review flagged the
/// redundant ~400 µs per spurious call. Bar content is deterministic
/// from a handful of fields — hashing them is cheaper than rendering.
last_top_sig: u64 = 0,
last_bottom_sig: u64 = 0,
/// Forces the next render regardless of signature. Set on config
/// reload + dimension change; cleared by the first render after.
dirty: bool = true,
	/// Set by render() when refreshCachedData detects a sysfs/proc value
	/// change. Forces re-render so the bar reflects updated CPU%, temp, etc.
	cache_dirty: bool = false,

	/// Non-blocking exec widget state. Each slot tracks one in-flight
	/// fork+pipe exec whose output will land asynchronously via the
	/// wlroots event loop. Slots with fd=-1 are free.
	pending_execs: [max_pending_execs]PendingExec = undefined,

pub fn create(server: *Server) ?*Bar {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const dims = server.activeOutputDims();
    const out_w: u32 = dims.w;
    const out_h: u32 = dims.h;
    const bar_h: u32 = cell_h + 4;

    const bar = allocator.create(Bar) catch return null;

    // Initialize pending exec slots as free
    for (&bar.pending_execs) |*pe| {
        pe.* = .{ .fd = -1, .pid = 0, .widget = undefined, .event_source = null };
    }

    // Create top bar
    bar.top = createBarInstance(server, allocator, out_w, bar_h, cell_w, cell_h, 0) orelse {
        allocator.destroy(bar);
        return null;
    };

    // Create bottom bar
    bar.bottom = createBarInstance(server, allocator, out_w, bar_h, cell_w, cell_h, @intCast(out_h - bar_h)) orelse {
        allocator.destroy(bar);
        return null;
    };

    bar.bar_height = bar_h;
    bar.output_width = out_w;
    bar.output_height = out_h;

    // Set default widget layout
    bar.top.left.widgets = BarWidget.parse(BarWidget.default_top_left);
    bar.top.center.widgets = BarWidget.parse(BarWidget.default_top_center);
    bar.top.right.widgets = BarWidget.parse(BarWidget.default_top_right);
    bar.top.enabled = true;

    // Bottom bar enabled by default with system info widgets
    bar.bottom.left.widgets = BarWidget.parse(BarWidget.default_bottom_left);
    bar.bottom.center.widgets = BarWidget.parse(BarWidget.default_bottom_center);
    bar.bottom.right.widgets = BarWidget.parse(BarWidget.default_bottom_right);
    bar.bottom.enabled = true;

    // Enable non-blocking exec widget evaluation via fork+pipe+event loop.
    // After this point, exec widget TTL expiry triggers fork+exec instead
    // of blocking popen() on the wlroots event loop.
    BarRenderer.exec_nonblocking = true;

    return bar;
}

fn createBarInstance(server: *Server, allocator: std.mem.Allocator, width: u32, height: u32, cell_w: u32, cell_h: u32, y_pos: c_int) ?BarInstance {
    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(width), @intCast(height)) orelse return null;
    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse return null;
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse return null;

    if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| {
        wlr.wlr_scene_node_set_position(node, 0, y_pos);
    }

    var renderer = SoftwareRenderer.init(allocator, width, height, cell_w, cell_h) catch return null;
    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        const needed = @as(usize, width) * @as(usize, height);
        if (needed > 0) renderer.framebuffer = data[0..needed];
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }

    return BarInstance{
        .renderer = renderer,
        .pixel_buffer = pixel_buffer,
        .scene_buffer = scene_buffer,
    };
}

/// Re-adopt the server's shared font atlas after a font-size zoom.
/// Resizes both bar buffers to the new cell-derived height (`cell_h + 4`)
/// and re-points the renderers at the new atlas. Unlike `create`, this
/// preserves widget layout and per-bar `.enabled` state. Caller reflows
/// tiling (`arrangeworkspace`) and repaints (`render`) afterwards.
pub fn refont(self: *Bar, server: *Server) void {
    const fa = server.font_atlas orelse return;
    if (fa.cell_width == 0 or fa.cell_height == 0) return;
    const new_h: u32 = fa.cell_height + 4;

    refontInstance(&self.top, fa, self.output_width, new_h, 0);
    refontInstance(&self.bottom, fa, self.output_width, new_h, @intCast(self.output_height -| new_h));

    self.bar_height = new_h;
    self.dirty = true; // force a repaint — signature alone won't catch the resize
}

/// Resize one bar instance's pixel buffer to `width × height`, re-point its
/// renderer at `fa`, and move its scene node to `y_pos`.
fn refontInstance(inst: *BarInstance, fa: *const teru.render.FontAtlas, width: u32, height: u32, y_pos: c_int) void {
    if (width == 0 or height == 0) return;
    if (!wlr.miozu_pixel_buffer_resize(inst.pixel_buffer, @intCast(width), @intCast(height))) return;
    const data = wlr.miozu_pixel_buffer_data(inst.pixel_buffer) orelse return;

    inst.renderer.framebuffer = data[0 .. @as(usize, width) * @as(usize, height)];
    inst.renderer.width = width;
    inst.renderer.height = height;
    inst.renderer.cell_width = fa.cell_width;
    inst.renderer.cell_height = fa.cell_height;
    inst.renderer.glyph_atlas = fa.atlas_data;
    inst.renderer.atlas_width = fa.atlas_width;
    inst.renderer.atlas_height = fa.atlas_height;

    wlr.wlr_scene_buffer_set_dest_size(inst.scene_buffer, @intCast(width), @intCast(height));
    if (wlr.miozu_scene_buffer_node(inst.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_position(node, 0, y_pos);
    }
}

/// Show/hide each bar's scene node to match `.enabled`.
/// Call this after toggling `bar.top.enabled` or `bar.bottom.enabled`.
pub fn updateVisibility(self: *Bar) void {
    if (wlr.miozu_scene_buffer_node(self.top.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, self.top.enabled);
    }
    if (wlr.miozu_scene_buffer_node(self.bottom.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, self.bottom.enabled);
    }
}

/// Render both bars from compositor state. Returns true if at least
/// one bar's scene buffer was actually re-painted — the periodic
/// bar-tick uses this to decide whether to scheduleRender (and so
/// avoids waking the compositor on a truly-idle frame).
pub fn render(self: *Bar, server: *Server) bool {
    // Refresh cached sysfs/proc data (TTL-gated, non-blocking reads).
    // Must happen before barSignature so value changes trigger re-render.
    const now = teru.compat.monotonicNow();
    if (BarRenderer.refreshCachedData(now)) {
        self.cache_dirty = true;
    }

    // Launch non-blocking exec widgets whose TTL has expired.
    // Output arrives asynchronously via wl_event_loop and marks bar dirty.
    self.refreshExecWidgets(server, now);

    const sig = self.barSignature(server);
    const force = self.dirty or self.cache_dirty;
    self.dirty = false;
    self.cache_dirty = false;

    var painted = false;
    if (self.top.enabled and (force or sig != self.last_top_sig)) {
        self.renderBar(&self.top, server);
        wlr.wlr_scene_buffer_set_buffer_with_damage(self.top.scene_buffer, self.top.pixel_buffer, null);
        self.last_top_sig = sig;
        painted = true;
    }
    if (self.bottom.enabled and (force or sig != self.last_bottom_sig)) {
        self.renderBar(&self.bottom, server);
        wlr.wlr_scene_buffer_set_buffer_with_damage(self.bottom.scene_buffer, self.bottom.pixel_buffer, null);
        self.last_bottom_sig = sig;
        painted = true;
    }
    return painted;
}

// ── Non-blocking exec widgets ─────────────────────────────────────
//
// Exec widgets (e.g. {exec:5:nvidia-smi ...}) are evaluated via
// fork+pipe instead of popen() so the wlroots event loop never blocks.
// refreshExecWidgets() is called every frame from render(); it checks
// each widget's TTL and launches a child process for expired ones.
// Output lands asynchronously via wl_event_loop_add_fd → execReadable(),
// which stores the result in the widget's cache and marks the bar dirty.

/// Iterate all widget sections and launch non-blocking execs for any
/// whose TTL has expired. Called from render() before the signature check.
fn refreshExecWidgets(self: *Bar, server: *Server, now_ns: i128) void {
    if (self.top.enabled) {
        refreshSectionExecs(self, &self.top.left, server, now_ns);
        refreshSectionExecs(self, &self.top.center, server, now_ns);
        refreshSectionExecs(self, &self.top.right, server, now_ns);
    }
    if (self.bottom.enabled) {
        refreshSectionExecs(self, &self.bottom.left, server, now_ns);
        refreshSectionExecs(self, &self.bottom.center, server, now_ns);
        refreshSectionExecs(self, &self.bottom.right, server, now_ns);
    }
}

fn refreshSectionExecs(self: *Bar, section: *Section, server: *Server, now_ns: i128) void {
    for (section.widgets.items[0..section.widgets.count]) |*w| {
        if (w.kind != .exec) continue;
        if (w.arg.len == 0) continue;

        // Check TTL
        const age_s: u32 = if (w.last_eval == 0) std.math.maxInt(u32) else blk: {
            const age = @divTrunc(now_ns -| w.last_eval, std.time.ns_per_s);
            break :blk if (age > std.math.maxInt(u32)) std.math.maxInt(u32) else @as(u32, @intCast(age));
        };
        if (age_s < w.interval) continue;

        // Prevent double-fork for the same widget
        if (findPendingExec(self, w) != null) continue;

        // Set last_eval now so we don't re-fork during this interval,
        // even if the child hasn't produced output yet.
        w.last_eval = now_ns;

        // Null-terminate command
        var cmd_z: [512]u8 = undefined;
        if (w.arg.len >= cmd_z.len) continue;
        @memcpy(cmd_z[0..w.arg.len], w.arg);
        cmd_z[w.arg.len] = 0;

        // Create pipe
        var pipe_fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) continue;
        const read_fd = pipe_fds[0];
        const write_fd = pipe_fds[1];

        // FD_CLOEXEC on both ends so a sibling exec widget's fork() does
        // not inherit this round's pipe fds and pin them open past its
        // own execve. The child's dup2(write_fd, STDOUT) below makes a
        // fresh non-CLOEXEC fd 1, so the command's stdout still flows.
        const FD_CLOEXEC: c_int = 1;
        for ([_]posix.fd_t{ read_fd, write_fd }) |pf| {
            const fdflags = std.c.fcntl(pf, posix.F.GETFD);
            if (fdflags >= 0) _ = std.c.fcntl(pf, posix.F.SETFD, fdflags | FD_CLOEXEC);
        }

        // Fork
        const pid = std.os.linux.fork();
        if (pid < 0) {
            _ = posix.system.close(read_fd);
            _ = posix.system.close(write_fd);
            continue;
        }

        if (pid == 0) {
            // Child: redirect stdout to pipe, exec /bin/sh -c <cmd>.
            _ = posix.system.close(read_fd);
            _ = std.c.dup2(write_fd, posix.STDOUT_FILENO);
            _ = std.c.dup2(write_fd, posix.STDERR_FILENO);
            _ = posix.system.close(write_fd);

            const cmd_slice: [:0]const u8 = cmd_z[0..w.arg.len :0];
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_slice.ptr, null };
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            _ = posix.system.execve("/bin/sh", &argv, @ptrCast(envp));
            std.os.linux.exit(1);
        }

        // Parent: close write end, set read end non-blocking.
        _ = posix.system.close(write_fd);

        const flags = std.c.fcntl(read_fd, posix.F.GETFL);
        if (flags >= 0) {
            _ = std.c.fcntl(read_fd, posix.F.SETFL, flags | teru.compat.O_NONBLOCK);
        }

        // Register with event loop
        if (addPendingExec(self, read_fd, @intCast(pid), w)) |pe| {
            if (server.event_loop) |el| {
                pe.event_source = wlr.wl_event_loop_add_fd(
                    el,
                    read_fd,
                    wlr.WL_EVENT_READABLE,
                    execReadable,
                    @ptrCast(pe),
                );
            }
        } else {
            // No free slot — clean up immediately (widget keeps stale cache).
            _ = posix.system.close(read_fd);
            _ = std.c.waitpid(@intCast(pid), null, std.c.W.NOHANG);
        }
    }
}

fn findPendingExec(self: *Bar, widget: *BarWidget.Widget) ?*PendingExec {
    for (&self.pending_execs) |*pe| {
        if (pe.fd != -1 and pe.widget == widget) return pe;
    }
    return null;
}

fn addPendingExec(self: *Bar, fd: posix.fd_t, pid: i32, widget: *BarWidget.Widget) ?*PendingExec {
    for (&self.pending_execs) |*pe| {
        if (pe.fd == -1) {
            pe.fd = fd;
            pe.pid = pid;
            pe.widget = widget;
            return pe;
        }
    }
    return null;
}

fn execReadable(fd: c_int, mask: u32, data: ?*anyopaque) callconv(.c) c_int {
    const pe: *PendingExec = @ptrCast(@alignCast(data orelse return 0));
    _ = mask; // the single read() below distinguishes data / EOF / EAGAIN —
    // no need to branch on READABLE vs HANGUP (they co-occur at EOF anyway).

    // Read whatever the child has written so far. The pipe is O_NONBLOCK
    // so we'll get EAGAIN if there's nothing yet (shouldn't happen since
    // the event loop only calls us when data is available).
    var buf: [BarWidget.max_exec_output]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n > 0) {
        var data_bytes = buf[0..@as(usize, @intCast(n))];
        // Trim trailing whitespace / newlines
        while (data_bytes.len > 0) {
            const c = data_bytes[data_bytes.len - 1];
            if (!isExecWhitespace(c)) break;
            data_bytes.len -= 1;
        }
        // Only keep first line (bar is single-line)
        if (std.mem.findScalar(u8, data_bytes, 0x0A)) |nl| data_bytes = data_bytes[0..nl];

        const copy_n = @min(data_bytes.len, pe.widget.cache.len);
        @memcpy(pe.widget.cache[0..copy_n], data_bytes[0..copy_n]);
        pe.widget.cache_len = @intCast(copy_n);
    }

    cleanupExec(pe);
    // libwayland ignores the return value of an fd source's callback —
    // cleanupExec() is what removes the source (wl_event_source_remove).
    return 0;
}

fn isExecWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn cleanupExec(pe: *PendingExec) void {
    // Remove the source from the wlroots event loop FIRST. Returning a
    // value from execReadable() does not do this — libwayland ignores
    // fd-handler return values. Skipping wl_event_source_remove leaks
    // the source: the pipe sits in epoll at permanent EOF/HUP, every
    // dispatch re-fires execReadable, and the compositor spins at 100%
    // CPU while leaking one pipe fd per exec until fd exhaustion.
    if (pe.event_source) |es| _ = wlr.wl_event_source_remove(es);
    pe.event_source = null;
    if (pe.fd != -1) _ = posix.system.close(pe.fd);
    if (pe.pid != 0) _ = std.c.waitpid(pe.pid, null, std.c.W.NOHANG);
    pe.fd = -1;
    pe.pid = 0;
}

/// Drain every in-flight exec widget. Called from Server.deinit so a
/// pending exec's pipe fd can't fire execReadable after the event loop
/// is torn down. Scene buffers / renderers are left for wlroots'
/// wl_display_destroy walker (same policy as TerminalPane.deinit).
pub fn deinitExecs(self: *Bar) void {
    for (&self.pending_execs) |*pe| {
        if (pe.fd != -1 or pe.event_source != null) cleanupExec(pe);
    }
}

/// Cheap u64 fingerprint of the user-visible bar state. Collisions
/// are benign (missed repaint on a field that didn't actually move
/// the displayed value — e.g. sub-microsecond avg-frame drift that
/// rounds to the same rendered digit). Intentionally omits perf
/// microstats so sub-µs frame jitter doesn't cause sustained redraw.
fn barSignature(self: *Bar, server: *Server) u64 {
    _ = self;
    const prime: u64 = 0x9e3779b97f4a7c15;
    var h: u64 = prime;
    h ^= @intCast(server.layout_engine.active_workspace);
    h *%= prime;

    // Workspace occupancy + urgency bitfield, one pass. Urgency reads
    // the pre-maintained per-ws counter (O(1)) instead of rescanning
    // 256 slots.
    var ws_bits: u64 = 0;
    for (0..10) |wi| {
        if (server.layout_engine.workspaces[wi].node_ids.items.len > 0)
            ws_bits |= (@as(u64, 1) << @intCast(wi));
        if (server.nodes.urgent_count_per_ws[wi] > 0)
            ws_bits |= (@as(u64, 1) << @intCast(wi + 16));
    }
    h ^= ws_bits;
    h *%= prime;

    // Layout char + pane count + title (pointer-identity check — when
    // a client retitles, the buffer address typically changes, and
    // even false collisions on the pointer mean "same title").
    const active_ws = server.layout_engine.getActiveWorkspace();
    h ^= @intFromEnum(active_ws.layout);
    h *%= prime;
    h ^= server.nodes.countInWorkspace(server.layout_engine.active_workspace);
    h *%= prime;
    if (server.focused_terminal) |tp| {
        // Hash title content so same-length title changes trigger re-render.
        // (title is [256]u8 — &tp.pane.vt.title is a stable fixed-array pointer,
        // so old code only caught length changes, not content changes.)
        const title_bytes = tp.pane.vt.title[0..tp.pane.vt.title_len];
        h ^= std.hash.Wyhash.hash(0, title_bytes);
    }
    h *%= prime;

    // Keymap name — changes on layout switch.
    h ^= @intFromPtr(server.active_keymap_name.ptr);
    h ^= server.active_keymap_name.len;
    h *%= prime;

    // Clock / exec widget staleness: hash the current minute so the
    // bar re-renders when time-dependent widgets (clock, exec-N)
    // need to show updated values. Without this, the signature
    // optimisation kept the bar frozen until a workspace switch.
    h ^= @intCast(@divTrunc(teru.compat.monotonicNow(), 60 * std.time.ns_per_s));
    h *%= prime;

    // Push widget used-mask, with a cheap short-circuit: if the first
    // slot's unused and the internal push_widget_count (maintained by
    // set/deletePushWidget) is zero, skip the 32-slot iteration.
    if (server.countPushWidgets() > 0) {
        var pw_mask: u64 = 0;
        for (server.push_widgets, 0..) |w, i| {
            if (w.used) pw_mask |= (@as(u64, 1) << @intCast(i % 64));
        }
        h ^= pw_mask;
    }

    // Desktop notification — fold in presence + marquee offset so the bar
    // repaints when one arrives, on every marquee step, and on expiry.
    // Without this the {notify} widget never draws: barSignature stays
    // constant, b.render() short-circuits, and the notification is invisible.
    if (server.current_notification != null) {
        h ^= 0x4e4f5449_00000000 ^ @as(u64, server.notify_scroll); // "NOTI" + scroll
        h *%= prime;
    }
    return h;
}

fn renderBar(self: *Bar, inst: *BarInstance, server: *Server) void {
    const cpu = &inst.renderer;
    const s = &cpu.scheme;
    const cw: usize = cpu.cell_width;
    const fb_w: usize = self.output_width;
    const bar_h: usize = self.bar_height;

    // Clear bar background
    const total = @min(fb_w * bar_h, cpu.framebuffer.len);
    teru.compat.memsetU32(cpu.framebuffer[0..total], s.bg);

    // Separator line
    if (fb_w > 0 and total >= fb_w) {
        teru.compat.memsetU32(cpu.framebuffer[0..fb_w], s.selection_bg);
    }

    // Build BarData from compositor state
    const data = self.buildBarData(server);
    const text_y: usize = 2;

    // ── Left section ──
    _ = BarRenderer.renderWidgets(cpu, inst.left.widgets.items[0..inst.left.widgets.count], &data, 4, text_y, fb_w / 3);

    // ── Right section ──
    const right_w = BarRenderer.measureWidgets(inst.right.widgets.items[0..inst.right.widgets.count], &data, cw);
    const right_x: usize = if (fb_w > right_w + cw * 2) fb_w - right_w - cw * 2 else 0;
    _ = BarRenderer.renderWidgets(cpu, inst.right.widgets.items[0..inst.right.widgets.count], &data, right_x, text_y, fb_w);

    // ── Center section ──
    const center_w = BarRenderer.measureWidgets(inst.center.widgets.items[0..inst.center.widgets.count], &data, cw);
    const center_x: usize = if (fb_w > center_w) (fb_w - center_w) / 2 else 0;
    _ = BarRenderer.renderWidgets(cpu, inst.center.widgets.items[0..inst.center.widgets.count], &data, center_x, text_y, fb_w);
}

/// Build BarData from compositor state.
fn buildBarData(_: *Bar, server: *Server) BarData {
    var data = BarData{};
    data.workspace_active = server.layout_engine.active_workspace;

    for (0..10) |wi| {
        data.workspace_has_nodes[wi] = server.layout_engine.workspaces[wi].node_ids.items.len > 0;
        data.workspace_urgent[wi] = server.nodes.anyUrgentOnWorkspace(@intCast(wi));
    }

    if (server.focused_terminal) |tp| {
        data.title = if (tp.pane.vt.title_len > 0) tp.pane.vt.title[0..tp.pane.vt.title_len] else "shell";
    }

    const active_ws = server.layout_engine.getActiveWorkspace();
    data.layout_char = switch (active_ws.layout) {
        .master_stack => 'M',
        .grid => 'G',
        .monocle => '#',
        .dishes => 'D',
        .accordion => 'A',
        .spiral => 'S',
        .three_col => '3',
        .columns => '|',
    };

    data.pane_count = server.nodes.countInWorkspace(server.layout_engine.active_workspace);

    // Performance stats
    data.frame_avg_us = server.perf.avgFrameUs();
    data.frame_max_us = server.perf.frame_time_max_us;
    if (data.frame_max_us == std.math.maxInt(u64)) data.frame_max_us = 0;
    data.pty_bytes_total = server.perf.pty_bytes;

    // Active keyboard layout short name. xkb layout names look like
    // "English (US)", "Ukrainian", "English (Dvorak)"; we shorten them.
    data.keymap = shortKeymap(server.active_keymap_name);

    // Color thresholds come from the user's config file ([bar.thresholds]).
    data.thresholds = server.wm_config.bar_thresholds;

    // Push widgets registered via MCP. Pass the whole fixed-size array;
    // the renderer filters by `used` and matches on name.
    data.push_widgets = &server.push_widgets;

    // Desktop notification (teruwm only) — copy the live Server.Notification
    // into the renderer's plain fields so BarRenderer (shared with teru) stays
    // free of compositor types. notify_active stays false when none is live,
    // so the {notify} widget renders nothing. The slices borrow the
    // Notification's fixed buffers, which outlive this BarData (it lives in
    // server.current_notification until barTick clears it).
    if (server.current_notification) |*n| {
        data.notify_active = true;
        data.notify_urgency = @intFromEnum(n.urgency);
        data.notify_scroll = server.notify_scroll;
        data.notify_app = n.app();
        data.notify_summary = n.summary();
        data.notify_body = n.body();
    }

    return data;
}

/// Thread-local storage for the short form returned by shortKeymap.
threadlocal var keymap_buf: [8]u8 = undefined;

/// Format an XKB layout identifier for display in the bar.
/// Prefers the raw code extracted upstream from xkb_keymap_get_as_string
/// (`us`, `ua`, `us(dvorak)`). If a variant is present, uses the variant
/// (Us(dvorak) → Dv). Otherwise uppercases the first letter:
///   "us" → "Us", "ua" → "Ua", "us(dvorak)" → "Dv"
///   "English (US)" (friendly-name fallback) → "Us"
fn shortKeymap(name: []const u8) []const u8 {
    if (name.len == 0) return "";

    // Prefer the variant in parens if there is one.
    var src: []const u8 = name;
    if (std.mem.findScalarLast(u8, name, '(')) |lp| {
        if (std.mem.findScalarPos(u8, name, lp + 1, ')')) |rp| {
            if (rp > lp + 1) src = name[lp + 1 .. rp];
        }
    }

    var i: usize = 0;
    while (i < src.len and !std.ascii.isAlphabetic(src[i])) i += 1;
    if (i >= src.len) return "";

    keymap_buf[0] = std.ascii.toUpper(src[i]);
    if (i + 1 < src.len and std.ascii.isAlphabetic(src[i + 1])) {
        keymap_buf[1] = std.ascii.toLower(src[i + 1]);
        return keymap_buf[0..2];
    }
    return keymap_buf[0..1];
}

test "shortKeymap raw xkb codes" {
    // Raw codes from xkb_keymap_get_as_string
    try std.testing.expectEqualStrings("Us", shortKeymap("us"));
    try std.testing.expectEqualStrings("Ua", shortKeymap("ua"));
    try std.testing.expectEqualStrings("Dv", shortKeymap("us(dvorak)"));
    try std.testing.expectEqualStrings("Co", shortKeymap("us(colemak)"));
    // Friendly-name fallback
    try std.testing.expectEqualStrings("Dv", shortKeymap("English (Dvorak)"));
    try std.testing.expectEqualStrings("Us", shortKeymap("English (US)"));
    try std.testing.expectEqualStrings("Uk", shortKeymap("Ukrainian"));
    try std.testing.expectEqualStrings("", shortKeymap(""));
}

// Widget rendering moved to libteru's src/render/BarRenderer.zig (shared with standalone teru).

/// Get the total height consumed by enabled bars.
pub fn totalHeight(self: *Bar) u32 {
    var h: u32 = 0;
    if (self.top.enabled) h += self.bar_height;
    if (self.bottom.enabled) h += self.bar_height;
    return h;
}

/// Get the Y offset for tiling (below top bar).
pub fn tilingOffsetY(self: *Bar) u32 {
    return if (self.top.enabled) self.bar_height else 0;
}

/// Configure from format strings (called after config load).
pub fn configure(self: *Bar, top_left: ?[]const u8, top_center: ?[]const u8, top_right: ?[]const u8, bottom_left: ?[]const u8, bottom_center: ?[]const u8, bottom_right: ?[]const u8) void {
    if (top_left) |s| self.top.left.widgets = BarWidget.parse(s);
    if (top_center) |s| self.top.center.widgets = BarWidget.parse(s);
    if (top_right) |s| self.top.right.widgets = BarWidget.parse(s);

    if (bottom_left) |s| { self.bottom.left.widgets = BarWidget.parse(s); self.bottom.enabled = true; }
    if (bottom_center) |s| { self.bottom.center.widgets = BarWidget.parse(s); self.bottom.enabled = true; }
    if (bottom_right) |s| { self.bottom.right.widgets = BarWidget.parse(s); self.bottom.enabled = true; }
}
