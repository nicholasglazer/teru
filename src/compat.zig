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
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;

// Platform-specific imports
const linux = if (builtin.os.tag == .linux) std.os.linux else undefined;

/// ioctl request constants — macOS std.posix.T is incomplete.
/// Type is c_int to match libc ioctl(fd, request: c_int, ...) signature.
pub const TIOCSWINSZ: c_int = switch (builtin.os.tag) {
    .linux => @bitCast(@as(c_uint, posix.T.IOCSWINSZ)),
    .macos => @bitCast(@as(c_uint, 0x80087467)), // _IOW('t', 103, struct winsize)
    else => if (@hasDecl(posix.T, "IOCSWINSZ")) @bitCast(@as(c_uint, posix.T.IOCSWINSZ)) else @bitCast(@as(c_uint, 0x80087467)),
};
pub const TIOCSCTTY: c_int = switch (builtin.os.tag) {
    .linux => @bitCast(@as(c_uint, posix.T.IOCSCTTY)),
    .macos => @bitCast(@as(c_uint, 0x20007461)), // _IO('t', 97)
    else => if (@hasDecl(posix.T, "IOCSCTTY")) @bitCast(@as(c_uint, posix.T.IOCSCTTY)) else @bitCast(@as(c_uint, 0x20007461)),
};

// Win32 externs not in Zig 0.16's kernel32 bindings
const win32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.c) c_int;
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.c) c_int;
    extern "kernel32" fn GetCurrentProcessId() callconv(.c) u32;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.c) void;
} else undefined;

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

// ── Time (cross-platform, no Io required) ──────────────────────

/// Wall-clock timestamp in nanoseconds (for PrefixState, etc).
pub fn nanoTimestamp() i128 {
    return clockGettime(.REALTIME);
}

/// Monotonic timestamp in nanoseconds (for animations, debounce, etc).
/// Use this instead of std.os.linux.clock_gettime(.MONOTONIC, ...) directly.
pub fn monotonicNow() i128 {
    return clockGettime(.MONOTONIC);
}

fn clockGettime(clock: anytype) i128 {
    if (builtin.os.tag == .windows) {
        var freq: i64 = undefined;
        var counter: i64 = undefined;
        _ = win32.QueryPerformanceFrequency(&freq);
        _ = win32.QueryPerformanceCounter(&counter);
        const ns_per_count = @divFloor(@as(i128, 1_000_000_000), @as(i128, freq));
        return @as(i128, counter) * ns_per_count;
    } else {
        // POSIX: clock_gettime (Linux, macOS, FreeBSD)
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(clock, &ts);
        return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
    }
}

/// Portable nanosleep. On Windows uses Sleep(), on POSIX uses nanosleep.
pub fn sleepNs(ns: u64) void {
    if (builtin.os.tag == .windows) {
        const ms: u32 = @intCast(@max(1, ns / 1_000_000));
        win32.Sleep(ms);
    } else {
        const req = std.c.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        _ = std.c.nanosleep(&req, null);
    }
}

/// Portable getpid.
pub fn getPid() i32 {
    if (builtin.os.tag == .windows) {
        return @intCast(win32.GetCurrentProcessId());
    } else if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.getpid());
    } else {
        return std.c.getpid();
    }
}

/// Portable getuid (returns 0 on Windows).
pub fn getUid() u32 {
    if (builtin.os.tag == .windows) {
        return 0;
    } else if (builtin.os.tag == .linux) {
        return std.os.linux.getuid();
    } else {
        return std.c.getuid();
    }
}

// ── Fork + exec helpers (POSIX: Linux + macOS) ─────────────────

/// Portable fork. Returns pid (>0 parent, 0 child, <0 error).
pub fn posixFork() isize {
    if (builtin.os.tag == .linux) {
        return @bitCast(std.os.linux.fork());
    } else {
        // macOS, FreeBSD, etc.
        const rc = std.c.fork();
        return @intCast(rc);
    }
}

/// Portable _exit (no atexit handlers).
pub fn posixExit(status: u8) noreturn {
    if (builtin.os.tag == .linux) {
        std.os.linux.exit(status);
    } else {
        std.c._exit(status);
    }
}

/// Fork and exec a command. Fire-and-forget — parent does NOT wait.
/// The child's stdin/stdout are inherited from the parent.
pub fn forkExec(argv: [*:null]const ?[*:0]const u8) void {
    if (builtin.os.tag == .windows) return; // TODO: CreateProcessW
    const pid = posixFork();
    if (pid < 0) return;
    if (pid == 0) {
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = posix.system.execve(argv[0].?, argv, @ptrCast(envp));
        posixExit(1);
    }
}

/// Fork, pipe `data` into the child's stdin, exec command. Fire-and-forget.
pub fn forkExecPipeStdin(argv: [*:null]const ?[*:0]const u8, data: []const u8) void {
    if (builtin.os.tag == .windows) return; // TODO: CreateProcessW
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return;
    const read_end = pipe_fds[0];
    const write_end = pipe_fds[1];

    const pid = posixFork();
    if (pid < 0) {
        _ = posix.system.close(read_end);
        _ = posix.system.close(write_end);
        return;
    }

    if (pid == 0) {
        _ = posix.system.close(write_end);
        _ = std.c.dup2(read_end, posix.STDIN_FILENO);
        _ = posix.system.close(read_end);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = posix.system.execve(argv[0].?, argv, @ptrCast(envp));
        posixExit(1);
    }

    _ = posix.system.close(read_end);
    _ = std.c.write(write_end, data.ptr, data.len);
    _ = posix.system.close(write_end);
}

/// Fork, exec command, read child's stdout into `output_fd`. Blocks until child exits.
pub fn forkExecReadStdout(argv: [*:null]const ?[*:0]const u8, output_fd: posix.fd_t) void {
    if (builtin.os.tag == .windows) return; // TODO: CreateProcessW
    var pipe_fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return;
    const read_end = pipe_fds[0];
    const write_end = pipe_fds[1];

    const pid = posixFork();
    if (pid < 0) {
        _ = posix.system.close(read_end);
        _ = posix.system.close(write_end);
        return;
    }

    if (pid == 0) {
        _ = posix.system.close(read_end);
        _ = std.c.dup2(write_end, posix.STDOUT_FILENO);
        _ = posix.system.close(write_end);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = posix.system.execve(argv[0].?, argv, @ptrCast(envp));
        posixExit(1);
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

// ── POSIX constants (cross-platform) ─────────────────────────────

/// O_NONBLOCK differs between Linux (0x800) and macOS (0x0004).
pub const O_NONBLOCK: c_int = if (builtin.os.tag == .macos) 0x0004 else 0x800;

// ── Environment (wraps std.c.getenv + sliceTo) ───────────────────

/// Look up an environment variable, returning a Zig slice or null.
/// Replaces the verbose `if (std.c.getenv("X")) |ptr| std.mem.sliceTo(ptr, 0)` pattern.
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(ptr, 0);
}

// ── Directory helpers ───────────────────────────────────────────

/// Create a directory and all parent components (like mkdir -p).
/// Uses C mkdir, ignoring EEXIST. No Io required.
pub fn ensureDirC(path: []const u8) void {
    mkdirAllTo(path);
}

/// Ensure the parent directory of `path` exists (mkdir -p on dirname).
/// No-op if `path` has no slash or its parent is "/".
pub fn ensureParentDirC(path: []const u8) void {
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (last_slash == 0) return;
    mkdirAllTo(path[0..last_slash]);
}

/// Read /proc/<pid>/cmdline, replacing null separators with spaces.
/// Returns the bytes written into `buf`. Empty on non-Linux or on error.
///
/// /proc reads are handled synchronously by the kernel (no real block);
/// we use raw std.c.open/read here rather than std.Io since this path
/// is called from contexts that don't thread io (session serialize).
pub fn readProcCmdline(pid: c_int, buf: []u8) []const u8 {
    if (builtin.os.tag != .linux) return "";
    var proc_path: [64:0]u8 = undefined;
    const p = std.fmt.bufPrint(&proc_path, "/proc/{d}/cmdline", .{pid}) catch return "";
    proc_path[p.len] = 0;

    const fd = std.c.open(&proc_path, .{ .ACCMODE = .RDONLY }, @as(std.posix.mode_t, 0));
    if (fd < 0) return "";
    defer _ = std.posix.system.close(fd);

    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return "";
    var end: usize = @intCast(n);
    while (end > 0 and buf[end - 1] == 0) end -= 1;
    for (buf[0..end]) |*c| {
        if (c.* == 0) c.* = ' ';
    }
    return buf[0..end];
}

fn mkdirAllTo(path: []const u8) void {
    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_z.len) return;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            @memcpy(path_z[0..i], path[0..i]);
            path_z[i] = 0;
            _ = std.c.mkdir(@ptrCast(path_z[0..i :0]), 0o755);
        }
    }
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    _ = std.c.mkdir(@ptrCast(path_z[0..path.len :0]), 0o755);
}

