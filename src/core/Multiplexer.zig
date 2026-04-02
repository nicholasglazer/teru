const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Pane = @import("Pane.zig");
const Grid = @import("Grid.zig");
const VtParser = @import("VtParser.zig");
const Pty = @import("../pty/Pty.zig");
const LayoutEngine = @import("../tiling/LayoutEngine.zig");
const Rect = LayoutEngine.Rect;
const Selection = @import("Selection.zig");
const SoftwareRenderer = @import("../render/software.zig").SoftwareRenderer;
const ColorScheme = @import("../config/Config.zig").ColorScheme;
const Session = @import("../persist/Session.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Scrollback = @import("../persist/Scrollback.zig");
const Compositor = @import("../render/Compositor.zig");

/// Multiplexer orchestrates multiple panes with tiling layout.
/// Each pane has its own PTY + Grid + VtParser. The LayoutEngine
/// determines where each pane renders on screen.
const Multiplexer = @This();

panes: std.ArrayListUnmanaged(Pane),
layout_engine: LayoutEngine,
active_workspace: u8,
allocator: Allocator,
scrollback: ?Scrollback,
next_pane_id: u64,
graph: ?*ProcessGraph = null,

// Scroll state (accessible from McpServer for teru_scroll tool)
scroll_offset: u32 = 0,

pub fn init(allocator: Allocator) Multiplexer {
    return .{
        .panes = .empty,
        .layout_engine = LayoutEngine.init(allocator),
        .active_workspace = 0,
        .allocator = allocator,
        .scrollback = null,
        .next_pane_id = 1,
    };
}

pub fn deinit(self: *Multiplexer) void {
    for (self.panes.items) |*pane| {
        pane.deinit(self.allocator);
    }
    self.panes.deinit(self.allocator);
    self.layout_engine.deinit();
    if (self.scrollback) |*sb| sb.deinit();
}

// ── Pane management ────────────────────────────────────────────

/// Spawn a new pane with the given grid dimensions.
/// Returns the pane ID. The pane is added to the active workspace.
pub fn spawnPane(self: *Multiplexer, rows: u16, cols: u16) !u64 {
    const id = self.next_pane_id;
    self.next_pane_id += 1;

    var pane = try Pane.init(self.allocator, rows, cols, id);
    errdefer pane.deinit(self.allocator);

    try self.panes.append(self.allocator, pane);
    errdefer _ = self.panes.pop();

    // Patch VtParser's grid pointer now that Pane is in its final memory location
    self.panes.items[self.panes.items.len - 1].linkVt(self.allocator);

    try self.layout_engine.workspaces[self.active_workspace].addNode(self.allocator, id);

    return id;
}

/// Spawn a pane running a custom command instead of the user's shell.
/// The command string is passed as the shell argument to Pty.spawn.
/// Returns the pane ID.
pub fn spawnPaneWithCommand(self: *Multiplexer, rows: u16, cols: u16, command: []const u8, cwd: ?[]const u8) !u64 {
    const id = self.next_pane_id;
    self.next_pane_id += 1;

    var grid = try Grid.init(self.allocator, rows, cols);
    errdefer grid.deinit(self.allocator);

    const sb = Scrollback.init(self.allocator, .{ .keyframe_interval = 100 });

    var pty = try Pty.spawn(.{ .rows = rows, .cols = cols, .shell = command, .cwd = cwd });
    errdefer pty.deinit();

    // Set PTY master to non-blocking
    const flags = std.c.fcntl(pty.master, posix.F.GETFL);
    if (flags < 0) return error.FcntlFailed;
    const O_NONBLOCK = 0x800;
    _ = std.c.fcntl(pty.master, posix.F.SETFL, flags | O_NONBLOCK);

    var pane = Pane{
        .pty = pty,
        .grid = grid,
        .vt = VtParser.initEmpty(),
        .id = id,
        .scrollback = sb,
    };
    _ = &pane;

    try self.panes.append(self.allocator, pane);
    errdefer _ = self.panes.pop();

    // Patch VtParser's grid pointer now that Pane is in its final memory location
    self.panes.items[self.panes.items.len - 1].linkVt(self.allocator);

    try self.layout_engine.workspaces[self.active_workspace].addNode(self.allocator, id);

    return id;
}

/// Close and remove a pane by its ID.
pub fn closePane(self: *Multiplexer, pane_id: u64) void {
    // Remove from all workspaces
    for (&self.layout_engine.workspaces) |*ws| {
        ws.removeNode(pane_id);
    }

    // Find and remove from panes list
    for (self.panes.items, 0..) |*pane, i| {
        if (pane.id == pane_id) {
            pane.deinit(self.allocator);
            _ = self.panes.orderedRemove(i);
            break;
        }
    }
}

/// Get the currently focused pane (active pane in active workspace).
pub fn getActivePane(self: *Multiplexer) ?*Pane {
    const ws = &self.layout_engine.workspaces[self.active_workspace];
    const active_id = ws.getActiveNodeId() orelse return null;
    return self.getPaneById(active_id);
}

/// Find a pane by its ID.
pub fn getPaneById(self: *Multiplexer, id: u64) ?*Pane {
    for (self.panes.items) |*pane| {
        if (pane.id == id) return pane;
    }
    return null;
}

// ── Navigation ─────────────────────────────────────────────────

/// Focus the next pane in the active workspace.
pub fn focusNext(self: *Multiplexer) void {
    self.layout_engine.workspaces[self.active_workspace].focusNext();
}

/// Focus the previous pane in the active workspace.
pub fn focusPrev(self: *Multiplexer) void {
    self.layout_engine.workspaces[self.active_workspace].focusPrev();
}

/// Switch to a workspace by index (0-8).
pub fn switchWorkspace(self: *Multiplexer, idx: u8) void {
    self.layout_engine.switchWorkspace(idx);
    self.active_workspace = self.layout_engine.active_workspace;
}

/// Cycle the layout of the active workspace.
pub fn cycleLayout(self: *Multiplexer) void {
    const ws = &self.layout_engine.workspaces[self.active_workspace];
    ws.layout = switch (ws.layout) {
        .master_stack => .grid,
        .grid => .monocle,
        .monocle => .floating,
        .floating => .master_stack,
    };
}

/// Toggle zoom: switch between current layout and monocle.
/// If already monocle, restore the previous layout.
pub fn toggleZoom(self: *Multiplexer) void {
    const ws = &self.layout_engine.workspaces[self.active_workspace];
    if (ws.layout == .monocle) {
        // Restore previous layout (default to master_stack)
        ws.layout = if (ws.prev_layout) |prev| prev else .master_stack;
        ws.prev_layout = null;
    } else {
        ws.prev_layout = ws.layout;
        ws.layout = .monocle;
    }
}

/// Resize the active pane by adjusting the master ratio.
/// dx > 0 grows width, dx < 0 shrinks. dy is reserved for future use.
pub fn resizeActive(self: *Multiplexer, dx: i8, dy: i8) void {
    _ = dy;
    const ws = &self.layout_engine.workspaces[self.active_workspace];
    if (ws.layout != .master_stack) return; // only master-stack supports ratio
    const step: f32 = @as(f32, @floatFromInt(dx)) * 0.02;
    ws.master_ratio = @min(0.85, @max(0.15, ws.master_ratio + step));
}

// ── PTY polling ────────────────────────────────────────────────

/// Read from all PTYs. Returns true if any had output.
pub fn pollPtys(self: *Multiplexer, buf: []u8) bool {
    var any_output = false;
    for (self.panes.items) |*pane| {
        const n = pane.readAndProcess(buf) catch 0;
        if (n > 0) any_output = true;
    }
    return any_output;
}

// ── Rendering ──────────────────────────────────────────────────

/// Render all visible panes into the software renderer's framebuffer.
/// Each pane is rendered into its layout rect. The active pane gets
/// a highlighted border.
pub fn renderAll(
    self: *Multiplexer,
    renderer: *SoftwareRenderer,
    screen_width: u32,
    screen_height: u32,
    cell_width: u32,
    cell_height: u32,
) void {
    self.renderAllWithSelection(renderer, screen_width, screen_height, cell_width, cell_height, null);
}

/// Render all visible panes with optional selection highlight on the active pane.
pub fn renderAllWithSelection(
    self: *Multiplexer,
    renderer: *SoftwareRenderer,
    screen_width: u32,
    screen_height: u32,
    cell_width: u32,
    cell_height: u32,
    sel: ?*const Selection,
) void {
    @memset(renderer.framebuffer, renderer.scheme.bg);

    const pad = renderer.padding;
    const screen_rect = Rect{
        .x = @intCast(pad),
        .y = @intCast(pad),
        .width = @intCast(@min(screen_width -| pad * 2, std.math.maxInt(u16))),
        .height = @intCast(@min(screen_height -| pad * 2, std.math.maxInt(u16))),
    };

    const ws = &self.layout_engine.workspaces[self.active_workspace];
    const node_ids = ws.node_ids.items;
    if (node_ids.len == 0) return;

    const rects = self.layout_engine.calculate(self.active_workspace, screen_rect) catch return;
    defer self.allocator.free(rects);

    const active_id = ws.getActiveNodeId();

    // Reserve bottom bar height only when agents are active
    const has_agents = if (self.graph) |g| g.countAgentsByState().running + g.countAgentsByState().done + g.countAgentsByState().failed > 0 else false;
    const bar_height: u16 = if (has_agents and screen_height > 60) 20 else 0;
    const effective_height: u16 = @intCast(screen_height -| bar_height -| pad);

    for (rects, 0..) |rect, i| {
        if (i >= node_ids.len) break;
        if (rect.width == 0 or rect.height == 0) continue;

        // Clamp rect to effective height (above status bar)
        var clamped = rect;
        if (@as(u32, clamped.y) + clamped.height > effective_height) {
            if (clamped.y >= effective_height) continue;
            clamped.height = effective_height - clamped.y;
        }

        const pane = self.getPaneById(node_ids[i]) orelse continue;
        const is_active = if (active_id) |aid| aid == pane.id else false;
        // Only apply selection highlight to the active pane
        const pane_sel = if (is_active) sel else null;

        // For multi-pane layouts, reserve 1px border around each pane
        const has_border = node_ids.len > 1;
        if (has_border) {
            // Draw border with agent-aware color
            const border_color = Compositor.getBorderColor(self.graph, pane.id, is_active, &renderer.scheme);
            Compositor.drawBorder(renderer, clamped, border_color);

            // Render grid into inset rect
            const inset = Compositor.insetRect(clamped, 1);
            Compositor.renderPaneIntoRect(renderer, &pane.grid, inset, cell_width, cell_height, is_active, pane_sel);
        } else {
            // Single pane: no border, full screen (above status bar)
            Compositor.renderPaneIntoRect(renderer, &pane.grid, clamped, cell_width, cell_height, is_active, pane_sel);
        }
    }

    // Render status bar at the bottom
    if (screen_height > bar_height + 40) {
        Compositor.renderAgentStatusBar(renderer, self.graph, screen_width, screen_height, bar_height);
    }
}


// ── Session persistence ────────────────────────────────────────

/// Save session state to a file. This serializes the process graph.
pub fn saveSession(self: *Multiplexer, graph: *const ProcessGraph, path: []const u8, io: Io) !void {
    _ = self;
    try Session.saveToFile(graph, path, io);
}


// ── Tests ──────────────────────────────────────────────────────

const t = std.testing;

test "Multiplexer init and deinit" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    try t.expectEqual(@as(u64, 1), mux.next_pane_id);
    try t.expectEqual(@as(u8, 0), mux.active_workspace);
    try t.expectEqual(@as(usize, 0), mux.panes.items.len);
}

test "Multiplexer spawnPane and closePane" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    const id1 = try mux.spawnPane(24, 80);
    try t.expectEqual(@as(u64, 1), id1);
    try t.expectEqual(@as(usize, 1), mux.panes.items.len);

    const id2 = try mux.spawnPane(24, 80);
    try t.expectEqual(@as(u64, 2), id2);
    try t.expectEqual(@as(usize, 2), mux.panes.items.len);

    // Active workspace should have both
    const ws = &mux.layout_engine.workspaces[0];
    try t.expectEqual(@as(usize, 2), ws.nodeCount());

    mux.closePane(id1);
    try t.expectEqual(@as(usize, 1), mux.panes.items.len);
    try t.expectEqual(@as(usize, 1), ws.nodeCount());
    try t.expectEqual(@as(?u64, id2), ws.getActiveNodeId());
}

test "Multiplexer getActivePane" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    // No panes yet
    try t.expectEqual(@as(?*Pane, null), mux.getActivePane());

    const id = try mux.spawnPane(24, 80);
    const active = mux.getActivePane();
    try t.expect(active != null);
    try t.expectEqual(id, active.?.id);
}

test "Multiplexer getPaneById" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    const id1 = try mux.spawnPane(10, 20);
    const id2 = try mux.spawnPane(10, 20);

    try t.expectEqual(id1, mux.getPaneById(id1).?.id);
    try t.expectEqual(id2, mux.getPaneById(id2).?.id);
    try t.expectEqual(@as(?*Pane, null), mux.getPaneById(999));
}

test "Multiplexer focus navigation" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    const id1 = try mux.spawnPane(10, 20);
    const id2 = try mux.spawnPane(10, 20);
    const id3 = try mux.spawnPane(10, 20);

    try t.expectEqual(id1, mux.getActivePane().?.id);

    mux.focusNext();
    try t.expectEqual(id2, mux.getActivePane().?.id);

    mux.focusNext();
    try t.expectEqual(id3, mux.getActivePane().?.id);

    mux.focusNext(); // wraps
    try t.expectEqual(id1, mux.getActivePane().?.id);

    mux.focusPrev(); // wraps back
    try t.expectEqual(id3, mux.getActivePane().?.id);
}

test "Multiplexer switchWorkspace" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    try t.expectEqual(@as(u8, 0), mux.active_workspace);

    mux.switchWorkspace(3);
    try t.expectEqual(@as(u8, 3), mux.active_workspace);

    // Out of range does nothing
    mux.switchWorkspace(99);
    try t.expectEqual(@as(u8, 3), mux.active_workspace);
}

test "Multiplexer cycleLayout" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    _ = try mux.spawnPane(10, 20);

    const ws = &mux.layout_engine.workspaces[0];

    // monocle (auto-selected for 1 pane) -> grid -> monocle -> ...
    // Force a known starting layout
    ws.layout = .master_stack;
    mux.cycleLayout();
    try t.expectEqual(LayoutEngine.Layout.grid, ws.layout);

    mux.cycleLayout();
    try t.expectEqual(LayoutEngine.Layout.monocle, ws.layout);

    mux.cycleLayout();
    try t.expectEqual(LayoutEngine.Layout.floating, ws.layout);

    mux.cycleLayout();
    try t.expectEqual(LayoutEngine.Layout.master_stack, ws.layout);
}

test "Multiplexer pollPtys" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    _ = try mux.spawnPane(10, 20);

    var buf: [4096]u8 = undefined;
    // Should not crash; may or may not have output
    _ = mux.pollPtys(&buf);
}

test "Multiplexer renderAll with single pane" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    _ = try mux.spawnPane(3, 4);

    const cw: u32 = 8;
    const ch: u32 = 16;
    const width: u32 = 4 * cw;
    const height: u32 = 3 * ch;

    var renderer = try SoftwareRenderer.init(t.allocator, width, height, cw, ch);
    renderer.padding = 0; // tests expect no padding
    defer renderer.deinit();

    mux.renderAll(&renderer, width, height, cw, ch);

    // Should have rendered something (at minimum the background)
    // Single pane = no border, cursor should be visible
    const scheme = ColorScheme{};
    try t.expectEqual(scheme.cursor, renderer.framebuffer[0]); // cursor at (0,0)
}

test "Multiplexer renderAll with multiple panes" {
    var mux = Multiplexer.init(t.allocator);
    defer mux.deinit();

    _ = try mux.spawnPane(3, 4);
    _ = try mux.spawnPane(3, 4);

    const cw: u32 = 8;
    const ch: u32 = 16;
    const width: u32 = 80;
    const height: u32 = 48;

    var renderer = try SoftwareRenderer.init(t.allocator, width, height, cw, ch);
    renderer.padding = 0; // tests expect no padding
    defer renderer.deinit();

    mux.renderAll(&renderer, width, height, cw, ch);

    // With 2 panes, borders should be drawn. Active pane border = scheme.border_active.
    const scheme = ColorScheme{};
    try t.expectEqual(scheme.border_active, renderer.framebuffer[0]);
}

