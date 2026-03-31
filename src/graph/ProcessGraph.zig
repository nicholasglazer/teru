const std = @import("std");
const Allocator = std.mem.Allocator;

const compat = @import("../compat.zig");
const ProcessGraph = @This();

pub const NodeId = u64;

pub const NodeKind = enum {
    shell,
    process,
    agent,
    group,
};

pub const NodeState = enum {
    running,
    paused,
    finished,
    persisted,
    interrupted,
};

pub const AgentMeta = struct {
    group: []const u8,
    role: []const u8,
    task: ?[]const u8 = null,
    progress: ?f32 = null,
    parent_agent: ?NodeId = null,
};

pub const Node = struct {
    id: NodeId,
    name: []const u8,
    kind: NodeKind,
    state: NodeState,

    // Graph edges
    parent: ?NodeId = null,
    children: std.ArrayListUnmanaged(NodeId) = .empty,

    // Process info
    pid: ?std.posix.pid_t = null,
    exit_code: ?u8 = null,
    started_at: i128,
    ended_at: ?i128 = null,

    // Agent metadata (populated via hooks or OSC protocol)
    agent: ?AgentMeta = null,

    // Workspace assignment
    workspace: u8 = 1,

    pub fn deinit(self: *Node, allocator: Allocator) void {
        self.children.deinit(allocator);
    }
};

// ── Graph state ──────────────────────────────────────────────────

allocator: Allocator,
nodes: std.AutoHashMapUnmanaged(NodeId, Node),
next_id: NodeId = 1,
root_nodes: std.ArrayListUnmanaged(NodeId) = .empty,

pub fn init(allocator: Allocator) ProcessGraph {
    return .{
        .allocator = allocator,
        .nodes = .{},
    };
}

pub fn deinit(self: *ProcessGraph) void {
    var it = self.nodes.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(self.allocator);
    }
    self.nodes.deinit(self.allocator);
    self.root_nodes.deinit(self.allocator);
}

// ── Operations ───────────────────────────────────────────────────

pub fn spawn(self: *ProcessGraph, opts: struct {
    name: []const u8,
    kind: NodeKind = .shell,
    parent: ?NodeId = null,
    pid: ?std.posix.pid_t = null,
    workspace: u8 = 1,
    agent: ?AgentMeta = null,
}) !NodeId {
    const id = self.next_id;
    self.next_id += 1;

    var node = Node{
        .id = id,
        .name = opts.name,
        .kind = opts.kind,
        .state = .running,
        .parent = opts.parent,
        .pid = opts.pid,
        .started_at = compat.nanoTimestamp(),
        .agent = opts.agent,
        .workspace = opts.workspace,
    };

    // Register as child of parent
    if (opts.parent) |parent_id| {
        if (self.nodes.getPtr(parent_id)) |parent_node| {
            try parent_node.children.append(self.allocator, id);
        }
    } else {
        try self.root_nodes.append(self.allocator, id);
    }

    // Initialize children list
    node.children = .empty;

    try self.nodes.put(self.allocator, id, node);
    return id;
}

pub fn remove(self: *ProcessGraph, id: NodeId) void {
    // Remove from parent's children list
    if (self.nodes.get(id)) |node| {
        if (node.parent) |parent_id| {
            if (self.nodes.getPtr(parent_id)) |parent_node| {
                for (parent_node.children.items, 0..) |child_id, i| {
                    if (child_id == id) {
                        _ = parent_node.children.swapRemove(i);
                        break;
                    }
                }
            }
        } else {
            // Remove from root_nodes
            for (self.root_nodes.items, 0..) |root_id, i| {
                if (root_id == id) {
                    _ = self.root_nodes.swapRemove(i);
                    break;
                }
            }
        }
    }

    if (self.nodes.getPtr(id)) |node| {
        node.deinit(self.allocator);
    }
    _ = self.nodes.remove(id);
}

pub fn markFinished(self: *ProcessGraph, id: NodeId, exit_code: u8) void {
    if (self.nodes.getPtr(id)) |node| {
        node.state = .finished;
        node.exit_code = exit_code;
        node.ended_at = compat.nanoTimestamp();
    }
}

pub fn moveToWorkspace(self: *ProcessGraph, id: NodeId, workspace: u8) void {
    if (self.nodes.getPtr(id)) |node| {
        node.workspace = workspace;
    }
}

pub fn reparent(self: *ProcessGraph, id: NodeId, new_parent: ?NodeId) !void {
    const node = self.nodes.getPtr(id) orelse return;

    // Remove from old parent
    if (node.parent) |old_parent_id| {
        if (self.nodes.getPtr(old_parent_id)) |old_parent| {
            for (old_parent.children.items, 0..) |child_id, i| {
                if (child_id == id) {
                    _ = old_parent.children.swapRemove(i);
                    break;
                }
            }
        }
    } else {
        for (self.root_nodes.items, 0..) |root_id, i| {
            if (root_id == id) {
                _ = self.root_nodes.swapRemove(i);
                break;
            }
        }
    }

    // Add to new parent
    if (new_parent) |new_parent_id| {
        if (self.nodes.getPtr(new_parent_id)) |parent_node| {
            try parent_node.children.append(self.allocator, id);
        }
    } else {
        try self.root_nodes.append(self.allocator, id);
    }

    node.parent = new_parent;
}

pub fn updateAgentStatus(self: *ProcessGraph, id: NodeId, task: ?[]const u8, progress: ?f32) void {
    if (self.nodes.getPtr(id)) |node| {
        if (node.agent) |*agent| {
            agent.task = task;
            agent.progress = progress;
        }
    }
}

pub fn getNode(self: *const ProcessGraph, id: NodeId) ?*const Node {
    return self.nodes.getPtr(id);
}

pub fn getNodeMut(self: *ProcessGraph, id: NodeId) ?*Node {
    return self.nodes.getPtr(id);
}

/// Get all nodes in a workspace.
pub fn nodesInWorkspace(self: *const ProcessGraph, workspace: u8, buf: []NodeId) usize {
    var count: usize = 0;
    var it = self.nodes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.workspace == workspace and count < buf.len) {
            buf[count] = entry.key_ptr.*;
            count += 1;
        }
    }
    return count;
}

/// Get all agent nodes in a specific group.
pub fn agentsInGroup(self: *const ProcessGraph, group: []const u8, buf: []NodeId) usize {
    var count: usize = 0;
    var it = self.nodes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.agent) |agent| {
            if (std.mem.eql(u8, agent.group, group) and count < buf.len) {
                buf[count] = entry.key_ptr.*;
                count += 1;
            }
        }
    }
    return count;
}

/// Find an agent node by name. Returns the node ID if found.
pub fn findAgentByName(self: *const ProcessGraph, name: []const u8) ?NodeId {
    var it = self.nodes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.kind == .agent and std.mem.eql(u8, entry.value_ptr.name, name)) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

/// Count agents by state. Returns counts for running, finished-ok, and failed.
pub fn countAgentsByState(self: *const ProcessGraph) struct { running: u32, done: u32, failed: u32 } {
    var running: u32 = 0;
    var done: u32 = 0;
    var failed: u32 = 0;

    var it = self.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.kind == .agent) {
            switch (node.state) {
                .running => running += 1,
                .finished => {
                    if ((node.exit_code orelse 1) == 0) done += 1 else failed += 1;
                },
                else => {},
            }
        }
    }
    return .{ .running = running, .done = done, .failed = failed };
}

/// Count total nodes.
pub fn nodeCount(self: *const ProcessGraph) usize {
    return self.nodes.count();
}

// ── Tests ────────────────────────────────────────────────────────

test "spawn and query nodes" {
    const allocator = std.testing.allocator;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    const root = try graph.spawn(.{ .name = "zsh" });
    const child = try graph.spawn(.{ .name = "vim", .kind = .process, .parent = root });

    try std.testing.expectEqual(@as(usize, 2), graph.nodeCount());

    const root_node = graph.getNode(root).?;
    try std.testing.expectEqual(@as(usize, 1), root_node.children.items.len);
    try std.testing.expectEqual(child, root_node.children.items[0]);

    const child_node = graph.getNode(child).?;
    try std.testing.expectEqual(root, child_node.parent.?);
}

test "reparent node" {
    const allocator = std.testing.allocator;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    const ws1 = try graph.spawn(.{ .name = "workspace-1" });
    const ws2 = try graph.spawn(.{ .name = "workspace-2" });
    const child = try graph.spawn(.{ .name = "shell", .parent = ws1 });

    try graph.reparent(child, ws2);

    const ws1_node = graph.getNode(ws1).?;
    try std.testing.expectEqual(@as(usize, 0), ws1_node.children.items.len);

    const ws2_node = graph.getNode(ws2).?;
    try std.testing.expectEqual(@as(usize, 1), ws2_node.children.items.len);
}

test "agent group query" {
    const allocator = std.testing.allocator;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    _ = try graph.spawn(.{
        .name = "backend-dev",
        .kind = .agent,
        .agent = .{ .group = "team-temporal", .role = "implementer" },
    });
    _ = try graph.spawn(.{
        .name = "frontend-dev",
        .kind = .agent,
        .agent = .{ .group = "team-temporal", .role = "implementer" },
    });
    _ = try graph.spawn(.{
        .name = "other-shell",
        .kind = .shell,
    });

    var buf: [16]NodeId = undefined;
    const count = graph.agentsInGroup("team-temporal", &buf);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "mark finished" {
    const allocator = std.testing.allocator;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    const id = try graph.spawn(.{ .name = "process" });
    graph.markFinished(id, 0);

    const node = graph.getNode(id).?;
    try std.testing.expectEqual(NodeState.finished, node.state);
    try std.testing.expectEqual(@as(u8, 0), node.exit_code.?);
    try std.testing.expect(node.ended_at != null);
}

test "findAgentByName" {
    const allocator = std.testing.allocator;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    const agent_id = try graph.spawn(.{
        .name = "backend-dev",
        .kind = .agent,
        .agent = .{ .group = "team-temporal", .role = "implementer" },
    });
    _ = try graph.spawn(.{ .name = "shell", .kind = .shell });

    try std.testing.expectEqual(agent_id, graph.findAgentByName("backend-dev").?);
    try std.testing.expectEqual(@as(?NodeId, null), graph.findAgentByName("nonexistent"));
    // Shell nodes are not agents — should not be found
    try std.testing.expectEqual(@as(?NodeId, null), graph.findAgentByName("shell"));
}

test "countAgentsByState" {
    const allocator = std.testing.allocator;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    const a1 = try graph.spawn(.{
        .name = "agent-1",
        .kind = .agent,
        .agent = .{ .group = "g", .role = "worker" },
    });
    _ = try graph.spawn(.{
        .name = "agent-2",
        .kind = .agent,
        .agent = .{ .group = "g", .role = "worker" },
    });
    const a3 = try graph.spawn(.{
        .name = "agent-3",
        .kind = .agent,
        .agent = .{ .group = "g", .role = "worker" },
    });
    // Not an agent — should not be counted
    _ = try graph.spawn(.{ .name = "shell", .kind = .shell });

    // All running
    var counts = graph.countAgentsByState();
    try std.testing.expectEqual(@as(u32, 3), counts.running);
    try std.testing.expectEqual(@as(u32, 0), counts.done);
    try std.testing.expectEqual(@as(u32, 0), counts.failed);

    // Finish one with success, one with failure
    graph.markFinished(a1, 0);
    graph.markFinished(a3, 1);
    counts = graph.countAgentsByState();
    try std.testing.expectEqual(@as(u32, 1), counts.running);
    try std.testing.expectEqual(@as(u32, 1), counts.done);
    try std.testing.expectEqual(@as(u32, 1), counts.failed);
}
