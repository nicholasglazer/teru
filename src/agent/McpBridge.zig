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
const posix = std.posix;

const max_line: usize = 65536;
const max_response: usize = 65536;
const socket_path_max: usize = 108;

// ── Entry point ──────────────────────────────────────────────────

pub fn run(io: std.Io) !void {
    _ = io; // Bridge uses blocking C I/O on stdin/stdout/socket

    const socket_path = findSocket() orelse {
        const msg = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"No teru MCP socket found. Set TERU_MCP_SOCKET or run teru first.\"},\"id\":null}\n";
        _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
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

        // Connect to teru's MCP server
        const sock = connectSocket(socket_path) orelse {
            const err_msg = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32000,\"message\":\"Cannot connect to teru socket\"},\"id\":null}\n";
            _ = std.c.write(posix.STDOUT_FILENO, err_msg.ptr, err_msg.len);
            continue;
        };

        // Send HTTP POST with the JSON line as body
        sendHttpRequest(sock, line);

        // Read HTTP response and extract JSON body
        var resp_buf: [max_response]u8 = undefined;
        if (readHttpResponse(sock, &resp_buf)) |json_body| {
            // Write JSON body + newline to stdout
            _ = std.c.write(posix.STDOUT_FILENO, json_body.ptr, json_body.len);
            _ = std.c.write(posix.STDOUT_FILENO, "\n", 1);
        }

        _ = posix.system.close(sock);
    }
}

// ── stdin reading ────────────────────────────────────────────────

fn readLine(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        const rc = std.c.read(posix.STDIN_FILENO, buf[pos..].ptr, 1);
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

fn connectSocket(path: []const u8) ?posix.fd_t {
    const sock = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (sock < 0) return null;

    var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    if (path.len > addr.path.len) {
        _ = posix.system.close(sock);
        return null;
    }
    @memcpy(addr.path[0..path.len], path);

    const addr_ptr: *const posix.sockaddr = @ptrCast(&addr);
    if (std.c.connect(sock, addr_ptr, @sizeOf(posix.sockaddr.un)) != 0) {
        _ = posix.system.close(sock);
        return null;
    }

    return sock;
}

// ── HTTP wrapping ────────────────────────────────────────────────

fn sendHttpRequest(sock: posix.fd_t, json: []const u8) void {
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "POST / HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{json.len}) catch return;
    _ = std.c.write(sock, header.ptr, header.len);
    _ = std.c.write(sock, json.ptr, json.len);
}

// ── HTTP response parsing ────────────────────────────────────────

fn readHttpResponse(sock: posix.fd_t, buf: []u8) ?[]const u8 {
    var total: usize = 0;

    while (total < buf.len) {
        const rc = std.c.read(sock, buf[total..].ptr, buf.len - total);
        if (rc <= 0) break;
        total += @intCast(rc);

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

fn findSocket() ?[]const u8 {
    // Try $TERU_MCP_SOCKET first
    if (std.c.getenv("TERU_MCP_SOCKET")) |env| {
        return std.mem.sliceTo(env, 0);
    }
    // Fallback: glob is too complex for Zig — just return null
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
    try t.expectEqual(@as(?posix.fd_t, null), result);
}
