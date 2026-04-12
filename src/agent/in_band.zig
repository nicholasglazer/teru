//! In-band MCP tool calls over OSC 9999.
//!
//! Lets an agent running *inside* a teru pane call the same MCP tools
//! an external client would — without a socket, without the stdio bridge,
//! without any process hop at all. The agent writes an OSC 9999 query
//! on its stdout (which teru is already parsing) and reads the DCS reply
//! on its stdin. Exactly how `ESC[6n` → `ESC[R;CR` already works for
//! cursor-position reports; we're just widening the vocabulary.
//!
//! Wire format
//! ───────────
//! Request  (agent → teru, via PTY stdout):
//!     ESC ] 9999 ; query ; id=<N> ; tool=<NAME> [ ; k=v ]* ST
//!
//!   ST may be either BEL (0x07) or ESC \\.  Scalar values only —
//!   embedded semicolons aren't supported. For complex inputs use the
//!   Unix-socket path (`--mcp-server`). See ../../tools/teru-query for
//!   a shell wrapper.
//!
//! Reply    (teru → agent, via PTY master write):
//!     ESC P 9999 ; id=<N> ; <json-body> ESC \\
//!
//!   DCS is the right envelope for multi-line JSON; it's what tmux uses
//!   for its passthrough replies, and every VT parser already handles
//!   it correctly (so the agent's terminal lib / language binding
//!   doesn't need to special-case anything — just strips the DCS).
//!
//! The whole call cost is: a few hundred bytes written into the PTY
//! ring, one McpServer.dispatch, a few hundred bytes written back.
//! Zero processes, zero sockets, zero context switches beyond the one
//! teru already does per PTY read.

const std = @import("std");
const Pane = @import("../core/Pane.zig");
const McpServer = @import("McpServer.zig");
const protocol = @import("protocol.zig");
const McpTools = @import("McpTools.zig");

/// Maximum in-band response payload (before DCS framing).
pub const max_response: usize = 16 * 1024;

/// Maximum synthesized JSON-RPC body we're willing to build.
pub const max_request: usize = 8 * 1024;

/// Handle an OSC query: build the equivalent JSON-RPC tools/call body,
/// dispatch through McpServer, frame the response as DCS, write to PTY.
/// Silently returns on any malformed input — an in-band channel must
/// never crash the terminal just because some agent sent garbage.
pub fn handleQuery(pane: *const Pane, event: protocol.AgentEvent, mcp: *McpServer) void {
    const tool = event.query_tool orelse return;
    const id = event.query_id orelse "null";

    var req_buf: [max_request]u8 = undefined;
    const req = buildJsonRpcRequest(tool, id, event.query_args.slice(), &req_buf) orelse return;

    var resp_buf: [max_response]u8 = undefined;
    const resp = mcp.dispatch(req, &resp_buf);

    var framed_buf: [max_response + 64]u8 = undefined;
    const framed = frameDcs(id, resp, &framed_buf) orelse return;
    _ = pane.ptyWrite(framed) catch {};
}

/// Build a JSON-RPC 2.0 request for `tools/call` from a flat k=v list.
/// Values are inferred as numbers when they parse as i64, else quoted
/// as JSON strings (with escaping). Tool name and id are not escaped —
/// the caller is responsible for not injecting junk there (they come
/// from our own parser, which already rejects anything with a `;`).
fn buildJsonRpcRequest(tool: []const u8, id: []const u8, args: []const protocol.QueryArg, buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    pos += (std.fmt.bufPrint(buf[pos..], "{{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{", .{tool}) catch return null).len;
    for (args, 0..) |arg, i| {
        if (i > 0) {
            if (pos >= buf.len) return null;
            buf[pos] = ',';
            pos += 1;
        }
        pos += (std.fmt.bufPrint(buf[pos..], "\"{s}\":", .{arg.key}) catch return null).len;
        pos += writeValue(buf[pos..], arg.value) orelse return null;
    }
    // id must be valid JSON — accept a bare integer if the value parses,
    // else emit as a quoted string.
    if (std.fmt.parseInt(i64, id, 10)) |_| {
        pos += (std.fmt.bufPrint(buf[pos..], "}}}},\"id\":{s}}}", .{id}) catch return null).len;
    } else |_| {
        var esc_buf: [64]u8 = undefined;
        const esc = McpTools.jsonEscapeString(id, &esc_buf);
        pos += (std.fmt.bufPrint(buf[pos..], "}}}},\"id\":\"{s}\"}}", .{esc}) catch return null).len;
    }
    return buf[0..pos];
}

/// Write an argument value (bool keyword, integer, or quoted string)
/// into `out` starting at position 0. Returns bytes written, or null
/// on overflow.
fn writeValue(out: []u8, v: []const u8) ?usize {
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "false")) {
        if (v.len > out.len) return null;
        @memcpy(out[0..v.len], v);
        return v.len;
    }
    if (std.fmt.parseInt(i64, v, 10)) |_| {
        if (v.len > out.len) return null;
        @memcpy(out[0..v.len], v);
        return v.len;
    } else |_| {}
    var esc_buf: [512]u8 = undefined;
    const esc = McpTools.jsonEscapeString(v, &esc_buf);
    const written = std.fmt.bufPrint(out, "\"{s}\"", .{esc}) catch return null;
    return written.len;
}

/// Wrap `body` in a DCS 9999 envelope: ESC P 9999 ; id=<id> ; <body> ESC \\
fn frameDcs(id: []const u8, body: []const u8, out: []u8) ?[]const u8 {
    var pos: usize = 0;
    pos += (std.fmt.bufPrint(out[pos..], "\x1bP9999;id={s};", .{id}) catch return null).len;
    if (pos + body.len + 2 > out.len) return null;
    @memcpy(out[pos..][0..body.len], body);
    pos += body.len;
    out[pos] = 0x1B;
    out[pos + 1] = '\\';
    pos += 2;
    return out[0..pos];
}

// ── Tests ───────────────────────────────────────────────────────

test "buildJsonRpcRequest — no args" {
    var buf: [1024]u8 = undefined;
    const req = buildJsonRpcRequest("teru_list_panes", "1", &[_]protocol.QueryArg{}, &buf).?;
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"teru_list_panes\",\"arguments\":{}},\"id\":1}",
        req,
    );
}

test "buildJsonRpcRequest — integer and string args" {
    var buf: [1024]u8 = undefined;
    const args = [_]protocol.QueryArg{
        .{ .key = "pane_id", .value = "3" },
        .{ .key = "pattern", .value = "hello" },
    };
    const req = buildJsonRpcRequest("teru_wait_for", "42", &args, &buf).?;
    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"teru_wait_for\",\"arguments\":{\"pane_id\":3,\"pattern\":\"hello\"}},\"id\":42}",
        req,
    );
}

test "buildJsonRpcRequest — string id quoted" {
    var buf: [1024]u8 = undefined;
    const req = buildJsonRpcRequest("teru_list_panes", "abc", &[_]protocol.QueryArg{}, &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, req, "\"id\":\"abc\"") != null);
}

test "frameDcs wraps the body in ESC P 9999 ; id=... ; body ESC\\\\" {
    var buf: [256]u8 = undefined;
    const out = frameDcs("5", "hello", &buf).?;
    try std.testing.expectEqualStrings("\x1bP9999;id=5;hello\x1b\\", out);
}

test "writeValue — bool passthrough" {
    var out: [16]u8 = undefined;
    const n = writeValue(&out, "true") orelse return error.Overflow;
    try std.testing.expectEqualStrings("true", out[0..n]);
}

test "writeValue — integer passthrough" {
    var out: [16]u8 = undefined;
    const n = writeValue(&out, "42") orelse return error.Overflow;
    try std.testing.expectEqualStrings("42", out[0..n]);
}

test "writeValue — string escaping" {
    var out: [64]u8 = undefined;
    const n = writeValue(&out, "he\"ll\nworld") orelse return error.Overflow;
    try std.testing.expectEqualStrings("\"he\\\"ll\\nworld\"", out[0..n]);
}
