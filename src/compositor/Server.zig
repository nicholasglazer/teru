//! Compositor server state. Owns all wlroots objects, listeners, and the
//! connection between libteru's tiling engine and the wlroots scene graph.

const std = @import("std");
const wlr = @import("wlr.zig");
const Output = @import("Output.zig");
const XdgView = @import("XdgView.zig");
const TerminalPane = @import("TerminalPane.zig");
const XwaylandView = @import("XwaylandView.zig");
const Launcher = @import("Launcher.zig");
const Bar = @import("Bar.zig");
const WmConfig = @import("WmConfig.zig");
const WmMcpServer = @import("WmMcpServer.zig");
const NodeRegistry = @import("Node.zig");
const teru = @import("teru");
const LayoutEngine = teru.LayoutEngine;
const Keybinds = teru.Keybinds;
const Mods = Keybinds.Mods;
const KB = Keybinds.Keybinds;
const KBAction = Keybinds.Action;
const KBMods = Keybinds.Mods;

const Server = @This();

pub const CursorMode = enum { normal, move, resize, border_drag };

// ── Zig allocator ─────────────────────────────────────────────

zig_allocator: std.mem.Allocator,

// ── wlroots objects (owned) ────────────────────────────────────

display: *wlr.wl_display,
backend: *wlr.wlr_backend,
renderer: *wlr.wlr_renderer,
allocator: *wlr.wlr_allocator,
scene: *wlr.wlr_scene,
output_layout: *wlr.wlr_output_layout,
xdg_shell: *wlr.wlr_xdg_shell,
seat: *wlr.wlr_seat,
cursor: *wlr.wlr_cursor,
cursor_mgr: *wlr.wlr_xcursor_manager,
xkb_ctx: *wlr.xkb_context,
session: ?*wlr.wlr_session = null,
xwayland: ?*wlr.wlr_xwayland = null,
wlr_compositor: ?*wlr.wlr_compositor = null, // needed for xwayland_create

/// Full-screen background scene rect (solid color). Created on output
/// attach, lowered beneath all other scene nodes. Color from wm_config.
bg_rect: ?*wlr.wlr_scene_rect = null,

// ── Tiling & nodes ─────────────────────────────────────────────

layout_engine: LayoutEngine,
nodes: NodeRegistry,
keybinds: KB = .{},
font_atlas: ?*teru.render.FontAtlas = null, // shared across all terminal panes
next_node_id: u64 = 1,
focused_view: ?*XdgView = null,
focused_terminal: ?*TerminalPane = null,
terminal_panes: [NodeRegistry.max_nodes]?*TerminalPane = [_]?*TerminalPane{null} ** NodeRegistry.max_nodes,
terminal_count: u16 = 0,
bar: ?*Bar = null,
primary_output: ?*wlr.wlr_output = null,
workspace_trees: [10]?*wlr.wlr_scene_tree = [_]?*wlr.wlr_scene_tree{null} ** 10,

// Active XKB layout name (for the {keymap} bar widget).
// Stored as a static buffer because the xkb string can outlive
// the keymap it came from between reads.
active_keymap_name_buf: [64]u8 = [_]u8{0} ** 64,
active_keymap_name: []const u8 = "",

/// Push widgets registered via MCP. Referenced by bar format strings
/// with `{widget:name}`. Fixed-size array; slot 0..N with `.used=false`
/// are empty. No heap allocation. Not persisted across hot-restart.
push_widgets: [teru.render.PushWidget.max_widgets]teru.render.PushWidget.PushWidget =
    [_]teru.render.PushWidget.PushWidget{.{}} ** teru.render.PushWidget.max_widgets,

// Fullscreen state: tracks which node is fullscreen (null = none)
fullscreen_node: ?u64 = null,
fullscreen_prev_bar_top: bool = true,
fullscreen_prev_bar_bottom: bool = false,

// Scratchpads: 9 floating terminal panes (Alt+RAlt+1-9)
scratchpads: [9]?*TerminalPane = [_]?*TerminalPane{null} ** 9,
scratchpad_visible: [9]bool = [_]bool{false} ** 9,

// Mouse move/resize state for floating windows
cursor_mode: CursorMode = .normal,
grab_node_id: ?u64 = null,
grab_x: f64 = 0,
grab_y: f64 = 0,
grab_w: u32 = 0,
grab_h: u32 = 0,

// Internal clipboard buffer (Ctrl+Shift+C/V between terminal panes)
clipboard_buf: [8192]u8 = undefined,
clipboard_len: u16 = 0,

// Built-in launcher
launcher: Launcher = .{},

// teruwm-specific config (~/.config/teruwm/config)
wm_config: WmConfig = .{},

// Autostart fires once on first output. True if we've already run it,
// OR if we're restoring from --restore (autostart is a cold-start feature;
// hot-restart must not re-spawn clients that are still connected).
autostart_fired: bool = false,

// Previous workspace, for Mod+Escape toggle-last. Updated on every
// workspace switch.
prev_workspace: ?u8 = null,

// User-defined spawn chord commands. Each slot pairs with the
// spawn_0..spawn_31 action variants; the keybind table maps chords
// to those actions, this array resolves to the shell command.
// Populated from `[keybind]` config section entries of the form
// `Mod+Return = spawn:teru`.
spawn_table: [32][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 32,
spawn_table_len: [32]u16 = [_]u16{0} ** 32,

// MCP server for compositor control
wm_mcp: ?*WmMcpServer = null,

// Deferred layout/resize — set by mouse handlers, applied in frame callback
layout_dirty: bool = false,
resize_pending_id: ?u64 = null,
resize_pending_w: u32 = 0,
resize_pending_h: u32 = 0,

// Performance stats
perf: PerfStats = .{},

// Restart flag — set by MCP, executed in frame callback (after response is sent)
restart_pending: bool = false,

// ── Listeners ──────────────────────────────────────────────────

new_output: wlr.wl_listener = makeListener(handleNewOutput),
new_input: wlr.wl_listener = makeListener(handleNewInput),
new_xdg_toplevel: wlr.wl_listener = makeListener(handleNewXdgToplevel),
cursor_motion: wlr.wl_listener = makeListener(handleCursorMotion),
cursor_motion_absolute: wlr.wl_listener = makeListener(handleCursorMotionAbsolute),
cursor_button: wlr.wl_listener = makeListener(handleCursorButton),
cursor_axis: wlr.wl_listener = makeListener(handleCursorAxis),
cursor_frame: wlr.wl_listener = makeListener(handleCursorFrame),
request_set_cursor: wlr.wl_listener = makeListener(handleRequestSetCursor),
new_xwayland_surface: wlr.wl_listener = makeListener(handleNewXwaylandSurface),

// xdg_activation_v1 — clients asking for focus (v0.4.17).
xdg_activate: wlr.wl_listener = makeListener(handleXdgActivation),
xdg_activation: ?*wlr.wlr_xdg_activation_v1 = null,

// ── Types ─────────────────────────────────────────────────────

pub const PerfStats = struct {
    frame_count: u64 = 0,
    frame_time_sum_us: u64 = 0,
    frame_time_max_us: u64 = 0,
    frame_time_min_us: u64 = std.math.maxInt(u64),
    pty_reads: u64 = 0,
    pty_bytes: u64 = 0,

    pub fn recordFrame(self: *PerfStats, elapsed_us: u64) void {
        self.frame_count += 1;
        self.frame_time_sum_us += elapsed_us;
        if (elapsed_us > self.frame_time_max_us) self.frame_time_max_us = elapsed_us;
        if (elapsed_us < self.frame_time_min_us) self.frame_time_min_us = elapsed_us;
    }

    pub fn recordPtyRead(self: *PerfStats, bytes: usize) void {
        self.pty_reads += 1;
        self.pty_bytes += bytes;
    }

    pub fn avgFrameUs(self: *const PerfStats) u64 {
        if (self.frame_count == 0) return 0;
        return self.frame_time_sum_us / self.frame_count;
    }
};

// ── Init ───────────────────────────────────────────────────────

/// Allocate Server on the heap and initialize in-place.
/// Critical: wl_listeners are registered by pointer. If Server is on the stack
/// and later moved/copied, those pointers dangle. This function ensures the
/// Server has a stable heap address before any listener is registered.
pub fn initOnHeap(display: *wlr.wl_display, event_loop: *wlr.wl_event_loop, allocator: std.mem.Allocator) !*Server {
    const self = try allocator.create(Server);
    errdefer allocator.destroy(self);
    self.* = try initFields(display, event_loop, allocator);
    registerListeners(self);
    return self;
}

fn initFields(display: *wlr.wl_display, event_loop: *wlr.wl_event_loop, allocator: std.mem.Allocator) !Server {
    // Backend (capture session for VT switching)
    var session_ptr: ?*wlr.wlr_session = null;
    const backend = wlr.wlr_backend_autocreate(event_loop, &session_ptr) orelse
        return error.BackendCreateFailed;

    // Renderer + allocator
    const renderer = wlr.wlr_renderer_autocreate(backend) orelse
        return error.RendererCreateFailed;
    _ = wlr.wlr_renderer_init_wl_display(renderer, display);

    const wlr_alloc = wlr.wlr_allocator_autocreate(backend, renderer) orelse
        return error.AllocatorCreateFailed;

    // Compositor protocol (wl_compositor, wl_subcompositor)
    const wlr_comp = wlr.wlr_compositor_create(display, 5, renderer);
    _ = wlr.wlr_subcompositor_create(display);
    _ = wlr.wlr_data_device_manager_create(display);

    // zwlr_screencopy_manager_v1 — enables grim, slurp+grim, wf-recorder,
    // OBS screencopy, and any other screen-capture client. wlroots hooks
    // wlr_output.commit internally and samples the composited framebuffer
    // every vsync; no extra render pass. Owned by the wl_display, so no
    // cleanup needed (tears down on display_destroy).
    _ = wlr.wlr_screencopy_manager_v1_create(display);

    // xdg_activation_v1 — clients ask "please focus me." We route this
    // to the urgency bit (not focus-steal) so hidden apps visibly flag
    // themselves on their workspace pill in the bar.
    const xdg_act = wlr.wlr_xdg_activation_v1_create(display);

    // Scene graph
    const scene = wlr.wlr_scene_create() orelse
        return error.SceneCreateFailed;

    // Note: background color is handled by wlr_renderer_clear in the
    // Output frame handler, not by a scene rect (avoids node type issues).

    // Output layout
    const output_layout = wlr.wlr_output_layout_create(display) orelse
        return error.OutputLayoutCreateFailed;
    _ = wlr.wlr_scene_attach_output_layout(scene, output_layout);

    // XDG shell
    const xdg_shell = wlr.wlr_xdg_shell_create(display, 3) orelse
        return error.XdgShellCreateFailed;

    // Cursor
    const cursor = wlr.wlr_cursor_create() orelse
        return error.CursorCreateFailed;
    wlr.wlr_cursor_attach_output_layout(cursor, output_layout);

    const cursor_mgr = wlr.wlr_xcursor_manager_create(null, 24) orelse
        return error.CursorMgrCreateFailed;

    // Seat
    const seat = wlr.wlr_seat_create(display, "seat0") orelse
        return error.SeatCreateFailed;

    // XKB context for keyboards
    const xkb_ctx = wlr.xkb_context_new(0) orelse
        return error.XkbContextFailed;

    // Keybinds: initialized with defaults. applyConfig() will set mod_key
    // to Super and reload, so these initial Alt defaults get overwritten.
    var keybinds = KB{};
    keybinds.loadDefaults();

    // Return fields only — listeners are registered separately by initOnHeap
    // after the struct has its final heap address.
    return Server{
        .zig_allocator = allocator,
        .keybinds = keybinds,
        .layout_engine = LayoutEngine.init(allocator),
        .nodes = .{},
        .display = display,
        .backend = backend,
        .renderer = renderer,
        .allocator = wlr_alloc,
        .scene = scene,
        .output_layout = output_layout,
        .xdg_shell = xdg_shell,
        .seat = seat,
        .cursor = cursor,
        .cursor_mgr = cursor_mgr,
        .xkb_ctx = xkb_ctx,
        .session = session_ptr,
        .wlr_compositor = wlr_comp,
        .xdg_activation = xdg_act,
    };
}

/// Register wl_signal listeners. Must be called AFTER the Server has its
/// final heap address (listeners are stored by pointer in wlroots linked lists).
fn registerListeners(self: *Server) void {
    wlr.wl_signal_add(wlr.miozu_backend_new_output(self.backend), &self.new_output);
    wlr.wl_signal_add(wlr.miozu_backend_new_input(self.backend), &self.new_input);
    wlr.wl_signal_add(wlr.miozu_xdg_shell_new_toplevel(self.xdg_shell), &self.new_xdg_toplevel);

    // xdg_activation_v1 — request_activate fires when a client asks to
    // be focused (e.g. chromium background tab opening a new window).
    if (self.xdg_activation) |xa| {
        wlr.wl_signal_add(wlr.miozu_xdg_activation_request_activate(xa), &self.xdg_activate);
    }
    wlr.wl_signal_add(wlr.miozu_cursor_motion(self.cursor), &self.cursor_motion);
    wlr.wl_signal_add(wlr.miozu_cursor_motion_absolute(self.cursor), &self.cursor_motion_absolute);
    wlr.wl_signal_add(wlr.miozu_cursor_button(self.cursor), &self.cursor_button);
    wlr.wl_signal_add(wlr.miozu_cursor_axis(self.cursor), &self.cursor_axis);
    wlr.wl_signal_add(wlr.miozu_cursor_frame(self.cursor), &self.cursor_frame);
    wlr.wl_signal_add(wlr.miozu_seat_request_set_cursor(self.seat), &self.request_set_cursor);

    // XWayland (lazy start — only spawns Xwayland process when an X11 client connects)
    if (self.wlr_compositor) |comp| {
        if (wlr.wlr_xwayland_create(self.display, comp, true)) |xwl| {
            self.xwayland = xwl;
            wlr.wl_signal_add(wlr.miozu_xwayland_new_surface(xwl), &self.new_xwayland_surface);
            wlr.wlr_xwayland_set_seat(xwl, self.seat);

            // Set DISPLAY env var so X11 clients (xterm, emacs, ...) can connect.
            // The display socket is reserved immediately by wlr_xwayland_create
            // even in lazy mode; the Xwayland process only spawns on first connect.
            if (wlr.miozu_xwayland_display_name(xwl)) |dn| {
                _ = wlr.setenv("DISPLAY", dn, 1);
                std.debug.print("teruwm: XWayland enabled (DISPLAY={s})\n", .{dn});
            } else {
                std.debug.print("teruwm: XWayland enabled\n", .{});
            }
        } else {
            std.debug.print("teruwm: XWayland init failed (X11 apps won't work)\n", .{});
        }
    }
}

/// Apply loaded config to server state: font, colors, keybinds, workspace layouts, bars.
pub fn applyConfig(self: *Server, config: *const teru.Config, allocator: std.mem.Allocator, io: std.Io) void {
    // ── Font atlas from config ──────────────────────────────
    if (teru.render.FontAtlas.init(allocator, config.font_path, config.font_size, io)) |atlas| {
        const fa = allocator.create(teru.render.FontAtlas) catch return;
        fa.* = atlas;
        self.font_atlas = fa;
        std.debug.print("teruwm: font loaded ({d}x{d} cells)\n", .{ fa.cell_width, fa.cell_height });
    } else |err| {
        std.debug.print("teruwm: font init failed: {}, using fallback\n", .{err});
    }

    // ── Keybinds: set mod to Super (compositor), load unified defaults + media ──
    self.keybinds.mod_key = Mods.SUPER;
    self.keybinds.loadDefaults(); // uses mod_key = Super for all $mod bindings
    self.keybinds.loadMediaDefaults(); // XF86 media keys (no modifier)
    // Apply user overrides from teru.conf on top
    // (config.keybinds were parsed with the old mod — we re-load with Super)

    // ── Launcher ($PATH scan) ─────────────────────────────────
    self.launcher.init();

    // ── Per-workspace layouts from config ────────────────────
    for (0..10) |i| {
        if (config.workspace_layout_counts[i] > 0) {
            self.layout_engine.workspaces[i].setLayouts(
                config.workspace_layout_lists[i][0..config.workspace_layout_counts[i]],
            );
        } else if (config.workspace_layouts[i]) |layout| {
            self.layout_engine.workspaces[i].layout = layout;
        }
        if (config.workspace_ratios[i]) |ratio| {
            self.layout_engine.workspaces[i].master_ratio = ratio;
        }
        if (config.workspace_names[i]) |name| {
            self.layout_engine.workspaces[i].name = name;
        }
    }

    // ── Color scheme for terminal pane rendering ─────────────
    // Stored on server, applied to each TerminalPane's SoftwareRenderer

    // ── teruwm-specific config (~/.config/teruwm/config) ────
    self.wm_config = WmConfig.load(io);
    if (self.wm_config.rule_count > 0) {
        std.debug.print("teruwm: loaded {d} window rules\n", .{self.wm_config.rule_count});
    }

    // ── User-defined spawn chords from [keybind] section ────
    self.applyWmSpawnChords();
}

/// Resolve each `[keybind] chord = spawn:cmd` entry into a spawn_table
/// slot and install the binding in the keybinds table.
fn applyWmSpawnChords(self: *Server) void {
    var slot: u8 = 0;
    for (self.wm_config.spawn_chords[0..self.wm_config.spawn_chord_count]) |*entry| {
        if (slot >= self.spawn_table.len) break;

        // Parse the chord ("Mod+Return") via the shared trigger parser
        const trig = Keybinds.parseTriggerWithMod(entry.getChord(), self.keybinds.mod_key) orelse {
            std.debug.print("teruwm: skipping bad keybind chord '{s}'\n", .{entry.getChord()});
            continue;
        };

        // Store cmd in spawn_table[slot]
        const cmd = entry.getCmd();
        const n = @min(cmd.len, self.spawn_table[slot].len);
        @memcpy(self.spawn_table[slot][0..n], cmd[0..n]);
        self.spawn_table_len[slot] = @intCast(n);

        // Map to spawn_N action
        const first_tag: u8 = @intFromEnum(Keybinds.Action.spawn_0);
        const action: Keybinds.Action = @enumFromInt(first_tag + slot);

        // Install in normal mode (shared works too but normal is the daily path)
        _ = self.keybinds.add(.normal, trig.mods, trig.key, action);
        slot += 1;
    }
    if (slot > 0) {
        std.debug.print("teruwm: loaded {d} spawn chords\n", .{slot});
    }
}

/// Apply teruwm bar config to the bar instance (called after bar creation).
pub fn applyWmBar(self: *Server) void {
    if (self.bar) |b| {
        const wc = &self.wm_config;
        b.configure(
            wc.bar_top_left,
            wc.bar_top_center,
            wc.bar_top_right,
            wc.bar_bottom_left,
            wc.bar_bottom_center,
            wc.bar_bottom_right,
        );
    }
}

pub fn startMcp(self: *Server) void {
    self.wm_mcp = WmMcpServer.init(self);
}

/// Reload compositor config from disk and re-apply live.
/// Called by Mod+Shift+R keybind or teruwm_reload_config MCP tool.
pub fn reloadWmConfig(self: *Server) void {
    // Re-read config file (requires io — use a dummy Io for file access)
    // Use libc fopen/fread to reload config (no Io needed)
    self.wm_config = WmConfig.loadWithLibc();

    // Re-apply bar configuration
    if (self.bar) |b| {
        b.configure(
            self.wm_config.bar_top_left,
            self.wm_config.bar_top_center,
            self.wm_config.bar_top_right,
            self.wm_config.bar_bottom_left,
            self.wm_config.bar_bottom_center,
            self.wm_config.bar_bottom_right,
        );
        b.render(self);
    }

    // Apply new background color to the scene rect
    if (self.bg_rect) |rect| {
        const col = self.wm_config.bg_color;
        const rgba: [4]f32 = .{
            @as(f32, @floatFromInt((col >> 16) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((col >> 8) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt(col & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((col >> 24) & 0xFF)) / 255.0,
        };
        wlr.wlr_scene_rect_set_color(rect, &rgba);
    }

    // Re-arrange all workspaces with new gap
    for (0..10) |wi| {
        const ws = &self.layout_engine.workspaces[wi];
        if (ws.node_ids.items.len > 0) {
            self.arrangeworkspace(@intCast(wi));
        }
    }

    std.debug.print("teruwm: config reloaded (gap={d}, border={d}, bg=0x{x:0>8})\n", .{ self.wm_config.gap, self.wm_config.border_width, self.wm_config.bg_color });
}

/// Restart the compositor: serialize state, exec new binary.
/// PTY fds survive exec() — shells keep running, zero downtime.
pub fn execRestart(self: *Server) void {
    const restart_path = "/tmp/teruwm-restart.bin";

    // Serialize: for each terminal pane, write {workspace, pty_fd, rows, cols, pid}
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Header: pane count
    var pane_count: u16 = 0;
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp != null) pane_count += 1;
    }
    if (pos + 2 <= buf.len) { std.mem.writeInt(u16, buf[pos..][0..2], pane_count, .little); pos += 2; }

    // Active workspace
    if (pos + 1 <= buf.len) { buf[pos] = self.layout_engine.active_workspace; pos += 1; }

    // Per-workspace layouts (10 workspaces)
    for (0..10) |wi| {
        if (pos + 1 <= buf.len) { buf[pos] = @intFromEnum(self.layout_engine.workspaces[wi].layout); pos += 1; }
    }

    // Per-pane data
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            const ws = if (self.nodes.findById(tp.node_id)) |slot| self.nodes.workspace[slot] else 0;
            const pty_fd: i32 = switch (tp.pane.backend) {
                .local => |p| p.master,
                .remote => -1,
            };
            const pid: i32 = switch (tp.pane.backend) {
                .local => |p| if (p.child_pid) |cp| @intCast(cp) else -1,
                .remote => -1,
            };
            if (pos + 13 <= buf.len) {
                buf[pos] = ws; pos += 1;
                std.mem.writeInt(i32, buf[pos..][0..4], pty_fd, .little); pos += 4;
                std.mem.writeInt(u16, buf[pos..][0..2], tp.pane.grid.rows, .little); pos += 2;
                std.mem.writeInt(u16, buf[pos..][0..2], tp.pane.grid.cols, .little); pos += 2;
                std.mem.writeInt(i32, buf[pos..][0..4], pid, .little); pos += 4;
            }

            // Clear FD_CLOEXEC on pty master so it survives exec
            if (pty_fd >= 0) {
                const flags = std.c.fcntl(pty_fd, std.posix.F.GETFD);
                if (flags >= 0) {
                    _ = std.c.fcntl(pty_fd, std.posix.F.SETFD, flags & ~@as(c_int, 1)); // clear FD_CLOEXEC
                }
            }
        }
    }

    // Write state file
    const file = std.c.fopen(restart_path, "wb");
    if (file) |f| {
        _ = std.c.fwrite(buf[0..pos].ptr, 1, pos, f);
        _ = std.c.fclose(f);
    } else {
        std.debug.print("teruwm: failed to write restart state\n", .{});
        return;
    }

    std.debug.print("teruwm: restarting ({d} panes saved)\n", .{pane_count});

    // exec the new binary
    const self_exe = "/proc/self/exe";
    var argv_buf: [3:null]?[*:0]const u8 = .{ @ptrCast(self_exe), @ptrCast("--restore"), null };
    _ = std.posix.system.execve(@ptrCast(self_exe), @ptrCast(&argv_buf), std.c.environ);

    // If exec fails, we're still running
    std.debug.print("teruwm: exec failed, continuing\n", .{});
}

pub fn deinit(self: *Server) void {
    if (self.wm_mcp) |mcp| mcp.deinit(self.zig_allocator);
    wlr.xkb_context_unref(self.xkb_ctx);
}

// ── Signal handlers ────────────────────────────────────────────

fn handleNewOutput(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_output", listener);
    const wlr_output: *wlr.wlr_output = @ptrCast(@alignCast(data orelse return));

    _ = Output.create(server, wlr_output, server.zig_allocator) catch {
        std.debug.print("teruwm: failed to create output\n", .{});
        return;
    };
    const first = (server.primary_output == null);
    if (first) server.primary_output = wlr_output;

    if (first and !server.autostart_fired) {
        server.autostart_fired = true;
        server.runAutostart();
    }
}

/// Run each command in `wm_config.autostart` via /bin/sh, inheriting env
/// so children see WAYLAND_DISPLAY. Window placement is handled by the
/// `[rules]` table on WM_CLASS match — autostart just launches.
fn runAutostart(self: *Server) void {
    if (self.wm_config.autostart_count == 0) return;
    for (self.wm_config.autostart[0..self.wm_config.autostart_count]) |*entry| {
        const cmd = entry.getCmd();
        std.debug.print("teruwm: autostart → {s}\n", .{cmd});
        self.spawnShell(cmd);
    }
}

fn handleNewInput(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_input", listener);
    const device: *wlr.wlr_input_device = @ptrCast(@alignCast(data orelse return));

    const device_type = wlr.miozu_input_device_type(device);

    if (device_type == wlr.WLR_INPUT_DEVICE_KEYBOARD) {
        server.setupKeyboard(device);
    } else if (device_type == wlr.WLR_INPUT_DEVICE_POINTER) {
        wlr.wlr_cursor_attach_input_device(server.cursor, device);
    }

    // Update seat capabilities
    var caps: u32 = wlr.WL_SEAT_CAPABILITY_POINTER;
    caps |= wlr.WL_SEAT_CAPABILITY_KEYBOARD;
    wlr.wlr_seat_set_capabilities(server.seat, caps);
}

fn handleNewXdgToplevel(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_xdg_toplevel", listener);
    const toplevel: *wlr.wlr_xdg_toplevel = @ptrCast(@alignCast(data orelse return));

    _ = XdgView.create(server, toplevel);
}

/// Client requested focus via xdg_activation_v1. We don't steal focus —
/// we just mark the node urgent so the bar indicator flips and agents
/// polling `teruwm_list_windows` see the flag. Focus-steal-prevention
/// policy matches i3/sway default.
fn handleXdgActivation(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "xdg_activate", listener);
    const ev: *wlr.wlr_xdg_activation_v1_request_activate_event = @ptrCast(@alignCast(data orelse return));
    const surface = wlr.miozu_xdg_activation_event_surface(ev) orelse return;
    const toplevel = wlr.miozu_xdg_toplevel_from_surface(surface) orelse return;
    const slot = server.nodes.findByToplevel(toplevel) orelse return;

    // If this window is already focused, nothing urgent about it.
    if (server.focused_view) |v| {
        if (v.toplevel == toplevel) return;
    }

    if (server.nodes.markUrgent(slot)) {
        std.debug.print("teruwm: urgent node={d} ws={d}\n", .{ server.nodes.node_id[slot], server.nodes.workspace[slot] });
        if (server.bar) |b| b.render(server);
        if (server.primary_output) |out| wlr.wlr_output_schedule_frame(out);
    }
}

fn handleCursorMotion(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_motion", listener);
    const event: *wlr.wlr_pointer_motion_event = @ptrCast(@alignCast(data orelse return));
    wlr.wlr_cursor_move(server.cursor, null, wlr.miozu_pointer_motion_dx(event), wlr.miozu_pointer_motion_dy(event));
    server.processCursorMotion(wlr.miozu_pointer_motion_time(event));
}

fn handleCursorMotionAbsolute(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_motion_absolute", listener);
    const event: *wlr.wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(data orelse return));
    wlr.wlr_cursor_warp_absolute(server.cursor, null, wlr.miozu_pointer_motion_abs_x(event), wlr.miozu_pointer_motion_abs_y(event));
    server.processCursorMotion(wlr.miozu_pointer_motion_abs_time(event));
}

fn handleCursorButton(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_button", listener);
    const event: *wlr.wlr_pointer_button_event = @ptrCast(@alignCast(data orelse return));
    server.processCursorButton(
        wlr.miozu_pointer_button_button(event),
        wlr.miozu_pointer_button_state(event),
        wlr.miozu_pointer_button_time(event),
        null, // null = read actual xkb state
    );
}

/// Pointer button dispatch. Shared by the wlroots listener and the MCP
/// test tools. `super_override = null` reads the live xkb state;
/// `.some(true|false)` forces the Super-held value (used by E2E tests
/// so the drag path works regardless of the synthetic keyboard state).
pub fn processCursorButton(server: *Server, button: u32, state: u32, time: u32, super_override: ?bool) void {
    // Button release: end any active grab
    if (state == 0) {
        if (server.cursor_mode == .border_drag) {
            // Drag ended — do the actual resize (re-render all panes at final size)
            server.arrangeworkspace(server.layout_engine.active_workspace);
        }
        if (server.cursor_mode != .normal) {
            server.cursor_mode = .normal;
            server.grab_node_id = null;
        }
        _ = wlr.wlr_seat_pointer_notify_button(server.seat, time, button, state);
        return;
    }

    // Button press: check for Super modifier to initiate move/resize on floating windows
    const super_held: bool = if (super_override) |v| v else blk: {
        const keyboard = wlr.miozu_seat_get_keyboard(server.seat);
        break :blk if (keyboard) |kb|
            if (wlr.miozu_keyboard_xkb_state(kb)) |xkb_st|
                wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0
            else false
        else false;
    };

    if (super_held) {
        // Identify the pane under the cursor (not necessarily focused).
        // Focused pane is a fallback for clicks not on any pane's rect.
        const cx = wlr.miozu_cursor_x(server.cursor);
        const cy = wlr.miozu_cursor_y(server.cursor);
        const nid: ?u64 = server.nodeAtPoint(cx, cy) orelse
            (if (server.focused_terminal) |tp| tp.node_id
             else if (server.focused_view) |view| view.node_id
             else null);

        if (nid) |id| {
            if (server.nodes.findById(id)) |slot| {
                // Auto-float: if the pane is still tiled, detach it from
                // the layout engine, mark floating, and give it a cursor-
                // anchored rect so the drag starts naturally under the
                // mouse instead of jumping to screen center.
                if (!server.nodes.floating[slot]) {
                    const cur_w = server.nodes.width[slot];
                    const cur_h = server.nodes.height[slot];
                    const float_w: u32 = if (cur_w > 0) cur_w else 640;
                    const float_h: u32 = if (cur_h > 0) cur_h else 480;
                    const fx: i32 = @intFromFloat(cx - @as(f64, @floatFromInt(float_w)) / 2.0);
                    const fy: i32 = @intFromFloat(cy - @as(f64, @floatFromInt(float_h)) / 2.0);

                    server.nodes.floating[slot] = true;
                    server.layout_engine.workspaces[server.layout_engine.active_workspace].removeNode(id);
                    server.nodes.applyRect(slot, fx, fy, float_w, float_h);
                    // Resize terminal pane framebuffer to match new rect
                    if (server.nodes.kind[slot] == .terminal) {
                        for (server.terminal_panes) |maybe_tp| {
                            if (maybe_tp) |tp| {
                                if (tp.node_id == id) {
                                    tp.resize(float_w, float_h);
                                    break;
                                }
                            }
                        }
                    }
                    // Re-tile remaining siblings
                    server.arrangeworkspace(server.layout_engine.active_workspace);
                }

                if (button == 272) { // BTN_LEFT: move
                    server.cursor_mode = .move;
                    server.grab_node_id = id;
                    server.grab_x = cx - @as(f64, @floatFromInt(server.nodes.pos_x[slot]));
                    server.grab_y = cy - @as(f64, @floatFromInt(server.nodes.pos_y[slot]));
                    return;
                } else if (button == 274) { // BTN_RIGHT: resize
                    server.cursor_mode = .resize;
                    server.grab_node_id = id;
                    server.grab_x = cx;
                    server.grab_y = cy;
                    server.grab_w = server.nodes.width[slot];
                    server.grab_h = server.nodes.height[slot];
                    return;
                }
            }
        }
    }

    // Tiled border drag: if click is on the gap between panes, start master ratio resize
    if (state == 1 and !super_held) {
        const ws = server.layout_engine.getActiveWorkspace();
        if (ws.node_ids.items.len >= 2) {
            // Check if cursor is near a pane border (within gap area)
            var on_border = false;
            for (server.terminal_panes) |maybe_tp| {
                if (maybe_tp) |tp| {
                    if (server.nodes.findById(tp.node_id)) |slot| {
                        const px = server.nodes.pos_x[slot];
                        const pw: i32 = @intCast(server.nodes.width[slot]);
                        const right_edge = px + pw;
                        const cursor_x: i32 = @intFromFloat(wlr.miozu_cursor_x(server.cursor));
                        // Within 8px of a right edge = on border
                        if (cursor_x >= right_edge - 2 and cursor_x <= right_edge + 8) {
                            on_border = true;
                            break;
                        }
                    }
                }
            }
            if (on_border) {
                server.cursor_mode = .border_drag;
                server.grab_x = wlr.miozu_cursor_x(server.cursor);
                return;
            }
        }
    }

    // Click-to-focus: find which terminal pane is under the cursor
    if (state == 1) { // press
        const cx = wlr.miozu_cursor_x(server.cursor);
        const cy = wlr.miozu_cursor_y(server.cursor);
        // Check each terminal pane's rect
        for (server.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| {
                if (server.nodes.findById(tp.node_id)) |slot| {
                    const px = server.nodes.pos_x[slot];
                    const py = server.nodes.pos_y[slot];
                    const pw: i32 = @intCast(server.nodes.width[slot]);
                    const ph: i32 = @intCast(server.nodes.height[slot]);
                    if (@as(i32, @intFromFloat(cx)) >= px and @as(i32, @intFromFloat(cx)) < px + pw and
                        @as(i32, @intFromFloat(cy)) >= py and @as(i32, @intFromFloat(cy)) < py + ph)
                    {
                        server.focused_terminal = tp;
                        server.focused_view = null;
                        // Update layout engine focus
                        const ws = server.layout_engine.getActiveWorkspace();
                        for (ws.node_ids.items, 0..) |nid, idx| {
                            if (nid == tp.node_id) {
                                ws.active_index = @intCast(idx);
                                break;
                            }
                        }
                        // Re-render borders + bar
                        for (server.terminal_panes) |mtp| {
                            if (mtp) |t| t.render();
                        }
                        if (server.bar) |b| b.render(server);
                        break;
                    }
                }
            }
        }
    }

    _ = wlr.wlr_seat_pointer_notify_button(server.seat, time, button, state);
}

fn handleCursorAxis(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_axis", listener);
    const event: *wlr.wlr_pointer_axis_event = @ptrCast(@alignCast(data orelse return));

    const orientation = wlr.miozu_pointer_axis_orientation(event);
    const delta = wlr.miozu_pointer_axis_delta(event);

    // Vertical scroll on focused terminal pane
    if (orientation == 0 and server.focused_terminal != null) { // 0 = vertical
        const tp = server.focused_terminal.?;
        const max_offset: u32 = @intCast(tp.pane.scrollback.total_lines);
        if (max_offset > 0) {
            const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
            const scroll_lines: i32 = if (delta > 0) 3 else -3;
            const pixel_delta: i32 = scroll_lines * @as(i32, @intCast(cell_h));

            var new_pixel = tp.pane.scroll_pixel + pixel_delta;
            var new_offset: i32 = @intCast(tp.pane.scroll_offset);
            const ch: i32 = @intCast(cell_h);

            while (new_pixel >= ch) { new_pixel -= ch; new_offset += 1; }
            while (new_pixel < 0) { new_pixel += ch; new_offset -= 1; }

            if (new_offset < 0) { new_offset = 0; new_pixel = 0; }
            if (new_offset > @as(i32, @intCast(max_offset))) { new_offset = @intCast(max_offset); new_pixel = 0; }

            tp.pane.scroll_offset = @intCast(new_offset);
            tp.pane.scroll_pixel = new_pixel;
            tp.pane.grid.dirty = true;
            tp.render();
            return;
        }
    }

    // Forward to Wayland clients if not consumed
    wlr.wlr_seat_pointer_notify_axis(
        server.seat,
        wlr.miozu_pointer_axis_time(event),
        orientation,
        delta,
        wlr.miozu_pointer_axis_delta_discrete(event),
        wlr.miozu_pointer_axis_source(event),
        0, // relative_direction: default
    );
}

fn handleCursorFrame(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_frame", listener);
    wlr.wlr_seat_pointer_notify_frame(server.seat);
}

fn handleNewXwaylandSurface(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_xwayland_surface", listener);
    const surface: *wlr.wlr_xwayland_surface = @ptrCast(@alignCast(data orelse return));
    _ = XwaylandView.create(server, surface);
}

fn handleRequestSetCursor(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "request_set_cursor", listener);
    const event_ptr = data orelse return;
    // Allow the focused client to set the cursor image
    const surface = wlr.miozu_set_cursor_event_surface(event_ptr);
    const hx = wlr.miozu_set_cursor_event_hotspot_x(event_ptr);
    const hy = wlr.miozu_set_cursor_event_hotspot_y(event_ptr);
    if (surface) |s| {
        wlr.wlr_cursor_set_surface(server.cursor, s, hx, hy);
    } else {
        wlr.wlr_cursor_set_surface(server.cursor, null, 0, 0);
    }
}

// ── Keyboard setup ─────────────────────────────────────────────

/// Per-keyboard state — allocated once per keyboard device, freed never
/// (keyboards rarely disconnect). Embeds listeners for O(1) dispatch.
const Keyboard = struct {
    server: *Server,
    wlr_keyboard: *wlr.wlr_keyboard,
    key_listener: wlr.wl_listener,
    modifiers_listener: wlr.wl_listener,

    fn handleKey(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
        const kb: *Keyboard = @fieldParentPtr("key_listener", listener);
        const event_ptr = data orelse return;

        const keycode = wlr.miozu_keyboard_key_keycode(event_ptr);
        const key_state = wlr.miozu_keyboard_key_state(event_ptr);
        const time = wlr.miozu_keyboard_key_time(event_ptr);
        const xkb_st = wlr.miozu_keyboard_xkb_state(kb.wlr_keyboard) orelse return;

        // Only handle keybinds on key press, not release
        if (key_state == 1) {
            if (kb.server.handleKey(keycode, xkb_st)) return;
        }

        // Route to focused terminal pane (convert keysym → UTF-8 → PTY)
        if (kb.server.focused_terminal) |tp| {
            if (key_state == 1) { // press only
                var buf: [8]u8 = undefined;
                const sym = wlr.xkb_state_key_get_one_sym(xkb_st, keycode + 8);
                const ctrl = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_CTRL, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;
                const shift = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;

                // Ctrl+Shift+C: copy cursor line to internal clipboard
                if (ctrl and shift and (sym == 'C' or sym == 'c')) {
                    kb.server.clipboardCopyCursorLine(tp);
                    return;
                }

                // Ctrl+Shift+V: paste internal clipboard to terminal PTY
                if (ctrl and shift and (sym == 'V' or sym == 'v')) {
                    kb.server.clipboardPaste(tp);
                    return;
                }

                // Ctrl+key → control character (Ctrl+C = 0x03, etc.)
                if (ctrl and sym >= 'a' and sym <= 'z') {
                    buf[0] = @intCast(sym - 'a' + 1);
                    tp.writeInput(buf[0..1]);
                } else {
                    // Normal key → UTF-8
                    const len = wlr.xkb_state_key_get_utf8(xkb_st, keycode + 8, &buf, buf.len);
                    if (len > 0) {
                        tp.writeInput(buf[0..@intCast(len)]);
                    }
                }
            }
            return;
        }

        // Forward to focused Wayland client surface
        wlr.wlr_seat_keyboard_notify_key(kb.server.seat, time, keycode, key_state);
    }

    fn handleModifiers(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const kb: *Keyboard = @fieldParentPtr("modifiers_listener", listener);
        wlr.wlr_seat_set_keyboard(kb.server.seat, kb.wlr_keyboard);
        wlr.wlr_seat_keyboard_notify_modifiers(kb.server.seat, wlr.miozu_keyboard_modifiers_ptr(kb.wlr_keyboard));

        // Refresh the layout-name cache so the {keymap} bar widget reflects
        // layout changes (e.g. Ctrl+Shift toggling us ↔ ua).
        kb.server.refreshActiveKeymap(kb.wlr_keyboard);
    }
};

/// Read the currently effective XKB layout CODE (e.g. "us", "ua",
/// "us(dvorak)") from the given keyboard and stash a copy in
/// `active_keymap_name`. Prefers the raw layout code parsed from
/// xkb_keymap_get_as_string (the XKB rules file input, same thing
/// xmobar and polybar display) over the friendly name.
// ── Push widget helpers ─────────────────────────────────────────

/// Upsert a push widget. Returns false only if all slots are full AND
/// no existing slot has the given name. Updates are O(n≤32).
pub fn setPushWidget(self: *Server, name: []const u8, text: []const u8, class: teru.render.PushWidget.Class) bool {
    if (name.len == 0) return false;

    var empty_slot: ?*teru.render.PushWidget.PushWidget = null;
    for (&self.push_widgets) |*pw| {
        if (pw.used and std.mem.eql(u8, pw.name(), name)) {
            writeWidgetText(pw, text, class);
            self.scheduleRender();
            return true;
        }
        if (!pw.used and empty_slot == null) empty_slot = pw;
    }

    const slot = empty_slot orelse return false;
    const n_n = @min(name.len, slot.name_buf.len);
    @memcpy(slot.name_buf[0..n_n], name[0..n_n]);
    slot.name_len = @intCast(n_n);
    slot.used = true;
    writeWidgetText(slot, text, class);
    self.scheduleRender();
    return true;
}

fn writeWidgetText(slot: *teru.render.PushWidget.PushWidget, text: []const u8, class: teru.render.PushWidget.Class) void {
    const t_n = @min(text.len, slot.text_buf.len);
    @memcpy(slot.text_buf[0..t_n], text[0..t_n]);
    slot.text_len = @intCast(t_n);
    slot.class = class;
    slot.last_update_ns = @intCast(teru.compat.monotonicNow());
}

/// Remove a push widget by name. Returns true if found and removed.
pub fn deletePushWidget(self: *Server, name: []const u8) bool {
    for (&self.push_widgets) |*pw| {
        if (pw.used and std.mem.eql(u8, pw.name(), name)) {
            pw.used = false;
            pw.name_len = 0;
            pw.text_len = 0;
            self.scheduleRender();
            return true;
        }
    }
    return false;
}

/// Count currently-registered widgets. Used by teruwm_list_widgets.
pub fn countPushWidgets(self: *const Server) usize {
    var n: usize = 0;
    for (&self.push_widgets) |*pw| if (pw.used) { n += 1; };
    return n;
}

/// Ask wlroots to fire a frame callback on the primary output. Used after
/// any push-widget update so the bar paints the new value without waiting
/// for the next vsync on a dirty terminal pane.
fn scheduleRender(self: *Server) void {
    if (self.primary_output) |out| {
        wlr.wlr_output_schedule_frame(out);
    }
}

pub fn refreshActiveKeymap(self: *Server, keyboard: *wlr.wlr_keyboard) void {
    const st = wlr.miozu_keyboard_xkb_state(keyboard) orelse return;
    const keymap = wlr.xkb_state_get_keymap(st) orelse return;
    const layout_idx = wlr.xkb_state_serialize_layout(st, wlr.XKB_STATE_LAYOUT_EFFECTIVE);

    // Try to extract the short XKB code from the keymap's symbols section.
    // Falls back to the friendly name if parsing fails.
    const short = extractLayoutCode(keymap, layout_idx);
    const name_slice: []const u8 = if (short.len > 0)
        short
    else blk: {
        const name_ptr = wlr.xkb_keymap_layout_get_name(keymap, layout_idx) orelse return;
        break :blk std.mem.sliceTo(name_ptr, 0);
    };

    const n = @min(name_slice.len, self.active_keymap_name_buf.len);
    @memcpy(self.active_keymap_name_buf[0..n], name_slice[0..n]);
    self.active_keymap_name = self.active_keymap_name_buf[0..n];

    if (self.bar) |b| b.render(self);
}

/// Extract the Nth XKB layout code from the keymap's `xkb_symbols` header.
/// Format seen in practice: `pc_us(dvorak)_ua_2_inet(evdev)` — tokens
/// separated by `_`. Layout codes are 2-letter tokens optionally followed
/// by `(variant)`, skipping "pc"/"inet"/bare digits.
/// Returns an empty slice on failure; the caller falls back to the
/// friendly layout name.
/// NOTE: the returned slice points into a scratch buffer owned by the
/// Server (keymap_raw_buf). Valid until the next refreshActiveKeymap.
fn extractLayoutCode(keymap: *wlr.xkb_keymap, target_idx: u32) []const u8 {
    const raw_ptr = wlr.xkb_keymap_get_as_string(keymap, wlr.XKB_KEYMAP_FORMAT_TEXT_V1) orelse return "";
    defer wlr.free(@as(*anyopaque, @ptrCast(raw_ptr)));
    const raw = std.mem.sliceTo(raw_ptr, 0);

    // Find the xkb_symbols "…" line.
    const hdr = "xkb_symbols";
    const hdr_pos = std.mem.indexOf(u8, raw, hdr) orelse return "";
    const q1 = std.mem.indexOfScalarPos(u8, raw, hdr_pos + hdr.len, '"') orelse return "";
    const q2 = std.mem.indexOfScalarPos(u8, raw, q1 + 1, '"') orelse return "";
    const sig = raw[q1 + 1 .. q2]; // e.g. pc_us(dvorak)_ua_2_inet(evdev)

    // Walk tokens split on '_'. Tokens that look like a layout code are
    // 2 lowercase letters, optionally followed by `(variant)`.
    var it = std.mem.splitScalar(u8, sig, '_');
    var idx: u32 = 0;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "pc") or std.mem.eql(u8, tok, "inet")) continue;
        // Skip bare numeric group tokens (e.g. "2")
        if (tok[0] >= '0' and tok[0] <= '9') continue;
        // Must start with two lowercase letters to look like a layout code
        if (tok.len < 2 or !std.ascii.isLower(tok[0]) or !std.ascii.isLower(tok[1])) continue;

        if (idx == target_idx) {
            const n = @min(tok.len, keymap_raw_buf.len);
            @memcpy(keymap_raw_buf[0..n], tok[0..n]);
            return keymap_raw_buf[0..n];
        }
        idx += 1;
    }
    return "";
}

// Scratch buffer for the XKB code returned by extractLayoutCode. Lives
// at module scope so the returned slice stays valid across the xkbcommon
// free() — the caller copies it into Server.active_keymap_name_buf.
var keymap_raw_buf: [32]u8 = undefined;

fn setupKeyboard(self: *Server, device: *wlr.wlr_input_device) void {
    const keyboard = wlr.miozu_input_device_keyboard(device) orelse return;

    // Create keymap from system defaults (respects XKB_DEFAULT_LAYOUT etc.)
    const keymap = wlr.xkb_keymap_new_from_names(self.xkb_ctx, null, 0) orelse return;
    defer wlr.xkb_keymap_unref(keymap);

    _ = wlr.wlr_keyboard_set_keymap(keyboard, keymap);
    wlr.wlr_keyboard_set_repeat_info(keyboard, 25, 600);

    // Allocate per-keyboard state
    const kb = self.zig_allocator.create(Keyboard) catch return;
    kb.* = .{
        .server = self,
        .wlr_keyboard = keyboard,
        .key_listener = .{ .link = .{ .prev = null, .next = null }, .notify = Keyboard.handleKey },
        .modifiers_listener = .{ .link = .{ .prev = null, .next = null }, .notify = Keyboard.handleModifiers },
    };

    wlr.wl_signal_add(wlr.miozu_keyboard_key(keyboard), &kb.key_listener);
    wlr.wl_signal_add(wlr.miozu_keyboard_modifiers(keyboard), &kb.modifiers_listener);

    wlr.wlr_seat_set_keyboard(self.seat, keyboard);

    // Capture the initial layout name for the {keymap} bar widget.
    self.refreshActiveKeymap(keyboard);

    std.debug.print("teruwm: keyboard configured\n", .{});
}

// ── Cursor processing ──────────────────────────────────────────

pub fn processCursorMotion(self: *Server, time: u32) void {
    const cx = wlr.miozu_cursor_x(self.cursor);
    const cy = wlr.miozu_cursor_y(self.cursor);

    // Handle tiled border drag — update ratio, defer layout to frame callback
    if (self.cursor_mode == .border_drag) {
        const out_w: f64 = @floatFromInt(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
        const delta = cx - self.grab_x;
        const ratio_delta: f32 = @floatCast(delta / out_w);
        const ws = self.layout_engine.getActiveWorkspace();
        ws.master_ratio = @max(0.1, @min(0.9, ws.master_ratio + ratio_delta));
        self.grab_x = cx;
        // Defer layout to frame callback — one arrange per vsync, not per motion event
        self.layout_dirty = true;
        if (self.primary_output) |output| wlr.wlr_output_schedule_frame(output);
        return;
    }

    // Handle floating window move/resize
    if (self.cursor_mode == .move) {
        if (self.grab_node_id) |id| {
            if (self.nodes.findById(id)) |slot| {
                const new_x: i32 = @intFromFloat(cx - self.grab_x);
                const new_y: i32 = @intFromFloat(cy - self.grab_y);
                self.nodes.pos_x[slot] = new_x;
                self.nodes.pos_y[slot] = new_y;

                // Update scene graph position
                if (self.nodes.scene_tree[slot]) |tree| {
                    if (wlr.miozu_scene_tree_node(tree)) |node| {
                        wlr.wlr_scene_node_set_position(node, new_x, new_y);
                    }
                }
                // Update terminal pane position
                if (self.nodes.kind[slot] == .terminal) {
                    for (self.terminal_panes) |maybe_tp| {
                        if (maybe_tp) |tp| {
                            if (tp.node_id == id) {
                                tp.setPosition(new_x, new_y);
                                break;
                            }
                        }
                    }
                }
            }
        }
        return;
    }

    if (self.cursor_mode == .resize) {
        if (self.grab_node_id) |id| {
            if (self.nodes.findById(id)) |slot| {
                const dx = cx - self.grab_x;
                const dy = cy - self.grab_y;
                const new_w: u32 = @intCast(@max(100, @as(i64, self.grab_w) + @as(i64, @intFromFloat(dx))));
                const new_h: u32 = @intCast(@max(100, @as(i64, self.grab_h) + @as(i64, @intFromFloat(dy))));
                self.nodes.width[slot] = new_w;
                self.nodes.height[slot] = new_h;

                // Resize xdg toplevel immediately (Wayland clients handle their own rendering)
                if (self.nodes.kind[slot] == .wayland_surface) {
                    if (self.nodes.xdg_toplevel[slot]) |toplevel| {
                        _ = wlr.wlr_xdg_toplevel_set_size(toplevel, new_w, new_h);
                    }
                }
                // Defer terminal pane resize to frame callback (avoids buffer realloc per motion)
                if (self.nodes.kind[slot] == .terminal) {
                    self.resize_pending_id = id;
                    self.resize_pending_w = new_w;
                    self.resize_pending_h = new_h;
                    if (self.primary_output) |output| wlr.wlr_output_schedule_frame(output);
                }
            }
        }
        return;
    }

    // Find surface under cursor via scene graph hit test
    const scene_tree_root = wlr.miozu_scene_tree(self.scene) orelse return;
    const root_node = wlr.miozu_scene_tree_node(scene_tree_root) orelse return;

    var sx: f64 = 0;
    var sy: f64 = 0;
    const node_under = wlr.wlr_scene_node_at(root_node, cx, cy, &sx, &sy);

    if (node_under) |scene_node| {
        // Resolve scene node → wlr_scene_buffer → wlr_scene_surface → wlr_surface
        if (wlr.wlr_scene_buffer_from_node(scene_node)) |buffer| {
            if (wlr.wlr_scene_surface_try_from_buffer(buffer)) |scene_surface| {
                if (wlr.miozu_scene_surface_get_surface(scene_surface)) |surface| {
                    wlr.wlr_seat_pointer_notify_enter(self.seat, surface, sx, sy);
                    wlr.wlr_seat_pointer_notify_motion(self.seat, time, sx, sy);
                    return;
                }
            }
        }
        // Scene node exists but isn't a client surface — show default cursor
        wlr.wlr_cursor_set_xcursor(self.cursor, self.cursor_mgr, "default");
        wlr.wlr_seat_pointer_clear_focus(self.seat);
    } else {
        // No node under cursor — desktop background
        wlr.wlr_cursor_set_xcursor(self.cursor, self.cursor_mgr, "default");
        wlr.wlr_seat_pointer_clear_focus(self.seat);
    }
}

// ── Keyboard handling ──────────────────────────────────────────

/// Called from per-keyboard key listener. Looks up the key in teru's
/// config-driven keybind system and executes the action. Returns true
/// if the key was consumed (not forwarded to client).
pub fn handleKey(self: *Server, keycode: u32, xkb_state_ptr: *wlr.xkb_state) bool {
    // xkb keycodes are offset by 8 from evdev
    const sym = wlr.xkb_state_key_get_one_sym(xkb_state_ptr, keycode + 8);

    // ── VT switching (Ctrl+Alt+F1-F12) — must be handled before anything else ──
    if (sym >= wlr.XKB_KEY_XF86Switch_VT_1 and sym <= wlr.XKB_KEY_XF86Switch_VT_1 + 11) {
        if (self.session) |session| {
            _ = wlr.wlr_session_change_vt(session, @intCast(sym - wlr.XKB_KEY_XF86Switch_VT_1 + 1));
        }
        return true;
    }

    // Convert xkb sym to key for teru's keybind lookup
    // Normalize uppercase ASCII to lowercase for keybind matching.
    // When Shift is held, xkb returns 'J' (0x4A) not 'j' (0x6A).
    // Bindings use lowercase — the shift flag is separate in Mods.
    const key: u32 = if (sym >= 'A' and sym <= 'Z') sym + 32 else if (sym >= 0x20 and sym <= 0x7e) sym else switch (sym) {
        0xff0d => '\r', // Return
        0xff1b => 0x1b, // Escape
        0xff09 => '\t', // Tab
        0xff08 => 0x7f, // BackSpace
        else => sym, // Pass full keysym for XF86/media keys
    };

    // Build modifier flags matching teru's Keybinds.Mods
    var mods = KBMods{};
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_ALT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.alt = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.shift = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_CTRL, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.ctrl = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.super_ = true;

    // ── Launcher mode: intercept all keys (raw keysym, not ASCII) ──
    if (self.launcher.active) {
        if (self.launcher.handleKey(sym, self)) {
            self.renderLauncherBar();
            return true;
        }
    }

    // ── Scratchpad toggle: Alt+RAlt+1-9 ──
    if (mods.alt and mods.ralt and key >= '1' and key <= '9') {
        self.toggleScratchpad(@intCast(key - '1'));
        return true;
    }

    // Lookup in teru's config-driven keybind table (same system standalone teru uses)
    const action = self.keybinds.lookup(.normal, mods, key) orelse return false;

    return self.executeAction(action);
}

/// Execute a keybind action. Shared by both compositor keybinds and
/// terminal pane keybinds (same Action enum, same execution logic).
pub fn executeAction(self: *Server, action: KBAction) bool {
    // Workspace switching
    if (action.workspaceIndex()) |ws| {
        const old_ws = self.layout_engine.active_workspace;
        if (ws == old_ws) return true; // no-op
        self.prev_workspace = old_ws;
        self.layout_engine.switchWorkspace(ws);
        self.setWorkspaceVisibility(old_ws, false);
        self.setWorkspaceVisibility(ws, true);
        self.arrangeworkspace(ws);
        self.updateFocusedTerminal();
        self.maybeFireWorkspaceStartup(ws);
        if (self.bar) |b| b.render(self);
        return true;
    }

    // Move node to workspace
    if (action.moveToIndex()) |ws| {
        const active_ws = self.layout_engine.getActiveWorkspace();
        if (active_ws.getActiveNodeId()) |nid| {
            self.layout_engine.moveNodeToWorkspace(nid, ws) catch {};
            self.arrangeworkspace(self.layout_engine.active_workspace);
            self.arrangeworkspace(ws);
        }
        return true;
    }

    switch (action) {
        .spawn_terminal => {
            self.spawnTerminal(self.layout_engine.active_workspace);
            return true;
        },
        .window_close, .pane_close => {
            self.closeFocused();
            return true;
        },
        .compositor_quit => {
            wlr.wl_display_terminate(self.display);
            return true;
        },
        .compositor_restart => {
            self.execRestart();
            return true;
        },
        .config_reload => {
            self.reloadWmConfig();
            return true;
        },
        .layout_cycle => {
            self.layout_engine.getActiveWorkspace().cycleLayout();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            if (self.bar) |b| b.render(self);
            return true;
        },
        .pane_focus_next => {
            self.layout_engine.getActiveWorkspace().focusNext();
            self.updateFocusedTerminal();
            return true;
        },
        .pane_focus_prev => {
            self.layout_engine.getActiveWorkspace().focusPrev();
            self.updateFocusedTerminal();
            return true;
        },
        .pane_swap_next => {
            self.layout_engine.getActiveWorkspace().swapWithNext();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .pane_swap_prev => {
            self.layout_engine.getActiveWorkspace().swapWithPrev();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .pane_set_master => {
            self.layout_engine.getActiveWorkspace().promoteToMaster();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .pane_swap_master => {
            self.layout_engine.getActiveWorkspace().swapWithMaster();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .pane_rotate_slaves_up => {
            self.layout_engine.getActiveWorkspace().rotateSlaves(true);
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .pane_rotate_slaves_down => {
            self.layout_engine.getActiveWorkspace().rotateSlaves(false);
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .master_count_inc => {
            self.layout_engine.getActiveWorkspace().adjustMasterCount(1);
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .master_count_dec => {
            self.layout_engine.getActiveWorkspace().adjustMasterCount(-1);
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .pane_sink => {
            self.sinkFocused();
            return true;
        },
        .pane_sink_all => {
            self.sinkAllOnActiveWorkspace();
            return true;
        },
        .layout_reset => {
            const ws = self.layout_engine.getActiveWorkspace();
            ws.layout = .master_stack;
            ws.master_count = 1;
            self.arrangeworkspace(self.layout_engine.active_workspace);
            if (self.bar) |b| b.render(self);
            return true;
        },
        .workspace_toggle_last => {
            if (self.prev_workspace) |prev| {
                const old_ws = self.layout_engine.active_workspace;
                if (prev != old_ws) {
                    self.prev_workspace = old_ws;
                    self.layout_engine.switchWorkspace(prev);
                    self.setWorkspaceVisibility(old_ws, false);
                    self.setWorkspaceVisibility(prev, true);
                    self.arrangeworkspace(prev);
                    self.updateFocusedTerminal();
                    if (self.bar) |b| b.render(self);
                }
            }
            return true;
        },
        .workspace_next_nonempty => {
            const start: u8 = self.layout_engine.active_workspace;
            var step: u8 = 1;
            while (step < 10) : (step += 1) {
                const cand: u8 = (start + step) % 10;
                if (self.nodes.countInWorkspace(cand) > 0) {
                    self.prev_workspace = start;
                    self.layout_engine.switchWorkspace(cand);
                    self.setWorkspaceVisibility(start, false);
                    self.setWorkspaceVisibility(cand, true);
                    self.arrangeworkspace(cand);
                    self.updateFocusedTerminal();
                    if (self.bar) |b| b.render(self);
                    break;
                }
            }
            return true;
        },
        .resize_shrink_w => {
            const ws = self.layout_engine.getActiveWorkspace();
            ws.master_ratio = @max(0.1, ws.master_ratio - 0.05);
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .resize_grow_w => {
            const ws = self.layout_engine.getActiveWorkspace();
            ws.master_ratio = @min(0.9, ws.master_ratio + 0.05);
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .split_vertical => {
            self.spawnTerminal(self.layout_engine.active_workspace);
            return true;
        },
        .float_toggle => {
            self.toggleFloat();
            return true;
        },
        .fullscreen_toggle => {
            self.toggleFullscreen();
            return true;
        },
        .launcher_toggle => {
            if (self.launcher.active) {
                self.launcher.deactivate();
                if (self.bar) |b| b.render(self); // restore normal bar
            } else {
                self.launcher.activate();
                self.renderLauncherBar();
            }
            return true;
        },
        .screenshot => {
            self.takeScreenshot();
            return true;
        },
        .screenshot_area => {
            // Uses external slurp + grim, both of which now work thanks
            // to teruwm's wlr-screencopy global. Output lands alongside
            // our own screenshots in $HOME/Pictures/.
            self.spawnShell(
                "mkdir -p \"$HOME/Pictures\" && grim -g \"$(slurp)\" \"$HOME/Pictures/teruwm-area-$(date +%s).png\"",
            );
            return true;
        },
        .screenshot_pane => {
            if (self.focused_terminal) |tp| {
                tp.render();
                var path_buf: [256:0]u8 = undefined;
                const ts = teru.compat.monotonicNow();
                const name = if (self.nodes.findById(tp.node_id)) |s| self.nodes.getName(s) else "pane";
                const path = std.fmt.bufPrint(&path_buf, "/tmp/teruwm-pane-{s}-{d}.png", .{ name, ts }) catch return true;
                path_buf[path.len] = 0;
                const png = teru.png;
                png.write(self.zig_allocator, @ptrCast(path_buf[0..path.len :0]), tp.renderer.framebuffer, tp.renderer.width, tp.renderer.height) catch return true;
                std.debug.print("teruwm: pane screenshot → {s}\n", .{path});
            }
            return true;
        },
        .bar_toggle_top => {
            if (self.bar) |b| {
                b.top.enabled = !b.top.enabled;
                b.updateVisibility();
                if (b.top.enabled) b.render(self);
                for (0..self.layout_engine.workspaces.len) |ws| {
                    self.arrangeworkspace(@intCast(ws));
                }
            }
            return true;
        },
        .bar_toggle_bottom => {
            if (self.bar) |b| {
                b.bottom.enabled = !b.bottom.enabled;
                b.updateVisibility();
                if (b.bottom.enabled) b.render(self);
                for (0..self.layout_engine.workspaces.len) |ws| {
                    self.arrangeworkspace(@intCast(ws));
                }
            }
            return true;
        },
        .volume_up => {
            self.spawnProcess("wpctl set-volume @DEFAULT_SINK@ 5%+");
            return true;
        },
        .volume_down => {
            self.spawnProcess("wpctl set-volume @DEFAULT_SINK@ 5%-");
            return true;
        },
        .volume_mute => {
            self.spawnProcess("wpctl set-mute @DEFAULT_SINK@ toggle");
            return true;
        },
        .brightness_up => {
            self.spawnProcess("brightnessctl set +5%");
            return true;
        },
        .brightness_down => {
            self.spawnProcess("brightnessctl set 5%-");
            return true;
        },
        .media_play => {
            self.spawnProcess("playerctl play-pause");
            return true;
        },
        .media_next => {
            self.spawnProcess("playerctl next");
            return true;
        },
        .media_prev => {
            self.spawnProcess("playerctl previous");
            return true;
        },
        .scroll_up_1, .scroll_up_half => {
            if (self.focused_terminal) |tp| {
                const lines: u32 = if (action == .scroll_up_half) tp.pane.grid.rows / 2 else 1;
                const max_offset: u32 = @intCast(tp.pane.scrollback.total_lines);
                if (max_offset > 0) {
                    tp.pane.scroll_offset = @min(tp.pane.scroll_offset + lines, max_offset);
                    tp.pane.scroll_pixel = 0;
                    tp.pane.grid.dirty = true;
                    tp.render();
                }
            }
            return true;
        },
        .scroll_down_1, .scroll_down_half => {
            if (self.focused_terminal) |tp| {
                const lines: u32 = if (action == .scroll_down_half) tp.pane.grid.rows / 2 else 1;
                tp.pane.scroll_offset -|= lines;
                tp.pane.scroll_pixel = 0;
                tp.pane.grid.dirty = true;
                tp.render();
            }
            return true;
        },
        .scroll_top => {
            if (self.focused_terminal) |tp| {
                const max_offset: u32 = @intCast(tp.pane.scrollback.total_lines);
                tp.pane.scroll_offset = max_offset;
                tp.pane.scroll_pixel = 0;
                tp.pane.grid.dirty = true;
                tp.render();
            }
            return true;
        },
        .scroll_bottom => {
            if (self.focused_terminal) |tp| {
                tp.pane.scroll_offset = 0;
                tp.pane.scroll_pixel = 0;
                tp.pane.grid.dirty = true;
                tp.render();
            }
            return true;
        },
        else => {
            // User-defined spawn chord? Each spawn_N action variant
            // resolves to spawn_table[N] if that slot is populated.
            const tag: u8 = @intFromEnum(action);
            const first: u8 = @intFromEnum(KBAction.spawn_0);
            const last: u8 = @intFromEnum(KBAction.spawn_31);
            if (tag >= first and tag <= last) {
                const slot: u8 = tag - first;
                const len: usize = self.spawn_table_len[slot];
                if (len > 0) {
                    self.spawnShell(self.spawn_table[slot][0..len]);
                }
                return true;
            }
            return false;
        },
    }
}

/// Un-float the focused node if it's currently floating. Reversed by
/// another float_toggle. Mirrors xmonad's W.sink on one window.
pub fn sinkFocused(self: *Server) void {
    const active_ws = self.layout_engine.getActiveWorkspace();
    const nid = active_ws.getActiveNodeId() orelse return;
    const slot = self.nodes.findById(nid) orelse return;
    if (!self.nodes.floating[slot]) return;
    self.nodes.floating[slot] = false;
    self.layout_engine.workspaces[self.layout_engine.active_workspace].addNode(self.zig_allocator, nid) catch {};
    self.arrangeworkspace(self.layout_engine.active_workspace);
}

/// Sink every floating node on the active workspace back into tiling.
/// Skips scratchpads (they live outside the tiled node list).
pub fn sinkAllOnActiveWorkspace(self: *Server) void {
    const ws_index = self.layout_engine.active_workspace;
    var changed = false;
    for (0..NodeRegistry.max_nodes) |i| {
        if (self.nodes.kind[i] == .empty) continue;
        if (self.nodes.workspace[i] != ws_index) continue;
        if (!self.nodes.floating[i]) continue;
        const nid = self.nodes.node_id[i];
        self.nodes.floating[i] = false;
        self.layout_engine.workspaces[ws_index].addNode(self.zig_allocator, nid) catch continue;
        changed = true;
    }
    if (changed) self.arrangeworkspace(ws_index);
}

// ── Tiling ─────────────────────────────────────────────────────

/// Recalculate layout for a workspace and apply rects to all scene nodes.
pub fn arrangeworkspace(self: *Server, ws_index: u8) void {
    // Get dimensions from the primary output, minus status bar height
    const w: u16 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const full_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
    const bar_h: u32 = if (self.bar) |b| b.totalHeight() else 0;
    const bar_y_offset: i32 = if (self.bar) |b| @intCast(b.tilingOffsetY()) else 0;
    const h: u16 = @intCast(@max(1, full_h - bar_h));

    // Pre-inset screen by half-gap so edge gaps equal inter-pane gaps.
    // Layout divides the inset area; post-processing adds another hg per side.
    // Result: edges = hg + hg = gap, between panes = hg + hg = gap.
    const g: i32 = @intCast(self.wm_config.gap);
    const hg: i32 = @divTrunc(g, 2);
    const screen = LayoutEngine.Rect{
        .x = @intCast(@as(i32, 0) + hg),
        .y = @intCast(bar_y_offset + hg),
        .width = if (w > @as(u16, @intCast(g))) w - @as(u16, @intCast(g)) else w,
        .height = if (h > @as(u16, @intCast(g))) h - @as(u16, @intCast(g)) else h,
    };

    const rects = self.layout_engine.calculate(ws_index, screen) catch return;
    defer self.zig_allocator.free(rects);

    const ws = &self.layout_engine.workspaces[ws_index];
    const node_ids = ws.node_ids.items;

    for (node_ids, 0..) |nid, i| {
        if (i >= rects.len) break;
        if (self.nodes.findById(nid)) |slot| {
            // Each pane inset by hg on all sides — combined with pre-inset,
            // this gives uniform gap at edges and between panes.
            const rx = rects[i].x + hg;
            const ry = rects[i].y + hg;
            const gu16: u16 = @intCast(g);
            const rw: u16 = if (rects[i].width > gu16) rects[i].width - gu16 else rects[i].width;
            const rh: u16 = if (rects[i].height > gu16) rects[i].height - gu16 else rects[i].height;
            self.nodes.applyRect(slot, rx, ry, rw, rh);

            // Resize terminal panes to match their assigned rect
            if (self.nodes.kind[slot] == .terminal) {
                for (self.terminal_panes) |maybe_tp| {
                    if (maybe_tp) |tp| {
                        if (tp.node_id == nid) {
                            tp.resize(rw, rh);
                            tp.setPosition(rx, ry);
                            // Force repaint so smart-border state (count changed,
                            // solo → shared or vice versa) gets reflected even
                            // when the rect didn't change.
                            tp.pane.grid.dirty = true;
                            break;
                        }
                    }
                }
            }
        }
    }
}

/// Smooth arrange: reposition + scale scene buffers WITHOUT resizing terminal grids.
/// Used during drag for instant visual feedback. Actual resize happens on release.
pub fn arrangeWorkspaceSmooth(self: *Server, ws_index: u8) void {
    const w: u16 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const full_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
    const bar_h: u32 = if (self.bar) |b| b.totalHeight() else 0;
    const bar_y_offset: i32 = if (self.bar) |b| @intCast(b.tilingOffsetY()) else 0;
    const h: u16 = @intCast(@max(1, full_h - bar_h));

    const g: i32 = @intCast(self.wm_config.gap);
    const hg: i32 = @divTrunc(g, 2);
    const screen = LayoutEngine.Rect{
        .x = @intCast(@as(i32, 0) + hg),
        .y = @intCast(bar_y_offset + hg),
        .width = if (w > @as(u16, @intCast(g))) w - @as(u16, @intCast(g)) else w,
        .height = if (h > @as(u16, @intCast(g))) h - @as(u16, @intCast(g)) else h,
    };

    const rects = self.layout_engine.calculate(ws_index, screen) catch return;
    defer self.zig_allocator.free(rects);

    const ws = &self.layout_engine.workspaces[ws_index];
    const node_ids = ws.node_ids.items;

    for (node_ids, 0..) |nid, i| {
        if (i >= rects.len) break;
        const rx = rects[i].x + hg;
        const ry = rects[i].y + hg;
        const gu16: u16 = @intCast(g);
        const rw: u16 = if (rects[i].width > gu16) rects[i].width - gu16 else rects[i].width;
        const rh: u16 = if (rects[i].height > gu16) rects[i].height - gu16 else rects[i].height;

        // Only reposition + scale — don't resize grid/PTY
        for (self.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| {
                if (tp.node_id == nid) {
                    tp.setPosition(rx, ry);
                    // Scale existing pixels to new size (no re-render)
                    wlr.wlr_scene_buffer_set_dest_size(tp.scene_buffer, @intCast(rw), @intCast(rh));
                    break;
                }
            }
        }

        if (self.nodes.findById(nid)) |slot| {
            self.nodes.pos_x[slot] = rx;
            self.nodes.pos_y[slot] = ry;
            self.nodes.width[slot] = rw;
            self.nodes.height[slot] = rh;
        }
    }
}

/// Focus a view — activate its toplevel and send keyboard focus.
pub fn focusView(self: *Server, view: *XdgView) void {
    // Deactivate previous
    if (self.focused_view) |prev| {
        _ = wlr.wlr_xdg_toplevel_set_activated(prev.toplevel, false);
    }

    // Activate new — clear terminal focus, external view gets keyboard
    _ = wlr.wlr_xdg_toplevel_set_activated(view.toplevel, true);
    self.focused_view = view;
    self.focused_terminal = null;

    // Clear urgency on focus gain
    if (self.nodes.findByToplevel(view.toplevel)) |slot| {
        _ = self.nodes.clearUrgent(slot);
    }

    // Send keyboard focus to the surface
    const surface = wlr.miozu_xdg_surface_surface(
        wlr.miozu_xdg_toplevel_base(view.toplevel) orelse return,
    ) orelse return;
    wlr.wlr_seat_keyboard_notify_enter(self.seat, surface, null, 0, null);

    if (self.bar) |b| b.render(self);
}

// ── Terminal pane management ───────────────────────────────────

/// Spawn an embedded terminal pane on the given workspace, sized to fill the output.
pub fn spawnTerminal(self: *Server, ws: u8) void {
    // Create at default size — arrangeworkspace will resize to fit the layout
    const tp = TerminalPane.create(self, ws, 24, 80) orelse {
        std.debug.print("teruwm: failed to spawn terminal pane\n", .{});
        return;
    };

    // Store in terminal_panes array FIRST (before arrangeworkspace)
    for (&self.terminal_panes) |*slot| {
        if (slot.* == null) {
            slot.* = tp;
            self.terminal_count += 1;
            break;
        }
    }

    // NOW arrange — all panes including the new one are findable
    self.arrangeworkspace(ws);

    // Focus the new terminal
    self.focused_terminal = tp;
    self.focused_view = null;

    // Re-render all panes (borders update for new focus)
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |t| t.render();
    }
    if (self.bar) |b| b.render(self);
}

// ── Clipboard (internal buffer for Ctrl+Shift+C/V) ───────────

/// Copy the cursor line from a terminal pane into the internal clipboard buffer.
/// Extracts the full line at the cursor row, trimming trailing whitespace.
fn clipboardCopyCursorLine(self: *Server, tp: *TerminalPane) void {
    const grid = &tp.pane.grid;
    const row = grid.cursor_row;
    var pos: usize = 0;

    var col: u16 = 0;
    while (col < grid.cols) : (col += 1) {
        const cell = grid.cellAtConst(row, col);
        const cp = cell.char;
        // Encode codepoint as UTF-8 into clipboard_buf
        if (cp < 0x80) {
            if (pos < self.clipboard_buf.len) {
                self.clipboard_buf[pos] = @intCast(cp);
                pos += 1;
            }
        } else if (cp < 0x800) {
            if (pos + 2 <= self.clipboard_buf.len) {
                self.clipboard_buf[pos] = @intCast(0xC0 | (cp >> 6));
                self.clipboard_buf[pos + 1] = @intCast(0x80 | (cp & 0x3F));
                pos += 2;
            }
        } else if (cp < 0x10000) {
            if (pos + 3 <= self.clipboard_buf.len) {
                self.clipboard_buf[pos] = @intCast(0xE0 | (cp >> 12));
                self.clipboard_buf[pos + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                self.clipboard_buf[pos + 2] = @intCast(0x80 | (cp & 0x3F));
                pos += 3;
            }
        } else {
            if (pos + 4 <= self.clipboard_buf.len) {
                self.clipboard_buf[pos] = @intCast(0xF0 | (cp >> 18));
                self.clipboard_buf[pos + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
                self.clipboard_buf[pos + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                self.clipboard_buf[pos + 3] = @intCast(0x80 | (cp & 0x3F));
                pos += 4;
            }
        }
    }

    // Trim trailing spaces
    while (pos > 0 and self.clipboard_buf[pos - 1] == ' ') {
        pos -= 1;
    }

    self.clipboard_len = @intCast(@min(pos, std.math.maxInt(u16)));
    std.debug.print("teruwm: clipboard copy ({d} bytes)\n", .{self.clipboard_len});
}

/// Paste internal clipboard buffer to a terminal pane's PTY.
/// Wraps with bracketed paste escape sequences if the terminal has it enabled.
fn clipboardPaste(self: *Server, tp: *TerminalPane) void {
    if (self.clipboard_len == 0) return;

    const data = self.clipboard_buf[0..self.clipboard_len];

    if (tp.pane.vt.bracketed_paste) {
        tp.writeInput("\x1b[200~");
    }
    tp.writeInput(data);
    if (tp.pane.vt.bracketed_paste) {
        tp.writeInput("\x1b[201~");
    }

    std.debug.print("teruwm: clipboard paste ({d} bytes)\n", .{self.clipboard_len});
}

/// Poll all terminal panes for PTY output. Called from the event loop.
/// Returns true if any pane produced output (needs re-render).
pub fn pollTerminals(self: *Server) bool {
    var any_output = false;
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            if (tp.poll()) any_output = true;
        }
    }
    return any_output;
}

// ── Launcher bar rendering ─────────────────────────────────────

fn renderLauncherBar(self: *Server) void {
    if (self.bar) |b| {
        if (self.launcher.active) {
            // Render launcher UI into the top bar's buffer
            self.launcher.render(&b.top.renderer);
            wlr.wlr_scene_buffer_set_buffer_with_damage(b.top.scene_buffer, b.top.pixel_buffer, null);
        } else {
            b.render(self); // restore normal bar
        }
    }
}

// ── Workspace visibility ──────────────────────────────────────

/// Show or hide all nodes in a workspace.
pub fn setWorkspaceVisibility(self: *Server, ws: u8, visible: bool) void {
    const ws_nodes = self.layout_engine.workspaces[ws].node_ids.items;
    for (ws_nodes) |nid| {
        // Terminal panes
        for (self.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| {
                if (tp.node_id == nid) tp.setVisible(visible);
            }
        }
        // External views: handled by the scene tree (XdgView nodes)
        if (self.nodes.findById(nid)) |slot| {
            if (self.nodes.kind[slot] == .wayland_surface) {
                if (self.nodes.scene_tree[slot]) |tree| {
                    if (wlr.miozu_scene_tree_node(tree)) |node| {
                        wlr.wlr_scene_node_set_enabled(node, visible);
                    }
                }
            }
        }
    }
}

// ── Float toggle ────────────────────────────────────────────

/// Toggle the focused node between floating and tiled.
/// Floating nodes are removed from the LayoutEngine workspace (not tiled)
/// but remain in the NodeRegistry for rendering. Tiling nodes are added
/// back to the workspace and re-arranged.
fn toggleFloat(self: *Server) void {
    // Determine the focused node ID
    const nid: u64 = if (self.focused_terminal) |tp|
        tp.node_id
    else if (self.focused_view) |view|
        view.node_id
    else
        return;

    const slot = self.nodes.findById(nid) orelse return;
    const ws = self.layout_engine.active_workspace;

    if (self.nodes.floating[slot]) {
        // ── Unfloat: add back to tiling ──
        self.nodes.floating[slot] = false;
        self.layout_engine.workspaces[ws].addNode(self.zig_allocator, nid) catch {};
        self.arrangeworkspace(ws);
        std.debug.print("teruwm: unfloat node={d}\n", .{nid});
    } else {
        // ── Float: remove from tiling, keep in registry ──
        self.nodes.floating[slot] = true;
        self.layout_engine.workspaces[ws].removeNode(nid);
        self.arrangeworkspace(ws);

        // Center the floating window at 50% of output size
        const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
        const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
        const float_w: u32 = out_w / 2;
        const float_h: u32 = out_h / 2;
        const float_x: i32 = @intCast(out_w / 4);
        const float_y: i32 = @intCast(out_h / 4);

        self.nodes.applyRect(slot, float_x, float_y, float_w, float_h);

        // Also resize terminal pane if applicable
        if (self.nodes.kind[slot] == .terminal) {
            if (self.focused_terminal) |tp| {
                tp.resize(float_w, float_h);
                tp.setPosition(float_x, float_y);
            }
        }

        std.debug.print("teruwm: float node={d}\n", .{nid});
    }

    if (self.bar) |b| b.render(self);
}

// ── Fullscreen ───────────────────────────────────────────────

/// Toggle the focused terminal pane to fill the entire output.
/// When entering fullscreen: hide bars, hide other panes, expand focused pane.
/// When leaving fullscreen: restore bars, re-arrange workspace.
fn toggleFullscreen(self: *Server) void {
    if (self.fullscreen_node != null) {
        // ── Exit fullscreen ──
        self.fullscreen_node = null;

        // Restore bar visibility
        if (self.bar) |b| {
            b.top.enabled = self.fullscreen_prev_bar_top;
            b.bottom.enabled = self.fullscreen_prev_bar_bottom;
            if (b.top.enabled) {
                if (wlr.miozu_scene_buffer_node(b.top.scene_buffer)) |node| {
                    wlr.wlr_scene_node_set_enabled(node, true);
                }
            }
            if (b.bottom.enabled) {
                if (wlr.miozu_scene_buffer_node(b.bottom.scene_buffer)) |node| {
                    wlr.wlr_scene_node_set_enabled(node, true);
                }
            }
        }

        // Show all panes in the active workspace
        const ws = self.layout_engine.active_workspace;
        self.setWorkspaceVisibility(ws, true);

        // Re-tile (respects bar height again)
        self.arrangeworkspace(ws);
        if (self.bar) |b| b.render(self);

        std.debug.print("teruwm: fullscreen off\n", .{});
        return;
    }

    // ── Enter fullscreen ──
    const tp = self.focused_terminal orelse return;

    self.fullscreen_node = tp.node_id;

    // Save and hide bars
    if (self.bar) |b| {
        self.fullscreen_prev_bar_top = b.top.enabled;
        self.fullscreen_prev_bar_bottom = b.bottom.enabled;
        if (wlr.miozu_scene_buffer_node(b.top.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_enabled(node, false);
        }
        if (wlr.miozu_scene_buffer_node(b.bottom.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_enabled(node, false);
        }
    }

    // Hide all other panes in the workspace
    const ws = self.layout_engine.active_workspace;
    const ws_nodes = self.layout_engine.workspaces[ws].node_ids.items;
    for (ws_nodes) |nid| {
        if (nid == tp.node_id) continue;
        for (self.terminal_panes) |maybe_tp| {
            if (maybe_tp) |other_tp| {
                if (other_tp.node_id == nid) other_tp.setVisible(false);
            }
        }
        // Also hide external views
        if (self.nodes.findById(nid)) |slot| {
            if (self.nodes.kind[slot] == .wayland_surface) {
                if (self.nodes.scene_tree[slot]) |tree| {
                    if (wlr.miozu_scene_tree_node(tree)) |node| {
                        wlr.wlr_scene_node_set_enabled(node, false);
                    }
                }
            }
        }
    }

    // Expand focused pane to fill entire output (no bar, no gaps)
    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
    tp.resize(out_w, out_h);
    tp.setPosition(0, 0);

    std.debug.print("teruwm: fullscreen on node={d}\n", .{tp.node_id});
}

// ── Scratchpads ───────────────────────────────────────────────

/// Toggle a numbered scratchpad (0-8, mapped from keys 1-9).
/// Creates the terminal pane on first toggle. Subsequent toggles show/hide.
/// Scratchpads are floating — not part of workspace tiling.
pub fn toggleScratchpad(self: *Server, index: u8) void {
    if (index >= 9) return;

    // Create on first use
    if (self.scratchpads[index] == null) {
        // 3x3 grid positions (same as XMonad config)
        const positions = [9][2]f32{
            .{ 0.1, 0.1 }, .{ 0.3, 0.1 }, .{ 0.5, 0.1 },
            .{ 0.1, 0.3 }, .{ 0.3, 0.3 }, .{ 0.5, 0.3 },
            .{ 0.1, 0.5 }, .{ 0.3, 0.5 }, .{ 0.5, 0.5 },
        };
        const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
        const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
        const sp_w: u32 = out_w * 35 / 100; // 35% width
        const sp_h: u32 = out_h * 40 / 100; // 40% height
        const cell_w: u32 = if (self.font_atlas) |fa| fa.cell_width else 8;
        const cell_h: u32 = if (self.font_atlas) |fa| fa.cell_height else 16;
        const cols: u16 = @intCast(@max(1, sp_w / cell_w));
        const rows: u16 = @intCast(@max(1, sp_h / cell_h));

        // Create scratchpad terminal (not added to any workspace's tiling)
        const tp = TerminalPane.createFloating(self, rows, cols) orelse return;
        self.scratchpads[index] = tp;

        // Position it (goes through setPosition so tp.pos_x/y stay in sync
        // — the screenshot compositor reads them directly).
        const pos_x: i32 = @intFromFloat(positions[index][0] * @as(f32, @floatFromInt(out_w)));
        const pos_y: i32 = @intFromFloat(positions[index][1] * @as(f32, @floatFromInt(out_h)));
        tp.setPosition(pos_x, pos_y);

        self.scratchpad_visible[index] = true;
        self.focused_terminal = tp;
        self.focused_view = null;
        std.debug.print("teruwm: scratchpad {d} created\n", .{index + 1});
        return;
    }

    // Toggle visibility
    self.scratchpad_visible[index] = !self.scratchpad_visible[index];
    if (self.scratchpads[index]) |tp| {
        if (wlr.miozu_scene_buffer_node(tp.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_enabled(node, self.scratchpad_visible[index]);
        }
        if (self.scratchpad_visible[index]) {
            self.focused_terminal = tp;
            self.focused_view = null;
            tp.render(); // re-render in case content changed while hidden
        }
    }
}

// ── Terminal lifecycle ─────────────────────────────────────────

/// Handle terminal pane exit (shell process died).
/// Close a window (terminal pane or XDG view) by node_id.
/// Returns true if a window was closed.
/// Hit-test: return the node_id of the pane whose rect contains (x, y),
/// or null. Floating panes win over tiled because they render on top in
/// the scene graph. Linear scan — fine given the node count budget.
pub fn nodeAtPoint(self: *const Server, x: f64, y: f64) ?u64 {
    var best_floating: ?u64 = null;
    var best_tiled: ?u64 = null;
    const ix: i32 = @intFromFloat(x);
    const iy: i32 = @intFromFloat(y);
    const cur_ws = self.layout_engine.active_workspace;

    for (0..NodeRegistry.max_nodes) |slot| {
        if (self.nodes.kind[slot] == .empty) continue;
        if (self.nodes.workspace[slot] != cur_ws) continue;
        const px = self.nodes.pos_x[slot];
        const py = self.nodes.pos_y[slot];
        const pw: i32 = @intCast(self.nodes.width[slot]);
        const ph: i32 = @intCast(self.nodes.height[slot]);
        if (ix < px or ix >= px + pw) continue;
        if (iy < py or iy >= py + ph) continue;
        if (self.nodes.floating[slot]) {
            best_floating = self.nodes.node_id[slot];
        } else {
            best_tiled = self.nodes.node_id[slot];
        }
    }
    return best_floating orelse best_tiled;
}

pub fn closeNode(self: *Server, node_id: u64) bool {
    // Try terminal pane first
    for (&self.terminal_panes, 0..) |*slot, i| {
        _ = i;
        if (slot.*) |tp| {
            if (tp.node_id == node_id) {
                const ws = if (self.nodes.findById(node_id)) |s| self.nodes.workspace[s] else self.layout_engine.active_workspace;
                self.layout_engine.workspaces[ws].removeNode(node_id);
                if (self.nodes.findById(node_id)) |_| _ = self.nodes.remove(node_id);

                tp.deinit(self.zig_allocator);
                self.zig_allocator.destroy(tp);
                slot.* = null;
                self.terminal_count -|= 1;
                self.arrangeworkspace(ws);
                self.updateFocusedTerminal();
                if (self.bar) |b| b.render(self);
                return true;
            }
        }
    }

    // XDG view: find the view with matching node_id and send close request
    if (self.focused_view) |view| {
        if (view.node_id == node_id) {
            wlr.wlr_xdg_toplevel_send_close(view.toplevel);
            return true;
        }
    }
    // Search all XDG views for node_id match (walk the scene? no tracking, so
    // we need to iterate differently). For now, handle only focused_view —
    // MCP callers close by node_id through NodeRegistry instead.
    return false;
}

/// Close whatever window is currently focused (terminal pane or XDG view).
/// Bound to Win+X. No-op if nothing focused.
pub fn closeFocused(self: *Server) void {
    if (self.focused_view) |view| {
        wlr.wlr_xdg_toplevel_send_close(view.toplevel);
        return;
    }
    if (self.focused_terminal) |tp| {
        _ = self.closeNode(tp.node_id);
    }
}

pub fn handleTerminalExit(self: *Server, tp: *TerminalPane) void {
    std.debug.print("teruwm: terminal exited node={d}\n", .{tp.node_id});

    // Remove from node registry and tiling engine
    _ = self.nodes.remove(tp.node_id);
    for (&self.layout_engine.workspaces) |*ws| {
        ws.removeNode(tp.node_id);
    }

    // DynamicProjects: if this empties any workspace, reset its
    // startup-fired flag so the next visit re-runs its startup hook.
    for (0..10) |ws_i| self.resetWorkspaceStartupIfEmpty(@intCast(ws_i));

    // Remove event source
    if (tp.event_source) |es| {
        _ = wlr.wl_event_source_remove(es);
        tp.event_source = null;
    }

    // Hide scene buffer
    if (wlr.miozu_scene_buffer_node(tp.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, false);
    }

    // Remove from terminal_panes array
    var found_in_tiled = false;
    for (&self.terminal_panes) |*slot| {
        if (slot.* == tp) {
            slot.* = null;
            self.terminal_count -= 1;
            found_in_tiled = true;
            break;
        }
    }

    // Also check scratchpads
    if (!found_in_tiled) {
        for (&self.scratchpads, 0..) |*slot, i| {
            if (slot.* == tp) {
                slot.* = null;
                self.scratchpad_visible[i] = false;
                break;
            }
        }
    }

    // Clear focus if this was focused
    if (self.focused_terminal == tp) {
        self.focused_terminal = null;
        self.updateFocusedTerminal();
    }

    // Re-tile
    self.arrangeworkspace(self.layout_engine.active_workspace);
    if (self.bar) |b| b.render(self);
}

// ── Focus management ──────────────────────────────────────────

/// Update focused_terminal to match the LayoutEngine's active node.
/// Also updates visual focus indicators (border color).
///
/// Prefer `ws.active_node` over `getActiveNodeId()`: floating panes are
/// removed from `node_ids.items` (the tiled list) so `getActiveNodeId`
/// can't see them. `active_node` is the explicit authoritative focus
/// target set by `teruwm_focus_window` and friends — it works for both
/// tiled and floating panes.
pub fn updateFocusedTerminal(self: *Server) void {
    const ws = self.layout_engine.getActiveWorkspace();
    const active_id = ws.active_node orelse ws.getActiveNodeId() orelse return;

    var found = false;
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            if (tp.node_id == active_id) {
                self.focused_terminal = tp;
                self.focused_view = null;
                found = true;
                break;
            }
        }
    }
    if (!found) self.focused_terminal = null;

    // Clear urgency for the newly-focused node, if any.
    if (self.nodes.findById(active_id)) |slot| {
        _ = self.nodes.clearUrgent(slot);
    }

    self.applyFocusOpacity();

    // Re-render ALL visible panes so border colors update immediately
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| tp.render();
    }
    if (self.bar) |b| b.render(self);
}

/// DynamicProjects (v0.4.17). If the workspace we're switching into
/// is empty and has a `startup` command configured, spawn it. The
/// flag tracks "has fired at least once since the workspace last
/// became empty" so revisits during the same session don't re-spawn.
/// When the workspace empties (last pane closed), the flag resets so
/// a fresh visit re-fires (xmonad-ish).
pub fn maybeFireWorkspaceStartup(self: *Server, ws: u8) void {
    if (ws >= 10) return;
    const cmd = self.wm_config.workspace_startup[ws] orelse return;
    if (self.wm_config.workspace_startup_fired[ws]) return;
    if (self.nodes.countInWorkspace(ws) > 0) return;
    self.wm_config.workspace_startup_fired[ws] = true;
    self.spawnShell(cmd);
}

/// Reset the startup-fired flag for a workspace (call when its count
/// drops to zero) so the next visit re-runs the startup hook.
pub fn resetWorkspaceStartupIfEmpty(self: *Server, ws: u8) void {
    if (ws >= 10) return;
    if (self.nodes.countInWorkspace(ws) == 0) {
        self.wm_config.workspace_startup_fired[ws] = false;
    }
}

/// Apply wm_config.unfocused_opacity to every terminal pane's
/// scene_buffer: 1.0 for the focused one, wm_config.unfocused_opacity
/// for the rest. wlroots blends on composite; zero CPU renderer cost.
/// When opacity == 1.0 (default), this is a noop and skipped.
fn applyFocusOpacity(self: *Server) void {
    const op = self.wm_config.unfocused_opacity;
    if (op >= 0.999) {
        // Default: force every buffer back to full opacity in case a
        // prior config change left someone faded.
        for (self.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| wlr.wlr_scene_buffer_set_opacity(tp.scene_buffer, 1.0);
        }
        return;
    }
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            const o: f32 = if (tp == self.focused_terminal) 1.0 else op;
            wlr.wlr_scene_buffer_set_opacity(tp.scene_buffer, o);
        }
    }
}

// ── Process spawning ───────────────────────────────────────────

/// Spawn a shell command detached from the compositor (double-fork to avoid zombies).
/// Uses /bin/sh -c to handle commands with arguments and pipes. Inherits the
/// compositor's environment so children see WAYLAND_DISPLAY, DISPLAY (Xwayland),
/// HOME, etc.
pub fn spawnProcess(_: *Server, cmd: [*:0]const u8) void {
    const pid = std.os.linux.fork();
    if (pid == 0) {
        const pid2 = std.os.linux.fork();
        if (pid2 == 0) {
            // Grandchild: exec via shell to handle args/pipes
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            _ = std.posix.system.execve("/bin/sh", &argv, @ptrCast(envp));
            std.os.linux.exit(1);
        }
        std.os.linux.exit(0);
    }
    if (pid > 0) {
        _ = std.c.waitpid(@intCast(pid), null, 0);
    }
}

/// Same as `spawnProcess` but takes a non-nul-terminated slice. Copies into
/// a stack buffer and nul-terminates. Commands longer than 511 bytes are
/// truncated (matches the config parser's bound).
pub fn spawnShell(self: *Server, cmd: []const u8) void {
    var buf: [512:0]u8 = undefined;
    const n = @min(cmd.len, buf.len);
    @memcpy(buf[0..n], cmd[0..n]);
    buf[n] = 0;
    self.spawnProcess(@ptrCast(&buf));
}

/// Take a screenshot of the entire output and save as PNG.
/// Composites all visible terminal pane framebuffers + bars into a single image.
fn takeScreenshot(self: *Server) void {
    var path_buf: [256:0]u8 = undefined;
    const home = teru.compat.getenv("HOME") orelse "/tmp";
    const timestamp = teru.compat.monotonicNow();
    const path = std.fmt.bufPrint(&path_buf, "{s}/Pictures/screenshot_{d}.png", .{ home, timestamp }) catch return;
    path_buf[path.len] = 0;

    if (self.takeScreenshotToPath(path)) {
        std.debug.print("teruwm: screenshot → {s}\n", .{path});
    }
}

/// Take a screenshot to a specific path. Returns true on success.
pub fn takeScreenshotToPath(self: *Server, path: []const u8) bool {
    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
    const total = @as(usize, out_w) * @as(usize, out_h);
    if (total == 0) return false;

    // Allocate compositing buffer
    const pixels = self.zig_allocator.alloc(u32, total) catch return false;
    defer self.zig_allocator.free(pixels);

    // Clear to configured background color (what the user actually sees in gaps)
    @memset(pixels, self.wm_config.bg_color);

    // Composite visible terminal panes — two passes so floating windows
    // land on top of tiled ones, matching wlroots' scene-graph z-order.
    // Without this, the screenshot tool disagrees with what the real
    // compositor draws, and float/drag E2E snapshots become misleading.
    const ws = self.layout_engine.active_workspace;
    for ([_]bool{ false, true }) |want_floating| {
        for (self.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| {
                const slot = self.nodes.findById(tp.node_id) orelse continue;
                if (self.nodes.workspace[slot] != ws) continue;
                if (self.nodes.floating[slot] != want_floating) continue;
                tp.render();
                blitRect(
                    pixels, out_w, out_h,
                    tp.renderer.framebuffer, tp.renderer.width, tp.renderer.height,
                    self.nodes.pos_x[slot], self.nodes.pos_y[slot],
                );
            }
        }
    }

    // Also composite scratchpads (always floating, always on top when visible).
    // Scratchpads aren't in the NodeRegistry; read position from the pane
    // itself (kept current by setPosition).
    for (&self.scratchpads, 0..) |maybe_tp, i| {
        if (!self.scratchpad_visible[i]) continue;
        if (maybe_tp) |tp| {
            tp.render();
            blitRect(
                pixels, out_w, out_h,
                tp.renderer.framebuffer, tp.renderer.width, tp.renderer.height,
                tp.pos_x, tp.pos_y,
            );
        }
    }

    // Composite top bar
    if (self.bar) |b| {
        if (b.top.enabled) {
            blitRect(pixels, out_w, out_h, b.top.renderer.framebuffer, b.output_width, b.bar_height, 0, 0);
        }
        if (b.bottom.enabled) {
            blitRect(pixels, out_w, out_h, b.bottom.renderer.framebuffer, b.output_width, b.bar_height, 0, @intCast(out_h - b.bar_height));
        }
    }

    // Encode
    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return false;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const png = teru.png;
    png.write(self.zig_allocator, @ptrCast(path_z[0..path.len :0]), pixels, out_w, out_h) catch return false;
    return true;
}

/// Blit a source framebuffer into a destination at the given offset.
fn blitRect(dst: []u32, dst_w: u32, dst_h: u32, src: []const u32, src_w: u32, src_h: u32, off_x: i32, off_y: i32) void {
    if (off_x < 0 or off_y < 0) return;
    const ox: u32 = @intCast(off_x);
    const oy: u32 = @intCast(off_y);

    const rows = @min(src_h, dst_h -| oy);
    const cols = @min(src_w, dst_w -| ox);
    if (rows == 0 or cols == 0) return;

    for (0..rows) |y| {
        const dst_start = (@as(usize, oy) + y) * @as(usize, dst_w) + @as(usize, ox);
        const src_start = y * @as(usize, src_w);
        if (dst_start + cols > dst.len or src_start + cols > src.len) continue;
        @memcpy(dst[dst_start..][0..cols], src[src_start..][0..cols]);
    }
}

// ── Helper ─────────────────────────────────────────────────────

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{
        .link = .{ .prev = null, .next = null },
        .notify = func,
    };
}
