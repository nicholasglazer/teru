//! Terminal pane for the miozu compositor.
//!
//! Wraps a libteru Pane (PTY + Grid + VtParser) with a SoftwareRenderer
//! and a wlr_scene_buffer. Each terminal pane is an independent scene node
//! that the compositor tiles alongside Wayland client windows.
//!
//! Rendering is zero-copy: SoftwareRenderer writes ARGB pixels directly
//! into a wlr_buffer. On each frame, if the grid is dirty, we re-render
//! and tell wlroots the buffer changed. No intermediate copies.

const std = @import("std");
const teru = @import("teru");
const Pane = teru.Pane;
const Grid = teru.Grid;
const SoftwareRenderer = teru.render.SoftwareRenderer;
const compat = teru.compat;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const TerminalPane = @This();

server: *Server,
pane: Pane,
renderer: SoftwareRenderer,
pixel_buffer: *wlr.wlr_buffer,
scene_buffer: *wlr.wlr_scene_buffer,
node_id: u64,
event_source: ?*wlr.wl_event_source = null,
read_buf: [8192]u8 = undefined,
// Monotonic ns when the pane first observed pane.vt.sync_output = true
// for the current DEC-2026 batch. 0 means "not currently in a batch".
// Used to timeout pathological apps that open a sync batch and never
// close it — the renderer falls through after 150 ms to avoid a
// frozen-pane look.
sync_started_ns: i128 = 0,

// ── Construction ───────────────────────────────────────────────

/// Common init: creates Pane + SoftwareRenderer + wlr_scene_buffer.
/// Does NOT register with workspace or node registry — callers do that.
fn init(server: *Server, rows: u16, cols: u16) ?*TerminalPane {
    return initWithSpawn(server, rows, cols, .{});
}

/// Same as init() but with an explicit SpawnConfig — used by session
/// restore to spawn each pane in its saved cwd running its saved cmd.
fn initWithSpawn(server: *Server, rows: u16, cols: u16, spawn_config: Pane.SpawnConfig) ?*TerminalPane {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const pixel_w: u32 = @as(u32, cols) * cell_w;
    const pixel_h: u32 = @as(u32, rows) * cell_h;

    // Resources acquired in order: pixel_buffer → scene_buffer → pane →
    // renderer → tp. Anything that fails after must roll back everything
    // before it. A plain `orelse return null` leaks; use labelled blocks
    // so each fallible step frees its predecessors explicitly.
    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(pixel_w), @intCast(pixel_h)) orelse return null;

    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };

    var pane = Pane.init(allocator, rows, cols, server.next_node_id, spawn_config) catch {
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };

    var renderer = SoftwareRenderer.init(allocator, pixel_w, pixel_h, cell_w, cell_h) catch {
        pane.deinit(allocator);
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    renderer.padding = 0; // compositor fb is exactly cols*cell_w — no room for padding

    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        const needed = @as(usize, pixel_w) * @as(usize, pixel_h);
        if (needed > 0) renderer.framebuffer = data[0..needed];
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }

    const tp = allocator.create(TerminalPane) catch {
        pane.deinit(allocator);
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };

    const node_id = server.next_node_id;
    server.next_node_id += 1;

    tp.* = .{
        .server = server,
        .pane = pane,
        .renderer = renderer,
        .pixel_buffer = pixel_buffer,
        .scene_buffer = scene_buffer,
        .node_id = node_id,
    };

    tp.pane.linkVt(allocator);

    // Register PTY fd with wlroots event loop
    if (tp.getPtyFd()) |fd| {
        if (wlr.wl_display_get_event_loop(server.display)) |event_loop| {
            tp.event_source = wlr.wl_event_loop_add_fd(event_loop, fd, wlr.WL_EVENT_READABLE, ptyReadable, @ptrCast(tp));
        }
    }

    return tp;
}

/// Create a tiled terminal pane on the given workspace.
/// NOTE: caller MUST add the returned pane to server.terminal_panes[]
/// BEFORE calling arrangeworkspace(), otherwise the pane can't be
/// found for resize/positioning.
pub fn create(server: *Server, ws: u8, rows: u16, cols: u16) ?*TerminalPane {
    return createWithSpawn(server, ws, rows, cols, .{});
}

/// Create a tiled pane with an explicit SpawnConfig (shell, cwd). Used
/// by session restore so each pane re-spawns in its saved cwd.
pub fn createWithSpawn(server: *Server, ws: u8, rows: u16, cols: u16, spawn_config: Pane.SpawnConfig) ?*TerminalPane {
    const tp = initWithSpawn(server, rows, cols, spawn_config) orelse return null;

    const slot = server.nodes.addTerminal(server.zig_allocator, tp.node_id, ws);
    server.layout_engine.workspaces[ws].addNode(server.zig_allocator, tp.node_id) catch return null;

    // Auto-name: "term-{ws}-{id}"
    if (slot) |s| {
        var name_buf: [32]u8 = undefined;
        const auto_name = std.fmt.bufPrint(&name_buf, "term-{d}-{d}", .{ ws, tp.node_id }) catch "term";
        server.nodes.setName(s, auto_name);
    }

    std.debug.print("teruwm: terminal pane node={d} ws={d} ({d}x{d})\n", .{ tp.node_id, ws, cols, rows });

    tp.render();
    return tp;
}

/// Create a terminal pane from a restored Pane (compositor restart).
/// The Pane already has an attached PTY fd with a running shell.
pub fn createRestored(server: *Server, ws: u8, pane: *Pane) ?*TerminalPane {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const pixel_w: u32 = @as(u32, pane.grid.cols) * cell_w;
    const pixel_h: u32 = @as(u32, pane.grid.rows) * cell_h;

    // Same unwind order as initWithSpawn. Pane is caller-owned, not
    // freed on failure here — the caller passes us a pre-attached Pane
    // during hot-restart.
    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(pixel_w), @intCast(pixel_h)) orelse return null;

    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };

    var renderer = SoftwareRenderer.init(allocator, pixel_w, pixel_h, cell_w, cell_h) catch {
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    renderer.padding = 0; // compositor fb is exactly cols*cell_w — no room for padding
    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        const needed = @as(usize, pixel_w) * @as(usize, pixel_h);
        if (needed > 0) renderer.framebuffer = data[0..needed];
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }

    const tp = allocator.create(TerminalPane) catch {
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return null;
    };
    tp.* = .{
        .server = server,
        .pane = pane.*,
        .renderer = renderer,
        .pixel_buffer = pixel_buffer,
        .scene_buffer = scene_buffer,
        .node_id = pane.id,
    };

    tp.pane.linkVt(allocator);

    // Register PTY fd with wlroots event loop
    if (tp.getPtyFd()) |fd| {
        if (wlr.wl_display_get_event_loop(server.display)) |event_loop| {
            tp.event_source = wlr.wl_event_loop_add_fd(event_loop, fd, wlr.WL_EVENT_READABLE, ptyReadable, @ptrCast(tp));
        }
    }

    // Register with node registry and workspace
    const slot = server.nodes.addTerminal(server.zig_allocator, tp.node_id, ws);
    server.layout_engine.workspaces[ws].addNode(server.zig_allocator, tp.node_id) catch {};

    // Auto-name restored pane
    if (slot) |s| {
        var name_buf: [32]u8 = undefined;
        const auto_name = std.fmt.bufPrint(&name_buf, "term-{d}-{d}", .{ ws, tp.node_id }) catch "term";
        server.nodes.setName(s, auto_name);
    }

    // Add to terminal_panes array
    for (server.terminal_panes, 0..) |maybe, i| {
        if (maybe == null) {
            server.terminal_panes[i] = tp;
            server.terminal_count += 1;
            break;
        }
    }
    server.pane_index.put(server.zig_allocator, tp.node_id, tp) catch {};

    tp.render();
    return tp;
}

/// Create a floating terminal pane (scratchpads — not part of workspace tiling).
pub fn createFloating(server: *Server, rows: u16, cols: u16) ?*TerminalPane {
    const tp = init(server, rows, cols) orelse return null;
    tp.render();
    return tp;
}

// ── I/O ────────────────────────────────────────────────────────

/// Read PTY output. Does NOT render — rendering happens in the frame callback
/// to coalesce multiple PTY reads into a single render per vsync.
/// Read PTY data with throttling. Processes up to max_reads_per_tick chunks
/// to prevent heavy output (e.g., Claude AI streaming) from starving mouse/keyboard.
pub fn poll(self: *TerminalPane) bool {
    const max_reads_per_tick = 4; // 4 * 8KB = 32KB max per event loop tick
    var any = false;
    for (0..max_reads_per_tick) |_| {
        const n = self.pane.readAndProcess(&self.read_buf) catch return any;
        if (n == 0) break;
        self.server.perf.recordPtyRead(n);
        any = true;
    }
    return any;
}

/// Incremental render if the grid has pending changes. Called from the frame callback.
/// Only re-renders dirty rows + cursor rows, not the entire grid.
pub fn renderIfDirty(self: *TerminalPane) bool {
    if (!self.pane.grid.dirty) return false;

    // DEC private mode 2026 — synchronized output batch. When the
    // application has opened a batch (ESC[?2026h) and hasn't closed it
    // yet (ESC[?2026l), hold the render. Claude Code + Ink apps +
    // fzf + ratatui rely on this: they paint the next screen state in
    // multiple writes and expect terminals to commit atomically.
    // Without this skip, every intermediate paint lands on screen and
    // the user sees a rapid scroll from top to bottom as the app's UI
    // rebuilds row-by-row. windowed.zig honours this already; the
    // compositor path had regressed since the module split.
    //
    // Safety valve: if an app enters the sync batch and never exits
    // (buggy client, crashed), fall through after ~150 ms so the
    // pane isn't frozen forever. Matches Alacritty's timeout.
    if (self.pane.vt.sync_output) {
        const now = compat.monotonicNow();
        if (self.sync_started_ns == 0) self.sync_started_ns = now;
        if (now - self.sync_started_ns < 150 * std.time.ns_per_ms) return false;
        // Timed out — let the frame render below and reset tracker.
        self.sync_started_ns = 0;
    } else {
        self.sync_started_ns = 0;
    }

    // Capture dirty range BEFORE renderDirty resets it. Convert
    // grid rows → pixel Y via cell_height. If the range is empty
    // (min > max sentinel, see Grid.clearDirty) fall back to full
    // damage — the renderer treats that as "paint everything".
    const grid = &self.pane.grid;
    const ch: c_int = @intCast(self.renderer.cell_height);
    const dirty_y0: c_int = if (grid.dirty_row_min > grid.dirty_row_max)
        -1
    else
        @as(c_int, grid.dirty_row_min) * ch;
    const dirty_y1: c_int = if (grid.dirty_row_min > grid.dirty_row_max)
        -1
    else
        (@as(c_int, grid.dirty_row_max) + 1) * ch;

    self.renderer.renderDirty(grid);

    const border: c_int = if (self.shouldDrawBorder()) blk: {
        const is_focused = (self.server.focused_terminal == self);
        const border_color: u32 = if (is_focused) 0xFFFF9837 else 0xFF3E4359;
        self.drawBorder(border_color);
        break :blk 2; // drawBorder paints a 2-px perimeter.
    } else 0;

    wlr.miozu_scene_buffer_commit_dirty(
        self.scene_buffer,
        self.pixel_buffer,
        @intCast(self.renderer.width),
        @intCast(self.renderer.height),
        dirty_y0,
        dirty_y1,
        border,
    );
    return true;
}

/// Repaint the border only (no grid rerender) and commit.
/// Called on focus state flip — the previous + new focused pane's
/// border colour changes but the cells haven't; a full `render()`
/// here was re-SIMD-blitting thousands of cells for nothing.
pub fn repaintBorderOnly(self: *TerminalPane) void {
    if (!self.shouldDrawBorder()) return;
    const is_focused = (self.server.focused_terminal == self);
    const border_color: u32 = if (is_focused) 0xFFFF9837 else 0xFF3E4359;
    self.drawBorder(border_color);
    // Only the 4 border strips changed — damage region is just those.
    // Pass dirty_y0=-1 so the helper skips the middle-band and unions
    // only the border strips.
    wlr.miozu_scene_buffer_commit_dirty(
        self.scene_buffer,
        self.pixel_buffer,
        @intCast(self.renderer.width),
        @intCast(self.renderer.height),
        0, // dirty_y0 = 0
        0, // dirty_y1 = 0 → middle band is zero-height, skipped
        2,
    );
}

/// Write input to the terminal's PTY.
pub fn writeInput(self: *TerminalPane, data: []const u8) void {
    _ = self.pane.ptyWrite(data) catch {};
}

/// Get the PTY master fd for polling.
pub fn getPtyFd(self: *TerminalPane) ?i32 {
    return switch (self.pane.backend) {
        .local => |p| p.master,
        .remote => null,
    };
}

// ── Rendering ──────────────────────────────────────────────────

/// Resize the terminal pane to fit the given pixel rect.
pub fn resize(self: *TerminalPane, pixel_w: u32, pixel_h: u32) void {
    const cell_w = self.renderer.cell_width;
    const cell_h = self.renderer.cell_height;
    if (cell_w == 0 or cell_h == 0) return;

    // Grid cells must be integer counts, but the framebuffer itself should
    // fill the FULL allocated pixel rect — otherwise the leftover pixels
    // (< one cell) contribute to gap-asymmetry between panes.
    const new_cols: u16 = @intCast(@max(1, pixel_w / cell_w));
    const new_rows: u16 = @intCast(@max(1, pixel_h / cell_h));
    const fb_w = pixel_w;
    const fb_h = pixel_h;

    // Skip resize if dimensions haven't changed
    if (fb_w == self.renderer.width and fb_h == self.renderer.height) return;

    // Skip unreasonable sizes
    if (fb_w == 0 or fb_h == 0 or fb_w > 8192 or fb_h > 8192) return;

    // Detach old buffer from scene before resizing (prevents stale references)
    wlr.wlr_scene_buffer_set_buffer(self.scene_buffer, null);

    if (!wlr.miozu_pixel_buffer_resize(self.pixel_buffer, @intCast(fb_w), @intCast(fb_h))) return;

    const data = wlr.miozu_pixel_buffer_data(self.pixel_buffer) orelse return;
    const needed = @as(usize, fb_w) * @as(usize, fb_h);
    if (needed == 0) return;

    // Update renderer ATOMICALLY — all three must be consistent
    self.renderer.framebuffer = data[0..needed];
    self.renderer.width = fb_w;
    self.renderer.height = fb_h;

    self.pane.resize(self.server.zig_allocator, new_rows, new_cols) catch return;
    wlr.wlr_scene_buffer_set_dest_size(self.scene_buffer, @intCast(fb_w), @intCast(fb_h));
    self.render();
}

/// Render the terminal grid into the pixel buffer + draw border.
pub fn render(self: *TerminalPane) void {
    self.renderer.render(&self.pane.grid);

    if (self.shouldDrawBorder()) {
        const is_focused = (self.server.focused_terminal == self);
        const border_color: u32 = if (is_focused) 0xFFFF9837 else 0xFF3E4359;
        self.drawBorder(border_color);
    }

    // Signal wlroots that buffer content changed (full damage, NULL region)
    wlr.wlr_scene_buffer_set_buffer_with_damage(self.scene_buffer, self.pixel_buffer, null);
}

/// Smart borders: suppress the focus border when this pane is the only
/// window on its workspace. Follows xmonad's smartBorders — a border
/// around the sole visible window carries no information. Scratchpads
/// (not in NodeRegistry) always keep their border so focus between a
/// scratchpad and a lone tiled pane stays visible.
fn shouldDrawBorder(self: *TerminalPane) bool {
    const slot = self.server.nodes.findById(self.node_id) orelse return true;
    const ws = self.server.nodes.workspace[slot];
    return self.server.nodes.countInWorkspace(ws) > 1;
}

fn drawBorder(self: *TerminalPane, color: u32) void {
    const w: usize = self.renderer.width;
    const h: usize = self.renderer.height;
    if (w < 5 or h < 5) return;
    const fb = self.renderer.framebuffer;
    if (fb.len < w * h) return; // safety: buffer must match dimensions

    // Top 2 rows
    @memset(fb[0..@min(w * 2, fb.len)], color);
    // Bottom 2 rows
    if (h >= 2) {
        const bot = (h - 2) * w;
        if (bot + w * 2 <= fb.len) @memset(fb[bot .. bot + w * 2], color);
    }
    // Left 2 cols + right 2 cols (skip top/bottom 2 rows already filled)
    var y: usize = 2;
    while (y < h -| 2) : (y += 1) {
        const row = y * w;
        fb[row] = color;
        fb[row + 1] = color;
        fb[row + w - 1] = color;
        fb[row + w - 2] = color;
    }
}

// ── Scene visibility ───────────────────────────────────────────

pub fn setVisible(self: *TerminalPane, visible: bool) void {
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, visible);
    }
}

pub fn setPosition(self: *TerminalPane, x: i32, y: i32) void {
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_position(node, x, y);
    }
}

// ── Event loop callback ────────────────────────────────────────

fn ptyReadable(_: c_int, mask: u32, data: ?*anyopaque) callconv(.c) c_int {
    const tp: *TerminalPane = @ptrCast(@alignCast(data orelse return 0));
    if (mask & 0x10 != 0) { // WL_EVENT_HANGUP
        tp.server.handleTerminalExit(tp);
        return 0;
    }
    if (tp.poll()) {
        // Grid is dirty — tell wlroots we need a new frame so handleFrame
        // renders the updated content on the next vsync.
        // Multi-output: schedule on every output, since a pane on
        // workspace K is only ever visible on the output showing K.
        // N ≤ 4 in practice, trivial cost. Fall back to primary_output
        // during the init window where outputs[] hasn't populated yet.
        if (tp.server.outputs.items.len > 0) {
            for (tp.server.outputs.items) |o| {
                wlr.wlr_output_schedule_frame(o.wlr_output);
            }
        } else if (tp.server.primary_output) |output| {
            wlr.wlr_output_schedule_frame(output);
        }
    }
    return 0;
}

// ── Cleanup ────────────────────────────────────────────────────

pub fn deinit(self: *TerminalPane, allocator: std.mem.Allocator) void {
    if (self.event_source) |es| {
        _ = wlr.wl_event_source_remove(es);
        self.event_source = null;
    }
    // Hide the scene node without destroying it. Disabling stops the
    // last-painted "ghost" frame from rendering on an otherwise empty
    // workspace, but leaves the scene_buffer in the tree so wlroots'
    // own shutdown walker (wl_display_destroy → scene destroy) is the
    // one to free it. An explicit wlr_scene_node_destroy here triggered
    // a segfault at shutdown — a listener attached to the buffer's
    // internal signals still fired after the Zig pane memory was gone.
    // wlroots handles full teardown correctly; we just need the node
    // invisible between close and display-destroy.
    if (wlr.miozu_scene_buffer_node(self.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, false);
        wlr.wlr_scene_buffer_set_buffer(self.scene_buffer, null);
    }
    self.pane.deinit(allocator);
    wlr.wlr_buffer_drop(self.pixel_buffer);
}
