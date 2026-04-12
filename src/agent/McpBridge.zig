//! MCP stdio proxy — pipes stdin ↔ `teru-mcp-$PID.sock` ↔ stdout.
//!
//! Usage: `teru --mcp-server`  (alias `teru --mcp-bridge` for legacy
//! `.mcp.json` files still referring to the previous flag name).
//!
//! Protocol is line-delimited JSON-RPC 2.0 on both sides: one
//! `\n`-terminated message per request, one per response. No HTTP,
//! no Content-Length. The main teru process listens on
//! `/run/user/$UID/teru-mcp-$PID.sock` and speaks the same framing.
//!
//! Discovery: `$TERU_MCP_SOCKET` if set, otherwise the first
//! `teru-mcp-*.sock` in the runtime dir. One socket connection per
//! request (teru's server closes after sending the response), which
//! keeps the bridge stateless.
//!
//! `$TERU_MCP_READONLY=1` filters write tools out of `tools/list` and
//! rejects `tools/call` for those tools before hitting the socket.

const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("../server/ipc.zig");

const max_line: usize = 65536;
const max_response: usize = 65536;

fn stdinFd() std.posix.fd_t {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetStdHandle(n: u32) callconv(.c) *anyopaque;
        };
        return k.GetStdHandle(@bitCast(@as(i32, -10)));
    }
    return 0;
}
fn stdoutFd() std.posix.fd_t {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetStdHandle(n: u32) callconv(.c) *anyopaque;
        };
        return k.GetStdHandle(@bitCast(@as(i32, -11)));
    }
    return 1;
}

// ── Entry point ──────────────────────────────────────────────────

pub fn run(io: std.Io) !void {
    _ = io; // Proxy uses blocking C I/O on stdin/stdout/socket.

    const read_only = if (std.c.getenv("TERU_MCP_READONLY")) |v|
        std.mem.sliceTo(v, 0).len > 0 and std.mem.sliceTo(v, 0)[0] == '1'
    else
        false;

    const socket_path = findSocket() orelse {
        const msg = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"No teru MCP socket found. Set TERU_MCP_SOCKET or run teru first.\"},\"id\":null}\n";
        _ = std.c.write(stdoutFd(), msg.ptr, msg.len);
        return error.NoSocket;
    };

    var line_buf: [max_line]u8 = undefined;

    while (true) {
        const line = readLine(&line_buf) orelse return; // EOF
        if (line.len == 0) continue;

        // Drop notifications (no id field) — server doesn't emit responses.
        if (std.mem.indexOf(u8, line, "\"id\"") == null or
            std.mem.indexOf(u8, line, "\"notifications/") != null)
        {
            continue;
        }

        // Read-only mode: reject write tool calls before the socket.
        if (read_only and isBlockedToolCall(line)) {
            var err_buf: [512]u8 = undefined;
            if (rejectToolCall(line, &err_buf)) |err_json| {
                _ = std.c.write(stdoutFd(), err_json.ptr, err_json.len);
                _ = std.c.write(stdoutFd(), "\n", 1);
            }
            continue;
        }

        var conn = ipc.connect(socket_path) catch {
            const err_msg = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Cannot connect to teru socket\"},\"id\":null}\n";
            _ = std.c.write(stdoutFd(), err_msg.ptr, err_msg.len);
            continue;
        };

        // Send the request line as-is + newline terminator.
        _ = conn.write(line) catch {};
        _ = conn.write("\n") catch {};

        // Read one line of response (server writes json + \n and closes).
        var resp_buf: [max_response]u8 = undefined;
        const resp = readResponse(&conn, &resp_buf);
        conn.close();
        if (resp.len == 0) continue;

        if (read_only and std.mem.indexOf(u8, line, "\"tools/list\"") != null) {
            var filter_buf: [max_response]u8 = undefined;
            if (filterToolsList(resp, &filter_buf)) |filtered| {
                _ = std.c.write(stdoutFd(), filtered.ptr, filtered.len);
                _ = std.c.write(stdoutFd(), "\n", 1);
                continue;
            }
        }
        _ = std.c.write(stdoutFd(), resp.ptr, resp.len);
        _ = std.c.write(stdoutFd(), "\n", 1);
    }
}

// ── stdin reading ────────────────────────────────────────────────

fn readLine(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        const rc = std.c.read(stdinFd(), buf[pos..].ptr, 1);
        if (rc <= 0) {
            if (pos == 0) return null;
            return buf[0..pos];
        }
        if (buf[pos] == '\n') return buf[0..pos];
        pos += 1;
    }
    return buf[0..pos];
}

fn readResponse(conn: *ipc.IpcHandle, buf: []u8) []const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = conn.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOfScalar(u8, buf[0..total], '\n') != null) break;
    }
    // Trim the trailing newline (and optional \r) if present.
    var end = total;
    if (end > 0 and buf[end - 1] == '\n') end -= 1;
    if (end > 0 and buf[end - 1] == '\r') end -= 1;
    return buf[0..end];
}

// ── Socket path discovery ────────────────────────────────────────

var discovered_path: [256]u8 = undefined;

fn findSocket() ?[]const u8 {
    if (std.c.getenv("TERU_MCP_SOCKET")) |env| return std.mem.sliceTo(env, 0);
    return discoverSocket();
}

fn discoverSocket() ?[]const u8 {
    if (builtin.os.tag == .windows) return null;

    const uid = std.c.getuid();
    var dir_buf: [128]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "/run/user/{d}", .{uid}) catch return null;

    const dir_z = std.fmt.bufPrintZ(&discovered_path, "{s}", .{dir_path}) catch return null;
    const dir = std.c.opendir(dir_z.ptr) orelse return null;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |ent| {
        const name_ptr: [*:0]const u8 = @ptrCast(&ent.*.name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (!std.mem.startsWith(u8, name, "teru-mcp-")) continue;
        if (!std.mem.endsWith(u8, name, ".sock")) continue;

        const full = std.fmt.bufPrint(&discovered_path, "{s}/{s}", .{ dir_path, name }) catch continue;
        return full;
    }
    return null;
}

// ── Read-only enforcement ───────────────────────────────────────

const write_tool_names = [_][]const u8{
    "teru_send_input",
    "teru_create_pane",
    "teru_broadcast",
    "teru_send_keys",
    "teru_close_pane",
    "teru_switch_workspace",
    "teru_set_layout",
    "teru_set_config",
    "teru_session_restore",
    "teru_focus_pane",
};

fn isBlockedToolCall(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "\"tools/call\"") == null) return false;
    for (write_tool_names) |n| {
        var needle_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{n}) catch continue;
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

fn rejectToolCall(line: []const u8, buf: []u8) ?[]const u8 {
    const id_start = std.mem.indexOf(u8, line, "\"id\":") orelse return null;
    const after = line[id_start + 5 ..];
    const id_end = blk: {
        var end: usize = 0;
        while (end < after.len) : (end += 1) {
            const c = after[end];
            if (c == ',' or c == '}' or c == ' ') break;
        }
        break :blk end;
    };
    const id = after[0..id_end];
    return std.fmt.bufPrint(buf,
        "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":-32601,\"message\":\"Read-only mode: write tools are disabled\"}},\"id\":{s}}}",
        .{id},
    ) catch null;
}

/// Filter write tools out of a `tools/list` response payload. Returns
/// the rewritten JSON, or null if the response doesn't match the
/// expected shape (in which case the caller should forward as-is).
fn filterToolsList(resp: []const u8, out: []u8) ?[]const u8 {
    // Find the tools array — we emit it verbatim minus any object whose
    // "name" matches a write tool.
    const tools_key = "\"tools\":[";
    const arr_start = std.mem.indexOf(u8, resp, tools_key) orelse return null;
    const body_start = arr_start + tools_key.len;
    const body_end = std.mem.lastIndexOfScalar(u8, resp, ']') orelse return null;
    if (body_end <= body_start) return null;

    // Copy prefix
    var pos: usize = 0;
    @memcpy(out[pos..][0..body_start], resp[0..body_start]);
    pos += body_start;

    // Walk tool objects: each is `{...},` or `{...}` at the end.
    var i: usize = body_start;
    var first = true;
    while (i < body_end) {
        if (resp[i] != '{') {
            i += 1;
            continue;
        }
        // Find matching closing brace (naive — schemas don't use nested braces in escaped strings)
        var depth: i32 = 0;
        var j = i;
        while (j < body_end) : (j += 1) {
            if (resp[j] == '{') depth += 1 else if (resp[j] == '}') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (j >= body_end) break;
        const obj = resp[i .. j + 1];

        // Skip write tools
        var is_write = false;
        for (write_tool_names) |n| {
            var needle_buf: [64]u8 = undefined;
            const needle = std.fmt.bufPrint(&needle_buf, "\"name\":\"{s}\"", .{n}) catch continue;
            if (std.mem.indexOf(u8, obj, needle) != null) {
                is_write = true;
                break;
            }
        }

        if (!is_write) {
            if (!first) {
                if (pos >= out.len) return null;
                out[pos] = ',';
                pos += 1;
            }
            if (pos + obj.len > out.len) return null;
            @memcpy(out[pos..][0..obj.len], obj);
            pos += obj.len;
            first = false;
        }

        i = j + 1;
    }

    // Copy suffix (]} ... )
    const suffix = resp[body_end..];
    if (pos + suffix.len > out.len) return null;
    @memcpy(out[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    return out[0..pos];
}

// ── Inline tests ─────────────────────────────────────────────────

test "isBlockedToolCall matches write tools" {
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"teru_send_input\",\"arguments\":{\"pane_id\":1,\"text\":\"x\"}},\"id\":1}";
    try std.testing.expect(isBlockedToolCall(line));
}

test "isBlockedToolCall passes read tools" {
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"teru_list_panes\"},\"id\":2}";
    try std.testing.expect(!isBlockedToolCall(line));
}

test "isBlockedToolCall ignores tools/list" {
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":3}";
    try std.testing.expect(!isBlockedToolCall(line));
}

test "rejectToolCall preserves id" {
    var buf: [512]u8 = undefined;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"teru_send_input\"},\"id\":42}";
    const err = rejectToolCall(line, &buf) orelse return error.NoReject;
    try std.testing.expect(std.mem.indexOf(u8, err, "\"id\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "Read-only") != null);
}

test "filterToolsList strips write tools" {
    const resp =
        "{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[" ++
        "{\"name\":\"teru_list_panes\",\"description\":\"r\"}," ++
        "{\"name\":\"teru_send_input\",\"description\":\"w\"}," ++
        "{\"name\":\"teru_get_graph\",\"description\":\"r\"}" ++
        "]},\"id\":1}";
    var out: [2048]u8 = undefined;
    const filtered = filterToolsList(resp, &out) orelse return error.FilterFailed;
    try std.testing.expect(std.mem.indexOf(u8, filtered, "teru_list_panes") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "teru_get_graph") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "teru_send_input") == null);
}
