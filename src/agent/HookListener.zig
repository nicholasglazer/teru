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
const builtin = @import("builtin");
const posix = std.posix;
const HookHandler = @import("HookHandler.zig");
const compat = @import("../compat.zig");
const ipc = @import("../server/ipc.zig");
const tools = @import("McpTools.zig");

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
queue: [MAX_QUEUED]?QueuedEvent = @splat(null),
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

    var path_buf: [108]u8 = @splat(0);
    const path_len = @min(path.len, path_buf.len);
    @memcpy(path_buf[0..path_len], path[0..path_len]);

    return .{
        .allocator = allocator,
        .server_fd = server.rawFd(),
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

/// True once `data` holds a complete HTTP request: headers terminated by a
/// blank line, plus a body of at least Content-Length bytes (0 if absent).
fn requestComplete(data: []const u8) bool {
    const hdr_end = std.mem.find(u8, data, "\r\n\r\n") orelse return false;
    const body_start = hdr_end + 4;
    const hdrs = data[0..hdr_end];
    var content_length: usize = 0;
    var i: usize = 0;
    while (i + 15 <= hdrs.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hdrs[i .. i + 15], "content-length:")) {
            var j = i + 15;
            while (j < hdrs.len and (hdrs[j] == ' ' or hdrs[j] == '\t')) j += 1;
            while (j < hdrs.len and hdrs[j] >= '0' and hdrs[j] <= '9') : (j += 1) {
                content_length = content_length * 10 + (hdrs[j] - '0');
            }
            break;
        }
    }
    return data.len >= body_start + content_length;
}

/// Accept and process one pending connection. Non-blocking.
pub fn poll(self: *HookListener) void {
    // Accept connection
    const client = ipc.accept(ipc.IpcHandle.fromRaw(self.server_fd)) orelse return;
    const client_fd = client.rawFd();
    defer client.close();

    // Read the full HTTP request. Hook POSTs are small and usually arrive in
    // one segment, but a larger tool_input can span TCP segments; reading once
    // and breaking on EAGAIN truncated the body and dropped the connection.
    // Stop as soon as the Content-Length body is complete (so a complete
    // request adds no latency), else wait briefly for the next segment.
    var buf: [RECV_BUF_SIZE]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        if (total > 0 and requestComplete(buf[0..total])) break;
        const n_raw = posix.system.read(client_fd, @ptrCast(buf[total..].ptr), buf.len - total);
        if (n_raw > 0) {
            total += @intCast(n_raw);
            continue;
        }
        if (n_raw == 0) break; // peer closed
        switch (posix.errno(n_raw)) {
            .AGAIN, .INTR => {
                // posix.poll / posix.pollfd don't exist on the Windows target
                // (ws2_32 has no pollfd, 0.17 std). The agent hook listener is a
                // Unix-socket feature; on Windows just proceed with what we have.
                if (builtin.os.tag == .windows) break;
                var pfd = [_]posix.pollfd{.{ .fd = client_fd, .events = posix.POLL.IN, .revents = 0 }};
                const pr = posix.poll(&pfd, 200) catch break;
                if (pr == 0) break; // 200ms with no more data — proceed with what we have
            },
            else => break,
        }
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
    if (tools.extractJsonStringOwned(body, "session_id", self.allocator)) |s| session_id = s;
    if (tools.extractJsonStringOwned(body, "tool_name", self.allocator)) |s| tool_name = s;

    // For PreToolUse, extract tool_input as raw JSON string
    if (tools.extractJsonStringOwned(body, "tool_input", self.allocator)) |s| tool_input = s;

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

