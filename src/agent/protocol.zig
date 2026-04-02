const std = @import("std");
const ProcessGraph = @import("../graph/ProcessGraph.zig");

/// Parser for the teru Agent Protocol (OSC 9999).
///
/// Format: ESC ] 9999 ; <command> ; key=value [; key=value]... ST
///
/// Commands:
///   agent:start  — declare this PTY as an agent
///   agent:stop   — agent finished
///   agent:status — update status/progress
///   agent:task   — report current task
///   agent:group  — join/create agent group
///   agent:meta   — arbitrary key-value metadata
pub const AgentCommand = enum {
    start,
    stop,
    status,
    task,
    group,
    meta,
};

pub const AgentEvent = struct {
    command: AgentCommand,
    name: ?[]const u8 = null,
    group: ?[]const u8 = null,
    role: ?[]const u8 = null,
    state: ?[]const u8 = null,
    progress: ?f32 = null,
    task_desc: ?[]const u8 = null,
    exit_status: ?[]const u8 = null,
    summary: ?[]const u8 = null,
};

/// OSC sequence state machine states.
const ParseState = enum {
    ground,
    esc,
    osc,
    osc_9999,
    st_esc,
};

/// Scans a byte buffer for OSC 9999 sequences.
/// Returns parsed events and the remaining (non-OSC) bytes for terminal display.
pub fn scanForAgentSequences(
    input: []const u8,
    events_buf: []AgentEvent,
    passthrough_buf: []u8,
) struct { events: usize, passthrough: usize } {
    var state: ParseState = .ground;
    var event_count: usize = 0;
    var pass_count: usize = 0;
    var payload_start: usize = 0;
    var osc_num_buf: [8]u8 = undefined;
    var osc_num_len: usize = 0;

    for (input, 0..) |byte, i| {
        switch (state) {
            .ground => {
                if (byte == 0x1B) { // ESC
                    state = .esc;
                } else {
                    if (pass_count < passthrough_buf.len) {
                        passthrough_buf[pass_count] = byte;
                        pass_count += 1;
                    }
                }
            },
            .esc => {
                if (byte == ']') { // OSC start
                    state = .osc;
                    osc_num_len = 0;
                } else {
                    // Not an OSC — pass through the ESC + this byte
                    if (pass_count + 1 < passthrough_buf.len) {
                        passthrough_buf[pass_count] = 0x1B;
                        pass_count += 1;
                        passthrough_buf[pass_count] = byte;
                        pass_count += 1;
                    }
                    state = .ground;
                }
            },
            .osc => {
                if (byte >= '0' and byte <= '9') {
                    if (osc_num_len < osc_num_buf.len) {
                        osc_num_buf[osc_num_len] = byte;
                        osc_num_len += 1;
                    }
                } else if (byte == ';' and osc_num_len > 0) {
                    const num_str = osc_num_buf[0..osc_num_len];
                    const num = std.fmt.parseInt(u16, num_str, 10) catch 0;
                    if (num == 9999) {
                        state = .osc_9999;
                        payload_start = i + 1;
                    } else {
                        // Not our OSC — pass through
                        if (pass_count + 2 + osc_num_len < passthrough_buf.len) {
                            passthrough_buf[pass_count] = 0x1B;
                            pass_count += 1;
                            passthrough_buf[pass_count] = ']';
                            pass_count += 1;
                            @memcpy(passthrough_buf[pass_count .. pass_count + osc_num_len], num_str);
                            pass_count += osc_num_len;
                            passthrough_buf[pass_count] = byte;
                            pass_count += 1;
                        }
                        state = .ground;
                    }
                } else {
                    state = .ground;
                }
            },
            .osc_9999 => {
                // Accumulate until ST (ESC \ or BEL)
                if (byte == 0x07) { // BEL = ST
                    if (event_count < events_buf.len) {
                        if (parsePayload(input[payload_start..i])) |event| {
                            events_buf[event_count] = event;
                            event_count += 1;
                        }
                    }
                    state = .ground;
                } else if (byte == 0x1B) {
                    state = .st_esc;
                }
            },
            .st_esc => {
                if (byte == '\\') { // ESC \ = ST
                    if (event_count < events_buf.len) {
                        const end = if (i >= 1) i - 1 else i;
                        if (parsePayload(input[payload_start..end])) |event| {
                            events_buf[event_count] = event;
                            event_count += 1;
                        }
                    }
                }
                state = .ground;
            },
        }
    }

    return .{ .events = event_count, .passthrough = pass_count };
}

/// Parse a raw OSC 9999 payload (without ESC framing) into an AgentEvent.
/// The payload format is: command;key=value;key=value...
/// Returns null if the command is unrecognized.
pub fn parsePayload(payload: []const u8) ?AgentEvent {
    var event = AgentEvent{ .command = .meta };
    var iter = std.mem.splitScalar(u8, payload, ';');

    // First field is the command
    if (iter.next()) |cmd_str| {
        if (std.mem.eql(u8, cmd_str, "agent:start")) {
            event.command = .start;
        } else if (std.mem.eql(u8, cmd_str, "agent:stop")) {
            event.command = .stop;
        } else if (std.mem.eql(u8, cmd_str, "agent:status")) {
            event.command = .status;
        } else if (std.mem.eql(u8, cmd_str, "agent:task")) {
            event.command = .task;
        } else if (std.mem.eql(u8, cmd_str, "agent:group")) {
            event.command = .group;
        } else if (std.mem.eql(u8, cmd_str, "agent:meta")) {
            event.command = .meta;
        } else {
            return null; // Unknown command
        }
    } else {
        return null;
    }

    // Remaining fields are key=value pairs
    while (iter.next()) |field| {
        if (std.mem.indexOfScalar(u8, field, '=')) |eq_pos| {
            const key = field[0..eq_pos];
            const value = field[eq_pos + 1 ..];

            if (std.mem.eql(u8, key, "name")) {
                event.name = value;
            } else if (std.mem.eql(u8, key, "group")) {
                event.group = value;
            } else if (std.mem.eql(u8, key, "role")) {
                event.role = value;
            } else if (std.mem.eql(u8, key, "state")) {
                event.state = value;
            } else if (std.mem.eql(u8, key, "progress")) {
                event.progress = std.fmt.parseFloat(f32, value) catch null;
            } else if (std.mem.eql(u8, key, "task")) {
                event.task_desc = value;
            } else if (std.mem.eql(u8, key, "exit")) {
                event.exit_status = value;
            } else if (std.mem.eql(u8, key, "summary")) {
                event.summary = value;
            }
        }
    }

    return event;
}

// ── Tests ────────────────────────────────────────────────────────

test "parse agent:start with BEL terminator" {
    const input = "\x1b]9999;agent:start;name=backend-dev;group=team-temporal;role=implementer\x07";
    var events: [4]AgentEvent = undefined;
    var passthrough: [256]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 1), result.events);
    try std.testing.expectEqual(@as(usize, 0), result.passthrough);
    try std.testing.expectEqual(AgentCommand.start, events[0].command);
    try std.testing.expectEqualStrings("backend-dev", events[0].name.?);
    try std.testing.expectEqualStrings("team-temporal", events[0].group.?);
    try std.testing.expectEqualStrings("implementer", events[0].role.?);
}

test "parse agent:status with progress" {
    const input = "\x1b]9999;agent:status;state=working;progress=0.6;task=Building API\x07";
    var events: [4]AgentEvent = undefined;
    var passthrough: [256]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 1), result.events);
    try std.testing.expectEqual(AgentCommand.status, events[0].command);
    try std.testing.expectEqualStrings("working", events[0].state.?);
    try std.testing.expect(events[0].progress.? > 0.59 and events[0].progress.? < 0.61);
    try std.testing.expectEqualStrings("Building API", events[0].task_desc.?);
}

test "passthrough non-OSC content" {
    const input = "hello\x1b]9999;agent:start;name=test\x07world";
    var events: [4]AgentEvent = undefined;
    var passthrough: [256]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 1), result.events);
    try std.testing.expectEqual(@as(usize, 10), result.passthrough);
    try std.testing.expectEqualStrings("helloworld", passthrough[0..result.passthrough]);
}

test "ESC backslash ST terminator" {
    const input = "\x1b]9999;agent:stop;exit=success\x1b\\";
    var events: [4]AgentEvent = undefined;
    var passthrough: [256]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 1), result.events);
    try std.testing.expectEqual(AgentCommand.stop, events[0].command);
    try std.testing.expectEqualStrings("success", events[0].exit_status.?);
}

// ── Spec Section 5.1: OSC 9999 command coverage ─────────────────

test "parse agent:stop with exit and summary" {
    const input = "\x1b]9999;agent:stop;exit=success;summary=API implementation complete\x07";
    var events: [4]AgentEvent = undefined;
    var passthrough: [256]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 1), result.events);
    try std.testing.expectEqual(AgentCommand.stop, events[0].command);
    try std.testing.expectEqualStrings("success", events[0].exit_status.?);
    try std.testing.expectEqualStrings("API implementation complete", events[0].summary.?);
}

test "parse agent:task command" {
    const input = "\x1b]9999;agent:task;name=backend-dev;task=Building REST handlers\x07";
    var events: [4]AgentEvent = undefined;
    var passthrough: [256]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 1), result.events);
    try std.testing.expectEqual(AgentCommand.task, events[0].command);
    try std.testing.expectEqualStrings("backend-dev", events[0].name.?);
    try std.testing.expectEqualStrings("Building REST handlers", events[0].task_desc.?);
}

test "parse agent:group command" {
    const input = "\x1b]9999;agent:group;name=frontend-dev;group=team-temporal\x07";
    var events: [4]AgentEvent = undefined;
    var passthrough: [256]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 1), result.events);
    try std.testing.expectEqual(AgentCommand.group, events[0].command);
    try std.testing.expectEqualStrings("frontend-dev", events[0].name.?);
    try std.testing.expectEqualStrings("team-temporal", events[0].group.?);
}

test "parse agent:meta command" {
    const input = "\x1b]9999;agent:meta;name=test-agent\x07";
    var events: [4]AgentEvent = undefined;
    var passthrough: [256]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 1), result.events);
    try std.testing.expectEqual(AgentCommand.meta, events[0].command);
    try std.testing.expectEqualStrings("test-agent", events[0].name.?);
}

test "unknown command returns null (silently ignored)" {
    // Spec: "Unknown commands return null (silently ignored)"
    const payload = "agent:unknown_future;name=x";
    const result = parsePayload(payload);
    try std.testing.expect(result == null);
}

test "unknown key-value pairs are silently ignored (forward-compatible)" {
    // Spec: "Unknown key-value pairs are silently ignored"
    const payload = "agent:start;name=dev;unknown_key=unknown_value;group=g1";
    const event = parsePayload(payload).?;
    try std.testing.expectEqual(AgentCommand.start, event.command);
    try std.testing.expectEqualStrings("dev", event.name.?);
    try std.testing.expectEqualStrings("g1", event.group.?);
}

test "multiple events in a single PTY read buffer" {
    // Spec: "Multiple events can appear in a single PTY read buffer"
    const input = "\x1b]9999;agent:start;name=a1\x07" ++
        "some text between" ++
        "\x1b]9999;agent:status;state=working;progress=0.5\x07" ++
        "\x1b]9999;agent:stop;exit=success\x07";
    var events: [8]AgentEvent = undefined;
    var passthrough: [256]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 3), result.events);
    try std.testing.expectEqual(AgentCommand.start, events[0].command);
    try std.testing.expectEqual(AgentCommand.status, events[1].command);
    try std.testing.expectEqual(AgentCommand.stop, events[2].command);
    // Passthrough should contain "some text between"
    try std.testing.expectEqualStrings("some text between", passthrough[0..result.passthrough]);
}

test "non-OSC-9999 sequences pass through unchanged" {
    // OSC 8 (hyperlinks) should be passed through, not consumed
    const input = "\x1b]8;;http://example.com\x07click\x1b]8;;\x07";
    var events: [4]AgentEvent = undefined;
    var passthrough: [512]u8 = undefined;

    const result = scanForAgentSequences(input, &events, &passthrough);

    try std.testing.expectEqual(@as(usize, 0), result.events);
    // The non-9999 OSC should be passed through
    try std.testing.expect(result.passthrough > 0);
}

test "empty payload returns null" {
    const result = parsePayload("");
    try std.testing.expect(result == null);
}

test "agent:start with all key-value fields" {
    // From spec: name, group, role are the expected fields for start
    const payload = "agent:start;name=backend-dev;group=team-temporal;role=implementer";
    const event = parsePayload(payload).?;

    try std.testing.expectEqual(AgentCommand.start, event.command);
    try std.testing.expectEqualStrings("backend-dev", event.name.?);
    try std.testing.expectEqualStrings("team-temporal", event.group.?);
    try std.testing.expectEqualStrings("implementer", event.role.?);
    // Fields not set should be null
    try std.testing.expect(event.state == null);
    try std.testing.expect(event.progress == null);
    try std.testing.expect(event.task_desc == null);
    try std.testing.expect(event.exit_status == null);
    try std.testing.expect(event.summary == null);
}

test "agent:status progress clamped to float 0.0 to 1.0" {
    const payload = "agent:status;progress=0.0;state=idle";
    const event = parsePayload(payload).?;
    try std.testing.expect(event.progress.? >= 0.0 and event.progress.? <= 0.01);

    const payload2 = "agent:status;progress=1.0;state=done";
    const event2 = parsePayload(payload2).?;
    try std.testing.expect(event2.progress.? >= 0.99 and event2.progress.? <= 1.01);
}

test "invalid progress value parsed as null" {
    const payload = "agent:status;progress=abc";
    const event = parsePayload(payload).?;
    try std.testing.expect(event.progress == null);
}
