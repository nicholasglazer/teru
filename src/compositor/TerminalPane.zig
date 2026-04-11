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

// ── Construction ───────────────────────────────────────────────

/// Common init: creates Pane + SoftwareRenderer + wlr_scene_buffer.
/// Does NOT register with workspace or node registry — callers do that.
fn init(server: *Server, rows: u16, cols: u16) ?*TerminalPane {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const pixel_w: u32 = @as(u32, cols) * cell_w;
    const pixel_h: u32 = @as(u32, rows) * cell_h;

    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(pixel_w), @intCast(pixel_h)) orelse return null;
    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse return null;
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse return null;

    const spawn_config = Pane.SpawnConfig{};
    var pane = Pane.init(allocator, rows, cols, server.next_node_id, spawn_config) catch return null;

    var renderer = SoftwareRenderer.init(allocator, pixel_w, pixel_h, cell_w, cell_h) catch {
        pane.deinit(allocator);
        return null;
    };

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
    const tp = init(server, rows, cols) orelse return null;

    _ = server.nodes.addTerminal(tp.node_id, ws);
    server.layout_engine.workspaces[ws].addNode(server.zig_allocator, tp.node_id) catch return null;

    std.debug.print("teruwm: terminal pane node={d} ws={d} ({d}x{d})\n", .{ tp.node_id, ws, cols, rows });

    // Don't call arrangeworkspace here — caller does it after adding to terminal_panes[]
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

/// Read PTY output and re-render if dirty.
pub fn poll(self: *TerminalPane) bool {
    const n = self.pane.readAndProcess(&self.read_buf) catch return false;
    if (n == 0) return false;
    self.render();
    return true;
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

    const new_cols: u16 = @intCast(@max(1, pixel_w / cell_w));
    const new_rows: u16 = @intCast(@max(1, pixel_h / cell_h));
    const actual_w = @as(u32, new_cols) * cell_w;
    const actual_h = @as(u32, new_rows) * cell_h;

    // Skip resize if dimensions haven't changed
    if (actual_w == self.renderer.width and actual_h == self.renderer.height) return;

    // Skip unreasonable sizes
    if (actual_w == 0 or actual_h == 0 or actual_w > 8192 or actual_h > 8192) return;

    // Detach old buffer from scene before resizing (prevents stale references)
    wlr.wlr_scene_buffer_set_buffer(self.scene_buffer, null);

    if (!wlr.miozu_pixel_buffer_resize(self.pixel_buffer, @intCast(actual_w), @intCast(actual_h))) return;

    const data = wlr.miozu_pixel_buffer_data(self.pixel_buffer) orelse return;
    const needed = @as(usize, actual_w) * @as(usize, actual_h);
    if (needed == 0) return;

    // Update renderer ATOMICALLY — all three must be consistent
    self.renderer.framebuffer = data[0..needed];
    self.renderer.width = actual_w;
    self.renderer.height = actual_h;

    self.pane.resize(self.server.zig_allocator, new_rows, new_cols) catch return;
    wlr.wlr_scene_buffer_set_dest_size(self.scene_buffer, @intCast(actual_w), @intCast(actual_h));
    self.render();
}

/// Render the terminal grid into the pixel buffer + draw border.
pub fn render(self: *TerminalPane) void {
    self.renderer.render(&self.pane.grid);

    // 2px focus border
    const is_focused = (self.server.focused_terminal == self);
    const border_color: u32 = if (is_focused) 0xFFFF9837 else 0xFF3E4359;
    self.drawBorder(border_color);

    // Signal wlroots that buffer content changed (full damage, NULL region)
    wlr.wlr_scene_buffer_set_buffer_with_damage(self.scene_buffer, self.pixel_buffer, null);
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
    _ = tp.poll();
    return 0;
}

// ── Cleanup ────────────────────────────────────────────────────

pub fn deinit(self: *TerminalPane, allocator: std.mem.Allocator) void {
    if (self.event_source) |es| {
        _ = wlr.wl_event_source_remove(es);
        self.event_source = null;
    }
    self.pane.deinit(allocator);
    wlr.wlr_buffer_drop(self.pixel_buffer);
}
