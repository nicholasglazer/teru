//! Binary session serialization and restore.
//!
//! Saves and loads the full terminal state (process graph, workspace layout)
//! to a compact binary format. Used by --attach and detach (prefix+d).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const compat = @import("../compat.zig");

const Session = @This();

// ── Constants ───────────────────────────────────────────────────

const magic = "TERU".*;
const format_version: u16 = 2;

// ── Types ───────────────────────────────────────────────────────

pub const SerializedNode = struct {
    id: u64,
    name: []const u8,
    kind: u8,
    state: u8,
    parent_id: ?u64,
    pid: ?i32,
    exit_code: ?u8,
    started_at: i128,
    ended_at: ?i128,
    workspace: u8,
    agent_group: ?[]const u8,
    agent_role: ?[]const u8,

    pub fn deinit(self: *SerializedNode, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.agent_group) |g| allocator.free(g);
        if (self.agent_role) |r| allocator.free(r);
    }
};

pub const WorkspaceState = struct {
    name: []const u8,
    layout: u8,
    active_index: u16,
    master_ratio: f32,
    pane_count: u16 = 0,
    node_ids: []u64,
};

// ── Session fields ──────────────────────────────────────────────

name: []const u8,
created_at: i128,
last_saved: i128,
graph_snapshot: []SerializedNode,
workspace_states: [10]WorkspaceState,
active_workspace: u8 = 0,
allocator: Allocator,

// ── Serialization ───────────────────────────────────────────────

/// Serialize the process graph into a binary format.
///
/// Format:
///   [4]  magic "TERU"
///   [2]  version u16 LE
///   [16] timestamp i128 LE
///   [4]  node_count u32 LE
///   ...  nodes (variable-length per node)
pub const WorkspaceMeta = struct {
    layout: u8 = 0,
    master_ratio: f32 = 0.55,
    pane_count: u16 = 0,
    active_workspace: u8 = 0,
};

pub fn serialize(graph: *const ProcessGraph, writer: anytype) !void {
    return serializeWithWorkspaces(graph, writer, null);
}

pub fn serializeWithWorkspaces(graph: *const ProcessGraph, writer: anytype, ws_meta: ?*const [10]WorkspaceMeta) !void {
    // Magic + version
    try writer.writeAll(&magic);
    try writer.writeInt(u16, format_version, .little);

    // Timestamp
    const now: i128 = compat.nanoTimestamp();
    try writer.writeInt(i128, now, .little);

    // Node count
    const count: u32 = @intCast(graph.nodeCount());
    try writer.writeInt(u32, count, .little);

    // Iterate all nodes
    var it = graph.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        try serializeNode(node, writer);
    }

    // v2: workspace metadata (10 workspaces)
    if (ws_meta) |meta| {
        try writer.writeByte(meta[0].active_workspace);
        for (meta) |ws| {
            try writer.writeByte(ws.layout);
            try writer.writeInt(u32, @bitCast(ws.master_ratio), .little);
            try writer.writeInt(u16, ws.pane_count, .little);
        }
    } else {
        // Write defaults
        try writer.writeByte(0); // active_workspace
        for (0..10) |_| {
            try writer.writeByte(0); // layout
            try writer.writeInt(u32, @bitCast(@as(f32, 0.55)), .little); // master_ratio
            try writer.writeInt(u16, 0, .little); // pane_count
        }
    }
}

fn serializeNode(node: *const ProcessGraph.Node, writer: anytype) !void {
    // id
    try writer.writeInt(u64, node.id, .little);

    // name (length-prefixed)
    const name_len: u16 = @intCast(node.name.len);
    try writer.writeInt(u16, name_len, .little);
    try writer.writeAll(node.name);

    // kind
    try writer.writeByte(@intFromEnum(node.kind));

    // state
    try writer.writeByte(@intFromEnum(node.state));

    // parent_id (optional)
    if (node.parent) |parent_id| {
        try writer.writeByte(1);
        try writer.writeInt(u64, parent_id, .little);
    } else {
        try writer.writeByte(0);
    }

    // pid (optional)
    if (node.pid) |pid| {
        try writer.writeByte(1);
        try writer.writeInt(i32, pid, .little);
    } else {
        try writer.writeByte(0);
    }

    // exit_code (optional)
    if (node.exit_code) |code| {
        try writer.writeByte(1);
        try writer.writeByte(code);
    } else {
        try writer.writeByte(0);
    }

    // started_at
    try writer.writeInt(i128, node.started_at, .little);

    // ended_at (optional)
    if (node.ended_at) |ended| {
        try writer.writeByte(1);
        try writer.writeInt(i128, ended, .little);
    } else {
        try writer.writeByte(0);
    }

    // workspace
    try writer.writeByte(node.workspace);

    // agent metadata (optional)
    if (node.agent) |agent| {
        try writer.writeByte(1);
        // agent_group
        const group_len: u16 = @intCast(agent.group.len);
        try writer.writeInt(u16, group_len, .little);
        try writer.writeAll(agent.group);
        // agent_role
        const role_len: u16 = @intCast(agent.role.len);
        try writer.writeInt(u16, role_len, .little);
        try writer.writeAll(agent.role);
    } else {
        try writer.writeByte(0);
    }
}

// ── Deserialization ─────────────────────────────────────────────

/// Deserialize a binary session back into a Session struct.
/// Caller owns the returned Session and must call deinit().
pub fn deserialize(reader: anytype, allocator: Allocator) !Session {
    // Validate magic
    var magic_buf: [4]u8 = undefined;
    const bytes_read = try reader.readAll(&magic_buf);
    if (bytes_read != 4 or !std.mem.eql(u8, &magic_buf, &magic)) {
        return error.InvalidFormat;
    }

    // Version (accept v1 and v2)
    const version = try reader.readInt(u16, .little);
    if (version != 1 and version != 2) {
        return error.UnsupportedVersion;
    }

    // Timestamp
    const timestamp = try reader.readInt(i128, .little);

    // Node count
    const count = try reader.readInt(u32, .little);

    // Allocate nodes
    const nodes = try allocator.alloc(SerializedNode, count);
    errdefer {
        for (nodes[0..count]) |*n| {
            n.deinit(allocator);
        }
        allocator.free(nodes);
    }

    for (0..count) |i| {
        nodes[i] = try deserializeNode(reader, allocator);
    }

    // Workspace states
    var ws: [10]WorkspaceState = undefined;
    var active_ws: u8 = 0;
    if (version >= 2) {
        // v2: read workspace metadata
        active_ws = try reader.readByte();
        for (0..10) |i| {
            const layout = try reader.readByte();
            const ratio_bits = try reader.readInt(u32, .little);
            const pane_count = try reader.readInt(u16, .little);
            ws[i] = .{
                .name = "",
                .layout = layout,
                .active_index = 0,
                .master_ratio = @bitCast(ratio_bits),
                .pane_count = pane_count,
                .node_ids = &.{},
            };
        }
    } else {
        for (0..10) |i| {
            ws[i] = .{
                .name = "",
                .layout = 0,
                .active_index = 0,
                .master_ratio = 0.55,
                .pane_count = 0,
                .node_ids = &.{},
            };
        }
    }

    return .{
        .name = "",
        .created_at = timestamp,
        .last_saved = timestamp,
        .graph_snapshot = nodes,
        .workspace_states = ws,
        .active_workspace = active_ws,
        .allocator = allocator,
    };
}

fn deserializeNode(reader: anytype, allocator: Allocator) !SerializedNode {
    // id
    const id = try reader.readInt(u64, .little);

    // name
    const name_len = try reader.readInt(u16, .little);
    const name = try allocator.alloc(u8, name_len);
    errdefer allocator.free(name);
    const name_read = try reader.readAll(name);
    if (name_read != name_len) return error.UnexpectedEof;

    // kind, state
    const kind = try reader.readByte();
    const state = try reader.readByte();

    // parent_id
    const has_parent = try reader.readByte();
    const parent_id: ?u64 = if (has_parent == 1) try reader.readInt(u64, .little) else null;

    // pid
    const has_pid = try reader.readByte();
    const pid: ?i32 = if (has_pid == 1) try reader.readInt(i32, .little) else null;

    // exit_code
    const has_exit_code = try reader.readByte();
    const exit_code_val: ?u8 = if (has_exit_code == 1) try reader.readByte() else null;

    // started_at
    const started_at = try reader.readInt(i128, .little);

    // ended_at
    const has_ended_at = try reader.readByte();
    const ended_at: ?i128 = if (has_ended_at == 1) try reader.readInt(i128, .little) else null;

    // workspace
    const workspace = try reader.readByte();

    // agent metadata
    const has_agent = try reader.readByte();
    var agent_group: ?[]const u8 = null;
    var agent_role: ?[]const u8 = null;
    errdefer {
        if (agent_group) |g| allocator.free(g);
        if (agent_role) |r| allocator.free(r);
    }

    if (has_agent == 1) {
        const group_len = try reader.readInt(u16, .little);
        const group = try allocator.alloc(u8, group_len);
        errdefer allocator.free(group);
        const group_read = try reader.readAll(group);
        if (group_read != group_len) return error.UnexpectedEof;

        const role_len = try reader.readInt(u16, .little);
        const role = try allocator.alloc(u8, role_len);
        const role_read = try reader.readAll(role);
        if (role_read != role_len) {
            allocator.free(role);
            allocator.free(group);
            return error.UnexpectedEof;
        }

        agent_group = group;
        agent_role = role;
    }

    return .{
        .id = id,
        .name = name,
        .kind = kind,
        .state = state,
        .parent_id = parent_id,
        .pid = pid,
        .exit_code = exit_code_val,
        .started_at = started_at,
        .ended_at = ended_at,
        .workspace = workspace,
        .agent_group = agent_group,
        .agent_role = agent_role,
    };
}

// ── File operations ─────────────────────────────────────────────

/// Serialize the graph and write to a file at the given path.
pub fn saveToFile(graph: *const ProcessGraph, path: []const u8, io: Io) !void {
    return saveToFileWithWorkspaces(graph, path, io, null);
}

/// Serialize the graph with workspace metadata and write to a file.
pub fn saveToFileWithWorkspaces(graph: *const ProcessGraph, path: []const u8, io: Io, ws_meta: ?*const [10]WorkspaceMeta) !void {
    // Serialize to dynamic memory buffer
    var dyn = compat.DynWriter{ .allocator = std.heap.page_allocator };
    defer dyn.deinit();
    try serializeWithWorkspaces(graph, &dyn, ws_meta);

    // Write to file
    const file = Dir.cwd().createFile(io, path, .{}) catch return error.CreateFailed;
    defer file.close(io);
    file.writeStreamingAll(io, dyn.getWritten()) catch return error.WriteFailed;
}

/// Read a session from a file at the given path.
/// Caller owns the returned Session and must call deinit().
pub fn loadFromFile(path: []const u8, allocator: Allocator, io: Io) !Session {
    const file = Dir.cwd().openFile(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);

    // Read file into dynamic buffer
    const s = file.stat(io) catch return error.StatFailed;
    const size: usize = @intCast(s.size);
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    const n = file.readPositionalAll(io, data, 0) catch return error.ReadFailed;

    // Deserialize from memory
    var reader = compat.MemReader{ .buffer = data[0..n] };
    return deserialize(&reader, allocator);
}

// ── Session directory ───────────────────────────────────────────

/// Returns the session directory path.
/// Checks $XDG_STATE_HOME/teru/sessions/ first, falls back to ~/.local/state/teru/sessions/.
/// Caller owns the returned slice.
pub fn getSessionDir(allocator: Allocator) ![]const u8 {
    if (compat.getenv("XDG_STATE_HOME")) |state_home| {
        return std.fmt.allocPrint(allocator, "{s}/teru/sessions", .{state_home});
    }

    const home = compat.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.local/state/teru/sessions", .{home});
}

// ── Cleanup ─────────────────────────────────────────────────────

pub fn deinit(self: *Session) void {
    for (self.graph_snapshot) |*node| {
        node.deinit(self.allocator);
    }
    self.allocator.free(self.graph_snapshot);
}

// ── Tests ───────────────────────────────────────────────────────

test "serialize and deserialize empty graph" {
    const allocator = std.testing.allocator;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    // Serialize
    var buf: [256]u8 = undefined;
    var writer = compat.MemWriter{ .buffer = &buf };
    try serialize(&graph, &writer);

    // Deserialize
    const written = writer.getWritten();
    var reader = compat.MemReader{ .buffer = written };
    var session = try deserialize(&reader, allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 0), session.graph_snapshot.len);
}

test "serialize and deserialize graph with 5 mixed nodes" {
    const allocator = std.testing.allocator;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    // Spawn 5 nodes: 2 shells, 1 process, 2 agents
    const shell1 = try graph.spawn(.{ .name = "zsh", .workspace = 1 });
    const shell2 = try graph.spawn(.{ .name = "bash", .workspace = 2 });
    const proc1 = try graph.spawn(.{
        .name = "vim",
        .kind = .process,
        .parent = shell1,
        .pid = 12345,
        .workspace = 1,
    });
    const agent1 = try graph.spawn(.{
        .name = "backend-dev",
        .kind = .agent,
        .workspace = 3,
        .agent = .{ .group = "team-temporal", .role = "implementer" },
    });
    const agent2 = try graph.spawn(.{
        .name = "frontend-dev",
        .kind = .agent,
        .parent = agent1,
        .workspace = 3,
        .agent = .{ .group = "team-temporal", .role = "reviewer" },
    });

    // Mark one finished
    graph.markFinished(proc1, 0);

    try std.testing.expectEqual(@as(usize, 5), graph.nodeCount());

    // Serialize
    var buf: [4096]u8 = undefined;
    var writer = compat.MemWriter{ .buffer = &buf };
    try serialize(&graph, &writer);

    // Deserialize
    const written = writer.getWritten();
    var reader = compat.MemReader{ .buffer = written };
    var session = try deserialize(&reader, allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 5), session.graph_snapshot.len);

    // Build a lookup by id for verification (order may differ from insertion)
    var found_shell1 = false;
    var found_shell2 = false;
    var found_proc1 = false;
    var found_agent1 = false;
    var found_agent2 = false;

    for (session.graph_snapshot) |sn| {
        if (sn.id == shell1) {
            found_shell1 = true;
            try std.testing.expectEqualStrings("zsh", sn.name);
            try std.testing.expectEqual(@as(u8, 0), sn.kind); // shell
            try std.testing.expectEqual(@as(u8, 0), sn.state); // running
            try std.testing.expectEqual(@as(?u64, null), sn.parent_id);
            try std.testing.expectEqual(@as(u8, 1), sn.workspace);
        } else if (sn.id == shell2) {
            found_shell2 = true;
            try std.testing.expectEqualStrings("bash", sn.name);
            try std.testing.expectEqual(@as(u8, 2), sn.workspace);
        } else if (sn.id == proc1) {
            found_proc1 = true;
            try std.testing.expectEqualStrings("vim", sn.name);
            try std.testing.expectEqual(@as(u8, 1), sn.kind); // process
            try std.testing.expectEqual(@as(u8, 2), sn.state); // finished
            try std.testing.expectEqual(shell1, sn.parent_id.?);
            try std.testing.expectEqual(@as(i32, 12345), sn.pid.?);
            try std.testing.expectEqual(@as(u8, 0), sn.exit_code.?);
            try std.testing.expect(sn.ended_at != null);
        } else if (sn.id == agent1) {
            found_agent1 = true;
            try std.testing.expectEqualStrings("backend-dev", sn.name);
            try std.testing.expectEqual(@as(u8, 2), sn.kind); // agent
            try std.testing.expectEqual(@as(u8, 3), sn.workspace);
        } else if (sn.id == agent2) {
            found_agent2 = true;
            try std.testing.expectEqualStrings("frontend-dev", sn.name);
            try std.testing.expectEqual(agent1, sn.parent_id.?);
        }
    }

    try std.testing.expect(found_shell1);
    try std.testing.expect(found_shell2);
    try std.testing.expect(found_proc1);
    try std.testing.expect(found_agent1);
    try std.testing.expect(found_agent2);
}

test "agent metadata round-trip" {
    const allocator = std.testing.allocator;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    _ = try graph.spawn(.{
        .name = "code-reviewer",
        .kind = .agent,
        .agent = .{ .group = "team-qa", .role = "auditor" },
    });

    // Serialize
    var buf: [2048]u8 = undefined;
    var writer = compat.MemWriter{ .buffer = &buf };
    try serialize(&graph, &writer);

    // Deserialize
    const written = writer.getWritten();
    var reader = compat.MemReader{ .buffer = written };
    var session = try deserialize(&reader, allocator);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 1), session.graph_snapshot.len);
    const sn = session.graph_snapshot[0];
    try std.testing.expectEqualStrings("team-qa", sn.agent_group.?);
    try std.testing.expectEqualStrings("auditor", sn.agent_role.?);
}

test "file save and load round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    const shell = try graph.spawn(.{ .name = "zsh", .pid = 42, .workspace = 1 });
    _ = try graph.spawn(.{
        .name = "cargo",
        .kind = .process,
        .parent = shell,
        .pid = 9999,
        .workspace = 1,
    });
    _ = try graph.spawn(.{
        .name = "lead",
        .kind = .agent,
        .workspace = 2,
        .agent = .{ .group = "team-deploy", .role = "coordinator" },
    });

    const tmp_path = "/tmp/teru-session-test.bin";

    // Save
    try saveToFile(&graph, tmp_path, io);

    // Load
    var session = try loadFromFile(tmp_path, allocator, io);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 3), session.graph_snapshot.len);

    // Verify we can find each node
    var found_zsh = false;
    var found_cargo = false;
    var found_lead = false;

    for (session.graph_snapshot) |sn| {
        if (std.mem.eql(u8, sn.name, "zsh")) {
            found_zsh = true;
            try std.testing.expectEqual(@as(i32, 42), sn.pid.?);
        } else if (std.mem.eql(u8, sn.name, "cargo")) {
            found_cargo = true;
            try std.testing.expectEqual(@as(i32, 9999), sn.pid.?);
            try std.testing.expectEqual(shell, sn.parent_id.?);
        } else if (std.mem.eql(u8, sn.name, "lead")) {
            found_lead = true;
            try std.testing.expectEqualStrings("team-deploy", sn.agent_group.?);
            try std.testing.expectEqualStrings("coordinator", sn.agent_role.?);
        }
    }

    try std.testing.expect(found_zsh);
    try std.testing.expect(found_cargo);
    try std.testing.expect(found_lead);

    // Clean up temp file
    Dir.cwd().deleteFile(io, "/tmp/teru-session-test.bin") catch {};
}
