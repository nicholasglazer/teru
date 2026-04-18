//! teruwmctl — shell CLI + MCP stdio adapter for teruwm.
//!
//! Two modes, same binary:
//!
//!   teruwmctl <verb> [args…]           shell CLI — one-shot tool call
//!   teruwmctl call <tool> [json]       generic — call any tool name
//!   teruwmctl --mcp-stdio              stdio proxy — for Claude Code / Cursor
//!
//! The shell CLI is a thin layer over the MCP: `teruwmctl list-windows`
//! becomes a `tools/call` for `teruwm_list_windows`, the JSON response's
//! `result` field is pretty-printed to stdout. Any dashes in the verb
//! map to underscores, and the `teruwm_` prefix is implicit (so
//! `teruwmctl list-windows` == `teruwmctl call teruwm_list_windows`).
//!
//! The stdio mode is spec-conformant MCP (newline-delimited JSON-RPC
//! 2.0, per MCP 2024-11-05). Internally it just calls
//! `teru.McpFramework.Bridge.run(io, .teruwm)` — same transport the
//! `teru --mcp-server --target teruwm` command uses. Exists as an
//! alias so users can register `teruwmctl` in their MCP config without
//! needing `teru` on PATH.

const std = @import("std");
const teru = @import("teru");
const forward = teru.forward;
const McpBridge = teru.McpBridge;

fn out(s: []const u8) void {
    _ = std.c.write(1, s.ptr, s.len);
}

fn outFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn errFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

const usage =
    \\teruwmctl — control the running teruwm compositor
    \\
    \\Usage:
    \\  teruwmctl <verb> [args…]          e.g. teruwmctl list-windows
    \\  teruwmctl call <tool> [json-args] e.g. teruwmctl call teruwm_spawn_terminal '{"workspace":2}'
    \\  teruwmctl list-tools              print every tool teruwm exposes
    \\  teruwmctl --mcp-stdio             MCP stdio proxy (for Claude Code / Cursor)
    \\  teruwmctl -h | --help             this text
    \\
    \\Verb form:
    \\  teruwmctl VERB                    → teruwm_<verb_with_underscores>
    \\  teruwmctl VERB '{…}'              → same, with JSON arguments
    \\  Examples:
    \\    teruwmctl list-windows
    \\    teruwmctl switch-workspace '{"workspace":2}'
    \\    teruwmctl screenshot '{"path":"/tmp/s.png"}'
    \\
    \\Discovery:
    \\  TERUWM_MCP_SOCKET env var, else scan /run/user/$UID/teruwm-mcp-*.sock
    \\
    \\Exit codes:
    \\  0 ok     1 tool-call error     2 no socket / connection     3 bad args
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = allocator;
    const io = init.io;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_it.deinit();
    _ = args_it.next(); // argv[0]

    const first = args_it.next() orelse {
        errFmt("{s}", .{usage});
        std.process.exit(3);
    };

    // Help flags
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        out(usage);
        return;
    }

    // MCP stdio alias — delegate to the shared bridge targeting teruwm.
    if (std.mem.eql(u8, first, "--mcp-stdio") or
        std.mem.eql(u8, first, "--mcp-server") or
        std.mem.eql(u8, first, "--mcp-bridge"))
    {
        return McpBridge.run(io, .teruwm);
    }

    // list-tools — forward tools/list, print compact.
    if (std.mem.eql(u8, first, "list-tools")) {
        try callAndPrint("tools/list", "{}");
        return;
    }

    // Generic call form: `teruwmctl call <tool_name> [json_args]`.
    if (std.mem.eql(u8, first, "call")) {
        const tool = args_it.next() orelse {
            errFmt("teruwmctl: `call` needs a tool name\n", .{});
            std.process.exit(3);
        };
        const args_json = args_it.next() orelse "{}";
        try callTool(tool, args_json);
        return;
    }

    // Verb form: convert `list-windows` → `teruwm_list_windows`, collect
    // optional JSON payload as next argv.
    var verb_buf: [128]u8 = undefined;
    const tool_name = buildVerb(&verb_buf, first) catch |err| switch (err) {
        error.TooLong => {
            errFmt("teruwmctl: verb too long: {s}\n", .{first});
            std.process.exit(3);
        },
        error.InvalidChar => {
            errFmt("teruwmctl: unknown verb '{s}'. Use `teruwmctl --help`.\n", .{first});
            std.process.exit(3);
        },
    };
    const args_json = args_it.next() orelse "{}";
    try callTool(tool_name, args_json);
}

/// `list-windows` → `teruwm_list_windows`. Plain ASCII letters + dashes
/// only; anything else is rejected. Guarantees the constructed name is
/// safe to embed into a JSON string literal without escaping.
fn buildVerb(buf: *[128]u8, verb: []const u8) ![]const u8 {
    const prefix = "teruwm_";
    if (verb.len + prefix.len >= buf.len) return error.TooLong;
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = 0;
    while (i < verb.len) : (i += 1) {
        const c = verb[i];
        const mapped: u8 = if (c == '-') '_' else c;
        if (!isValidToolChar(mapped)) return error.InvalidChar;
        buf[prefix.len + i] = mapped;
    }
    return buf[0 .. prefix.len + verb.len];
}

fn isValidToolChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Issue a `tools/call` against teruwm, print the `result.content[0].text`
/// if present (that's where teruwm returns its JSON-encoded payload
/// strings), else the raw `result`. On JSON-RPC error: print `error.message`
/// to stderr and exit 1.
fn callTool(tool: []const u8, args_json: []const u8) !void {
    var req_buf: [8192]u8 = undefined;
    const body = std.fmt.bufPrint(&req_buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
        .{ tool, args_json },
    ) catch {
        errFmt("teruwmctl: request body too long\n", .{});
        std.process.exit(3);
    };
    try runAndPrint(body);
}

/// Issue a raw JSON-RPC method (no `tools/call` wrapping). Used for
/// `tools/list` which lives at the top level of the JSON-RPC
/// envelope rather than under `tools/call`.
fn callAndPrint(method: []const u8, params_json: []const u8) !void {
    var req_buf: [4096]u8 = undefined;
    const body = std.fmt.bufPrint(&req_buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params_json },
    ) catch {
        errFmt("teruwmctl: request body too long\n", .{});
        std.process.exit(3);
    };
    try runAndPrint(body);
}

fn runAndPrint(body: []const u8) !void {
    var resp_buf: [65536]u8 = undefined;
    const resp = forward.forwardRequest(body, &resp_buf) orelse {
        errFmt("teruwmctl: no teruwm MCP socket. Set TERUWM_MCP_SOCKET or start teruwm.\n", .{});
        std.process.exit(2);
    };

    // JSON-RPC error → stderr + exit 1. Conservative string search;
    // full parse would need std.json. The server always places
    // `"error":{` at a fixed depth, so substring match is reliable.
    if (std.mem.indexOf(u8, resp, "\"error\":{") != null) {
        _ = std.c.write(2, resp.ptr, resp.len);
        out("\n");
        std.process.exit(1);
    }

    // Extract result.content[0].text if it's a tools/call response
    // (teruwm wraps its payload strings there). For tools/list or
    // other envelopes, fall through and print the whole response.
    if (extractContentText(resp)) |inner| {
        out(inner);
        if (inner.len == 0 or inner[inner.len - 1] != '\n') out("\n");
        return;
    }

    out(resp);
    out("\n");
}

/// If the response body looks like
///   {"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"<PAYLOAD>"}]},"id":1}
/// return the unescaped PAYLOAD slice pointing inside `resp`. Otherwise
/// null. We only handle the exact shape teruwm produces — no fancy
/// JSON walking — because the server's output format is known-stable.
fn extractContentText(resp: []const u8) ?[]const u8 {
    const marker = "\"text\":\"";
    const start = std.mem.indexOf(u8, resp, marker) orelse return null;
    const body_start = start + marker.len;
    // Walk forward looking for the unescaped closing quote.
    var i = body_start;
    while (i < resp.len) : (i += 1) {
        if (resp[i] == '\\') {
            i += 1;
            continue;
        }
        if (resp[i] == '"') break;
    }
    if (i >= resp.len) return null;
    return resp[body_start..i];
}

test "buildVerb: simple dash-to-underscore" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("teruwm_list_windows", try buildVerb(&buf, "list-windows"));
    try std.testing.expectEqualStrings("teruwm_screenshot", try buildVerb(&buf, "screenshot"));
    try std.testing.expectEqualStrings("teruwm_set_layout", try buildVerb(&buf, "set-layout"));
}

test "buildVerb: rejects garbage" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidChar, buildVerb(&buf, "list windows"));
    try std.testing.expectError(error.InvalidChar, buildVerb(&buf, "list;rm -rf"));
}

test "extractContentText: finds teruwm's wrapped payload" {
    const resp = "{\"jsonrpc\":\"2.0\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[]\"}]},\"id\":1}";
    try std.testing.expectEqualStrings("[]", extractContentText(resp).?);
}

test "extractContentText: null on non-content response" {
    const resp = "{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[]},\"id\":1}";
    try std.testing.expect(extractContentText(resp) == null);
}
