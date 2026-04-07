//! HTTP hook listener for Claude Code integration.
//!
//! Creates a Unix socket and accepts HTTP POST requests from Claude Code's
//! `http` hook handler type. Parses the JSON body using HookHandler and
//! queues events for the main event loop to process.
//!
//! Socket path: /run/user/$UID/teru-hooks-$PID.sock
//!
//! Claude Code hook config (in ~/.claude/settings.json):
//! ```json
//! {
//!   "hooks": {
//!     "SubagentStart": [{ "type": "http", "url": "http+unix:///run/user/1000/teru-hooks-12345.sock" }],
//!     "SubagentStop": [{ "type": "http", "url": "http+unix:///run/user/1000/teru-hooks-12345.sock" }],
//!     "PreToolUse": [{ "type": "http", "url": "http+unix:///run/user/1000/teru-hooks-12345.sock" }],
//!     "PostToolUse": [{ "type": "http", "url": "http+unix:///run/user/1000/teru-hooks-12345.sock" }]
//!   }
//! }
//! ```

const std = @import("std");
const posix = std.posix;
const HookHandler = @import("HookHandler.zig");
const compat = @import("../compat.zig");
const ipc = @import("../server/ipc.zig");

const HookListener = @This();

const MAX_QUEUED = 32;
const RECV_BUF_SIZE = 8192;

/// Queued hook event with heap-owned data.
pub const QueuedEvent = struct {
    event: HookHandler.HookEvent,
    session_id: ?[]const u8,
    tool_name: ?[]const u8,
    tool_input: ?[]const u8,
};

// ── State ──────────────────────────────────────────────────────────

allocator: std.mem.Allocator,
server_fd: posix.fd_t,
socket_path: [108]u8,
socket_path_len: usize,

/// Ring buffer of queued events (main loop drains this).
queue: [MAX_QUEUED]?QueuedEvent = [_]?QueuedEvent{null} ** MAX_QUEUED,
queue_head: usize = 0,
queue_tail: usize = 0,

// ── Init / Deinit ──────────────────────────────────────────────────

pub fn init(allocator: std.mem.Allocator) !HookListener {
    const pid = compat.getPid();
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return error.PathTooLong;

    var ipc_path_buf: [256]u8 = undefined;
    const path = ipc.buildPath(&ipc_path_buf, "hooks", pid_str) orelse return error.PathTooLong;

    const server = ipc.listen(path) catch return error.SocketFailed;

    var path_buf: [108]u8 = [_]u8{0} ** 108;
    const path_len = @min(path.len, path_buf.len);
    @memcpy(path_buf[0..path_len], path[0..path_len]);

    return .{
        .allocator = allocator,
        .server_fd = server.fd,
        .socket_path = path_buf,
        .socket_path_len = path_len,
    };
}

pub fn deinit(self: *HookListener) void {
    _ = posix.system.close(self.server_fd);
    _ = posix.system.unlink(@ptrCast(&self.socket_path));

    // Free any queued events
    for (&self.queue) |*slot| {
        if (slot.*) |*ev| {
            HookHandler.freeHookEvent(&ev.event, self.allocator);
            if (ev.session_id) |s| self.allocator.free(s);
            if (ev.tool_name) |s| self.allocator.free(s);
            if (ev.tool_input) |s| self.allocator.free(s);
            slot.* = null;
        }
    }
}

pub fn getSocketPath(self: *const HookListener) []const u8 {
    return self.socket_path[0..self.socket_path_len];
}

// ── Poll (called from main event loop) ─────────────────────────────

/// Accept and process one pending connection. Non-blocking.
pub fn poll(self: *HookListener) void {
    // Accept connection
    const client = ipc.accept(.{ .fd = self.server_fd }) orelse return;
    const client_fd = client.fd;
    defer client.close();

    // Read HTTP request (small — hook payloads are typically <2KB)
    var buf: [RECV_BUF_SIZE]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n_raw = posix.system.read(client_fd, @ptrCast(buf[total..].ptr), buf.len - total);
        if (n_raw <= 0) break;
        const n: usize = @intCast(n_raw);
        total += n;
    }
    if (total == 0) return;

    // Extract JSON body from HTTP POST (skip headers)
    const body = extractHttpBody(buf[0..total]) orelse return;
    if (body.len == 0) return;

    // Parse hook event
    const event = HookHandler.parseHookEvent(body, self.allocator) catch return;

    // Extract extra fields we care about (session_id, tool_name, tool_input)
    var session_id: ?[]const u8 = null;
    var tool_name: ?[]const u8 = null;
    var tool_input: ?[]const u8 = null;
    if (extractJsonString(body, "session_id", self.allocator)) |s| session_id = s;
    if (extractJsonString(body, "tool_name", self.allocator)) |s| tool_name = s;

    // For PreToolUse, extract tool_input as raw JSON string
    if (extractJsonString(body, "tool_input", self.allocator)) |s| tool_input = s;

    // Queue the event
    self.enqueue(.{
        .event = event,
        .session_id = session_id,
        .tool_name = tool_name,
        .tool_input = tool_input,
    });

    // Send HTTP 200 response with continue:true
    const response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 17\r\nConnection: close\r\n\r\n{\"continue\":true}";
    _ = posix.system.write(client_fd, response.ptr, response.len);
}

/// Dequeue the next event. Returns null if queue is empty.
pub fn nextEvent(self: *HookListener) ?QueuedEvent {
    if (self.queue[self.queue_head] == null) return null;
    const ev = self.queue[self.queue_head].?;
    self.queue[self.queue_head] = null;
    self.queue_head = (self.queue_head + 1) % MAX_QUEUED;
    return ev;
}

// ── Internal ───────────────────────────────────────────────────────

fn enqueue(self: *HookListener, ev: QueuedEvent) void {
    if (self.queue[self.queue_tail] != null) {
        // Queue full — drop oldest
        if (self.queue[self.queue_head]) |*old| {
            HookHandler.freeHookEvent(&old.event, self.allocator);
            if (old.session_id) |s| self.allocator.free(s);
            if (old.tool_name) |s| self.allocator.free(s);
            if (old.tool_input) |s| self.allocator.free(s);
            self.queue[self.queue_head] = null;
            self.queue_head = (self.queue_head + 1) % MAX_QUEUED;
        }
    }
    self.queue[self.queue_tail] = ev;
    self.queue_tail = (self.queue_tail + 1) % MAX_QUEUED;
}

/// Find the HTTP body after the \r\n\r\n separator.
fn extractHttpBody(data: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n') {
            return data[i + 4 ..];
        }
    }
    return null;
}

/// Quick extraction of a string field from JSON (avoids full parse).
fn extractJsonString(json: []const u8, key: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    // Search for "key":"value" pattern
    var i: usize = 0;
    while (i + key.len + 4 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len + 1 < json.len) {
            if (std.mem.eql(u8, json[i + 1 ..][0..key.len], key) and json[i + 1 + key.len] == '"') {
                // Found key — skip to value
                var j = i + 1 + key.len + 1;
                // Skip ":"
                while (j < json.len and (json[j] == ':' or json[j] == ' ')) : (j += 1) {}
                if (j >= json.len or json[j] != '"') return null;
                j += 1; // skip opening quote
                const start = j;
                while (j < json.len and json[j] != '"') : (j += 1) {
                    if (json[j] == '\\') j += 1; // skip escaped char
                }
                if (j > start) {
                    return allocator.dupe(u8, json[start..j]) catch null;
                }
                return null;
            }
        }
    }
    return null;
}
