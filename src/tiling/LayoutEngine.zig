const std = @import("std");
const Allocator = std.mem.Allocator;

const LayoutEngine = @This();

// ── Core types ──────────────────────────────────────────────────

pub const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and
            self.width == other.width and self.height == other.height;
    }

    pub const zero = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
};

pub const Layout = enum {
    master_stack,
    grid,
    monocle,
    floating,
};

pub const Workspace = struct {
    name: []const u8,
    layout: Layout,
    prev_layout: ?Layout = null,
    node_ids: std.ArrayListUnmanaged(u64),
    active_index: usize = 0,
    master_ratio: f32 = 0.6,

    fn init(name: []const u8) Workspace {
        return .{
            .name = name,
            .layout = .monocle,
            .node_ids = .empty,
        };
    }

    pub fn deinit(self: *Workspace, allocator: Allocator) void {
        self.node_ids.deinit(allocator);
    }

    pub fn addNode(self: *Workspace, allocator: Allocator, id: u64) !void {
        // Prevent duplicates
        for (self.node_ids.items) |existing| {
            if (existing == id) return;
        }
        try self.node_ids.append(allocator, id);
        // Auto-select layout for new count
        self.layout = autoSelectLayout(self.node_ids.items.len);
    }

    pub fn removeNode(self: *Workspace, id: u64) void {
        for (self.node_ids.items, 0..) |existing, i| {
            if (existing == id) {
                _ = self.node_ids.orderedRemove(i);
                break;
            }
        }
        // Clamp active_index
        if (self.node_ids.items.len == 0) {
            self.active_index = 0;
        } else if (self.active_index >= self.node_ids.items.len) {
            self.active_index = self.node_ids.items.len - 1;
        }
        // Auto-select layout for new count
        self.layout = autoSelectLayout(self.node_ids.items.len);
    }

    pub fn focusNext(self: *Workspace) void {
        if (self.node_ids.items.len == 0) return;
        self.active_index = (self.active_index + 1) % self.node_ids.items.len;
    }

    pub fn focusPrev(self: *Workspace) void {
        if (self.node_ids.items.len == 0) return;
        if (self.active_index == 0) {
            self.active_index = self.node_ids.items.len - 1;
        } else {
            self.active_index -= 1;
        }
    }

    pub fn swapWithNext(self: *Workspace) void {
        const len = self.node_ids.items.len;
        if (len < 2) return;
        const next = (self.active_index + 1) % len;
        const items = self.node_ids.items;
        const tmp = items[self.active_index];
        items[self.active_index] = items[next];
        items[next] = tmp;
        self.active_index = next;
    }

    pub fn swapWithPrev(self: *Workspace) void {
        const len = self.node_ids.items.len;
        if (len < 2) return;
        const prev = if (self.active_index == 0) len - 1 else self.active_index - 1;
        const items = self.node_ids.items;
        const tmp = items[self.active_index];
        items[self.active_index] = items[prev];
        items[prev] = tmp;
        self.active_index = prev;
    }

    pub fn promoteToMaster(self: *Workspace) void {
        if (self.node_ids.items.len < 2 or self.active_index == 0) return;
        const items = self.node_ids.items;
        const promoted = items[self.active_index];
        // Shift everything between 0..active_index right by one
        var i = self.active_index;
        while (i > 0) : (i -= 1) {
            items[i] = items[i - 1];
        }
        items[0] = promoted;
        self.active_index = 0;
    }

    pub fn getActiveNodeId(self: *const Workspace) ?u64 {
        if (self.node_ids.items.len == 0) return null;
        return self.node_ids.items[self.active_index];
    }

    pub fn nodeCount(self: *const Workspace) usize {
        return self.node_ids.items.len;
    }
};

// ── Layout engine state ─────────────────────────────────────────

allocator: Allocator,
workspaces: [9]Workspace,
active_workspace: u8 = 0,

pub fn init(allocator: Allocator) LayoutEngine {
    var engine: LayoutEngine = .{
        .allocator = allocator,
        .workspaces = undefined,
    };
    const names = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };
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
/// Caller owns the returned slice and must free it with the same allocator.
pub fn calculate(self: *LayoutEngine, workspace_index: u8, screen: Rect) ![]Rect {
    if (workspace_index >= 9) return error.InvalidWorkspace;
    const ws = &self.workspaces[workspace_index];
    const count = ws.node_ids.items.len;

    if (count == 0) {
        return try self.allocator.alloc(Rect, 0);
    }

    return switch (ws.layout) {
        .master_stack => try calculateMasterStack(self.allocator, count, screen, ws.master_ratio),
        .grid => try calculateGrid(self.allocator, count, screen),
        .monocle => try calculateMonocle(self.allocator, count, screen, ws.active_index),
        .floating => try calculateFloating(self.allocator, count, screen),
    };
}

fn calculateMasterStack(allocator: Allocator, count: usize, screen: Rect, ratio: f32) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        // Single node gets the full screen
        rects[0] = screen;
        return rects;
    }

    const master_w: u16 = @intFromFloat(@as(f32, @floatFromInt(screen.width)) * ratio);
    const stack_w: u16 = screen.width - master_w;
    const stack_count: u16 = @intCast(count - 1);

    // Master pane
    rects[0] = .{
        .x = screen.x,
        .y = screen.y,
        .width = master_w,
        .height = screen.height,
    };

    // Stack panes — divide right portion equally
    const cell_h = screen.height / stack_count;
    const remainder = screen.height % stack_count;

    for (0..stack_count) |i| {
        const idx: u16 = @intCast(i);
        // Distribute remainder pixels to the last pane
        const extra: u16 = if (i == stack_count - 1) remainder else 0;
        rects[i + 1] = .{
            .x = screen.x + master_w,
            .y = screen.y + idx * cell_h,
            .width = stack_w,
            .height = cell_h + extra,
        };
    }

    return rects;
}

fn calculateGrid(allocator: Allocator, count: usize, screen: Rect) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        rects[0] = screen;
        return rects;
    }

    // Calculate optimal grid dimensions: cols = ceil(sqrt(count)), rows = ceil(count/cols)
    const cols = gridCols(count);
    const rows = (count + cols - 1) / cols;

    const cell_w: u16 = screen.width / @as(u16, @intCast(cols));
    const cell_h: u16 = screen.height / @as(u16, @intCast(rows));

    for (0..count) |i| {
        const col = i % cols;
        const row = i / cols;

        // Last column gets remainder width, last row gets remainder height
        const is_last_col = (col == cols - 1);
        const is_last_row = (row == rows - 1);
        const w_extra: u16 = if (is_last_col) screen.width % @as(u16, @intCast(cols)) else 0;
        const h_extra: u16 = if (is_last_row) screen.height % @as(u16, @intCast(rows)) else 0;

        rects[i] = .{
            .x = screen.x + @as(u16, @intCast(col)) * cell_w,
            .y = screen.y + @as(u16, @intCast(row)) * cell_h,
            .width = cell_w + w_extra,
            .height = cell_h + h_extra,
        };
    }

    return rects;
}

fn calculateMonocle(allocator: Allocator, count: usize, screen: Rect, active: usize) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    for (0..count) |i| {
        if (i == active) {
            rects[i] = screen;
        } else {
            rects[i] = Rect.zero;
        }
    }

    return rects;
}

fn calculateFloating(allocator: Allocator, count: usize, screen: Rect) ![]Rect {
    // Floating layout: position nodes in a reasonable default (cascading)
    // since we don't store per-node rects yet.
    const rects = try allocator.alloc(Rect, count);

    const default_w = screen.width * 3 / 4;
    const default_h = screen.height * 3 / 4;

    for (0..count) |i| {
        const offset: u16 = @intCast(@min(i * 2, screen.width / 4));
        rects[i] = .{
            .x = screen.x + offset,
            .y = screen.y + offset,
            .width = @min(default_w, screen.width -| offset),
            .height = @min(default_h, screen.height -| offset),
        };
    }

    return rects;
}

/// Optimal column count for a grid of n items.
fn gridCols(n: usize) usize {
    if (n <= 1) return 1;
    var cols: usize = 1;
    while (cols * cols < n) : (cols += 1) {}
    return cols;
}

// ── Workspace management ────────────────────────────────────────

pub fn switchWorkspace(self: *LayoutEngine, index: u8) void {
    if (index < 9) {
        self.active_workspace = index;
    }
}

pub fn moveNodeToWorkspace(self: *LayoutEngine, node_id: u64, target: u8) !void {
    if (target >= 9) return error.InvalidWorkspace;

    // Remove from all workspaces (node might be in any one)
    for (&self.workspaces) |*ws| {
        ws.removeNode(node_id);
    }

    // Add to target
    try self.workspaces[target].addNode(self.allocator, node_id);
}

pub fn getActiveWorkspace(self: *LayoutEngine) *Workspace {
    return &self.workspaces[self.active_workspace];
}

pub fn autoSelectLayout(node_count: usize) Layout {
    return switch (node_count) {
        0, 1 => .monocle,
        2, 3, 4 => .master_stack,
        else => .grid,
    };
}

// ── Tests ───────────────────────────────────────────────────────

const t = std.testing;

fn testEngine() struct { engine: LayoutEngine, allocator: Allocator } {
    const a = t.allocator;
    return .{ .engine = LayoutEngine.init(a), .allocator = a };
}

test "autoSelectLayout" {
    try t.expectEqual(Layout.monocle, autoSelectLayout(0));
    try t.expectEqual(Layout.monocle, autoSelectLayout(1));
    try t.expectEqual(Layout.master_stack, autoSelectLayout(2));
    try t.expectEqual(Layout.master_stack, autoSelectLayout(3));
    try t.expectEqual(Layout.master_stack, autoSelectLayout(4));
    try t.expectEqual(Layout.grid, autoSelectLayout(5));
    try t.expectEqual(Layout.grid, autoSelectLayout(9));
}

test "gridCols" {
    try t.expectEqual(@as(usize, 1), gridCols(1));
    try t.expectEqual(@as(usize, 2), gridCols(2));
    try t.expectEqual(@as(usize, 2), gridCols(3));
    try t.expectEqual(@as(usize, 2), gridCols(4));
    try t.expectEqual(@as(usize, 3), gridCols(5));
    try t.expectEqual(@as(usize, 3), gridCols(6));
    try t.expectEqual(@as(usize, 3), gridCols(9));
    try t.expectEqual(@as(usize, 4), gridCols(10));
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

test "master_stack — four nodes" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    for (1..5) |id| try ws.addNode(s.allocator, @intCast(id));
    ws.layout = .master_stack;
    ws.master_ratio = 0.5;

    const rects = try s.engine.calculate(0, .{ .x = 0, .y = 0, .width = 1200, .height = 900 });
    defer s.allocator.free(rects);
    try t.expectEqual(@as(usize, 4), rects.len);
    try t.expectEqual(@as(u16, 600), rects[0].width);
    try t.expectEqual(@as(u16, 900), rects[0].height);
    try t.expectEqual(@as(u16, 600), rects[1].x);
    try t.expectEqual(@as(u16, 0), rects[1].y);
    try t.expectEqual(@as(u16, 300), rects[1].height);
    try t.expectEqual(@as(u16, 600), rects[2].x);
    try t.expectEqual(@as(u16, 300), rects[2].y);
    try t.expectEqual(@as(u16, 300), rects[2].height);
    try t.expectEqual(@as(u16, 600), rects[3].x);
    try t.expectEqual(@as(u16, 600), rects[3].y);
    try t.expectEqual(@as(u16, 300), rects[3].height);
}

test "master_stack — offset origin and remainder height" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try ws.addNode(s.allocator, 1);
    try ws.addNode(s.allocator, 2);
    ws.layout = .master_stack;
    ws.master_ratio = 0.5;

    // Offset origin
    const r1 = try s.engine.calculate(0, .{ .x = 10, .y = 20, .width = 800, .height = 600 });
    defer s.allocator.free(r1);
    try t.expectEqual(@as(u16, 10), r1[0].x);
    try t.expectEqual(@as(u16, 20), r1[0].y);
    try t.expectEqual(@as(u16, 400), r1[0].width);
    try t.expectEqual(@as(u16, 410), r1[1].x);
    try t.expectEqual(@as(u16, 20), r1[1].y);
    try t.expectEqual(@as(u16, 400), r1[1].width);

    // Remainder: 3 nodes, height=101, 2 stack panes
    try ws.addNode(s.allocator, 3);
    ws.layout = .master_stack;
    const r2 = try s.engine.calculate(0, .{ .x = 0, .y = 0, .width = 100, .height = 101 });
    defer s.allocator.free(r2);
    try t.expectEqual(@as(u16, 50), r2[1].height);
    try t.expectEqual(@as(u16, 51), r2[2].height);
    try t.expectEqual(@as(u16, 0), r2[1].y);
    try t.expectEqual(@as(u16, 50), r2[2].y);
}

test "grid — four nodes (2x2)" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    for (1..5) |id| try ws.addNode(s.allocator, @intCast(id));
    ws.layout = .grid;

    const rects = try s.engine.calculate(0, .{ .x = 0, .y = 0, .width = 1000, .height = 800 });
    defer s.allocator.free(rects);
    try t.expectEqual(@as(usize, 4), rects.len);
    try t.expect(rects[0].eql(.{ .x = 0, .y = 0, .width = 500, .height = 400 }));
    try t.expect(rects[1].eql(.{ .x = 500, .y = 0, .width = 500, .height = 400 }));
    try t.expect(rects[2].eql(.{ .x = 0, .y = 400, .width = 500, .height = 400 }));
    try t.expect(rects[3].eql(.{ .x = 500, .y = 400, .width = 500, .height = 400 }));
}

test "grid — six nodes (3x2)" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    for (1..7) |id| try ws.addNode(s.allocator, @intCast(id));
    ws.layout = .grid;

    const rects = try s.engine.calculate(0, .{ .x = 0, .y = 0, .width = 900, .height = 600 });
    defer s.allocator.free(rects);
    try t.expectEqual(@as(usize, 6), rects.len);
    try t.expectEqual(@as(u16, 300), rects[0].width);
    try t.expectEqual(@as(u16, 300), rects[0].height);
    try t.expectEqual(@as(u16, 0), rects[0].x);
    try t.expectEqual(@as(u16, 0), rects[0].y);
    try t.expectEqual(@as(u16, 600), rects[2].x);
    try t.expectEqual(@as(u16, 0), rects[2].y);
    try t.expectEqual(@as(u16, 0), rects[3].x);
    try t.expectEqual(@as(u16, 300), rects[3].y);
}

test "grid — five nodes (3x2, sparse last row)" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    for (1..6) |id| try ws.addNode(s.allocator, @intCast(id));
    ws.layout = .grid;

    const rects = try s.engine.calculate(0, .{ .x = 0, .y = 0, .width = 900, .height = 600 });
    defer s.allocator.free(rects);
    try t.expectEqual(@as(usize, 5), rects.len);
    try t.expectEqual(@as(u16, 0), rects[0].x);
    try t.expectEqual(@as(u16, 300), rects[1].x);
    try t.expectEqual(@as(u16, 600), rects[2].x);
    try t.expectEqual(@as(u16, 0), rects[3].x);
    try t.expectEqual(@as(u16, 300), rects[3].y);
    try t.expectEqual(@as(u16, 300), rects[4].x);
    try t.expectEqual(@as(u16, 300), rects[4].y);
}

test "grid — remainder pixels go to last col/row" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    for (1..5) |id| try ws.addNode(s.allocator, @intCast(id));
    ws.layout = .grid;

    const rects = try s.engine.calculate(0, .{ .x = 0, .y = 0, .width = 1001, .height = 801 });
    defer s.allocator.free(rects);
    try t.expectEqual(@as(u16, 500), rects[0].width);
    try t.expectEqual(@as(u16, 400), rects[0].height);
    try t.expectEqual(@as(u16, 501), rects[1].width);
    try t.expectEqual(@as(u16, 400), rects[1].height);
    try t.expectEqual(@as(u16, 500), rects[2].width);
    try t.expectEqual(@as(u16, 401), rects[2].height);
    try t.expectEqual(@as(u16, 501), rects[3].width);
    try t.expectEqual(@as(u16, 401), rects[3].height);
}

test "monocle — active node gets full screen, focus switching" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try ws.addNode(s.allocator, 1);
    try ws.addNode(s.allocator, 2);
    try ws.addNode(s.allocator, 3);
    ws.layout = .monocle;
    ws.active_index = 1;

    const screen: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    const r1 = try s.engine.calculate(0, screen);
    defer s.allocator.free(r1);
    try t.expectEqual(@as(usize, 3), r1.len);
    try t.expect(r1[0].eql(Rect.zero));
    try t.expect(r1[1].eql(screen));
    try t.expect(r1[2].eql(Rect.zero));

    // Switch focus
    ws.active_index = 0;
    const r2 = try s.engine.calculate(0, screen);
    defer s.allocator.free(r2);
    try t.expect(r2[0].eql(screen));
    try t.expect(r2[1].eql(Rect.zero));
}

test "floating — cascading default positions" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    for (1..4) |id| try ws.addNode(s.allocator, @intCast(id));
    ws.layout = .floating;

    const rects = try s.engine.calculate(0, .{ .x = 0, .y = 0, .width = 800, .height = 600 });
    defer s.allocator.free(rects);
    try t.expectEqual(@as(usize, 3), rects.len);
    try t.expectEqual(@as(u16, 0), rects[0].x);
    try t.expectEqual(@as(u16, 0), rects[0].y);
    try t.expectEqual(@as(u16, 600), rects[0].width);
    try t.expectEqual(@as(u16, 450), rects[0].height);
    try t.expectEqual(@as(u16, 2), rects[1].x);
    try t.expectEqual(@as(u16, 2), rects[1].y);
}

test "calculate — zero nodes and invalid workspace" {
    var s = testEngine();
    defer s.engine.deinit();
    const screen: Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    const rects = try s.engine.calculate(0, screen);
    defer s.allocator.free(rects);
    try t.expectEqual(@as(usize, 0), rects.len);

    try t.expectError(error.InvalidWorkspace, s.engine.calculate(9, screen));
    try t.expectError(error.InvalidWorkspace, s.engine.calculate(255, screen));
}

test "addNode prevents duplicates" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try ws.addNode(s.allocator, 42);
    try ws.addNode(s.allocator, 42);
    try ws.addNode(s.allocator, 42);
    try t.expectEqual(@as(usize, 1), ws.node_ids.items.len);
}

test "removeNode — clamps active_index and handles empty" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try ws.addNode(s.allocator, 1);
    try ws.addNode(s.allocator, 2);
    try ws.addNode(s.allocator, 3);
    ws.active_index = 2;

    ws.removeNode(3);
    try t.expectEqual(@as(usize, 2), ws.node_ids.items.len);
    try t.expectEqual(@as(usize, 1), ws.active_index);

    // Remove to empty
    ws.removeNode(1);
    ws.removeNode(2);
    try t.expectEqual(@as(usize, 0), ws.node_ids.items.len);
    try t.expectEqual(@as(usize, 0), ws.active_index);
    try t.expectEqual(@as(?u64, null), ws.getActiveNodeId());
}

test "focusNext and focusPrev — wrapping and empty" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];

    // No-op on empty
    ws.focusNext();
    ws.focusPrev();
    try t.expectEqual(@as(usize, 0), ws.active_index);

    try ws.addNode(s.allocator, 1);
    try ws.addNode(s.allocator, 2);
    try ws.addNode(s.allocator, 3);

    // focusNext wraps
    try t.expectEqual(@as(usize, 0), ws.active_index);
    ws.focusNext();
    try t.expectEqual(@as(usize, 1), ws.active_index);
    ws.focusNext();
    try t.expectEqual(@as(usize, 2), ws.active_index);
    ws.focusNext();
    try t.expectEqual(@as(usize, 0), ws.active_index);

    // focusPrev wraps
    ws.focusPrev();
    try t.expectEqual(@as(usize, 2), ws.active_index);
    ws.focusPrev();
    try t.expectEqual(@as(usize, 1), ws.active_index);
}

test "swapWithNext — normal and wrap" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try ws.addNode(s.allocator, 10);
    try ws.addNode(s.allocator, 20);
    try ws.addNode(s.allocator, 30);

    // Normal swap from index 0
    ws.swapWithNext();
    try t.expectEqual(@as(u64, 20), ws.node_ids.items[0]);
    try t.expectEqual(@as(u64, 10), ws.node_ids.items[1]);
    try t.expectEqual(@as(usize, 1), ws.active_index);

    // Wrap: swap from last index
    ws.active_index = 2;
    ws.swapWithNext();
    try t.expectEqual(@as(u64, 30), ws.node_ids.items[0]);
    try t.expectEqual(@as(usize, 0), ws.active_index);
}

test "swapWithPrev — normal and wrap" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try ws.addNode(s.allocator, 10);
    try ws.addNode(s.allocator, 20);
    try ws.addNode(s.allocator, 30);

    // Normal swap from index 2
    ws.active_index = 2;
    ws.swapWithPrev();
    try t.expectEqual(@as(u64, 30), ws.node_ids.items[1]);
    try t.expectEqual(@as(u64, 20), ws.node_ids.items[2]);
    try t.expectEqual(@as(usize, 1), ws.active_index);

    // Wrap: swap from index 0 — state is now [10, 30, 20]
    ws.active_index = 0;
    ws.swapWithPrev();
    try t.expectEqual(@as(u64, 20), ws.node_ids.items[0]);
    try t.expectEqual(@as(u64, 10), ws.node_ids.items[2]);
    try t.expectEqual(@as(usize, 2), ws.active_index);
}

test "promoteToMaster — normal and no-op when already master" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try ws.addNode(s.allocator, 10);
    try ws.addNode(s.allocator, 20);
    try ws.addNode(s.allocator, 30);
    try ws.addNode(s.allocator, 40);

    ws.active_index = 2;
    ws.promoteToMaster();
    try t.expectEqual(@as(u64, 30), ws.node_ids.items[0]);
    try t.expectEqual(@as(u64, 10), ws.node_ids.items[1]);
    try t.expectEqual(@as(u64, 20), ws.node_ids.items[2]);
    try t.expectEqual(@as(u64, 40), ws.node_ids.items[3]);
    try t.expectEqual(@as(usize, 0), ws.active_index);

    // No-op when already at index 0
    ws.promoteToMaster();
    try t.expectEqual(@as(u64, 30), ws.node_ids.items[0]);
    try t.expectEqual(@as(u64, 10), ws.node_ids.items[1]);
}

test "getActiveNodeId" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];
    try t.expectEqual(@as(?u64, null), ws.getActiveNodeId());
    try ws.addNode(s.allocator, 42);
    try t.expectEqual(@as(?u64, 42), ws.getActiveNodeId());
    try ws.addNode(s.allocator, 99);
    ws.active_index = 1;
    try t.expectEqual(@as(?u64, 99), ws.getActiveNodeId());
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
    try t.expect(std.mem.eql(u8, "9", s.engine.getActiveWorkspace().name));

    // Out of range — no change
    s.engine.switchWorkspace(9);
    try t.expectEqual(@as(u8, 8), s.engine.active_workspace);
    s.engine.switchWorkspace(255);
    try t.expectEqual(@as(u8, 8), s.engine.active_workspace);
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
    for (s.engine.workspaces[0].node_ids.items) |id| {
        try t.expect(id != 2);
    }

    // Invalid target
    try t.expectError(error.InvalidWorkspace, s.engine.moveNodeToWorkspace(1, 9));
}

test "addNode/removeNode auto-selects layout" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];

    // Adding nodes transitions monocle -> master_stack -> grid
    try ws.addNode(s.allocator, 1);
    try t.expectEqual(Layout.monocle, ws.layout);
    try ws.addNode(s.allocator, 2);
    try t.expectEqual(Layout.master_stack, ws.layout);
    try ws.addNode(s.allocator, 3);
    try t.expectEqual(Layout.master_stack, ws.layout);
    try ws.addNode(s.allocator, 4);
    try t.expectEqual(Layout.master_stack, ws.layout);
    try ws.addNode(s.allocator, 5);
    try t.expectEqual(Layout.grid, ws.layout);

    // Removing nodes transitions back
    ws.removeNode(5);
    try t.expectEqual(Layout.master_stack, ws.layout);
    ws.removeNode(4);
    try t.expectEqual(Layout.master_stack, ws.layout);
    ws.removeNode(3);
    try t.expectEqual(Layout.master_stack, ws.layout);
    ws.removeNode(2);
    try t.expectEqual(Layout.monocle, ws.layout);
    ws.removeNode(1);
    try t.expectEqual(Layout.monocle, ws.layout);
}

test "engine init — 9 workspaces with correct names" {
    var s = testEngine();
    defer s.engine.deinit();
    try t.expectEqual(@as(u8, 0), s.engine.active_workspace);
    for (s.engine.workspaces, 0..) |ws, i| {
        const expected_name = [_]u8{'1' + @as(u8, @intCast(i))};
        try t.expect(std.mem.eql(u8, &expected_name, ws.name));
        try t.expectEqual(@as(usize, 0), ws.node_ids.items.len);
        try t.expectEqual(Layout.monocle, ws.layout);
    }
}
