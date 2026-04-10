//! Remote PTY backend — communicates with a teru daemon over IPC.
//!
//! Same interface as PosixPty (read/write/resize/deinit/isAlive) but routes
//! all I/O through the daemon protocol instead of local PTY file descriptors.
//! The main event loop polls the IPC socket and pushes daemon output into the
//! ring buffer; pane read() drains from it.

const std = @import("std");
const posix = std.posix;
const proto = @import("../server/protocol.zig");

const RemotePty = @This();

ipc_fd: posix.fd_t,
pane_id: u64,
alive: bool = true,

/// Ring buffer for pending output (filled by main loop's IPC poll, drained by read()).
pending: RingBuffer = .{},

/// Fixed-size lock-free ring buffer using wrapping arithmetic.
/// Overflow drops oldest bytes (head advances past tail).
pub const RingBuffer = struct {
    buf: [65536]u8 = undefined,
    head: usize = 0, // write position
    tail: usize = 0, // read position

    /// Push bytes into the ring buffer. On overflow, oldest bytes are dropped.
    pub fn push(self: *RingBuffer, data: []const u8) void {
        for (data) |byte| {
            self.buf[self.head % self.buf.len] = byte;
            self.head +%= 1;
            // If head catches tail, advance tail (drop oldest)
            if (self.head -% self.tail > self.buf.len) {
                self.tail = self.head -% self.buf.len;
            }
        }
    }

    /// Number of bytes available to read.
    pub fn available(self: *const RingBuffer) usize {
        return self.head -% self.tail;
    }

    /// Drain up to `out.len` bytes from the buffer. Returns number of bytes copied.
    pub fn drain(self: *RingBuffer, out: []u8) usize {
        const avail = self.available();
        const n = @min(avail, out.len);
        for (0..n) |i| {
            out[i] = self.buf[(self.tail +% i) % self.buf.len];
        }
        self.tail +%= n;
        return n;
    }
};

/// Compat constants to match PosixPty interface where needed.
pub const master: posix.fd_t = -1; // not used for remote
pub const child_pid: ?posix.pid_t = null; // process lives on daemon side

/// Read pending output from the ring buffer.
/// Returns error.WouldBlock if no data available (non-blocking semantics).
pub fn read(self: *RemotePty, buf: []u8) !usize {
    const n = self.pending.drain(buf);
    if (n == 0) return error.WouldBlock;
    return n;
}

/// Write input to daemon (tagged with pane_id).
/// Data is chunked into 4096-byte segments to fit protocol payload limits.
pub fn write(self: *const RemotePty, data: []const u8) !usize {
    var payload_buf: [8 + 4096]u8 = undefined;
    var sent: usize = 0;
    while (sent < data.len) {
        const end = sent + @min(data.len - sent, 4096);
        const chunk = data[sent..end];
        const tagged = proto.encodePanePayload(self.pane_id, chunk, &payload_buf) orelse
            return error.WriteFailed;
        if (!proto.sendMessage(self.ipc_fd, .input, tagged)) return error.WriteFailed;
        sent = end;
    }
    return sent;
}

/// Send resize to daemon for this pane.
/// Payload: 8-byte pane_id (LE) + 4-byte resize (u16 rows + u16 cols LE).
pub fn resize(self: *const RemotePty, rows: u16, cols: u16) void {
    var buf: [12]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], self.pane_id, .little);
    const r = proto.encodeResize(rows, cols);
    buf[8] = r[0];
    buf[9] = r[1];
    buf[10] = r[2];
    buf[11] = r[3];
    _ = proto.sendMessage(self.ipc_fd, .resize, &buf);
}

/// Mark as dead. Does NOT close ipc_fd — it is shared by all remote panes
/// and owned by the main event loop.
pub fn deinit(self: *RemotePty) void {
    self.alive = false;
}

/// Check whether this remote pane is still alive.
pub fn isAlive(self: *const RemotePty) bool {
    return self.alive;
}

// ── Tests ─────────────────────────────────────────────────────────

test "RingBuffer: push/drain round-trip" {
    var rb = RingBuffer{};
    const input = "hello, daemon!";
    rb.push(input);

    var out: [64]u8 = undefined;
    const n = rb.drain(&out);
    try std.testing.expectEqual(@as(usize, input.len), n);
    try std.testing.expectEqualStrings(input, out[0..n]);
}

test "RingBuffer: overflow wraps and drops oldest" {
    var rb = RingBuffer{};

    // Fill the entire buffer
    var fill: [65536]u8 = undefined;
    for (&fill, 0..) |*b, i| b.* = @truncate(i);
    rb.push(&fill);

    // Push 10 more bytes — these should evict the first 10
    const extra = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44 };
    rb.push(&extra);

    try std.testing.expectEqual(@as(usize, 65536), rb.available());

    // Drain everything and verify last 10 bytes are the extra data
    var out: [65536]u8 = undefined;
    const n = rb.drain(&out);
    try std.testing.expectEqual(@as(usize, 65536), n);
    try std.testing.expectEqualSlices(u8, &extra, out[n - 10 .. n]);
}

test "RingBuffer: empty drain returns 0" {
    var rb = RingBuffer{};
    var out: [16]u8 = undefined;
    const n = rb.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "RingBuffer: partial drain leaves remainder" {
    var rb = RingBuffer{};
    rb.push("abcdef");

    var out: [3]u8 = undefined;
    const n1 = rb.drain(&out);
    try std.testing.expectEqual(@as(usize, 3), n1);
    try std.testing.expectEqualStrings("abc", out[0..3]);

    try std.testing.expectEqual(@as(usize, 3), rb.available());

    var out2: [8]u8 = undefined;
    const n2 = rb.drain(&out2);
    try std.testing.expectEqual(@as(usize, 3), n2);
    try std.testing.expectEqualStrings("def", out2[0..3]);
}

test "read: returns WouldBlock when empty" {
    var rpty = RemotePty{
        .ipc_fd = -1,
        .pane_id = 42,
    };
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.WouldBlock, rpty.read(&buf));
}

test "read: drains pending data" {
    var rpty = RemotePty{
        .ipc_fd = -1,
        .pane_id = 42,
    };
    rpty.pending.push("terminal output");

    var buf: [64]u8 = undefined;
    const n = try rpty.read(&buf);
    try std.testing.expectEqualStrings("terminal output", buf[0..n]);
}

test "deinit: marks not alive" {
    var rpty = RemotePty{
        .ipc_fd = -1,
        .pane_id = 1,
    };
    try std.testing.expect(rpty.isAlive());
    rpty.deinit();
    try std.testing.expect(!rpty.isAlive());
}
