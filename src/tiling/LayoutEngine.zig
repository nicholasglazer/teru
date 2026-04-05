//! Tiling layout engine for pane arrangement.
//!
//! Supports four layouts: master-stack, grid, monocle, and floating.
//! Each workspace tracks its own layout, master ratio, and node list.

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

pub const SplitDirection = enum { horizontal, vertical };

pub const SplitNode = union(enum) {
    leaf: u64, // pane ID
    split: Split,

    pub const Split = struct {
        dir: SplitDirection,
        ratio: f32, // 0.0–1.0, fraction given to `first`
        first: u16, // index into nodes[]
        second: u16,
    };
};

pub const Workspace = struct {
    name: []const u8,
    layout: Layout,
    prev_layout: ?Layout = null,
    node_ids: std.ArrayListUnmanaged(u64),
    active_index: usize = 0,
    master_ratio: f32 = 0.6,

    // ── Binary split tree (pre-allocated, no heap) ─────────────
    split_nodes: [64]SplitNode = undefined,
    split_node_count: u16 = 0,
    split_root: ?u16 = null, // index into split_nodes, null = empty tree
    active_node: ?u64 = null, // active pane ID for tree operations

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
        if (self.split_root != null) { self.focusNextInTree(); return; }
        if (self.node_ids.items.len == 0) return;
        self.active_index = (self.active_index + 1) % self.node_ids.items.len;
    }

    pub fn focusPrev(self: *Workspace) void {
        if (self.split_root != null) { self.focusPrevInTree(); return; }
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
        if (self.split_root != null) return self.active_node;
        if (self.node_ids.items.len == 0) return null;
        return self.node_ids.items[self.active_index];
    }

    pub fn nodeCount(self: *const Workspace) usize {
        return self.node_ids.items.len;
    }

    pub const BorderHit = struct { node_idx: u16, is_horizontal: bool };

    // ── Split tree operations ──────────────────────────────────

    /// Allocate a node in the pre-allocated array. Returns index.
    fn allocSplitNode(self: *Workspace, node: SplitNode) ?u16 {
        if (self.split_node_count >= 64) return null;
        const idx = self.split_node_count;
        self.split_nodes[idx] = node;
        self.split_node_count += 1;
        return idx;
    }

    /// Split the active pane (or add first pane if tree is empty).
    /// Creates a new split node: active pane becomes `first`, new pane becomes `second`.
    pub fn addNodeSplit(self: *Workspace, allocator: Allocator, pane_id: u64, direction: SplitDirection) !void {
        // Also maintain the flat list for backward compat
        for (self.node_ids.items) |existing| {
            if (existing == pane_id) return;
        }
        try self.node_ids.append(allocator, pane_id);
        self.layout = autoSelectLayout(self.node_ids.items.len);

        if (self.split_root == null) {
            // Tree empty — check if there's an existing pane in the flat list to split
            if (self.node_ids.items.len >= 2) {
                // We have the existing pane + the new one. Build a split.
                const existing_id = blk: {
                    for (self.node_ids.items) |nid| {
                        if (nid != pane_id) break :blk nid;
                    }
                    break :blk pane_id; // fallback
                };
                const first_idx = self.allocSplitNode(.{ .leaf = existing_id }) orelse return;
                const second_idx = self.allocSplitNode(.{ .leaf = pane_id }) orelse return;
                const split_idx = self.allocSplitNode(.{ .split = .{
                    .dir = direction,
                    .ratio = 0.5,
                    .first = first_idx,
                    .second = second_idx,
                } }) orelse return;
                self.split_root = split_idx;
                self.active_node = pane_id;
                return;
            }
            // Truly empty — single leaf
            const idx = self.allocSplitNode(.{ .leaf = pane_id }) orelse return;
            self.split_root = idx;
            self.active_node = pane_id;
            return;
        }

        const active_id = self.active_node orelse {
            // No active node — just add a leaf (shouldn't normally happen)
            _ = self.allocSplitNode(.{ .leaf = pane_id });
            return;
        };

        // Find the leaf node for active_id and replace it with a split
        const leaf_idx = self.findLeaf(self.split_root.?, active_id) orelse return;

        // Allocate two new leaves: existing active + new pane
        const first_idx = self.allocSplitNode(.{ .leaf = active_id }) orelse return;
        const second_idx = self.allocSplitNode(.{ .leaf = pane_id }) orelse return;

        // Replace the leaf with a split node
        self.split_nodes[leaf_idx] = .{ .split = .{
            .dir = direction,
            .ratio = 0.5,
            .first = first_idx,
            .second = second_idx,
        } };

        self.active_node = pane_id;
    }

    /// Find index of the leaf node containing `pane_id`, searching from `idx`.
    fn findLeaf(self: *const Workspace, idx: u16, pane_id: u64) ?u16 {
        switch (self.split_nodes[idx]) {
            .leaf => |id| return if (id == pane_id) idx else null,
            .split => |s| {
                return self.findLeaf(s.first, pane_id) orelse self.findLeaf(s.second, pane_id);
            },
        }
    }

    /// Remove a pane from the tree. If it's in a split, replace the parent split
    /// with the sibling. If it's the only node, clear the tree.
    pub fn removeNodeFromTree(self: *Workspace, pane_id: u64) void {
        const root = self.split_root orelse return;

        // Single leaf at root
        switch (self.split_nodes[root]) {
            .leaf => |id| {
                if (id == pane_id) {
                    self.split_root = null;
                    self.split_node_count = 0;
                    self.active_node = null;
                }
                return;
            },
            .split => {},
        }

        // Find parent split that contains pane_id as a direct child leaf
        self.removeLeafRecursive(root, pane_id);

        // Update active_node if the removed pane was active
        if (self.active_node) |active| {
            if (active == pane_id) {
                // Pick first leaf in tree as new active
                var buf: [1]u64 = undefined;
                const n = self.getTreePaneIds(&buf);
                self.active_node = if (n > 0) buf[0] else null;
            }
        }
    }

    /// Recursively find and remove the leaf with `pane_id`. Replace parent split with sibling.
    fn removeLeafRecursive(self: *Workspace, idx: u16, pane_id: u64) void {
        switch (self.split_nodes[idx]) {
            .leaf => return,
            .split => |s| {
                // Check if first child is the leaf to remove
                if (self.split_nodes[s.first] == .leaf and self.split_nodes[s.first].leaf == pane_id) {
                    // Replace this split node with the second child
                    self.split_nodes[idx] = self.split_nodes[s.second];
                    return;
                }
                // Check if second child is the leaf to remove
                if (self.split_nodes[s.second] == .leaf and self.split_nodes[s.second].leaf == pane_id) {
                    // Replace this split node with the first child
                    self.split_nodes[idx] = self.split_nodes[s.first];
                    return;
                }
                // Recurse into children
                self.removeLeafRecursive(s.first, pane_id);
                self.removeLeafRecursive(s.second, pane_id);
            },
        }
    }

    /// Depth-first traversal: fill `buf` with pane IDs in order. Returns count.
    pub fn getTreePaneIds(self: *const Workspace, buf: []u64) usize {
        const root = self.split_root orelse return 0;
        var count: usize = 0;
        self.collectPaneIds(root, buf, &count);
        return count;
    }

    fn collectPaneIds(self: *const Workspace, idx: u16, buf: []u64, count: *usize) void {
        switch (self.split_nodes[idx]) {
            .leaf => |id| {
                if (count.* < buf.len) {
                    buf[count.*] = id;
                    count.* += 1;
                }
            },
            .split => |s| {
                self.collectPaneIds(s.first, buf, count);
                self.collectPaneIds(s.second, buf, count);
            },
        }
    }

    /// Walk the tree depth-first, subdivide the screen rect according to split
    /// directions and ratios. Returns rects in same order as `getTreePaneIds()`.
    /// Caller owns returned slice.
    pub fn calculateFromTree(self: *const Workspace, allocator: Allocator, screen: Rect) ![]Rect {
        const root = self.split_root orelse return try allocator.alloc(Rect, 0);
        var pane_count: usize = 0;
        self.countLeaves(root, &pane_count);
        const rects = try allocator.alloc(Rect, pane_count);
        var idx: usize = 0;
        self.layoutNode(root, screen, rects, &idx);
        return rects;
    }

    fn countLeaves(self: *const Workspace, idx: u16, count: *usize) void {
        switch (self.split_nodes[idx]) {
            .leaf => count.* += 1,
            .split => |s| {
                self.countLeaves(s.first, count);
                self.countLeaves(s.second, count);
            },
        }
    }

    fn layoutNode(self: *const Workspace, idx: u16, rect: Rect, rects: []Rect, out: *usize) void {
        switch (self.split_nodes[idx]) {
            .leaf => {
                if (out.* < rects.len) {
                    rects[out.*] = rect;
                    out.* += 1;
                }
            },
            .split => |s| {
                var first_rect = rect;
                var second_rect = rect;

                switch (s.dir) {
                    .vertical => {
                        // Split left/right
                        const first_w: u16 = @intFromFloat(@as(f32, @floatFromInt(rect.width)) * s.ratio);
                        const second_w: u16 = rect.width -| first_w;
                        first_rect.width = first_w;
                        second_rect.x = rect.x +| first_w;
                        second_rect.width = second_w;
                    },
                    .horizontal => {
                        // Split top/bottom
                        const first_h: u16 = @intFromFloat(@as(f32, @floatFromInt(rect.height)) * s.ratio);
                        const second_h: u16 = rect.height -| first_h;
                        first_rect.height = first_h;
                        second_rect.y = rect.y +| first_h;
                        second_rect.height = second_h;
                    },
                }

                self.layoutNode(s.first, first_rect, rects, out);
                self.layoutNode(s.second, second_rect, rects, out);
            },
        }
    }

    /// Focus the next pane in depth-first order within the tree.
    pub fn focusNextInTree(self: *Workspace) void {
        var buf: [32]u64 = undefined;
        const count = self.getTreePaneIds(&buf);
        if (count == 0) return;
        const active = self.active_node orelse {
            self.active_node = buf[0];
            return;
        };
        for (buf[0..count], 0..) |id, i| {
            if (id == active) {
                self.active_node = buf[(i + 1) % count];
                return;
            }
        }
        self.active_node = buf[0];
    }

    /// Focus the previous pane in depth-first order within the tree.
    pub fn focusPrevInTree(self: *Workspace) void {
        var buf: [32]u64 = undefined;
        const count = self.getTreePaneIds(&buf);
        if (count == 0) return;
        const active = self.active_node orelse {
            self.active_node = buf[0];
            return;
        };
        for (buf[0..count], 0..) |id, i| {
            if (id == active) {
                self.active_node = buf[if (i == 0) count - 1 else i - 1];
                return;
            }
        }
        self.active_node = buf[count - 1];
    }

    /// Find which split node's border the mouse is near.
    /// Returns the split node index and whether the border is horizontal.
    pub fn findSplitForBorder(
        self: *const Workspace,
        screen: Rect,
        x: u32,
        y: u32,
        zone: u32,
    ) ?BorderHit {
        const root = self.split_root orelse return null;
        return self.findBorderRecursive(root, screen, x, y, zone);
    }

    fn findBorderRecursive(
        self: *const Workspace,
        idx: u16,
        rect: Rect,
        x: u32,
        y: u32,
        zone: u32,
    ) ?BorderHit {
        switch (self.split_nodes[idx]) {
            .leaf => return null,
            .split => |s| {
                var first_rect = rect;
                var second_rect = rect;
                var border_pos: u32 = 0;
                var is_horizontal = false;

                switch (s.dir) {
                    .vertical => {
                        const first_w: u16 = @intFromFloat(@as(f32, @floatFromInt(rect.width)) * s.ratio);
                        first_rect.width = first_w;
                        second_rect.x = rect.x +| first_w;
                        second_rect.width = rect.width -| first_w;
                        border_pos = @as(u32, rect.x) + first_w;
                        is_horizontal = false;
                    },
                    .horizontal => {
                        const first_h: u16 = @intFromFloat(@as(f32, @floatFromInt(rect.height)) * s.ratio);
                        first_rect.height = first_h;
                        second_rect.y = rect.y +| first_h;
                        second_rect.height = rect.height -| first_h;
                        border_pos = @as(u32, rect.y) + first_h;
                        is_horizontal = true;
                    },
                }

                // Check if mouse is near this split's border
                if (!is_horizontal) {
                    // Vertical split: border is a vertical line at border_pos
                    if (x >= border_pos -| zone and x <= border_pos + zone and
                        y >= rect.y and y < @as(u32, rect.y) + rect.height)
                    {
                        return .{ .node_idx = idx, .is_horizontal = false };
                    }
                } else {
                    // Horizontal split: border is a horizontal line at border_pos
                    if (y >= border_pos -| zone and y <= border_pos + zone and
                        x >= rect.x and x < @as(u32, rect.x) + rect.width)
                    {
                        return .{ .node_idx = idx, .is_horizontal = true };
                    }
                }

                // Recurse into children (depth-first, check deeper splits first)
                return self.findBorderRecursive(s.first, first_rect, x, y, zone) orelse
                    self.findBorderRecursive(s.second, second_rect, x, y, zone);
            },
        }
    }

    /// Set the ratio on a split node, clamped to [0.15, 0.85].
    pub fn resizeSplit(self: *Workspace, node_idx: u16, new_ratio: f32) void {
        if (node_idx >= self.split_node_count) return;
        switch (self.split_nodes[node_idx]) {
            .split => |*s| {
                s.ratio = std.math.clamp(new_ratio, 0.15, 0.85);
            },
            .leaf => {},
        }
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
/// When the split tree has nodes, uses the tree layout. Otherwise falls back
/// to the classic flat-list layout (master-stack, grid, monocle, floating).
/// Caller owns the returned slice and must free it with the same allocator.
pub fn calculate(self: *LayoutEngine, workspace_index: u8, screen: Rect) ![]Rect {
    if (workspace_index >= 9) return error.InvalidWorkspace;
    const ws = &self.workspaces[workspace_index];

    // Use tree layout when the tree has nodes
    if (ws.split_root != null) {
        return ws.calculateFromTree(self.allocator, screen);
    }

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

// ── Split tree tests ───────────────────────────────────────────

fn testWorkspace() Workspace {
    return Workspace.init("test");
}

test "addNodeSplit — first pane creates single leaf" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 100, .vertical);
    try t.expectEqual(@as(?u16, 0), ws.split_root);
    try t.expectEqual(@as(u16, 1), ws.split_node_count);
    try t.expectEqual(@as(?u64, 100), ws.active_node);

    // Tree contains one leaf
    var buf: [4]u64 = undefined;
    const n = ws.getTreePaneIds(&buf);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(@as(u64, 100), buf[0]);
}

test "addNodeSplit — second pane creates vertical split" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    try ws.addNodeSplit(a, 2, .vertical);

    // 3 nodes used: root split + 2 leaves
    try t.expectEqual(@as(u16, 3), ws.split_node_count);
    try t.expectEqual(@as(?u64, 2), ws.active_node);

    var buf: [4]u64 = undefined;
    const n = ws.getTreePaneIds(&buf);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(@as(u64, 1), buf[0]); // first (depth-first)
    try t.expectEqual(@as(u64, 2), buf[1]); // second
}

test "addNodeSplit — prevents duplicate pane IDs" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    try ws.addNodeSplit(a, 1, .vertical); // duplicate, should be no-op
    try t.expectEqual(@as(u16, 1), ws.split_node_count);
}

test "addNodeSplit — three panes, mixed directions" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 10, .vertical);
    try ws.addNodeSplit(a, 20, .vertical); // split 10 vertically: [10 | 20]
    try ws.addNodeSplit(a, 30, .horizontal); // split 20 horizontally: [10 | [20 / 30]]

    var buf: [4]u64 = undefined;
    const n = ws.getTreePaneIds(&buf);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(u64, 10), buf[0]);
    try t.expectEqual(@as(u64, 20), buf[1]);
    try t.expectEqual(@as(u64, 30), buf[2]);
}

test "calculateFromTree — single pane gets full screen" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    const screen: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const rects = try ws.calculateFromTree(a, screen);
    defer a.free(rects);

    try t.expectEqual(@as(usize, 1), rects.len);
    try t.expect(rects[0].eql(screen));
}

test "calculateFromTree — vertical split 50/50" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    try ws.addNodeSplit(a, 2, .vertical);
    const screen: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const rects = try ws.calculateFromTree(a, screen);
    defer a.free(rects);

    try t.expectEqual(@as(usize, 2), rects.len);
    // First pane: left half
    try t.expectEqual(@as(u16, 0), rects[0].x);
    try t.expectEqual(@as(u16, 500), rects[0].width);
    try t.expectEqual(@as(u16, 800), rects[0].height);
    // Second pane: right half
    try t.expectEqual(@as(u16, 500), rects[1].x);
    try t.expectEqual(@as(u16, 500), rects[1].width);
    try t.expectEqual(@as(u16, 800), rects[1].height);
}

test "calculateFromTree — horizontal split 50/50" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .horizontal);
    try ws.addNodeSplit(a, 2, .horizontal);
    const screen: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const rects = try ws.calculateFromTree(a, screen);
    defer a.free(rects);

    try t.expectEqual(@as(usize, 2), rects.len);
    // First pane: top half
    try t.expectEqual(@as(u16, 0), rects[0].y);
    try t.expectEqual(@as(u16, 400), rects[0].height);
    try t.expectEqual(@as(u16, 1000), rects[0].width);
    // Second pane: bottom half
    try t.expectEqual(@as(u16, 400), rects[1].y);
    try t.expectEqual(@as(u16, 400), rects[1].height);
}

test "calculateFromTree — nested splits" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    // Build: [10 | [20 / 30]]
    try ws.addNodeSplit(a, 10, .vertical);
    try ws.addNodeSplit(a, 20, .vertical); // active=20, split vertically
    try ws.addNodeSplit(a, 30, .horizontal); // active=30, split 20 horizontally

    const screen: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const rects = try ws.calculateFromTree(a, screen);
    defer a.free(rects);

    try t.expectEqual(@as(usize, 3), rects.len);
    // Pane 10: left half
    try t.expectEqual(@as(u16, 0), rects[0].x);
    try t.expectEqual(@as(u16, 500), rects[0].width);
    try t.expectEqual(@as(u16, 800), rects[0].height);
    // Pane 20: top-right quarter
    try t.expectEqual(@as(u16, 500), rects[1].x);
    try t.expectEqual(@as(u16, 0), rects[1].y);
    try t.expectEqual(@as(u16, 500), rects[1].width);
    try t.expectEqual(@as(u16, 400), rects[1].height);
    // Pane 30: bottom-right quarter
    try t.expectEqual(@as(u16, 500), rects[2].x);
    try t.expectEqual(@as(u16, 400), rects[2].y);
    try t.expectEqual(@as(u16, 500), rects[2].width);
    try t.expectEqual(@as(u16, 400), rects[2].height);
}

test "removeNodeFromTree — remove from split collapses to sibling" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    try ws.addNodeSplit(a, 2, .vertical);

    // Remove pane 2 — tree should collapse to just pane 1
    ws.removeNodeFromTree(2);
    var buf: [4]u64 = undefined;
    const n = ws.getTreePaneIds(&buf);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(@as(u64, 1), buf[0]);
}

test "removeNodeFromTree — remove first child of split" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    try ws.addNodeSplit(a, 2, .vertical);

    // Remove pane 1 — tree should collapse to just pane 2
    ws.removeNodeFromTree(1);
    var buf: [4]u64 = undefined;
    const n = ws.getTreePaneIds(&buf);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqual(@as(u64, 2), buf[0]);
}

test "removeNodeFromTree — remove only node clears tree" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 42, .vertical);
    ws.removeNodeFromTree(42);
    try t.expectEqual(@as(?u16, null), ws.split_root);
    try t.expectEqual(@as(?u64, null), ws.active_node);
}

test "removeNodeFromTree — remove from nested tree" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    // Build: [10 | [20 / 30]]
    try ws.addNodeSplit(a, 10, .vertical);
    try ws.addNodeSplit(a, 20, .vertical);
    try ws.addNodeSplit(a, 30, .horizontal);

    // Remove pane 20 — should become [10 | 30]
    ws.removeNodeFromTree(20);
    var buf: [4]u64 = undefined;
    const n = ws.getTreePaneIds(&buf);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(@as(u64, 10), buf[0]);
    try t.expectEqual(@as(u64, 30), buf[1]);
}

test "removeNodeFromTree — updates active_node when removed pane was active" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    try ws.addNodeSplit(a, 2, .vertical);
    ws.active_node = 2;

    ws.removeNodeFromTree(2);
    // Should pick first remaining pane as active
    try t.expectEqual(@as(?u64, 1), ws.active_node);
}

test "focusNextInTree — cycles through panes" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 10, .vertical);
    try ws.addNodeSplit(a, 20, .vertical);
    try ws.addNodeSplit(a, 30, .horizontal);

    ws.active_node = 10;
    ws.focusNextInTree();
    try t.expectEqual(@as(?u64, 20), ws.active_node);
    ws.focusNextInTree();
    try t.expectEqual(@as(?u64, 30), ws.active_node);
    ws.focusNextInTree(); // wraps
    try t.expectEqual(@as(?u64, 10), ws.active_node);
}

test "focusPrevInTree — cycles backward" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 10, .vertical);
    try ws.addNodeSplit(a, 20, .vertical);
    try ws.addNodeSplit(a, 30, .horizontal);

    ws.active_node = 10;
    ws.focusPrevInTree(); // wraps to last
    try t.expectEqual(@as(?u64, 30), ws.active_node);
    ws.focusPrevInTree();
    try t.expectEqual(@as(?u64, 20), ws.active_node);
    ws.focusPrevInTree();
    try t.expectEqual(@as(?u64, 10), ws.active_node);
}

test "focusNextInTree — empty tree is no-op" {
    var ws = testWorkspace();
    ws.focusNextInTree();
    try t.expectEqual(@as(?u64, null), ws.active_node);
}

test "findSplitForBorder — detects vertical split border" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    try ws.addNodeSplit(a, 2, .vertical);

    const screen: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    // Border is at x=500 (50% of 1000)
    const result = ws.findSplitForBorder(screen, 500, 400, 4);
    try t.expect(result != null);
    try t.expectEqual(@as(u16, 0), result.?.node_idx); // root split
    try t.expectEqual(false, result.?.is_horizontal);

    // Far from border — no hit
    const miss = ws.findSplitForBorder(screen, 100, 400, 4);
    try t.expect(miss == null);
}

test "findSplitForBorder — detects horizontal split border" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .horizontal);
    try ws.addNodeSplit(a, 2, .horizontal);

    const screen: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    // Border is at y=400 (50% of 800)
    const result = ws.findSplitForBorder(screen, 500, 400, 4);
    try t.expect(result != null);
    try t.expectEqual(true, result.?.is_horizontal);
}

test "findSplitForBorder — empty tree returns null" {
    var ws = testWorkspace();
    try t.expect(ws.findSplitForBorder(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, 50, 50, 4) == null);
}

test "resizeSplit — clamps ratio" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    try ws.addNodeSplit(a, 2, .vertical);

    // Root is a split at index 0
    ws.resizeSplit(0, 0.7);
    try t.expect(ws.split_nodes[0] == .split);
    try t.expectEqual(@as(f32, 0.7), ws.split_nodes[0].split.ratio);

    // Clamp low
    ws.resizeSplit(0, 0.05);
    try t.expectEqual(@as(f32, 0.15), ws.split_nodes[0].split.ratio);

    // Clamp high
    ws.resizeSplit(0, 0.95);
    try t.expectEqual(@as(f32, 0.85), ws.split_nodes[0].split.ratio);
}

test "resizeSplit — no-op on leaf or out-of-bounds" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 1, .vertical);
    // Index 0 is a leaf
    ws.resizeSplit(0, 0.3); // no-op on leaf
    try t.expect(ws.split_nodes[0] == .leaf);

    // Out of bounds
    ws.resizeSplit(99, 0.5); // should not crash
}

test "calculate uses tree when split_root is set" {
    var s = testEngine();
    defer s.engine.deinit();
    const ws = &s.engine.workspaces[0];

    // Use addNodeSplit to populate the tree
    try ws.addNodeSplit(s.allocator, 1, .vertical);
    try ws.addNodeSplit(s.allocator, 2, .vertical);

    const screen: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const rects = try s.engine.calculate(0, screen);
    defer s.allocator.free(rects);

    // Should get tree-based layout (2 panes, 500px each)
    try t.expectEqual(@as(usize, 2), rects.len);
    try t.expectEqual(@as(u16, 500), rects[0].width);
    try t.expectEqual(@as(u16, 500), rects[1].width);
}

test "calculateFromTree — empty tree returns empty slice" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    const rects = try ws.calculateFromTree(a, .{ .x = 0, .y = 0, .width = 100, .height = 100 });
    defer a.free(rects);
    try t.expectEqual(@as(usize, 0), rects.len);
}

test "getTreePaneIds — matches calculateFromTree order" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    try ws.addNodeSplit(a, 10, .vertical);
    try ws.addNodeSplit(a, 20, .vertical);
    try ws.addNodeSplit(a, 30, .horizontal);

    var id_buf: [4]u64 = undefined;
    const id_count = ws.getTreePaneIds(&id_buf);

    const rects = try ws.calculateFromTree(a, .{ .x = 0, .y = 0, .width = 1000, .height = 800 });
    defer a.free(rects);

    // Same count, and depth-first order matches
    try t.expectEqual(rects.len, id_count);
    try t.expectEqual(@as(u64, 10), id_buf[0]);
    try t.expectEqual(@as(u64, 20), id_buf[1]);
    try t.expectEqual(@as(u64, 30), id_buf[2]);
}
