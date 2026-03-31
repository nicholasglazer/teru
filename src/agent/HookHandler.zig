const std = @import("std");

/// Claude Code Hook Handler.
///
/// When teru registers as a hook handler for Claude Code, the harness
/// sends JSON on stdin describing lifecycle events (subagent start/stop,
/// task created/completed, teammate idle, etc.).
///
/// This module parses that JSON into teru's internal `HookEvent` union
/// so the process graph can react (add/remove agent nodes, update status).
///
/// JSON format (stdin, one object per invocation):
/// ```json
/// {
///   "session_id": "abc123",
///   "hook_event_name": "SubagentStart",
///   "agent_id": "agent-xyz",
///   "agent_type": "backend-dev",
///   "cwd": "/home/user/project"
/// }
/// ```

pub const HookEvent = union(enum) {
    // Agent lifecycle
    subagent_start: SubagentStart,
    subagent_stop: SubagentStop,
    teammate_idle: TeammateIdle,

    // Task management
    task_created: TaskCreated,
    task_completed: TaskCompleted,

    // Tool activity
    pre_tool_use: PreToolUse,
    post_tool_use: PostToolUse,
    post_tool_use_failure: PostToolUseFailure,

    // Session lifecycle
    session_start: SessionStart,
    session_end,
    stop: Stop,
    stop_failure: StopFailure,

    // Notifications
    notification: Notification,

    // Context management
    pre_compact,
    post_compact,

    unknown,

    pub const SubagentStart = struct {
        agent_id: []const u8,
        agent_type: []const u8,
    };

    pub const SubagentStop = struct {
        agent_id: []const u8,
    };

    pub const TaskCreated = struct {
        task_id: []const u8,
        description: []const u8,
    };

    pub const TaskCompleted = struct {
        task_id: []const u8,
    };

    pub const TeammateIdle = struct {
        agent_id: []const u8,
    };

    pub const PreToolUse = struct {
        tool_name: []const u8,
    };

    pub const PostToolUse = struct {
        tool_name: []const u8,
    };

    pub const PostToolUseFailure = struct {
        tool_name: []const u8,
        error_msg: []const u8,
    };

    pub const SessionStart = struct {
        session_id: []const u8,
    };

    pub const Stop = struct {
        reason: []const u8,
    };

    pub const StopFailure = struct {
        error_class: []const u8,
    };

    pub const Notification = struct {
        notification_type: []const u8,
    };
};

/// Parse a Claude Code hook JSON payload into a HookEvent.
///
/// The caller owns the returned slices — they point into the parsed
/// JSON tree which lives until `parsed.deinit()` is called. To keep
/// the data beyond the parse lifetime, dupe the strings with the
/// provided allocator.
///
/// Returns `.unknown` for unrecognized event names (forward-compatible).
pub fn parseHookEvent(json: []const u8, allocator: std.mem.Allocator) !HookEvent {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json,
        .{},
    );
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };

    const event_name = switch (obj.get("hook_event_name") orelse return error.MissingEventName) {
        .string => |s| s,
        else => return error.InvalidEventName,
    };

    if (std.mem.eql(u8, event_name, "SubagentStart")) {
        const agent_id = try getStr(obj, "agent_id");
        const agent_type = try getStr(obj, "agent_type");
        // Dupe strings so they outlive the parsed JSON tree.
        return .{ .subagent_start = .{
            .agent_id = try allocator.dupe(u8, agent_id),
            .agent_type = try allocator.dupe(u8, agent_type),
        } };
    }

    if (std.mem.eql(u8, event_name, "SubagentStop")) {
        const agent_id = try getStr(obj, "agent_id");
        return .{ .subagent_stop = .{
            .agent_id = try allocator.dupe(u8, agent_id),
        } };
    }

    if (std.mem.eql(u8, event_name, "TaskCreated")) {
        const task_id = try getStr(obj, "task_id");
        const description = try getStr(obj, "task_description");
        return .{ .task_created = .{
            .task_id = try allocator.dupe(u8, task_id),
            .description = try allocator.dupe(u8, description),
        } };
    }

    if (std.mem.eql(u8, event_name, "TaskCompleted")) {
        const task_id = try getStr(obj, "task_id");
        return .{ .task_completed = .{
            .task_id = try allocator.dupe(u8, task_id),
        } };
    }

    if (std.mem.eql(u8, event_name, "TeammateIdle")) {
        const agent_id = try getStr(obj, "agent_id");
        return .{ .teammate_idle = .{
            .agent_id = try allocator.dupe(u8, agent_id),
        } };
    }

    if (std.mem.eql(u8, event_name, "PreToolUse")) {
        const tool_name = getStr(obj, "tool_name") catch "unknown";
        return .{ .pre_tool_use = .{
            .tool_name = try allocator.dupe(u8, tool_name),
        } };
    }

    if (std.mem.eql(u8, event_name, "PostToolUse")) {
        const tool_name = getStr(obj, "tool_name") catch "unknown";
        return .{ .post_tool_use = .{
            .tool_name = try allocator.dupe(u8, tool_name),
        } };
    }

    if (std.mem.eql(u8, event_name, "PostToolUseFailure")) {
        const tool_name = getStr(obj, "tool_name") catch "unknown";
        const error_msg = getStr(obj, "error") catch "unknown error";
        return .{ .post_tool_use_failure = .{
            .tool_name = try allocator.dupe(u8, tool_name),
            .error_msg = try allocator.dupe(u8, error_msg),
        } };
    }

    if (std.mem.eql(u8, event_name, "SessionStart")) {
        const session_id = getStr(obj, "session_id") catch "unknown";
        return .{ .session_start = .{
            .session_id = try allocator.dupe(u8, session_id),
        } };
    }

    if (std.mem.eql(u8, event_name, "SessionEnd")) {
        return .session_end;
    }

    if (std.mem.eql(u8, event_name, "Stop")) {
        const reason = getStr(obj, "stop_reason") catch "end_turn";
        return .{ .stop = .{
            .reason = try allocator.dupe(u8, reason),
        } };
    }

    if (std.mem.eql(u8, event_name, "StopFailure")) {
        const error_class = getStr(obj, "error_class") catch "unknown";
        return .{ .stop_failure = .{
            .error_class = try allocator.dupe(u8, error_class),
        } };
    }

    if (std.mem.eql(u8, event_name, "Notification")) {
        const ntype = getStr(obj, "notification_type") catch "unknown";
        return .{ .notification = .{
            .notification_type = try allocator.dupe(u8, ntype),
        } };
    }

    if (std.mem.eql(u8, event_name, "PreCompact")) return .pre_compact;
    if (std.mem.eql(u8, event_name, "PostCompact")) return .post_compact;

    return .unknown;
}

/// Extract a string field from a JSON object, or return an error.
fn getStr(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (obj.get(key) orelse return error.MissingField) {
        .string => |s| s,
        else => error.InvalidFieldType,
    };
}

/// Free all heap-allocated strings inside a HookEvent.
pub fn freeHookEvent(event: *const HookEvent, allocator: std.mem.Allocator) void {
    switch (event.*) {
        .subagent_start => |e| {
            allocator.free(e.agent_id);
            allocator.free(e.agent_type);
        },
        .subagent_stop => |e| allocator.free(e.agent_id),
        .task_created => |e| {
            allocator.free(e.task_id);
            allocator.free(e.description);
        },
        .task_completed => |e| allocator.free(e.task_id),
        .teammate_idle => |e| allocator.free(e.agent_id),
        .pre_tool_use => |e| allocator.free(e.tool_name),
        .post_tool_use => |e| allocator.free(e.tool_name),
        .post_tool_use_failure => |e| {
            allocator.free(e.tool_name);
            allocator.free(e.error_msg);
        },
        .session_start => |e| allocator.free(e.session_id),
        .stop => |e| allocator.free(e.reason),
        .stop_failure => |e| allocator.free(e.error_class),
        .notification => |e| allocator.free(e.notification_type),
        .session_end, .pre_compact, .post_compact, .unknown => {},
    }
}

// ── Tests ────────────────────────────────────────────────────────

test "parse SubagentStart" {
    const json =
        \\{"session_id":"s1","hook_event_name":"SubagentStart","agent_id":"agent-abc","agent_type":"backend-dev","cwd":"/home/user/project"}
    ;
    const event = try parseHookEvent(json, std.testing.allocator);
    defer freeHookEvent(&event, std.testing.allocator);

    switch (event) {
        .subagent_start => |e| {
            try std.testing.expectEqualStrings("agent-abc", e.agent_id);
            try std.testing.expectEqualStrings("backend-dev", e.agent_type);
        },
        else => return error.WrongVariant,
    }
}

test "parse SubagentStop" {
    const json =
        \\{"hook_event_name":"SubagentStop","agent_id":"agent-xyz","last_assistant_message":"done"}
    ;
    const event = try parseHookEvent(json, std.testing.allocator);
    defer freeHookEvent(&event, std.testing.allocator);

    switch (event) {
        .subagent_stop => |e| {
            try std.testing.expectEqualStrings("agent-xyz", e.agent_id);
        },
        else => return error.WrongVariant,
    }
}

test "parse TaskCreated" {
    const json =
        \\{"hook_event_name":"TaskCreated","task_id":"task-001","task_description":"Implement billing API"}
    ;
    const event = try parseHookEvent(json, std.testing.allocator);
    defer freeHookEvent(&event, std.testing.allocator);

    switch (event) {
        .task_created => |e| {
            try std.testing.expectEqualStrings("task-001", e.task_id);
            try std.testing.expectEqualStrings("Implement billing API", e.description);
        },
        else => return error.WrongVariant,
    }
}

test "parse TaskCompleted" {
    const json =
        \\{"hook_event_name":"TaskCompleted","task_id":"task-001","completion_reason":"success"}
    ;
    const event = try parseHookEvent(json, std.testing.allocator);
    defer freeHookEvent(&event, std.testing.allocator);

    switch (event) {
        .task_completed => |e| {
            try std.testing.expectEqualStrings("task-001", e.task_id);
        },
        else => return error.WrongVariant,
    }
}

test "parse TeammateIdle" {
    const json =
        \\{"hook_event_name":"TeammateIdle","agent_id":"agent-idle-1","idle_reason":"waiting for review"}
    ;
    const event = try parseHookEvent(json, std.testing.allocator);
    defer freeHookEvent(&event, std.testing.allocator);

    switch (event) {
        .teammate_idle => |e| {
            try std.testing.expectEqualStrings("agent-idle-1", e.agent_id);
        },
        else => return error.WrongVariant,
    }
}

test "unknown event returns .unknown" {
    const json =
        \\{"hook_event_name":"SomeFutureEvent","data":"whatever"}
    ;
    const event = try parseHookEvent(json, std.testing.allocator);
    defer freeHookEvent(&event, std.testing.allocator);

    try std.testing.expect(event == .unknown);
}

test "missing hook_event_name returns error" {
    const json =
        \\{"agent_id":"a1","agent_type":"test"}
    ;
    const result = parseHookEvent(json, std.testing.allocator);
    try std.testing.expectError(error.MissingEventName, result);
}

test "invalid JSON returns error" {
    // Any parse error is acceptable — just must not succeed.
    if (parseHookEvent("not json at all", std.testing.allocator)) |event| {
        freeHookEvent(&event, std.testing.allocator);
        return error.ShouldHaveFailed;
    } else |_| {}
}

test "extra fields are ignored (forward-compatible)" {
    const json =
        \\{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"t1","extra_field":"ignored","nested":{"a":1}}
    ;
    const event = try parseHookEvent(json, std.testing.allocator);
    defer freeHookEvent(&event, std.testing.allocator);

    switch (event) {
        .subagent_start => |e| {
            try std.testing.expectEqualStrings("a1", e.agent_id);
            try std.testing.expectEqualStrings("t1", e.agent_type);
        },
        else => return error.WrongVariant,
    }
}
