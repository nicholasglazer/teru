//! Bar widget system for miozu compositor.
//!
//! Parses format strings like "{workspaces} | {title}" into a list of
//! widgets. Each widget evaluates to a string at render time. Widgets
//! are stateless evaluators — the bar owns the render buffer.
//!
//! Token format: {name} or {name:arg}
//!   {workspaces}        — workspace tabs (active highlighted)
//!   {title}             — focused pane/window title
//!   {layout}            — current layout indicator [M] [G] etc.
//!   {clock}             — current time (HH:MM)
//!   {clock:%H:%M:%S}    — custom strftime format
//!   {panes}             — pane count for active workspace
//!   {mem}               — RAM usage from /proc/meminfo
//!   {exec:N:command}    — shell command output, refreshed every N seconds
//!   literal text        — rendered as-is

const std = @import("std");

pub const max_widgets = 32;
pub const max_exec_output = 128;

pub const WidgetKind = enum {
    workspaces,
    title,
    layout,
    clock,
    panes,
    mem,
    exec,
    text,
};

pub const Widget = struct {
    kind: WidgetKind,
    // For text: the literal string. For clock: format string. For exec: command.
    arg: []const u8 = "",
    // For exec: refresh interval in seconds
    interval: u32 = 5,
    // Cached output (evaluated at runtime)
    cache: [max_exec_output]u8 = [_]u8{0} ** max_exec_output,
    cache_len: u8 = 0,
    last_eval: i128 = 0,
};

pub const WidgetList = struct {
    items: [max_widgets]Widget = undefined,
    count: u8 = 0,

    pub fn append(self: *WidgetList, w: Widget) void {
        if (self.count < max_widgets) {
            self.items[self.count] = w;
            self.count += 1;
        }
    }
};

/// Parse a format string into a widget list.
/// "{workspaces} | {title}" → [workspaces, text(" | "), title]
/// Returns a WidgetList with parsed widgets.
pub fn parse(format: []const u8) WidgetList {
    var list = WidgetList{};
    var i: usize = 0;
    var text_start: usize = 0;

    while (i < format.len) {
        if (format[i] == '{') {
            // Flush any literal text before this token
            if (i > text_start) {
                list.append(.{ .kind = .text, .arg = format[text_start..i] });
            }

            // Find closing brace
            const end = std.mem.indexOfPos(u8, format, i + 1, "}") orelse {
                // Unclosed brace — treat rest as text
                list.append(.{ .kind = .text, .arg = format[i..] });
                return list;
            };

            const token = format[i + 1 .. end];
            list.append(parseToken(token));

            i = end + 1;
            text_start = i;
        } else {
            i += 1;
        }
    }

    // Trailing text
    if (text_start < format.len) {
        list.append(.{ .kind = .text, .arg = format[text_start..] });
    }

    return list;
}

/// Parse a single token (contents between { and }).
fn parseToken(token: []const u8) Widget {
    if (std.mem.eql(u8, token, "workspaces")) return .{ .kind = .workspaces };
    if (std.mem.eql(u8, token, "title")) return .{ .kind = .title };
    if (std.mem.eql(u8, token, "layout")) return .{ .kind = .layout };
    if (std.mem.eql(u8, token, "panes")) return .{ .kind = .panes };
    if (std.mem.eql(u8, token, "mem")) return .{ .kind = .mem };
    if (std.mem.eql(u8, token, "clock")) return .{ .kind = .clock, .arg = "%H:%M" };

    // {clock:format}
    if (std.mem.startsWith(u8, token, "clock:")) {
        return .{ .kind = .clock, .arg = token["clock:".len..] };
    }

    // {exec:N:command}
    if (std.mem.startsWith(u8, token, "exec:")) {
        const rest = token["exec:".len..];
        // Find first colon → interval
        if (std.mem.indexOf(u8, rest, ":")) |colon| {
            const interval = std.fmt.parseInt(u32, rest[0..colon], 10) catch 5;
            return .{ .kind = .exec, .arg = rest[colon + 1 ..], .interval = interval };
        }
        // No interval specified → default 5s
        return .{ .kind = .exec, .arg = rest, .interval = 5 };
    }

    // Unknown token — render as literal
    return .{ .kind = .text, .arg = token };
}

// ── Default formats ────────────────────────────────────────────

pub const default_top_left = "{workspaces}";
pub const default_top_center = "{title}";
pub const default_top_right = "{clock}";
pub const default_bottom_left = "";
pub const default_bottom_center = "";
pub const default_bottom_right = "";

// ── Tests ──────────────────────────────────────────────────────

test "parse simple tokens" {
    const list = parse("{workspaces} | {title}");
    try std.testing.expectEqual(@as(u8, 3), list.count);
    try std.testing.expectEqual(WidgetKind.workspaces, list.items[0].kind);
    try std.testing.expectEqual(WidgetKind.text, list.items[1].kind);
    try std.testing.expect(std.mem.eql(u8, " | ", list.items[1].arg));
    try std.testing.expectEqual(WidgetKind.title, list.items[2].kind);
}

test "parse exec with interval" {
    const list = parse("{exec:2:sensors -f}");
    try std.testing.expectEqual(@as(u8, 1), list.count);
    try std.testing.expectEqual(WidgetKind.exec, list.items[0].kind);
    try std.testing.expectEqual(@as(u32, 2), list.items[0].interval);
    try std.testing.expect(std.mem.eql(u8, "sensors -f", list.items[0].arg));
}

test "parse clock with format" {
    const list = parse("{clock:%H:%M:%S}");
    try std.testing.expectEqual(@as(u8, 1), list.count);
    try std.testing.expectEqual(WidgetKind.clock, list.items[0].kind);
    try std.testing.expect(std.mem.eql(u8, "%H:%M:%S", list.items[0].arg));
}

test "parse mixed text and tokens" {
    const list = parse("cpu: {mem} | gpu: {exec:5:nvidia-smi}");
    try std.testing.expectEqual(@as(u8, 4), list.count);
    try std.testing.expectEqual(WidgetKind.text, list.items[0].kind);
    try std.testing.expectEqual(WidgetKind.mem, list.items[1].kind);
    try std.testing.expectEqual(WidgetKind.text, list.items[2].kind);
    try std.testing.expectEqual(WidgetKind.exec, list.items[3].kind);
}

test "parse empty string" {
    const list = parse("");
    try std.testing.expectEqual(@as(u8, 0), list.count);
}

test "parse plain text only" {
    const list = parse("hello world");
    try std.testing.expectEqual(@as(u8, 1), list.count);
    try std.testing.expectEqual(WidgetKind.text, list.items[0].kind);
    try std.testing.expect(std.mem.eql(u8, "hello world", list.items[0].arg));
}
