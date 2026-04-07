//! Cross-platform IPC transport for daemon, MCP, and hook sockets.
//!
//! POSIX (Linux + macOS): Unix domain sockets (AF_UNIX, SOCK_STREAM)
//! Windows: Named pipes (\\.\pipe\teru-*)
//!
//! Provides a unified interface so daemon.zig, McpServer.zig, etc.
//! don't need platform-specific code.

const std = @import("std");
const builtin = @import("builtin");
const posix = if (builtin.os.tag != .windows) std.posix else undefined;
const compat = @import("../compat.zig");

pub const IpcError = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
    ConnectFailed,
    PipeFailed,
    PathTooLong,
    Unsupported,
};

/// Cross-platform IPC handle. Wraps either a POSIX fd or a Windows HANDLE.
pub const IpcHandle = if (builtin.os.tag == .windows) WindowsHandle else PosixHandle;

const PosixHandle = struct {
    fd: i32,

    pub fn close(self: PosixHandle) void {
        _ = posix.system.close(self.fd);
    }

    pub fn read(self: PosixHandle, buf: []u8) !usize {
        return posix.read(self.fd, buf);
    }

    pub fn write(self: PosixHandle, data: []const u8) !usize {
        const rc = std.c.write(self.fd, data.ptr, data.len);
        if (rc < 0) return error.WriteFailed;
        return @intCast(rc);
    }
};

const WindowsHandle = struct {
    handle: HANDLE,

    pub fn close(self: WindowsHandle) void {
        _ = CloseHandle(self.handle);
    }

    pub fn read(self: WindowsHandle, buf: []u8) !usize {
        var bytes_read: u32 = 0;
        if (ReadFile(self.handle, buf.ptr, @intCast(buf.len), &bytes_read, null) == 0)
            return error.ReadFailed;
        return @intCast(bytes_read);
    }

    pub fn write(self: WindowsHandle, data: []const u8) !usize {
        var bytes_written: u32 = 0;
        if (WriteFile(self.handle, data.ptr, @intCast(data.len), &bytes_written, null) == 0)
            return error.WriteFailed;
        return @intCast(bytes_written);
    }
};

// ── Server: create a listening endpoint ─────────────────────────

/// Create a listening IPC endpoint at the given path.
/// POSIX: creates a Unix domain socket, binds, listens.
/// Windows: creates a named pipe at \\.\pipe\{name}.
pub fn listen(path: []const u8) IpcError!IpcHandle {
    if (builtin.os.tag == .windows) {
        return listenWin32(path);
    } else {
        return listenPosix(path);
    }
}

/// Accept a client connection (blocking or non-blocking depending on setup).
pub fn accept(server: IpcHandle) ?IpcHandle {
    if (builtin.os.tag == .windows) {
        return acceptWin32(server);
    } else {
        return acceptPosix(server);
    }
}

/// Connect to an existing IPC endpoint.
pub fn connect(path: []const u8) IpcError!IpcHandle {
    if (builtin.os.tag == .windows) {
        return connectWin32(path);
    } else {
        return connectPosix(path);
    }
}

/// Build a platform-appropriate IPC path for a teru service.
/// Examples:
///   POSIX: /run/user/1000/teru-session-myproject.sock
///   macOS: /tmp/teru-1000-session-myproject.sock
///   Windows: \\.\pipe\teru-session-myproject
pub fn buildPath(buf: *[256]u8, prefix: []const u8, name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        return std.fmt.bufPrint(buf, "\\\\.\\pipe\\teru-{s}-{s}", .{ prefix, name }) catch null;
    } else if (builtin.os.tag == .macos) {
        const uid = compat.getUid();
        return std.fmt.bufPrint(buf, "/tmp/teru-{d}-{s}-{s}.sock", .{ uid, prefix, name }) catch null;
    } else {
        const uid = compat.getUid();
        return std.fmt.bufPrint(buf, "/run/user/{d}/teru-{s}-{s}.sock", .{ uid, prefix, name }) catch null;
    }
}

// ── POSIX implementation ────────────────────────────────────────

fn listenPosix(path: []const u8) IpcError!IpcHandle {
    if (path.len >= 108) return IpcError.PathTooLong;

    // Remove stale socket
    var path_z: [109]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    _ = std.c.unlink(@ptrCast(&path_z));

    const sock = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (sock < 0) return IpcError.SocketFailed;
    errdefer _ = posix.system.close(sock);

    // Non-blocking
    const flags = std.c.fcntl(sock, posix.F.GETFL);
    if (flags >= 0) _ = std.c.fcntl(sock, posix.F.SETFL, flags | compat.O_NONBLOCK);

    // Bind
    var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);

    if (std.c.bind(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0)
        return IpcError.BindFailed;

    _ = std.c.chmod(@ptrCast(&path_z), 0o660);

    if (std.c.listen(sock, 5) != 0)
        return IpcError.ListenFailed;

    return .{ .fd = sock };
}

fn acceptPosix(server: IpcHandle) ?IpcHandle {
    const conn = std.c.accept(server.fd, null, null);
    if (conn < 0) return null;

    // Set non-blocking
    const flags = std.c.fcntl(conn, posix.F.GETFL);
    if (flags >= 0) _ = std.c.fcntl(conn, posix.F.SETFL, flags | compat.O_NONBLOCK);

    return .{ .fd = conn };
}

fn connectPosix(path: []const u8) IpcError!IpcHandle {
    if (path.len >= 108) return IpcError.PathTooLong;

    const sock = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (sock < 0) return IpcError.SocketFailed;
    errdefer _ = posix.system.close(sock);

    var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);

    if (std.c.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) != 0)
        return IpcError.ConnectFailed;

    return .{ .fd = sock };
}

// ── Windows implementation ──────────────────────────────────────

const HANDLE = *anyopaque;
const INVALID_HANDLE: usize = @as(usize, 0) -% 1;
const PIPE_ACCESS_DUPLEX: u32 = 0x00000003;
const PIPE_TYPE_BYTE: u32 = 0x00000000;
const PIPE_READMODE_BYTE: u32 = 0x00000000;
const PIPE_WAIT: u32 = 0x00000000;
const PIPE_NOWAIT: u32 = 0x00000001;
const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
const OPEN_EXISTING: u32 = 3;
const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;

extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const u16,
    dwOpenMode: u32,
    dwPipeMode: u32,
    nMaxInstances: u32,
    nOutBufferSize: u32,
    nInBufferSize: u32,
    nDefaultTimeOut: u32,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.c) HANDLE;

extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.c) c_int;
extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.c) c_int;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?HANDLE,
) callconv(.c) HANDLE;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) c_int;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.c) c_int;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.c) c_int;

fn listenWin32(path: []const u8) IpcError!IpcHandle {
    // Convert path to UTF-16 for Win32 API
    var wide_path: [256]u16 = undefined;
    var i: usize = 0;
    for (path) |byte| {
        if (i >= wide_path.len - 1) return IpcError.PathTooLong;
        wide_path[i] = byte;
        i += 1;
    }
    wide_path[i] = 0;

    const pipe = CreateNamedPipeW(
        @ptrCast(wide_path[0..i :0]),
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT,
        1, // max instances
        8192, // out buffer
        8192, // in buffer
        0, // default timeout
        null,
    );
    if (@intFromPtr(pipe) == INVALID_HANDLE) return IpcError.PipeFailed;

    return .{ .handle = pipe };
}

fn acceptWin32(server: IpcHandle) ?IpcHandle {
    // For non-blocking named pipe, ConnectNamedPipe returns immediately.
    // If a client is connected, it returns success or ERROR_PIPE_CONNECTED.
    const rc = ConnectNamedPipe(server.handle, null);
    if (rc != 0) return server; // Client connected
    // Check GetLastError for ERROR_PIPE_CONNECTED (535)
    // For now, return null if no client is waiting
    return null;
}

fn connectWin32(path: []const u8) IpcError!IpcHandle {
    var wide_path: [256]u16 = undefined;
    var i: usize = 0;
    for (path) |byte| {
        if (i >= wide_path.len - 1) return IpcError.PathTooLong;
        wide_path[i] = byte;
        i += 1;
    }
    wide_path[i] = 0;

    const handle = CreateFileW(
        @ptrCast(wide_path[0..i :0]),
        GENERIC_READ | GENERIC_WRITE,
        0, // no sharing
        null,
        OPEN_EXISTING,
        0,
        null,
    );
    if (@intFromPtr(handle) == INVALID_HANDLE) return IpcError.ConnectFailed;

    return .{ .handle = handle };
}

// ── Tests ───────────────────────────────────────────────────────

test "buildPath: Linux format" {
    if (builtin.os.tag == .windows) return;
    var buf: [256]u8 = undefined;
    const path = buildPath(&buf, "session", "myproject");
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.endsWith(u8, path.?, "teru-session-myproject.sock"));
}

test "buildPath: returns null for overflow" {
    var buf: [256]u8 = undefined;
    const long_name = "a" ** 250;
    const path = buildPath(&buf, "session", long_name);
    try std.testing.expect(path == null);
}

test "IpcHandle: PosixHandle size" {
    if (builtin.os.tag == .windows) return;
    try std.testing.expectEqual(@sizeOf(i32), @sizeOf(PosixHandle));
}
