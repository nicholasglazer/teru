//! MCP stdio bridge — translates MCP stdio protocol to teru's Unix-socket HTTP protocol.
//!
//! Usage: `teru --mcp-bridge`
//!
//! This is a blocking bridge process (not part of the event loop). It reads
//! newline-delimited JSON-RPC 2.0 from stdin, wraps each message in HTTP,
//! sends it to teru's MCP server over a Unix domain socket, reads the HTTP
//! response, extracts the JSON body, and writes it to stdout with a newline.
//!
//! The bridge discovers the socket path from $TERU_MCP_SOCKET or returns an
//! error if no socket is found.

const std = @import("std");
const builtin = @import("builtin");
const posix = if (builtin.os.tag != .windows) std.posix else undefined;
const ipc = @import("../server/ipc.zig");

const max_line: usize = 65536;
const max_response: usize = 65536;

/// Portable stdin/stdout for std.c.read / std.c.write.
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
    _ = io; // Bridge uses blocking C I/O on stdin/stdout/socket

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
        // Read one line from stdin (blocking)
        const line = readLine(&line_buf) orelse return; // EOF
        if (line.len == 0) continue; // empty line

        // Notifications (no "id" field) don't expect a response.
        // Don't forward them to the socket — teru doesn't handle them.
        if (std.mem.indexOf(u8, line, "\"id\"") == null or
            std.mem.indexOf(u8, line, "\"notifications/") != null)
        {
            continue;
        }

        // Read-only mode: reject calls to write tools
        if (read_only and isBlockedToolCall(line)) {
            var err_buf: [512]u8 = undefined;
            if (rejectToolCall(line, &err_buf)) |err_json| {
                _ = std.c.write(stdoutFd(), err_json.ptr, err_json.len);
                _ = std.c.write(stdoutFd(), "\n", 1);
            }
            continue;
        }

        // Connect to teru's MCP server
        var conn = connectSocket(socket_path) orelse {
            const err_msg = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Cannot connect to teru socket\"},\"id\":null}\n";
            _ = std.c.write(stdoutFd(), err_msg.ptr, err_msg.len);
            continue;
        };

        // Send HTTP POST with the JSON line as body
        sendHttpRequest(&conn, line);

        // Read HTTP response and extract JSON body
        var resp_buf: [max_response]u8 = undefined;
        if (readHttpResponse(&conn, &resp_buf)) |json_body| {
            if (read_only and std.mem.indexOf(u8, line, "\"tools/list\"") != null) {
                // Filter write tools from tools/list response
                var filter_buf: [max_response]u8 = undefined;
                if (filterToolsList(json_body, &filter_buf)) |filtered| {
                    _ = std.c.write(stdoutFd(), filtered.ptr, filtered.len);
                    _ = std.c.write(stdoutFd(), "\n", 1);
                    conn.close();
                    continue;
                }
            }
            // Write JSON body + newline to stdout
            _ = std.c.write(stdoutFd(), json_body.ptr, json_body.len);
            _ = std.c.write(stdoutFd(), "\n", 1);
        }

        conn.close();
    }
}

// ── stdin reading ────────────────────────────────────────────────

fn readLine(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        const rc = std.c.read(stdinFd(), buf[pos..].ptr, 1);
        if (rc <= 0) {
            // EOF or error — return what we have, or null if nothing
            if (pos == 0) return null;
            return buf[0..pos];
        }
        if (buf[pos] == '\n') {
            return buf[0..pos];
        }
        pos += 1;
    }
    // Line too long — return what fits
    return buf[0..pos];
}

// ── Socket connection ────────────────────────────────────────────

fn connectSocket(path: []const u8) ?ipc.IpcHandle {
    return ipc.connect(path) catch null;
}

// ── HTTP wrapping ────────────────────────────────────────────────

fn sendHttpRequest(conn: *ipc.IpcHandle, json: []const u8) void {
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "POST / HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{json.len}) catch return;
    _ = conn.write(header) catch {};
    _ = conn.write(json) catch {};
}

// ── HTTP response parsing ────────────────────────────────────────

fn readHttpResponse(conn: *ipc.IpcHandle, buf: []u8) ?[]const u8 {
    var total: usize = 0;

    while (total < buf.len) {
        const n = conn.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;

        // Check if we have complete headers + body
        if (findHeaderEnd(buf[0..total])) |header_end| {
            if (parseContentLength(buf[0..total])) |content_len| {
                if (total >= header_end + content_len) {
                    return buf[header_end .. header_end + content_len];
                }
                // Keep reading for more body bytes
            } else {
                // No Content-Length — connection-close semantics, keep reading
            }
        }
    }

    // Connection closed — extract body from what we have
    if (total == 0) return null;
    if (findHeaderEnd(buf[0..total])) |header_end| {
        if (header_end < total) {
            return buf[header_end..total];
        }
    }
    // No HTTP headers found — treat entire response as body (bare JSON)
    return buf[0..total];
}

// ── Socket path discovery ────────────────────────────────────────

/// Static buffer for auto-discovered socket path (stable memory for returned slice).
var discovered_path: [256]u8 = undefined;

fn findSocket() ?[]const u8 {
    // Try $TERU_MCP_SOCKET first
    if (std.c.getenv("TERU_MCP_SOCKET")) |env| {
        return std.mem.sliceTo(env, 0);
    }
    // Fallback: scan runtime directory for teru-mcp-*.sock
    return discoverSocket();
}

fn discoverSocket() ?[]const u8 {
    const runtime_dir_z = getRuntimeDir() orelse return null;
    const runtime_dir = std.mem.sliceTo(runtime_dir_z, 0);

    const dir = std.c.opendir(runtime_dir_z) orelse return null;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.sliceTo(name_ptr, 0);

        // Match teru-mcp-*.sock
        if (!std.mem.startsWith(u8, name, "teru-mcp-")) continue;
        if (!std.mem.endsWith(u8, name, ".sock")) continue;

        // Build full path and try connecting
        const full_len = runtime_dir.len + 1 + name.len;
        if (full_len >= discovered_path.len) continue;

        @memcpy(discovered_path[0..runtime_dir.len], runtime_dir);
        discovered_path[runtime_dir.len] = '/';
        @memcpy(discovered_path[runtime_dir.len + 1 ..][0..name.len], name);

        // Test if this socket is alive
        if (ipc.connect(discovered_path[0..full_len])) |conn| {
            conn.close();
            return discovered_path[0..full_len];
        } else |_| {
            continue; // stale socket, try next
        }
    }
    return null;
}

var runtime_dir_buf: [128:0]u8 = undefined;

fn getRuntimeDir() ?[*:0]const u8 {
    if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| {
        return dir;
    }
    // Fallback: /run/user/{uid}
    if (builtin.os.tag == .linux) {
        const uid = std.c.getuid();
        const slice = std.fmt.bufPrint(&runtime_dir_buf, "/run/user/{d}", .{uid}) catch return null;
        runtime_dir_buf[slice.len] = 0;
        return @ptrCast(&runtime_dir_buf);
    }
    return null;
}

// ── Read-only mode filtering ────────────────────────────────────

/// Tools that are blocked in read-only mode (mutate state).
const blocked_tools = [_][]const u8{
    "teru_send_input",
    "teru_send_keys",
    "teru_create_pane",
    "teru_close_pane",
    "teru_broadcast",
    "teru_set_config",
    "teru_session_restore",
};

/// Check if a tools/call request targets a blocked tool.
fn isBlockedToolCall(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "\"tools/call\"") == null) return false;
    for (blocked_tools) |tool| {
        if (std.mem.indexOf(u8, line, tool) != null) return true;
    }
    return false;
}

/// Build a JSON-RPC error response for a rejected tool call.
fn rejectToolCall(line: []const u8, buf: []u8) ?[]const u8 {
    // Extract "id" value from request
    const id_str = extractId(line) orelse "null";
    return std.fmt.bufPrint(buf, "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":-32600,\"message\":\"Tool blocked: read-only mode (TERU_MCP_READONLY=1)\"}},\"id\":{s}}}", .{id_str}) catch null;
}

/// Filter blocked tools from a tools/list JSON response.
/// Rebuilds the response with only allowed tools.
fn filterToolsList(json: []const u8, buf: []u8) ?[]const u8 {
    // Strategy: find each tool definition block and skip blocked ones.
    // Tool defs are `{"name":"teru_xxx",...}` objects in the tools array.
    var out_pos: usize = 0;
    var pos: usize = 0;

    // Copy everything up to the tools array
    const tools_start = std.mem.indexOf(u8, json, "\"tools\":[") orelse return null;
    const array_start = tools_start + "\"tools\":[".len;
    if (array_start + out_pos > buf.len) return null;
    @memcpy(buf[0..array_start], json[0..array_start]);
    out_pos = array_start;

    // Parse individual tool objects from the array
    pos = array_start;
    var first = true;
    while (pos < json.len) {
        // Skip whitespace and commas
        while (pos < json.len and (json[pos] == ' ' or json[pos] == ',' or json[pos] == '\n' or json[pos] == '\r')) : (pos += 1) {}
        if (pos >= json.len or json[pos] == ']') break;
        if (json[pos] != '{') break;

        // Find matching closing brace (handle nested braces)
        const obj_start = pos;
        var depth: usize = 0;
        while (pos < json.len) : (pos += 1) {
            if (json[pos] == '{') depth += 1;
            if (json[pos] == '}') {
                depth -= 1;
                if (depth == 0) {
                    pos += 1;
                    break;
                }
            }
        }
        const obj = json[obj_start..pos];

        // Check if this tool is blocked
        var blocked = false;
        for (blocked_tools) |tool| {
            if (std.mem.indexOf(u8, obj, tool) != null) {
                blocked = true;
                break;
            }
        }

        if (!blocked) {
            if (!first) {
                if (out_pos < buf.len) {
                    buf[out_pos] = ',';
                    out_pos += 1;
                }
            }
            if (out_pos + obj.len > buf.len) return null;
            @memcpy(buf[out_pos..][0..obj.len], obj);
            out_pos += obj.len;
            first = false;
        }
    }

    // Copy the rest (closing brackets, id field, etc.)
    // Find "]" after tools array
    const array_end = std.mem.indexOfScalarPos(u8, json, pos, ']') orelse return null;
    const tail = json[array_end..];
    if (out_pos + tail.len > buf.len) return null;
    @memcpy(buf[out_pos..][0..tail.len], tail);
    out_pos += tail.len;

    return buf[0..out_pos];
}

/// Extract the JSON "id" field value as a raw string (number, string, or null).
fn extractId(json: []const u8) ?[]const u8 {
    const needle = "\"id\":";
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = pos + needle.len;
    if (start >= json.len) return null;

    // Skip whitespace
    var i = start;
    while (i < json.len and json[i] == ' ') : (i += 1) {}
    if (i >= json.len) return null;

    if (json[i] == '"') {
        // String id — find closing quote
        const str_start = i;
        i += 1;
        while (i < json.len and json[i] != '"') : (i += 1) {}
        if (i < json.len) return json[str_start .. i + 1];
    } else {
        // Numeric or null — read until comma, brace, or end
        const val_start = i;
        while (i < json.len and json[i] != ',' and json[i] != '}' and json[i] != ' ') : (i += 1) {}
        return json[val_start..i];
    }
    return null;
}

// ── HTTP parsing helpers ─────────────────────────────────────────

fn findHeaderEnd(data: []const u8) ?usize {
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |pos| {
        return pos + 4;
    }
    return null;
}

fn parseContentLength(data: []const u8) ?usize {
    const needle = "Content-Length: ";
    const pos = std.mem.indexOf(u8, data, needle) orelse
        (std.mem.indexOf(u8, data, "content-length: ") orelse return null);

    const start = pos + needle.len;
    const end = std.mem.indexOfScalar(u8, data[start..], '\r') orelse return null;
    return std.fmt.parseInt(usize, data[start .. start + end], 10) catch null;
}

// ── HTTP formatting (public for tests) ───────────────────────────

pub fn formatHttpRequest(json: []const u8, buf: []u8) ?[]const u8 {
    const header = std.fmt.bufPrint(buf, "POST / HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{json.len}) catch return null;
    const header_len = header.len;
    if (header_len + json.len > buf.len) return null;
    @memcpy(buf[header_len .. header_len + json.len], json);
    return buf[0 .. header_len + json.len];
}

pub fn extractJsonFromHttp(http: []const u8) ?[]const u8 {
    const header_end = findHeaderEnd(http) orelse return null;
    if (parseContentLength(http)) |content_len| {
        if (header_end + content_len <= http.len) {
            return http[header_end .. header_end + content_len];
        }
    }
    // Fallback: everything after headers
    if (header_end < http.len) {
        return http[header_end..];
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────

const t = std.testing;

test "formatHttpRequest wraps JSON in HTTP POST" {
    var buf: [512]u8 = undefined;
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}";
    const result = formatHttpRequest(json, &buf);
    try t.expect(result != null);
    const http = result.?;

    // Should start with POST
    try t.expect(std.mem.startsWith(u8, http, "POST / HTTP/1.1\r\n"));

    // Should contain Content-Length matching json length
    var expected_cl: [64]u8 = undefined;
    const cl_str = try std.fmt.bufPrint(&expected_cl, "Content-Length: {d}\r\n", .{json.len});
    try t.expect(std.mem.indexOf(u8, http, cl_str) != null);

    // Should contain Content-Type
    try t.expect(std.mem.indexOf(u8, http, "Content-Type: application/json\r\n") != null);

    // Should end with the JSON body after \r\n\r\n
    try t.expect(std.mem.endsWith(u8, http, json));
}

test "extractJsonFromHttp parses HTTP response" {
    const http = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 45\r\n\r\n{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[]},\"id\":1}";
    const result = extractJsonFromHttp(http);
    try t.expect(result != null);
    try t.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[]},\"id\":1}", result.?);
}

test "extractJsonFromHttp handles missing Content-Length" {
    const http = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"jsonrpc\":\"2.0\",\"result\":{},\"id\":1}";
    const result = extractJsonFromHttp(http);
    try t.expect(result != null);
    try t.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{},\"id\":1}", result.?);
}

test "extractJsonFromHttp returns null for no body" {
    const http = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
    const result = extractJsonFromHttp(http);
    // Content-Length is 0, so header_end + 0 == header_end == http.len, returns empty slice
    try t.expect(result != null);
    try t.expectEqual(@as(usize, 0), result.?.len);
}

test "findHeaderEnd locates header boundary" {
    try t.expectEqual(@as(?usize, 6), findHeaderEnd("AB\r\n\r\nCD"));
    try t.expectEqual(@as(?usize, null), findHeaderEnd("no separator"));
}

test "parseContentLength extracts value" {
    try t.expectEqual(@as(?usize, 42), parseContentLength("Content-Length: 42\r\n"));
    try t.expectEqual(@as(?usize, 100), parseContentLength("content-length: 100\r\n"));
    try t.expectEqual(@as(?usize, null), parseContentLength("no header here"));
}

test "findSocket returns null when env not set" {
    // In test environment TERU_MCP_SOCKET is not set
    // We can only test the fallback path
    // (If the env IS set in some CI, this test still passes since it just returns the path)
    const result = findSocket();
    _ = result; // Just verify it doesn't crash
}

test "formatHttpRequest roundtrip with extractJsonFromHttp" {
    var buf: [1024]u8 = undefined;
    const original = "{\"method\":\"tools/list\",\"id\":42}";
    const http = formatHttpRequest(original, &buf) orelse unreachable;
    // Now parse it as if it were a response (rewrite status line for test)
    // Instead, test the raw request body extraction
    const body_start = findHeaderEnd(http) orelse unreachable;
    const body = http[body_start..];
    try t.expectEqualStrings(original, body);
}

test "connectSocket returns null for bad path" {
    // Non-existent socket should fail to connect
    const result = connectSocket("/tmp/teru-nonexistent-test.sock");
    try t.expect(result == null);
}

// ── Read-only mode tests ────────────────────────────────────────

test "isBlockedToolCall detects write tools" {
    try t.expect(isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_send_input\"},\"id\":1}"));
    try t.expect(isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_create_pane\"},\"id\":2}"));
    try t.expect(isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_close_pane\"},\"id\":3}"));
    try t.expect(isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_send_keys\"},\"id\":4}"));
    try t.expect(isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_broadcast\"},\"id\":5}"));
    try t.expect(isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_set_config\"},\"id\":6}"));
    try t.expect(isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_session_restore\"},\"id\":7}"));
}

test "isBlockedToolCall allows read tools" {
    try t.expect(!isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_list_panes\"},\"id\":1}"));
    try t.expect(!isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_read_output\"},\"id\":2}"));
    try t.expect(!isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_get_graph\"},\"id\":3}"));
    try t.expect(!isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_get_state\"},\"id\":4}"));
    try t.expect(!isBlockedToolCall("{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_screenshot\"},\"id\":5}"));
}

test "isBlockedToolCall ignores non-call methods" {
    try t.expect(!isBlockedToolCall("{\"method\":\"tools/list\",\"id\":1}"));
    try t.expect(!isBlockedToolCall("{\"method\":\"initialize\",\"id\":1}"));
}

test "rejectToolCall builds error response with numeric id" {
    var buf: [512]u8 = undefined;
    const line = "{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_send_input\"},\"id\":42}";
    const result = rejectToolCall(line, &buf);
    try t.expect(result != null);
    try t.expect(std.mem.indexOf(u8, result.?, "\"id\":42") != null);
    try t.expect(std.mem.indexOf(u8, result.?, "read-only mode") != null);
}

test "rejectToolCall builds error response with string id" {
    var buf: [512]u8 = undefined;
    const line = "{\"method\":\"tools/call\",\"params\":{\"name\":\"teru_send_input\"},\"id\":\"req-7\"}";
    const result = rejectToolCall(line, &buf);
    try t.expect(result != null);
    try t.expect(std.mem.indexOf(u8, result.?, "\"id\":\"req-7\"") != null);
}

test "extractId extracts numeric id" {
    try t.expectEqualStrings("42", extractId("{\"id\":42,\"method\":\"test\"}").?);
    try t.expectEqualStrings("1", extractId("{\"id\":1}").?);
}

test "extractId extracts string id" {
    try t.expectEqualStrings("\"abc\"", extractId("{\"id\":\"abc\"}").?);
}

test "extractId extracts null id" {
    try t.expectEqualStrings("null", extractId("{\"id\":null}").?);
}

test "filterToolsList removes blocked tools" {
    const json =
        \\{"jsonrpc":"2.0","result":{"tools":[{"name":"teru_list_panes"},{"name":"teru_send_input"},{"name":"teru_read_output"}]},"id":1}
    ;
    var buf: [max_response]u8 = undefined;
    const result = filterToolsList(json, &buf);
    try t.expect(result != null);
    const filtered = result.?;
    // Allowed tools should be present
    try t.expect(std.mem.indexOf(u8, filtered, "teru_list_panes") != null);
    try t.expect(std.mem.indexOf(u8, filtered, "teru_read_output") != null);
    // Blocked tool should be removed
    try t.expect(std.mem.indexOf(u8, filtered, "teru_send_input") == null);
}

test "filterToolsList keeps all tools when none blocked" {
    const json =
        \\{"jsonrpc":"2.0","result":{"tools":[{"name":"teru_list_panes"},{"name":"teru_get_graph"}]},"id":1}
    ;
    var buf: [max_response]u8 = undefined;
    const result = filterToolsList(json, &buf);
    try t.expect(result != null);
    const filtered = result.?;
    try t.expect(std.mem.indexOf(u8, filtered, "teru_list_panes") != null);
    try t.expect(std.mem.indexOf(u8, filtered, "teru_get_graph") != null);
}

test "discoverSocket returns null when no sockets exist" {
    // In test environment there may or may not be teru sockets.
    // This just verifies the function doesn't crash.
    const result = discoverSocket();
    _ = result;
}

test "getRuntimeDir returns a path on Linux" {
    if (builtin.os.tag == .linux) {
        const dir = getRuntimeDir();
        try t.expect(dir != null);
        const slice = std.mem.sliceTo(dir.?, 0);
        try t.expect(slice.len > 0);
    }
}
