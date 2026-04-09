//! Tiling layout engine for pane arrangement.
//!
//! Supports 8 layouts: master-stack, grid, monocle, dishes, spiral,
//! three-col, columns, accordion. Each workspace tracks its own layout,
//! master ratio, and node list.
//!
//! This file is the public facade. Implementation is split across:
//!   types.zig     — Rect, Layout, SplitDirection, SplitNode, max_layouts
//!   Workspace.zig — Workspace struct (flat list + split tree + layout cycling)
//!   layouts.zig   — 8 layout calculation algorithms

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const layouts = @import("layouts.zig");

const LayoutEngine = @This();

// ── Re-exports (public API, no caller changes needed) ──────────

pub const Rect = types.Rect;
pub const Layout = types.Layout;
pub const SplitDirection = types.SplitDirection;
pub const SplitNode = types.SplitNode;
pub const max_layouts = types.max_layouts;
pub const Workspace = @import("Workspace.zig");
pub const autoSelectLayout = Workspace.autoSelectLayout;

// ── Layout engine state ─────────────────────────────────────────

allocator: Allocator,
workspaces: [10]Workspace,
active_workspace: u8 = 0,

pub fn init(allocator: Allocator) LayoutEngine {
    var engine: LayoutEngine = .{
        .allocator = allocator,
        .workspaces = undefined,
    };
    const names = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" };
    for (&engine.workspaces, 0..) |*ws, i| {
        ws.* = Workspace.init(names[i]);
    }
    return engine;
}

pub fn deinit(self: *LayoutEngine) void {
    for (&self.workspaces) |*ws| {
        ws.deinit(self.allocator);
    }
}

// ── Layout calculation ──────────────────────────────────────────

/// Compute positioned rectangles for every node in the given workspace.
/// When the split tree has nodes, uses the tree layout. Otherwise falls back
/// to the flat-list layout algorithm selected by ws.layout.
/// Caller owns the returned slice and must free it with the same allocator.
pub fn calculate(self: *LayoutEngine, workspace_index: u8, screen: Rect) ![]Rect {
    if (workspace_index >= 10) return error.InvalidWorkspace;
    const ws = &self.workspaces[workspace_index];

    if (ws.split_root != null) {
        return ws.calculateFromTree(self.allocator, screen);
    }

    const count = ws.node_ids.items.len;
    if (count == 0) {
        return try self.allocator.alloc(Rect, 0);
    }

    return switch (ws.layout) {
        .master_stack => try layouts.masterStack(self.allocator, count, screen, ws.master_ratio),
        .grid => try layouts.grid(self.allocator, count, screen),
        .monocle => try layouts.monocle(self.allocator, count, screen, ws.active_index),
        .dishes => try layouts.dishes(self.allocator, count, screen, ws.master_ratio),
        .spiral => try layouts.spiral(self.allocator, count, screen),
        .three_col => try layouts.threeCol(self.allocator, count, screen, ws.master_ratio),
        .columns => try layouts.columns(self.allocator, count, screen),
        .accordion => try layouts.accordion(self.allocator, count, screen, ws.active_index),
    };
}

// ── Workspace management ────────────────────────────────────────

pub fn switchWorkspace(self: *LayoutEngine, index: u8) void {
    if (index < 10) {
        self.active_workspace = index;
    }
}

pub fn moveNodeToWorkspace(self: *LayoutEngine, node_id: u64, target: u8) !void {
    if (target >= 10) return error.InvalidWorkspace;
    for (&self.workspaces) |*ws| {
        ws.removeNode(node_id);
    }
    try self.workspaces[target].addNode(self.allocator, node_id);
}

pub fn getActiveWorkspace(self: *LayoutEngine) *Workspace {
    return &self.workspaces[self.active_workspace];
}

// ── Pull sub-module tests ───────────────────────────────────────

test {
    _ = @import("Workspace.zig");
    _ = @import("layouts.zig");
}

// ── Integration tests (engine.calculate dispatch) ───────────────

const t = std.testing;

fn testEngine() struct { engine: LayoutEngine, allocator: Allocator } {
    const a = t.allocator;
    return .{ .engine = LayoutEngine.init(a), .allocator = a };
}

test "single node gets full screen in master_stack and grid" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try ws.addNode(s.allocator, 1);
    const screen = Rect{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    ws.layout = .master_stack;
    const r1 = try s.engine.calculate(0, screen);
    defer s.allocator.free(r1);
    try t.expectEqual(@as(usize, 1), r1.len);
    try t.expect(r1[0].eql(screen));

    ws.layout = .grid;
    const r2 = try s.engine.calculate(0, screen);
    defer s.allocator.free(r2);
    try t.expect(r2[0].eql(screen));
}

test "master_stack — two nodes" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try ws.addNode(s.allocator, 1);
    try ws.addNode(s.allocator, 2);
    ws.layout = .master_stack;

    const rects = try s.engine.calculate(0, .{ .x = 0, .y = 0, .width = 1000, .height = 800 });
    defer s.allocator.free(rects);
    try t.expectEqual(@as(usize, 2), rects.len);
    try t.expectEqual(@as(u16, 0), rects[0].x);
    try t.expectEqual(@as(u16, 600), rects[0].width);
    try t.expectEqual(@as(u16, 800), rects[0].height);
    try t.expectEqual(@as(u16, 600), rects[1].x);
    try t.expectEqual(@as(u16, 400), rects[1].width);
    try t.expectEqual(@as(u16, 800), rects[1].height);
}

test "calculate — zero nodes and invalid workspace" {
    var s = testEngine();
    defer s.engine.deinit();
    const screen: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    const rects = try s.engine.calculate(0, screen);
    defer s.allocator.free(rects);
    try t.expectEqual(@as(usize, 0), rects.len);

    try t.expectError(error.InvalidWorkspace, s.engine.calculate(10, screen));
    try t.expectError(error.InvalidWorkspace, s.engine.calculate(255, screen));
}

test "engine init — 10 workspaces with correct names" {
    var s = testEngine();
    defer s.engine.deinit();
    try t.expectEqual(@as(u8, 0), s.engine.active_workspace);
    for (s.engine.workspaces, 0..) |ws, i| {
        if (i < 9) {
            const expected_name = [_]u8{'1' + @as(u8, @intCast(i))};
            try t.expect(std.mem.eql(u8, &expected_name, ws.name));
        } else {
            try t.expect(std.mem.eql(u8, "0", ws.name));
        }
        try t.expectEqual(@as(usize, 0), ws.node_ids.items.len);
        try t.expectEqual(Layout.monocle, ws.layout);
    }
}

test "switchWorkspace" {
    var s = testEngine();
    defer s.engine.deinit();
    try t.expectEqual(@as(u8, 0), s.engine.active_workspace);

    s.engine.switchWorkspace(3);
    try t.expectEqual(@as(u8, 3), s.engine.active_workspace);
    try t.expect(std.mem.eql(u8, "4", s.engine.getActiveWorkspace().name));

    s.engine.switchWorkspace(8);
    try t.expectEqual(@as(u8, 8), s.engine.active_workspace);

    s.engine.switchWorkspace(9);
    try t.expectEqual(@as(u8, 9), s.engine.active_workspace);

    // Out of range — no change
    s.engine.switchWorkspace(10);
    try t.expectEqual(@as(u8, 9), s.engine.active_workspace);
}

test "moveNodeToWorkspace" {
    var s = testEngine();
    defer s.engine.deinit();
    try s.engine.workspaces[0].addNode(s.allocator, 1);
    try s.engine.workspaces[0].addNode(s.allocator, 2);
    try s.engine.workspaces[0].addNode(s.allocator, 3);

    try s.engine.moveNodeToWorkspace(2, 3);
    try t.expectEqual(@as(usize, 2), s.engine.workspaces[0].nodeCount());
    try t.expectEqual(@as(usize, 1), s.engine.workspaces[3].nodeCount());
    try t.expectEqual(@as(?u64, 2), s.engine.workspaces[3].getActiveNodeId());

    try t.expectError(error.InvalidWorkspace, s.engine.moveNodeToWorkspace(1, 10));
}

test "calculate uses tree when split_root is set" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];

    try ws.addNodeSplit(s.allocator, 1, .vertical);
    try ws.addNodeSplit(s.allocator, 2, .vertical);

    const screen: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const rects = try s.engine.calculate(0, screen);
    defer s.allocator.free(rects);

    try t.expectEqual(@as(usize, 2), rects.len);
    try t.expectEqual(@as(u16, 500), rects[0].width);
    try t.expectEqual(@as(u16, 500), rects[1].width);
}
