const std = @import("std");
const builtin = @import("builtin");

const WinPty = @This();

/// ConPTY pseudo-console handle.
hpc: HPCON,
/// Process handle for the spawned child.
process_handle: HANDLE,
/// Parent writes here; data flows to child stdin.
stdin_write: HANDLE,
/// Parent reads here; child stdout/stderr data arrives.
stdout_read: HANDLE,

// Re-export SpawnOptions so callers see the same interface as Pty.zig.
pub const SpawnOptions = struct {
    shell: ?[]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    cwd: ?[]const u8 = null,
    env: ?[*:null]const ?[*:0]const u8 = null,
    term: ?[]const u8 = null,
};

// ── Public API (mirrors Pty.zig) ─────────────────────────────────

pub fn spawn(opts: SpawnOptions) !WinPty {
    // ── 1. Create pipe pairs ─────────────────────────────────────
    // stdin pipe: parent writes to stdin_write, child reads from stdin_read
    var stdin_read: HANDLE = undefined;
    var stdin_write: HANDLE = undefined;
    if (CreatePipe(&stdin_read, &stdin_write, null, 0) == 0)
        return error.PipeCreationFailed;
    errdefer {
        _ = CloseHandle(stdin_read);
        _ = CloseHandle(stdin_write);
    }

    // stdout pipe: child writes to stdout_write, parent reads from stdout_read
    var stdout_read: HANDLE = undefined;
    var stdout_write: HANDLE = undefined;
    if (CreatePipe(&stdout_read, &stdout_write, null, 0) == 0)
        return error.PipeCreationFailed;
    errdefer {
        _ = CloseHandle(stdout_read);
        _ = CloseHandle(stdout_write);
    }

    // ── 2. Create pseudo console ─────────────────────────────────
    const size = makeCoord(opts.cols, opts.rows);
    var hpc: HPCON = undefined;
    const hr = CreatePseudoConsole(size, stdin_read, stdout_write, 0, &hpc);
    if (hr < 0) return error.CreatePseudoConsoleFailed;
    errdefer ClosePseudoConsole(hpc);

    // The ConPTY now owns the child-side pipe endpoints.  Close them
    // in the parent so only ConPTY holds them; when the console closes
    // the pipes will properly break.
    _ = CloseHandle(stdin_read);
    _ = CloseHandle(stdout_write);

    // ── 3. Set up STARTUPINFOEX with ConPTY attribute ────────────
    var attr_size: usize = 0;
    // First call: query required size.
    _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    if (attr_size == 0) return error.AttributeListSizeFailed;

    var attr_buf: [1024]u8 align(@alignOf(usize)) = undefined;
    if (attr_size > attr_buf.len) return error.AttributeListTooLarge;
    const attr_list: LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(&attr_buf);

    if (InitializeProcThreadAttributeList(attr_list, 1, 0, &attr_size) == 0)
        return error.AttributeListInitFailed;

    // PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
    if (UpdateProcThreadAttribute(
        attr_list,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        hpc,
        @sizeOf(HPCON),
        null,
        null,
    ) == 0) return error.UpdateAttributeFailed;

    // ── 4. Build command line ────────────────────────────────────
    var cmd_buf: [MAX_CMD_LEN]u16 = undefined;
    const cmd_line = try buildCommandLine(&cmd_buf, opts.shell);

    // Build working-directory wide string (optional).
    var cwd_buf: [MAX_PATH]u16 = undefined;
    const cwd_wide: ?[*:0]const u16 = if (opts.cwd) |cwd|
        utf8ToWide(&cwd_buf, cwd) catch null
    else
        null;

    // ── 5. CreateProcessW ────────────────────────────────────────
    var si: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
    si.lpAttributeList = attr_list;

    var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);

    const create_flags: u32 = EXTENDED_STARTUPINFO_PRESENT;
    if (CreateProcessW(
        null,
        cmd_line,
        null,
        null,
        0, // bInheritHandles = FALSE
        create_flags,
        null,
        cwd_wide,
        @ptrCast(&si),
        &pi,
    ) == 0) return error.CreateProcessFailed;

    // We only need the process handle; close the thread handle.
    _ = CloseHandle(pi.hThread);

    return WinPty{
        .hpc = hpc,
        .process_handle = pi.hProcess,
        .stdin_write = stdin_write,
        .stdout_read = stdout_read,
    };
}

pub fn read(self: *const WinPty, buf: []u8) !usize {
    var bytes_read: u32 = 0;
    if (ReadFile(self.stdout_read, buf.ptr, @intCast(buf.len), &bytes_read, null) == 0) {
        return error.ReadFailed;
    }
    return @intCast(bytes_read);
}

pub fn write(self: *const WinPty, data: []const u8) !usize {
    var bytes_written: u32 = 0;
    if (WriteFile(self.stdin_write, data.ptr, @intCast(data.len), &bytes_written, null) == 0) {
        return error.WriteFailed;
    }
    return @intCast(bytes_written);
}

pub fn resize(self: *const WinPty, rows: u16, cols: u16) void {
    _ = ResizePseudoConsole(self.hpc, makeCoord(cols, rows));
}

pub fn waitForExit(self: *const WinPty) !u32 {
    _ = WaitForSingleObject(self.process_handle, INFINITE);
    var exit_code: u32 = 0;
    if (GetExitCodeProcess(self.process_handle, &exit_code) == 0)
        return error.GetExitCodeFailed;
    return exit_code;
}

pub fn deinit(self: *WinPty) void {
    ClosePseudoConsole(self.hpc);
    _ = CloseHandle(self.process_handle);
    _ = CloseHandle(self.stdin_write);
    _ = CloseHandle(self.stdout_read);
    self.hpc = undefined;
    self.process_handle = undefined;
    self.stdin_write = undefined;
    self.stdout_read = undefined;
}

pub fn isAlive(self: *const WinPty) bool {
    const rc = WaitForSingleObject(self.process_handle, 0);
    return rc == WAIT_TIMEOUT;
}

// ── Pure helpers (testable on all platforms) ──────────────────────

pub fn makeCoord(cols: u16, rows: u16) COORD {
    return .{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
}

/// Resolve the default Windows shell: %COMSPEC% or fallback to
/// C:\Windows\System32\cmd.exe.
pub fn getDefaultShell() []const u8 {
    const comspec = std.c.getenv("COMSPEC");
    if (comspec) |ptr| {
        return std.mem.sliceTo(ptr, 0);
    }
    return "C:\\Windows\\System32\\cmd.exe";
}

/// Encode a UTF-8 string into a null-terminated UTF-16LE buffer for
/// Win32 wide-string APIs.  Returns the null-terminated pointer or
/// an error if the buffer is too small.
pub fn utf8ToWide(buf: []u16, utf8: []const u8) !?[*:0]const u16 {
    var i: usize = 0;
    var src: usize = 0;
    while (src < utf8.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(utf8[src]) catch return error.InvalidUtf8;
        if (src + seq_len > utf8.len) return error.InvalidUtf8;
        const cp = std.unicode.utf8Decode(utf8[src..][0..seq_len]) catch return error.InvalidUtf8;
        src += seq_len;
        if (cp <= 0xFFFF) {
            if (i >= buf.len - 1) return error.BufferTooSmall;
            buf[i] = @intCast(cp);
            i += 1;
        } else {
            // Surrogate pair for codepoints above the BMP.
            if (i + 1 >= buf.len - 1) return error.BufferTooSmall;
            const adj = cp - 0x10000;
            buf[i] = @intCast(0xD800 + (adj >> 10));
            buf[i + 1] = @intCast(0xDC00 + (adj & 0x3FF));
            i += 2;
        }
    }
    if (i >= buf.len) return error.BufferTooSmall;
    buf[i] = 0;
    return @ptrCast(buf[0..i :0].ptr);
}

/// Build a null-terminated wide command line from the shell path.
fn buildCommandLine(buf: *[MAX_CMD_LEN]u16, shell_opt: ?[]const u8) !?[*:0]u16 {
    const shell = shell_opt orelse getDefaultShell();
    var i: usize = 0;
    for (shell) |byte| {
        if (i >= MAX_CMD_LEN - 1) return error.CommandLineTooLong;
        buf[i] = @intCast(byte);
        i += 1;
    }
    if (i >= MAX_CMD_LEN) return error.CommandLineTooLong;
    buf[i] = 0;
    return @ptrCast(buf[0..i :0].ptr);
}

// ── Win32 types ──────────────────────────────────────────────────

pub const HANDLE = *anyopaque;
pub const HPCON = *anyopaque;
const LPPROC_THREAD_ATTRIBUTE_LIST = *anyopaque;

pub const COORD = extern struct {
    X: i16,
    Y: i16,
};

const STARTUPINFOW = extern struct {
    cb: u32 = 0,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*anyopaque = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW = .{},
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE = undefined,
    hThread: HANDLE = undefined,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};

// ── Win32 constants ──────────────────────────────────────────────

const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x00080000;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const INFINITE: u32 = 0xFFFFFFFF;
const WAIT_TIMEOUT: u32 = 0x00000102;
const MAX_CMD_LEN: usize = 32768;
const MAX_PATH: usize = 260;

// ── Win32 extern declarations ────────────────────────────────────

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*anyopaque,
    nSize: u32,
) callconv(.c) c_int;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: c_int,
    dwCreationFlags: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *anyopaque,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.c) c_int;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) c_int;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.c) c_int;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.c) c_int;

extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: u32,
) callconv(.c) u32;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: HANDLE,
    lpExitCode: *u32,
) callconv(.c) c_int;

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: u32,
    phPC: *HPCON,
) callconv(.c) i32;

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.c) i32;

extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.c) void;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?LPPROC_THREAD_ATTRIBUTE_LIST,
    dwAttributeCount: u32,
    dwFlags: u32,
    lpSize: *usize,
) callconv(.c) c_int;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
    dwFlags: u32,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.c) c_int;

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
) callconv(.c) void;

// ── Tests (pure logic only — no Win32 calls) ─────────────────────

test "COORD construction" {
    const c = makeCoord(80, 24);
    try std.testing.expectEqual(@as(i16, 80), c.X);
    try std.testing.expectEqual(@as(i16, 24), c.Y);
}

test "COORD i16 boundary" {
    // Win32 COORD uses i16, so the practical maximum per axis is 32767.
    // Real terminals never approach this — typical max is ~500 cols.
    const max_safe: u16 = @intCast(std.math.maxInt(i16));
    const c = makeCoord(max_safe, max_safe);
    try std.testing.expectEqual(@as(i16, 32767), c.X);
    try std.testing.expectEqual(@as(i16, 32767), c.Y);
}

test "COORD zero" {
    const c = makeCoord(0, 0);
    try std.testing.expectEqual(@as(i16, 0), c.X);
    try std.testing.expectEqual(@as(i16, 0), c.Y);
}

test "COORD typical terminal sizes" {
    const c1 = makeCoord(80, 24);
    try std.testing.expectEqual(@as(i16, 80), c1.X);
    try std.testing.expectEqual(@as(i16, 24), c1.Y);

    const c2 = makeCoord(200, 50);
    try std.testing.expectEqual(@as(i16, 200), c2.X);
    try std.testing.expectEqual(@as(i16, 50), c2.Y);

    const c3 = makeCoord(320, 100);
    try std.testing.expectEqual(@as(i16, 320), c3.X);
    try std.testing.expectEqual(@as(i16, 100), c3.Y);
}

test "default shell fallback" {
    // When COMSPEC is not set, we fall back to cmd.exe path.
    // We cannot unset env in a test reliably, but we can verify
    // the function returns something non-empty.
    const shell = getDefaultShell();
    try std.testing.expect(shell.len > 0);
}

test "utf8ToWide: ASCII" {
    var buf: [64]u16 = undefined;
    const result = try utf8ToWide(&buf, "hello");
    try std.testing.expect(result != null);
    const ptr = result.?;
    try std.testing.expectEqual(@as(u16, 'h'), ptr[0]);
    try std.testing.expectEqual(@as(u16, 'e'), ptr[1]);
    try std.testing.expectEqual(@as(u16, 'l'), ptr[2]);
    try std.testing.expectEqual(@as(u16, 'l'), ptr[3]);
    try std.testing.expectEqual(@as(u16, 'o'), ptr[4]);
    try std.testing.expectEqual(@as(u16, 0), ptr[5]);
}

test "utf8ToWide: empty string" {
    var buf: [4]u16 = undefined;
    const result = try utf8ToWide(&buf, "");
    try std.testing.expect(result != null);
    const ptr = result.?;
    try std.testing.expectEqual(@as(u16, 0), ptr[0]);
}

test "utf8ToWide: Windows path" {
    var buf: [MAX_PATH]u16 = undefined;
    const result = try utf8ToWide(&buf, "C:\\Windows\\System32\\cmd.exe");
    try std.testing.expect(result != null);
    const ptr = result.?;
    try std.testing.expectEqual(@as(u16, 'C'), ptr[0]);
    try std.testing.expectEqual(@as(u16, ':'), ptr[1]);
    try std.testing.expectEqual(@as(u16, '\\'), ptr[2]);
}

test "utf8ToWide: buffer too small" {
    var buf: [3]u16 = undefined;
    const result = utf8ToWide(&buf, "hello");
    try std.testing.expectError(error.BufferTooSmall, result);
}

test "utf8ToWide: multibyte UTF-8" {
    // U+00E9 (e-acute) = 0xC3 0xA9 in UTF-8, 0x00E9 in UTF-16
    var buf: [16]u16 = undefined;
    const result = try utf8ToWide(&buf, "caf\xC3\xA9");
    try std.testing.expect(result != null);
    const ptr = result.?;
    try std.testing.expectEqual(@as(u16, 'c'), ptr[0]);
    try std.testing.expectEqual(@as(u16, 'a'), ptr[1]);
    try std.testing.expectEqual(@as(u16, 'f'), ptr[2]);
    try std.testing.expectEqual(@as(u16, 0x00E9), ptr[3]);
    try std.testing.expectEqual(@as(u16, 0), ptr[4]);
}

test "buildCommandLine: explicit shell" {
    var buf: [MAX_CMD_LEN]u16 = undefined;
    const result = try buildCommandLine(&buf, "powershell.exe");
    try std.testing.expect(result != null);
    const ptr = result.?;
    try std.testing.expectEqual(@as(u16, 'p'), ptr[0]);
    try std.testing.expectEqual(@as(u16, 'o'), ptr[1]);
    try std.testing.expectEqual(@as(u16, 'w'), ptr[2]);
}

test "buildCommandLine: null uses default" {
    var buf: [MAX_CMD_LEN]u16 = undefined;
    const result = try buildCommandLine(&buf, null);
    try std.testing.expect(result != null);
    // Should be non-empty (either COMSPEC or cmd.exe path)
}

test "SpawnOptions defaults" {
    const opts = SpawnOptions{};
    try std.testing.expectEqual(@as(?[]const u8, null), opts.shell);
    try std.testing.expectEqual(@as(u16, 24), opts.rows);
    try std.testing.expectEqual(@as(u16, 80), opts.cols);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.cwd);
    try std.testing.expect(opts.env == null);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.term);
}

test "Win32 constants" {
    try std.testing.expectEqual(@as(u32, 0x00080000), EXTENDED_STARTUPINFO_PRESENT);
    try std.testing.expectEqual(@as(usize, 0x00020016), PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), INFINITE);
    try std.testing.expectEqual(@as(u32, 0x00000102), WAIT_TIMEOUT);
}

test "STARTUPINFOEXW size" {
    // STARTUPINFOEXW must be large enough to hold the base STARTUPINFOW
    // plus the attribute list pointer.
    try std.testing.expect(@sizeOf(STARTUPINFOEXW) >= @sizeOf(STARTUPINFOW));
}

test "PROCESS_INFORMATION layout" {
    const pi = std.mem.zeroes(PROCESS_INFORMATION);
    try std.testing.expectEqual(@as(u32, 0), pi.dwProcessId);
    try std.testing.expectEqual(@as(u32, 0), pi.dwThreadId);
}
