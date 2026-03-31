//! Compatibility layer for Zig 0.16-dev.
//!
//! Contains helpers that don't have a direct native Io equivalent:
//!   - MemWriter/MemReader/DynWriter — in-memory serialization streams
//!   - nanoTimestamp() — clock_gettime(REALTIME) for code without Io access
//!   - getenv() — convenience wrapper around std.c.getenv
//!   - forkExec*() — process spawning with PTY/pipe setup
//!
//! File I/O has been migrated to native std.Io.Dir / std.Io.File APIs.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

// ── In-memory stream (replaces removed std.io.fixedBufferStream) ──

/// Minimal in-memory writer that provides writeAll/writeInt/writeByte.
pub const MemWriter = struct {
    buffer: []u8,
    pos: usize = 0,

    pub fn writeAll(self: *MemWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn writeByte(self: *MemWriter, byte: u8) !void {
        if (self.pos >= self.buffer.len) return error.NoSpaceLeft;
        self.buffer[self.pos] = byte;
        self.pos += 1;
    }

    pub fn writeInt(self: *MemWriter, comptime T: type, value: T, comptime endian: std.builtin.Endian) !void {
        const bytes = std.mem.toBytes(if (endian == .big) std.mem.nativeToBig(T, value) else std.mem.nativeToLittle(T, value));
        try self.writeAll(&bytes);
    }

    pub fn getWritten(self: *const MemWriter) []const u8 {
        return self.buffer[0..self.pos];
    }
};

/// Minimal in-memory reader that provides readAll/readInt/readByte.
pub const MemReader = struct {
    buffer: []const u8,
    pos: usize = 0,

    pub fn readAll(self: *MemReader, dest: []u8) !usize {
        const avail = self.buffer.len - self.pos;
        const n = @min(avail, dest.len);
        @memcpy(dest[0..n], self.buffer[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    pub fn readByte(self: *MemReader) !u8 {
        if (self.pos >= self.buffer.len) return error.EndOfStream;
        const byte = self.buffer[self.pos];
        self.pos += 1;
        return byte;
    }

    pub fn readInt(self: *MemReader, comptime T: type, comptime endian: std.builtin.Endian) !T {
        const size = @sizeOf(T);
        if (self.pos + size > self.buffer.len) return error.EndOfStream;
        const bytes = self.buffer[self.pos..][0..size];
        self.pos += size;
        const raw = std.mem.bytesToValue(T, bytes);
        return if (endian == .big) std.mem.bigToNative(T, raw) else std.mem.littleToNative(T, raw);
    }
};

/// Minimal dynamic writer backed by an allocator (replaces ArrayListAligned + writer).
pub const DynWriter = struct {
    items: []u8 = &.{},
    len: usize = 0,
    allocator: Allocator,

    pub fn writeAll(self: *DynWriter, data: []const u8) !void {
        try self.ensureCapacity(self.len + data.len);
        @memcpy(self.items[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn writeByte(self: *DynWriter, byte: u8) !void {
        try self.ensureCapacity(self.len + 1);
        self.items[self.len] = byte;
        self.len += 1;
    }

    pub fn writeInt(self: *DynWriter, comptime T: type, value: T, comptime endian: std.builtin.Endian) !void {
        const bytes = std.mem.toBytes(if (endian == .big) std.mem.nativeToBig(T, value) else std.mem.nativeToLittle(T, value));
        try self.writeAll(&bytes);
    }

    pub fn getWritten(self: *const DynWriter) []const u8 {
        return self.items[0..self.len];
    }

    pub fn deinit(self: *DynWriter) void {
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = .{ .allocator = self.allocator };
    }

    fn ensureCapacity(self: *DynWriter, needed: usize) !void {
        if (needed <= self.items.len) return;
        var new_cap = if (self.items.len == 0) @as(usize, 256) else self.items.len;
        while (new_cap < needed) new_cap *= 2;
        const new_buf = try self.allocator.alloc(u8, new_cap);
        if (self.len > 0) @memcpy(new_buf[0..self.len], self.items[0..self.len]);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = new_buf;
    }
};

// ── Time (replaces removed std.time.nanoTimestamp) ───────────────

pub fn nanoTimestamp() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

// ── Fork + exec helpers (replaces duplicated fork/pipe/exec) ─────

/// Fork and exec a command. Fire-and-forget — parent does NOT wait.
/// The child's stdin/stdout are inherited from the parent.
pub fn forkExec(argv: [*:null]const ?[*:0]const u8) void {
    const fork_rc = linux.fork();
    const pid: isize = @bitCast(fork_rc);
    if (pid < 0) return; // fork failed
    if (pid == 0) {
        // Child
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = posix.system.execve(argv[0].?, argv, @ptrCast(envp));
        linux.exit(1);
    }
    // Parent: fire-and-forget
}

/// Fork, pipe `data` into the child's stdin, exec command. Fire-and-forget.
pub fn forkExecPipeStdin(argv: [*:null]const ?[*:0]const u8, data: []const u8) void {
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return;
    const read_end = pipe_fds[0];
    const write_end = pipe_fds[1];

    const fork_rc = linux.fork();
    const pid: isize = @bitCast(fork_rc);
    if (pid < 0) {
        _ = posix.system.close(read_end);
        _ = posix.system.close(write_end);
        return;
    }

    if (pid == 0) {
        // Child: redirect stdin to read end of pipe
        _ = posix.system.close(write_end);
        _ = std.c.dup2(read_end, posix.STDIN_FILENO);
        _ = posix.system.close(read_end);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = posix.system.execve(argv[0].?, argv, @ptrCast(envp));
        linux.exit(1);
    }

    // Parent: write data to pipe, then close
    _ = posix.system.close(read_end);
    _ = std.c.write(write_end, data.ptr, data.len);
    _ = posix.system.close(write_end);
}

/// Fork, exec command, read child's stdout into `output_fd`. Blocks until child exits.
pub fn forkExecReadStdout(argv: [*:null]const ?[*:0]const u8, output_fd: posix.fd_t) void {
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return;
    const read_end = pipe_fds[0];
    const write_end = pipe_fds[1];

    const fork_rc = linux.fork();
    const pid: isize = @bitCast(fork_rc);
    if (pid < 0) {
        _ = posix.system.close(read_end);
        _ = posix.system.close(write_end);
        return;
    }

    if (pid == 0) {
        // Child: redirect stdout to write end of pipe
        _ = posix.system.close(read_end);
        _ = std.c.dup2(write_end, posix.STDOUT_FILENO);
        _ = posix.system.close(write_end);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = posix.system.execve(argv[0].?, argv, @ptrCast(envp));
        linux.exit(1);
    }

    // Parent: read from pipe and write to output_fd
    _ = posix.system.close(write_end);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = posix.read(read_end, &buf) catch break;
        if (n == 0) break;
        _ = std.c.write(output_fd, buf[0..n].ptr, n);
    }
    _ = posix.system.close(read_end);

    // Reap the child
    var status: c_int = 0;
    _ = std.c.waitpid(@intCast(pid), &status, 0);
}

// ── Environment (wraps std.c.getenv + sliceTo) ───────────────────

/// Look up an environment variable, returning a Zig slice or null.
/// Replaces the verbose `if (std.c.getenv("X")) |ptr| std.mem.sliceTo(ptr, 0)` pattern.
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

