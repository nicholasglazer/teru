//! Daemon/client wire protocol for teru session persistence.
//!
//! Simple message framing over Unix domain sockets. Each message is a
//! 5-byte header (tag + length) followed by a variable-length payload.
//! All I/O uses raw C read/write — no std.Io (daemon may not have a window).

const std = @import("std");
const posix = std.posix;

/// Message types for daemon <-> client communication.
pub const Tag = enum(u8) {
    /// Client -> daemon: keyboard/input bytes.
    input = 0,
    /// Daemon -> client: raw PTY output bytes.
    output = 1,
    /// Client -> daemon: terminal size changed (payload: 4 bytes, u16 rows + u16 cols).
    resize = 2,
    /// Client -> daemon: graceful disconnect.
    detach = 3,
    /// Daemon -> client: full grid snapshot on attach (reserved for Phase 3 GUI).
    grid_sync = 4,
    /// Daemon -> client: pane layout info (reserved for Phase 3 GUI).
    pane_info = 5,
    /// Client -> daemon: multiplexer command (split, close, etc; reserved).
    command = 6,

    pub fn fromByte(b: u8) ?Tag {
        return switch (b) {
            0 => .input,
            1 => .output,
            2 => .resize,
            3 => .detach,
            4 => .grid_sync,
            5 => .pane_info,
            6 => .command,
            else => null,
        };
    }
};

/// Wire header: 1 byte tag + 4 bytes little-endian length.
pub const Header = extern struct {
    tag: Tag,
    len: u32 align(1),

    pub fn toBytes(self: Header) [header_size]u8 {
        var buf: [header_size]u8 = undefined;
        buf[0] = @intFromEnum(self.tag);
        const len_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, self.len));
        buf[1] = len_bytes[0];
        buf[2] = len_bytes[1];
        buf[3] = len_bytes[2];
        buf[4] = len_bytes[3];
        return buf;
    }

    pub fn fromBytes(bytes: [header_size]u8) ?Header {
        const tag = Tag.fromByte(bytes[0]) orelse return null;
        const len = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, bytes[1..5]));
        return .{ .tag = tag, .len = len };
    }
};

pub const header_size: usize = 5;
pub const max_payload: usize = 65536;

/// Send a framed message over a file descriptor.
/// Uses raw C write — suitable for sockets and pipes.
pub fn sendMessage(fd: posix.fd_t, tag: Tag, payload: []const u8) bool {
    const hdr = Header{ .tag = tag, .len = @intCast(payload.len) };
    const hdr_bytes = hdr.toBytes();
    if (!writeAll(fd, &hdr_bytes)) return false;
    if (payload.len > 0) {
        if (!writeAll(fd, payload)) return false;
    }
    return true;
}

/// Receive a framed message from a file descriptor (non-blocking).
/// Returns the payload slice within `payload_buf`, or null on EAGAIN/EOF/error.
pub fn recvMessage(fd: posix.fd_t, header_out: *Header, payload_buf: []u8) ?[]const u8 {
    var hdr_bytes: [header_size]u8 = undefined;
    const hdr_n = readNonBlock(fd, &hdr_bytes);
    if (hdr_n == null) return null; // EAGAIN
    if (hdr_n.? != header_size) return null; // partial/EOF

    const hdr = Header.fromBytes(hdr_bytes) orelse return null;
    header_out.* = hdr;

    if (hdr.len == 0) return payload_buf[0..0];
    if (hdr.len > payload_buf.len) return null; // payload too large

    const payload_len: usize = hdr.len;
    var total: usize = 0;
    while (total < payload_len) {
        const rc = std.c.read(fd, payload_buf[total..].ptr, payload_len - total);
        if (rc <= 0) return null; // EOF or error
        total += @intCast(rc);
    }

    return payload_buf[0..payload_len];
}

/// Encode a resize payload: u16 rows + u16 cols as 4 little-endian bytes.
pub fn encodeResize(rows: u16, cols: u16) [4]u8 {
    var buf: [4]u8 = undefined;
    const r = std.mem.toBytes(std.mem.nativeToLittle(u16, rows));
    const c = std.mem.toBytes(std.mem.nativeToLittle(u16, cols));
    buf[0] = r[0];
    buf[1] = r[1];
    buf[2] = c[0];
    buf[3] = c[1];
    return buf;
}

/// Decode a resize payload.
pub fn decodeResize(payload: []const u8) ?struct { rows: u16, cols: u16 } {
    if (payload.len < 4) return null;
    const rows = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, payload[0..2]));
    const cols = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, payload[2..4]));
    return .{ .rows = rows, .cols = cols };
}

// ── Internal helpers ──────────────────────────────────────────────

/// Write all bytes to fd using raw C write. Returns false on error.
fn writeAll(fd: posix.fd_t, data: []const u8) bool {
    var written: usize = 0;
    while (written < data.len) {
        const rc = std.c.write(fd, data[written..].ptr, data.len - written);
        if (rc <= 0) return false;
        written += @intCast(rc);
    }
    return true;
}

/// Non-blocking read of exactly `buf.len` bytes. Returns null on EAGAIN, byte count otherwise.
fn readNonBlock(fd: posix.fd_t, buf: []u8) ?usize {
    const rc = std.c.read(fd, buf.ptr, buf.len);
    if (rc < 0) return null; // EAGAIN or error
    if (rc == 0) return null; // EOF
    return @intCast(rc);
}

// ── Tests ─────────────────────────────────────────────────────────

test "Header: round-trip toBytes/fromBytes" {
    const hdr = Header{ .tag = .input, .len = 42 };
    const bytes = hdr.toBytes();
    const decoded = Header.fromBytes(bytes).?;
    try std.testing.expectEqual(Tag.input, decoded.tag);
    try std.testing.expectEqual(@as(u32, 42), decoded.len);
}

test "Header: all tags round-trip" {
    const tags = [_]Tag{ .input, .output, .resize, .detach, .grid_sync, .pane_info, .command };
    for (tags) |tag| {
        const hdr = Header{ .tag = tag, .len = 100 };
        const bytes = hdr.toBytes();
        const decoded = Header.fromBytes(bytes).?;
        try std.testing.expectEqual(tag, decoded.tag);
    }
}

test "Header: invalid tag byte returns null" {
    var bytes = [_]u8{ 0xFF, 0, 0, 0, 0 };
    try std.testing.expect(Header.fromBytes(bytes) == null);
    bytes[0] = 99;
    try std.testing.expect(Header.fromBytes(bytes) == null);
}

test "encodeResize/decodeResize round-trip" {
    const encoded = encodeResize(24, 80);
    const decoded = decodeResize(&encoded).?;
    try std.testing.expectEqual(@as(u16, 24), decoded.rows);
    try std.testing.expectEqual(@as(u16, 80), decoded.cols);
}

test "encodeResize/decodeResize: large values" {
    const encoded = encodeResize(500, 200);
    const decoded = decodeResize(&encoded).?;
    try std.testing.expectEqual(@as(u16, 500), decoded.rows);
    try std.testing.expectEqual(@as(u16, 200), decoded.cols);
}

test "decodeResize: too short payload returns null" {
    const buf = [_]u8{ 1, 2, 3 };
    try std.testing.expect(decodeResize(&buf) == null);
}

test "Tag.fromByte: valid and invalid" {
    try std.testing.expectEqual(Tag.input, Tag.fromByte(0).?);
    try std.testing.expectEqual(Tag.output, Tag.fromByte(1).?);
    try std.testing.expectEqual(Tag.command, Tag.fromByte(6).?);
    try std.testing.expect(Tag.fromByte(7) == null);
    try std.testing.expect(Tag.fromByte(255) == null);
}

test "Header: zero-length payload" {
    const hdr = Header{ .tag = .detach, .len = 0 };
    const bytes = hdr.toBytes();
    const decoded = Header.fromBytes(bytes).?;
    try std.testing.expectEqual(Tag.detach, decoded.tag);
    try std.testing.expectEqual(@as(u32, 0), decoded.len);
}

test "sendMessage/recvMessage: round-trip via socketpair" {
    // Create a Unix socketpair for testing
    var fds: [2]posix.fd_t = undefined;
    const rc = std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return; // skip if socketpair not available

    defer _ = posix.system.close(fds[0]);
    defer _ = posix.system.close(fds[1]);

    // Send a message on fds[0]
    const payload = "hello daemon";
    const ok = sendMessage(fds[0], .input, payload);
    try std.testing.expect(ok);

    // Receive on fds[1]
    var hdr: Header = undefined;
    var buf: [max_payload]u8 = undefined;
    const received = recvMessage(fds[1], &hdr, &buf);
    try std.testing.expect(received != null);
    try std.testing.expectEqual(Tag.input, hdr.tag);
    try std.testing.expectEqualStrings(payload, received.?);
}

test "sendMessage/recvMessage: resize message round-trip" {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return;

    defer _ = posix.system.close(fds[0]);
    defer _ = posix.system.close(fds[1]);

    const resize_payload = encodeResize(50, 132);
    const ok = sendMessage(fds[0], .resize, &resize_payload);
    try std.testing.expect(ok);

    var hdr: Header = undefined;
    var buf: [max_payload]u8 = undefined;
    const received = recvMessage(fds[1], &hdr, &buf);
    try std.testing.expect(received != null);
    try std.testing.expectEqual(Tag.resize, hdr.tag);

    const sz = decodeResize(received.?).?;
    try std.testing.expectEqual(@as(u16, 50), sz.rows);
    try std.testing.expectEqual(@as(u16, 132), sz.cols);
}

test "sendMessage: empty payload (detach)" {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return;

    defer _ = posix.system.close(fds[0]);
    defer _ = posix.system.close(fds[1]);

    const ok = sendMessage(fds[0], .detach, "");
    try std.testing.expect(ok);

    var hdr: Header = undefined;
    var buf: [max_payload]u8 = undefined;
    const received = recvMessage(fds[1], &hdr, &buf);
    try std.testing.expect(received != null);
    try std.testing.expectEqual(Tag.detach, hdr.tag);
    try std.testing.expectEqual(@as(usize, 0), received.?.len);
}
