//! Node registry for the miozu compositor.
//!
//! Manages the mapping between tiling engine node IDs and their backing
//! surfaces (terminal panes or Wayland clients). Uses a struct-of-arrays
//! layout for cache-friendly tiling calculation — position/size arrays
//! are contiguous in memory so the layout engine touches minimal cache
//! lines when computing rects for all nodes.
//!
//! Fixed capacity (256 nodes). Zero allocation after init. Node IDs are
//! u64 to match libteru's Multiplexer.next_pane_id.

const std = @import("std");
const wlr = @import("wlr.zig");

const Node = @This();

pub const max_nodes = 256;

pub const Kind = enum(u8) {
    empty, // slot is unused
    terminal, // backed by a libteru Pane (software-rendered)
    wayland_surface, // backed by a wlr_xdg_toplevel (GPU-composited)
};

// ── Struct-of-Arrays storage ───────────────────────────────────
// Layout calculation only touches pos/size arrays (64 bytes per 8 nodes).
// Kind and surface pointers are cold data — only accessed on focus change
// or render, never during tiling math.

// Hot path: touched every layout recalculation
pos_x: [max_nodes]i32 = [_]i32{0} ** max_nodes,
pos_y: [max_nodes]i32 = [_]i32{0} ** max_nodes,
width: [max_nodes]u32 = [_]u32{0} ** max_nodes,
height: [max_nodes]u32 = [_]u32{0} ** max_nodes,

// Warm path: touched on workspace switch and focus change
kind: [max_nodes]Kind = [_]Kind{.empty} ** max_nodes,
node_id: [max_nodes]u64 = [_]u64{0} ** max_nodes,
workspace: [max_nodes]u8 = [_]u8{0} ** max_nodes,
floating: [max_nodes]bool = [_]bool{false} ** max_nodes,

// Cold path: touched only on render or surface interaction
scene_tree: [max_nodes]?*wlr.wlr_scene_tree = [_]?*wlr.wlr_scene_tree{null} ** max_nodes,
xdg_toplevel: [max_nodes]?*wlr.wlr_xdg_toplevel = [_]?*wlr.wlr_xdg_toplevel{null} ** max_nodes,

// Identity: touched on MCP queries, name lookups, config rule matching
name: [max_nodes][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** max_nodes,
name_len: [max_nodes]u8 = [_]u8{0} ** max_nodes,
group_id: [max_nodes]u8 = [_]u8{0} ** max_nodes, // 0=none, 1-255=group index
app_id: [max_nodes][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** max_nodes,
app_id_len: [max_nodes]u8 = [_]u8{0} ** max_nodes,

// Bookkeeping
count: u16 = 0,

// ── Public API ─────────────────────────────────────────────────

/// Register a new Wayland surface node. Returns the slot index.
pub fn addSurface(self: *Node, id: u64, ws: u8, toplevel: ?*wlr.wlr_xdg_toplevel, tree: *wlr.wlr_scene_tree) ?u16 {
    const slot = self.findEmptySlot() orelse return null;
    self.kind[slot] = .wayland_surface;
    self.node_id[slot] = id;
    self.workspace[slot] = ws;
    self.xdg_toplevel[slot] = toplevel;
    self.scene_tree[slot] = tree;
    self.pos_x[slot] = 0;
    self.pos_y[slot] = 0;
    self.width[slot] = 0;
    self.height[slot] = 0;
    self.floating[slot] = false;
    self.name_len[slot] = 0;
    self.group_id[slot] = 0;
    self.app_id_len[slot] = 0;
    self.count += 1;
    return slot;
}

/// Register a terminal pane node. Returns the slot index.
pub fn addTerminal(self: *Node, id: u64, ws: u8) ?u16 {
    const slot = self.findEmptySlot() orelse return null;
    self.kind[slot] = .terminal;
    self.node_id[slot] = id;
    self.workspace[slot] = ws;
    self.xdg_toplevel[slot] = null;
    self.scene_tree[slot] = null;
    self.pos_x[slot] = 0;
    self.pos_y[slot] = 0;
    self.width[slot] = 0;
    self.height[slot] = 0;
    self.floating[slot] = false;
    self.name_len[slot] = 0;
    self.group_id[slot] = 0;
    self.app_id_len[slot] = 0;
    self.count += 1;
    return slot;
}

/// Remove a node by its ID. Returns true if found and removed.
pub fn remove(self: *Node, id: u64) bool {
    for (0..max_nodes) |i| {
        if (self.kind[i] != .empty and self.node_id[i] == id) {
            self.kind[i] = .empty;
            self.node_id[i] = 0;
            self.scene_tree[i] = null;
            self.xdg_toplevel[i] = null;
            self.floating[i] = false;
            self.name_len[i] = 0;
            self.group_id[i] = 0;
            self.app_id_len[i] = 0;
            self.count -= 1;
            return true;
        }
    }
    return false;
}

/// Find a node's slot index by its ID.
pub fn findById(self: *const Node, id: u64) ?u16 {
    for (0..max_nodes) |i| {
        if (self.kind[i] != .empty and self.node_id[i] == id) {
            return @intCast(i);
        }
    }
    return null;
}

/// Find a node's slot index by its xdg_toplevel pointer (fast surface lookup on events).
pub fn findByToplevel(self: *const Node, toplevel: *wlr.wlr_xdg_toplevel) ?u16 {
    for (0..max_nodes) |i| {
        if (self.kind[i] == .wayland_surface and self.xdg_toplevel[i] == toplevel) {
            return @intCast(i);
        }
    }
    return null;
}

/// Apply a rect from the LayoutEngine to a node slot.
/// This is the hot-path bridge: layout engine produces rects, we store them
/// and position the scene graph node.
pub fn applyRect(self: *Node, slot: u16, x: i32, y: i32, w: u32, h: u32) void {
    self.pos_x[slot] = x;
    self.pos_y[slot] = y;
    self.width[slot] = w;
    self.height[slot] = h;

    // Position the wlr_scene_tree node (if it exists)
    if (self.scene_tree[slot]) |tree| {
        if (wlr.miozu_scene_tree_node(tree)) |node| {
            wlr.wlr_scene_node_set_position(node, x, y);
        }
    }

    // Resize the xdg toplevel (if it's a Wayland surface)
    if (self.kind[slot] == .wayland_surface) {
        if (self.xdg_toplevel[slot]) |toplevel| {
            _ = wlr.wlr_xdg_toplevel_set_size(toplevel, w, h);
        }
    }
}

/// Count nodes in a specific workspace.
pub fn countInWorkspace(self: *const Node, ws: u8) u16 {
    var n: u16 = 0;
    for (0..max_nodes) |i| {
        if (self.kind[i] != .empty and self.workspace[i] == ws) n += 1;
    }
    return n;
}

// ── Name & Identity ───────────────────────────────────────────

/// Assign a human-readable name to a node (max 31 chars).
pub fn setName(self: *Node, slot: u16, n: []const u8) void {
    const len = @min(n.len, 31);
    @memcpy(self.name[slot][0..len], n[0..len]);
    self.name[slot][len] = 0;
    self.name_len[slot] = @intCast(len);
}

/// Get a node's name (empty slice if unnamed).
pub fn getName(self: *const Node, slot: u16) []const u8 {
    return self.name[slot][0..self.name_len[slot]];
}

/// Store a Wayland app_id for a node.
pub fn setAppId(self: *Node, slot: u16, aid: []const u8) void {
    const len = @min(aid.len, 63);
    @memcpy(self.app_id[slot][0..len], aid[0..len]);
    self.app_id[slot][len] = 0;
    self.app_id_len[slot] = @intCast(len);
}

/// Get a node's app_id (empty slice if none).
pub fn getAppId(self: *const Node, slot: u16) []const u8 {
    return self.app_id[slot][0..self.app_id_len[slot]];
}

/// Find a node by name. If workspace is non-null, only search that workspace.
pub fn findByName(self: *const Node, n: []const u8, ws: ?u8) ?u16 {
    if (n.len == 0) return null;
    for (0..max_nodes) |i| {
        if (self.kind[i] == .empty) continue;
        if (ws) |w| { if (self.workspace[i] != w) continue; }
        if (self.name_len[i] == n.len and std.mem.eql(u8, self.name[i][0..self.name_len[i]], n)) {
            return @intCast(i);
        }
    }
    return null;
}

// ── Internal ───────────────────────────────────────────────────

fn findEmptySlot(self: *const Node) ?u16 {
    for (0..max_nodes) |i| {
        if (self.kind[i] == .empty) return @intCast(i);
    }
    return null; // full
}

// ── Tests ──────────────────────────────────────────────────────

test "add and remove nodes" {
    var reg = Node{};
    try std.testing.expectEqual(@as(u16, 0), reg.count);

    const s1 = reg.addTerminal(100, 0).?;
    try std.testing.expectEqual(@as(u16, 1), reg.count);
    try std.testing.expectEqual(Kind.terminal, reg.kind[s1]);
    try std.testing.expectEqual(@as(u64, 100), reg.node_id[s1]);

    const s2 = reg.addTerminal(200, 1).?;
    try std.testing.expectEqual(@as(u16, 2), reg.count);

    try std.testing.expect(reg.remove(100));
    try std.testing.expectEqual(@as(u16, 1), reg.count);
    try std.testing.expectEqual(Kind.empty, reg.kind[s1]);

    // Slot reuse
    const s3 = reg.addTerminal(300, 0).?;
    try std.testing.expectEqual(s1, s3); // reuses freed slot
    _ = s2;
}

test "findById and findByToplevel" {
    var reg = Node{};
    _ = reg.addTerminal(42, 0);
    _ = reg.addTerminal(99, 1);

    try std.testing.expectEqual(@as(?u16, 0), reg.findById(42));
    try std.testing.expectEqual(@as(?u16, 1), reg.findById(99));
    try std.testing.expectEqual(@as(?u16, null), reg.findById(777));
}

test "applyRect stores position and size" {
    var reg = Node{};
    const slot = reg.addTerminal(1, 0).?;
    reg.applyRect(slot, 100, 200, 960, 540);

    try std.testing.expectEqual(@as(i32, 100), reg.pos_x[slot]);
    try std.testing.expectEqual(@as(i32, 200), reg.pos_y[slot]);
    try std.testing.expectEqual(@as(u32, 960), reg.width[slot]);
    try std.testing.expectEqual(@as(u32, 540), reg.height[slot]);
}

test "countInWorkspace" {
    var reg = Node{};
    _ = reg.addTerminal(1, 0);
    _ = reg.addTerminal(2, 0);
    _ = reg.addTerminal(3, 1);

    try std.testing.expectEqual(@as(u16, 2), reg.countInWorkspace(0));
    try std.testing.expectEqual(@as(u16, 1), reg.countInWorkspace(1));
    try std.testing.expectEqual(@as(u16, 0), reg.countInWorkspace(5));
}

test "setName and findByName" {
    var reg = Node{};
    const s1 = reg.addTerminal(1, 0).?;
    const s2 = reg.addTerminal(2, 0).?;
    const s3 = reg.addTerminal(3, 1).?;

    reg.setName(s1, "editor");
    reg.setName(s2, "terminal");
    reg.setName(s3, "browser");

    try std.testing.expect(std.mem.eql(u8, "editor", reg.getName(s1)));
    try std.testing.expect(std.mem.eql(u8, "terminal", reg.getName(s2)));
    try std.testing.expect(std.mem.eql(u8, "browser", reg.getName(s3)));

    // Find by name (any workspace)
    try std.testing.expectEqual(@as(?u16, s1), reg.findByName("editor", null));
    try std.testing.expectEqual(@as(?u16, s3), reg.findByName("browser", null));
    try std.testing.expectEqual(@as(?u16, null), reg.findByName("nonexistent", null));

    // Find by name (specific workspace)
    try std.testing.expectEqual(@as(?u16, s1), reg.findByName("editor", 0));
    try std.testing.expectEqual(@as(?u16, null), reg.findByName("browser", 0)); // browser is on ws 1
    try std.testing.expectEqual(@as(?u16, s3), reg.findByName("browser", 1));

    // Empty name
    try std.testing.expectEqual(@as(?u16, null), reg.findByName("", null));
}

test "max capacity" {
    var reg = Node{};
    for (0..max_nodes) |i| {
        try std.testing.expect(reg.addTerminal(@intCast(i), 0) != null);
    }
    try std.testing.expectEqual(@as(u16, max_nodes), reg.count);
    try std.testing.expectEqual(@as(?u16, null), reg.addTerminal(999, 0));
}
