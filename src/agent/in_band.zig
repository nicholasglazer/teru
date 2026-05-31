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
//!
//! Authorisation
//! ─────────────
//! The in-band channel is OPT-IN — `agent_in_band = true` in
//! teru.conf. When disabled (the default) every query is rejected
//! with a JSON-RPC -32601 and never reaches McpServer.dispatch.
//!
//! When enabled, only the allowlisted tools below are dispatchable.
//! The allowlist is intentionally narrow: read-only introspection
//! and self-affecting agent metadata. Tools that mutate other panes
//! (`teru_send_input`, `teru_send_keys`, `teru_create_pane`, etc.),
//! spawn processes, write the user's config, take screenshots, or
//! drive the compositor (`teruwm_*`) are NOT exposed to in-band —
//! they're available via the Unix socket where the caller has
//! already crossed an authorisation boundary by holding the runtime
//! socket. For any allowlisted tool that takes a `pane_id`, the
//! handler forces it to the calling pane's id, so an agent can only
//! query / annotate its own pane.

const std = @import("std");
const Pane = @import("../core/Pane.zig");
const McpServer = @import("McpServer.zig");
const protocol = @import("protocol.zig");
const McpTools = @import("McpTools.zig");

/// Maximum in-band response payload (before DCS framing).
pub const max_response: usize = 16 * 1024;

/// Maximum synthesized JSON-RPC body we're willing to build.
pub const max_request: usize = 8 * 1024;

/// Per-call options threaded from the caller (windowed mode reads
/// `agent_in_band` from Config and passes it through). Decoupled
/// from McpServer so a single dispatcher serves both paths.
pub const Options = struct {
    enabled: bool = false,
};

/// Tools an in-band agent is allowed to call. Read-only introspection
/// and self-affecting metadata only — anything that mutates state in
/// other panes / on disk / in the compositor is dispatched only over
/// the Unix socket. Keep this list short; broaden only after auditing
/// the target tool's argument surface.
const allowed_tools = [_][]const u8{
    // Read-only / introspection
    "teru_list_panes",
    "teru_get_state",
    "teru_get_graph",
    "teru_query_status",
    "teru_query_history",
    "teru_list_widgets",
    "teru_read_output", // pane_id forced to caller's pane below
    // Agent metadata for the calling pane
    "teru_progress",
    "teru_agent_status",
    // Push widgets (no exec, no pane_id)
    "teru_set_widget",
    "teru_delete_widget",
    // Event subscribe (returns socket paths; caller still has to connect)
    "teru_subscribe_events",
};

fn isToolAllowed(tool: []const u8) bool {
    for (allowed_tools) |t| {
        if (std.mem.eql(u8, tool, t)) return true;
    }
    return false;
}

/// Replace any `pane_id` argument with the calling pane's id (or inject
/// one if absent). This is the security-critical step: without it, an
/// allowlisted read tool like `teru_read_output` could exfil another
/// pane's scrollback (which may contain a sudo password prompt, an
/// SSH session, etc.) just because the caller asked for a different id.
fn overridePaneId(
    args_in: []const protocol.QueryArg,
    out: []protocol.QueryArg,
    pane_id_str: []const u8,
) []const protocol.QueryArg {
    // Emit the forced pane_id FIRST and DROP any caller-supplied pane_id.
    // The downstream extractor (extractNestedJsonInt) is first-match, so a
    // leading forced pane_id wins even if a duplicate were somehow injected.
    // Rewriting in place (the old behaviour) left the caller's pane_id at its
    // original position, which a JSON-key-injection could move ahead of the
    // forced one — letting an agent read another pane's scrollback.
    var n: usize = 0;
    out[n] = .{ .key = "pane_id", .value = pane_id_str };
    n += 1;
    for (args_in) |a| {
        if (n >= out.len) break;
        if (std.mem.eql(u8, a.key, "pane_id")) continue; // drop caller's
        out[n] = a;
        n += 1;
    }
    return out[0..n];
}

/// True only for plain identifier keys ([A-Za-z0-9_]). buildJsonRpcRequest
/// emits keys unescaped, so a key containing '"' ':' or ',' could forge extra
/// JSON structure (e.g. a second `pane_id`) and bypass the pane-scoping guard.
fn isPlainKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Build a small JSON-RPC error and frame it as a DCS reply.
fn writeErrorReply(pane: *const Pane, id: []const u8, code: i32, msg: []const u8) void {
    var body_buf: [256]u8 = undefined;
    const id_is_int = std.fmt.parseInt(i64, id, 10) catch null != null;
    const body = if (id_is_int)
        std.fmt.bufPrint(&body_buf,
            \\{{"jsonrpc":"2.0","error":{{"code":{d},"message":"{s}"}},"id":{s}}}
        , .{ code, msg, id }) catch return
    else
        std.fmt.bufPrint(&body_buf,
            \\{{"jsonrpc":"2.0","error":{{"code":{d},"message":"{s}"}},"id":"{s}"}}
        , .{ code, msg, id }) catch return;
    var framed_buf: [320]u8 = undefined;
    const framed = frameDcs(id, body, &framed_buf) orelse return;
    _ = pane.ptyWrite(framed) catch {};
}

/// Handle an OSC query: build the equivalent JSON-RPC tools/call body,
/// dispatch through McpServer, frame the response as DCS, write to PTY.
/// Silently returns on any malformed input — an in-band channel must
/// never crash the terminal just because some agent sent garbage.
pub fn handleQuery(pane: *const Pane, event: protocol.AgentEvent, mcp: *McpServer, opts: Options) void {
    const tool = event.query_tool orelse return;
    const id = event.query_id orelse "null";

    if (!opts.enabled) {
        writeErrorReply(pane, id, -32601, "in-band MCP disabled (set agent_in_band=true)");
        return;
    }

    if (!isToolAllowed(tool)) {
        writeErrorReply(pane, id, -32601, "tool not allowed via in-band channel");
        return;
    }

    // Force pane_id to the calling pane's id for any tool that takes one.
    var args_buf: [protocol.max_query_args + 1]protocol.QueryArg = undefined;
    var pane_id_digits: [21]u8 = undefined;
    const pane_id_str = std.fmt.bufPrint(&pane_id_digits, "{d}", .{pane.id}) catch return;
    const args = overridePaneId(event.query_args.slice(), &args_buf, pane_id_str);

    var req_buf: [max_request]u8 = undefined;
    const req = buildJsonRpcRequest(tool, id, args, &req_buf) orelse return;

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
        // Reject any key that isn't a plain identifier. Keys are emitted
        // unescaped below; a forged key like `x":50,"pane_id` would otherwise
        // inject a second structural token and defeat the pane-scoping guard.
        if (!isPlainKey(arg.key)) return null;
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
    try std.testing.expect(std.mem.find(u8, req, "\"id\":\"abc\"") != null);
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

test "isToolAllowed — allowlist hits" {
    try std.testing.expect(isToolAllowed("teru_list_panes"));
    try std.testing.expect(isToolAllowed("teru_get_state"));
    try std.testing.expect(isToolAllowed("teru_progress"));
    try std.testing.expect(isToolAllowed("teru_set_widget"));
}

test "isToolAllowed — block list" {
    // Cross-pane mutations
    try std.testing.expect(!isToolAllowed("teru_send_input"));
    try std.testing.expect(!isToolAllowed("teru_send_keys"));
    try std.testing.expect(!isToolAllowed("teru_create_pane"));
    try std.testing.expect(!isToolAllowed("teru_close_pane"));
    try std.testing.expect(!isToolAllowed("teru_focus_pane"));
    // Disk + config
    try std.testing.expect(!isToolAllowed("teru_set_config"));
    try std.testing.expect(!isToolAllowed("teru_screenshot"));
    try std.testing.expect(!isToolAllowed("teru_session_save"));
    try std.testing.expect(!isToolAllowed("teru_session_restore"));
    // Compositor surface
    try std.testing.expect(!isToolAllowed("teruwm_list_windows"));
    try std.testing.expect(!isToolAllowed("teruwm_send_input"));
    try std.testing.expect(!isToolAllowed("teruwm_screenshot"));
    // Garbage
    try std.testing.expect(!isToolAllowed(""));
    try std.testing.expect(!isToolAllowed("teru_nope"));
}

test "overridePaneId — replaces existing pane_id" {
    var out: [4]protocol.QueryArg = undefined;
    const args_in = [_]protocol.QueryArg{
        .{ .key = "pane_id", .value = "99" },
        .{ .key = "lines", .value = "10" },
    };
    const result = overridePaneId(&args_in, &out, "7");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("pane_id", result[0].key);
    try std.testing.expectEqualStrings("7", result[0].value);
    try std.testing.expectEqualStrings("lines", result[1].key);
    try std.testing.expectEqualStrings("10", result[1].value);
}

test "overridePaneId — injects pane_id when absent" {
    var out: [4]protocol.QueryArg = undefined;
    const args_in = [_]protocol.QueryArg{
        .{ .key = "lines", .value = "10" },
    };
    const result = overridePaneId(&args_in, &out, "7");
    try std.testing.expectEqual(@as(usize, 2), result.len);
    // pane_id is forced FIRST now so first-match extraction always returns it.
    try std.testing.expectEqualStrings("pane_id", result[0].key);
    try std.testing.expectEqualStrings("7", result[0].value);
    try std.testing.expectEqualStrings("lines", result[1].key);
}

test "overridePaneId — empty input still gets pane_id" {
    var out: [4]protocol.QueryArg = undefined;
    const args_in = [_]protocol.QueryArg{};
    const result = overridePaneId(&args_in, &out, "42");
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("pane_id", result[0].key);
    try std.testing.expectEqualStrings("42", result[0].value);
}

test "in-band pane scoping cannot be bypassed (cross-pane exfil guard)" {
    var out: [protocol.max_query_args + 1]protocol.QueryArg = undefined;
    var req_buf: [max_request]u8 = undefined;

    // 1. A caller-supplied pane_id is dropped; the forced caller id wins.
    //    extractNestedJsonInt is first-match, so the forced id must be first.
    const args1 = [_]protocol.QueryArg{
        .{ .key = "lines", .value = "50" },
        .{ .key = "pane_id", .value = "99" },
    };
    const forced1 = overridePaneId(&args1, &out, "2");
    var pane_id_keys: usize = 0;
    for (forced1) |a| {
        if (std.mem.eql(u8, a.key, "pane_id")) pane_id_keys += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), pane_id_keys);
    const req1 = buildJsonRpcRequest("teru_read_output", "1", forced1, &req_buf).?;
    try std.testing.expectEqual(@as(?u64, 2), McpTools.extractNestedJsonInt(req1, "pane_id"));

    // 2. A forged structural key (the real attack: a key that closes the
    //    value and opens a second "pane_id":99) is rejected outright — the
    //    whole request is dropped rather than reaching the dispatcher.
    const args2 = [_]protocol.QueryArg{
        .{ .key = "x\":50,\"pane_id", .value = "99" },
    };
    const forced2 = overridePaneId(&args2, &out, "2");
    try std.testing.expect(buildJsonRpcRequest("teru_read_output", "1", forced2, &req_buf) == null);
}
