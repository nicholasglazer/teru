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
const Io = std.Io;
const teru = @import("teru");
const Pane = teru.Pane;
const Grid = teru.Grid;
const SoftwareRenderer = teru.render.SoftwareRenderer;
const FontAtlas = teru.render.FontAtlas;
const Config = teru.Config;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const TerminalPane = @This();

server: *Server,
pane: Pane,
renderer: SoftwareRenderer,
pixel_buffer: *wlr.wlr_buffer,
scene_buffer: *wlr.wlr_scene_buffer,
node_id: u64,
event_source: ?*wlr.wl_event_source = null, // PTY fd registered with wl_event_loop
read_buf: [8192]u8 = undefined, // PTY read buffer (stack, no alloc)

/// Create a terminal pane on the given workspace.
pub fn create(server: *Server, ws: u8, rows: u16, cols: u16) ?*TerminalPane {
    const allocator = server.zig_allocator;

    // Get cell dimensions from shared font atlas (or fallback defaults)
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const pixel_w: u32 = @as(u32, cols) * cell_w;
    const pixel_h: u32 = @as(u32, rows) * cell_h;

    // Create wlr pixel buffer (ARGB8888, zero-copy)
    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(pixel_w), @intCast(pixel_h)) orelse return null;

    // Create scene buffer node under the root scene tree
    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse return null;
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse return null;

    // Create libteru Pane (PTY + Grid + VtParser)
    const spawn_config = Pane.SpawnConfig{};
    var pane = Pane.init(allocator, rows, cols, server.next_node_id, spawn_config) catch return null;

    // Create software renderer targeting the pixel buffer
    var renderer = SoftwareRenderer.init(allocator, pixel_w, pixel_h, cell_w, cell_h) catch {
        pane.deinit(allocator);
        return null;
    };

    // Point the renderer's framebuffer at the wlr pixel buffer data (zero-copy)
    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        renderer.framebuffer = data[0 .. pixel_w * pixel_h];
    }

    // Wire up font atlas for glyph rendering
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }

    // Allocate the TerminalPane wrapper
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

    // Link VtParser to Grid (must be done after struct is in final location)
    tp.pane.linkVt(allocator);

    // Register in node registry and tiling engine
    _ = server.nodes.addTerminal(node_id, ws);
    server.layout_engine.workspaces[ws].addNode(allocator, node_id) catch return null;

    // Register PTY fd with wlroots event loop for automatic polling
    if (tp.getPtyFd()) |fd| {
        const event_loop = wlr.wl_display_get_event_loop(server.display) orelse return tp;
        tp.event_source = wlr.wl_event_loop_add_fd(event_loop, fd, wlr.WL_EVENT_READABLE, ptyReadable, @ptrCast(tp));
    }

    std.debug.print("miozu: terminal pane created node={d} ws={d} ({d}x{d})\n", .{ node_id, ws, cols, rows });

    // Trigger initial tiling
    server.arrangeworkspace(ws);

    return tp;
}

/// Read PTY output and re-render if dirty. Called from the compositor's
/// event loop (or timer). Returns true if the pane produced output.
pub fn poll(self: *TerminalPane) bool {
    const n = self.pane.readAndProcess(&self.read_buf) catch return false;
    if (n == 0) return false;

    // Grid changed — re-render into the pixel buffer
    self.render();
    return true;
}

/// Force a re-render of the terminal grid into the pixel buffer.
pub fn render(self: *TerminalPane) void {
    self.renderer.render(&self.pane.grid);

    // Tell wlroots the buffer content changed
    wlr.wlr_scene_buffer_set_buffer(self.scene_buffer, self.pixel_buffer);
}

/// Get the PTY master fd for polling in the event loop.
pub fn getPtyFd(self: *TerminalPane) ?i32 {
    return switch (self.pane.backend) {
        .local => |p| p.master,
        .remote => null,
    };
}

/// Write input to the terminal's PTY (keyboard input from compositor).
pub fn writeInput(self: *TerminalPane, data: []const u8) void {
    _ = self.pane.ptyWrite(data) catch {};
}

/// wl_event_loop callback: PTY fd is readable → read output and re-render.
/// Called by wlroots' event loop — zero additional polling code needed.
fn ptyReadable(_: c_int, _: u32, data: ?*anyopaque) callconv(.c) c_int {
    const tp: *TerminalPane = @ptrCast(@alignCast(data orelse return 0));
    _ = tp.poll();
    return 0;
}

pub fn deinit(self: *TerminalPane, allocator: std.mem.Allocator) void {
    self.pane.deinit(allocator);
    wlr.wlr_buffer_drop(self.pixel_buffer);
}
