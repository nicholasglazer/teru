//! Workspace: per-workspace state for the tiling layout engine.
//!
//! Tracks layout, node list, focus, master ratio, split tree, and
//! per-workspace layout cycling (xmonad ||| pattern).

const std = @import("std");
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const Rect = types.Rect;
const Layout = types.Layout;
const SplitDirection = types.SplitDirection;
const SplitNode = types.SplitNode;
const max_layouts = types.max_layouts;

const Workspace = @This();

// ── Fields ─────────────────────────────────────────────────────

name: []const u8,
layout: Layout,
prev_layout: ?Layout = null,
node_ids: std.ArrayListUnmanaged(u64),
active_index: usize = 0,
master_ratio: f32 = 0.6,

// Per-workspace layout list (xmonad ||| pattern)
// When layout_count > 0, cycleLayout cycles within this list.
// When layout_count == 0, cycles through all layouts (legacy behavior).
layouts: [max_layouts]Layout = undefined,
layout_count: u8 = 0,
layout_index: u8 = 0,

// Marked master pane — Alt+Shift+M sets, Alt+M focuses
master_id: ?u64 = null,

// Attention flag — set when output arrives in a non-active workspace
attention: bool = false,

// ── Binary split tree (pre-allocated, no heap) ─────────────────
split_nodes: [64]SplitNode = undefined,
split_node_count: u16 = 0,
split_root: ?u16 = null, // index into split_nodes, null = empty tree
active_node: ?u64 = null, // active pane ID for tree operations

// ── Init / Deinit ──────────────────────────────────────────────

pub fn init(name: []const u8) Workspace {
    return .{
        .name = name,
        .layout = .monocle,
        .node_ids = .empty,
    };
}

pub fn deinit(self: *Workspace, allocator: Allocator) void {
    self.node_ids.deinit(allocator);
}

// ── Layout list ────────────────────────────────────────────────

/// Set the workspace layout list. First layout becomes active.
pub fn setLayouts(self: *Workspace, list: []const Layout) void {
    const count = @min(list.len, max_layouts);
    for (0..count) |i| {
        self.layouts[i] = list[i];
    }
    self.layout_count = @intCast(count);
    self.layout_index = 0;
    if (count > 0) {
        self.layout = self.layouts[0];
    }
}

/// Cycle to the next layout in the workspace's layout list.
/// If no list is configured, cycles through all layouts.
pub fn cycleLayout(self: *Workspace) void {
    if (self.layout_count > 1) {
        self.layout_index = (self.layout_index + 1) % self.layout_count;
        self.layout = self.layouts[self.layout_index];
    } else if (self.layout_count == 0) {
        // Legacy: cycle through all layouts
        self.layout = switch (self.layout) {
            .master_stack => .grid,
            .grid => .monocle,
            .monocle => .dishes,
            .dishes => .spiral,
            .spiral => .three_col,
            .three_col => .columns,
            .columns => .accordion,
            .accordion => .master_stack,
        };
    }
    // layout_count == 1: no-op (only one layout)
}

// ── Node management ────────────────────────────────────────────

pub fn addNode(self: *Workspace, allocator: Allocator, id: u64) !void {
    // Prevent duplicates
    for (self.node_ids.items) |existing| {
        if (existing == id) return;
    }
    try self.node_ids.append(allocator, id);
    // Auto-select layout only when no per-workspace layout list is configured
    if (self.layout_count == 0) {
        self.layout = autoSelectLayout(self.node_ids.items.len);
    }
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
    // Auto-select layout only when no per-workspace layout list is configured
    if (self.layout_count == 0) {
        self.layout = autoSelectLayout(self.node_ids.items.len);
    }
}

// ── Focus ──────────────────────────────────────────────────────

pub fn focusNext(self: *Workspace) void {
    if (self.split_root != null) {
        self.focusNextInTree();
        return;
    }
    if (self.node_ids.items.len == 0) return;
    self.active_index = (self.active_index + 1) % self.node_ids.items.len;
}

pub fn focusPrev(self: *Workspace) void {
    if (self.split_root != null) {
        self.focusPrevInTree();
        return;
    }
    if (self.node_ids.items.len == 0) return;
    if (self.active_index == 0) {
        self.active_index = self.node_ids.items.len - 1;
    } else {
        self.active_index -= 1;
    }
}

// ── Swap / Promote ─────────────────────────────────────────────

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

// ── Queries ────────────────────────────────────────────────────

pub fn getActiveNodeId(self: *const Workspace) ?u64 {
    if (self.split_root != null) return self.active_node;
    if (self.node_ids.items.len == 0) return null;
    return self.node_ids.items[self.active_index];
}

pub fn nodeCount(self: *const Workspace) usize {
    return self.node_ids.items.len;
}

pub const BorderHit = struct { node_idx: u16, is_horizontal: bool };

// ── Split tree operations ──────────────────────────────────────

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
    // Maintain the flat list for backward compat (skip if already present)
    var in_flat = false;
    for (self.node_ids.items) |existing| {
        if (existing == pane_id) {
            in_flat = true;
            break;
        }
    }
    if (!in_flat) {
        try self.node_ids.append(allocator, pane_id);
        if (self.layout_count == 0) {
            self.layout = autoSelectLayout(self.node_ids.items.len);
        }
    }

    // Check if pane already exists in the tree
    if (self.split_root) |root| {
        if (self.findLeaf(root, pane_id) != null) return;
    }

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

            const clamped_ratio = std.math.clamp(s.ratio, 0.0, 1.0);
            switch (s.dir) {
                .vertical => {
                    const fw = @as(f32, @floatFromInt(rect.width)) * clamped_ratio;
                    const first_w: u16 = if (fw < 0 or fw > @as(f32, @floatFromInt(std.math.maxInt(u16)))) rect.width / 2 else @intFromFloat(fw);
                    const second_w: u16 = rect.width -| first_w;
                    first_rect.width = first_w;
                    second_rect.x = rect.x +| first_w;
                    second_rect.width = second_w;
                },
                .horizontal => {
                    const fh = @as(f32, @floatFromInt(rect.height)) * clamped_ratio;
                    const first_h: u16 = if (fh < 0 or fh > @as(f32, @floatFromInt(std.math.maxInt(u16)))) rect.height / 2 else @intFromFloat(fh);
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

// ── Auto-select ────────────────────────────────────────────────

pub fn autoSelectLayout(node_count: usize) Layout {
    return switch (node_count) {
        0, 1 => .monocle,
        2, 3, 4 => .master_stack,
        else => .grid,
    };
}

// ── Tests ──────────────────────────────────────────────────────

const t = std.testing;

fn testWorkspace() Workspace {
    return Workspace.init("test");
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

test "setLayouts — sets layout list and activates first" {
    var ws = testWorkspace();
    ws.setLayouts(&.{ .spiral, .grid, .monocle });

    try t.expectEqual(@as(u8, 3), ws.layout_count);
    try t.expectEqual(@as(u8, 0), ws.layout_index);
    try t.expectEqual(Layout.spiral, ws.layout);
}

test "cycleLayout — cycles within layout list" {
    const a = t.allocator;
    var ws = testWorkspace();
    defer ws.deinit(a);

    ws.setLayouts(&.{ .master_stack, .three_col, .monocle });

    try t.expectEqual(Layout.master_stack, ws.layout);
    ws.cycleLayout();
    try t.expectEqual(Layout.three_col, ws.layout);
    ws.cycleLayout();
    try t.expectEqual(Layout.monocle, ws.layout);
    ws.cycleLayout(); // wraps
    try t.expectEqual(Layout.master_stack, ws.layout);
}

test "cycleLayout — single layout list is no-op" {
    var ws = testWorkspace();
    ws.setLayouts(&.{.spiral});
    ws.cycleLayout();
    try t.expectEqual(Layout.spiral, ws.layout);
    ws.cycleLayout();
    try t.expectEqual(Layout.spiral, ws.layout);
}
