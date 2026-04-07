const std = @import("std");
const builtin = @import("builtin");
const posix = if (builtin.os.tag != .windows) std.posix else undefined;
const compat = @import("../compat.zig");
const Pty = @import("../pty/pty.zig").Pty;

/// Raw terminal mode manager.
/// On POSIX: saves/restores termios, uses poll(2) for I/O bridging.
/// On Windows: saves/restores console mode, uses WaitForMultipleObjects.
const Terminal = @This();

// ── Platform-specific state ─────────────────────────────────────

const State = if (builtin.os.tag == .windows) struct {
    stdin_handle: HANDLE = undefined,
    stdout_handle: HANDLE = undefined,
    original_mode: u32 = 0,
} else struct {
    original_termios: ?posix.termios = null,
    host_fd: posix.fd_t,
};

state: State,

pub const TermSize = struct { rows: u16, cols: u16 };

pub fn init() Terminal {
    if (builtin.os.tag == .windows) {
        return .{ .state = .{
            .stdin_handle = GetStdHandle(STD_INPUT_HANDLE),
            .stdout_handle = GetStdHandle(STD_OUTPUT_HANDLE),
        } };
    } else {
        return .{ .state = .{ .host_fd = posix.STDIN_FILENO } };
    }
}

/// Switch the host terminal into raw mode.
pub fn enterRawMode(self: *Terminal) !void {
    if (builtin.os.tag == .windows) {
        return self.enterRawModeWin32();
    } else {
        return self.enterRawModePosix();
    }
}

/// Restore the host terminal to its original mode.
pub fn exitRawMode(self: *Terminal) void {
    if (builtin.os.tag == .windows) {
        self.exitRawModeWin32();
    } else {
        self.exitRawModePosix();
    }
}

/// Get the current terminal window size.
pub fn getSize(self: *const Terminal) !TermSize {
    if (builtin.os.tag == .windows) {
        return self.getSizeWin32();
    } else {
        return self.getSizePosix();
    }
}

/// Main I/O loop: bridge host terminal <-> child PTY.
pub fn runLoop(self: *Terminal, pty: *const Pty) !void {
    if (builtin.os.tag == .windows) {
        return self.runLoopWin32(pty);
    } else {
        return self.runLoopPosix(pty);
    }
}

/// Get the host stdin fd (POSIX) or -1 (Windows).
/// Used by SignalManager for SIGWINCH propagation.
pub fn hostFd(self: *const Terminal) i32 {
    if (builtin.os.tag == .windows) return -1;
    return self.state.host_fd;
}

pub fn deinit(self: *Terminal) void {
    self.exitRawMode();
}

// ── POSIX implementation (Linux + macOS) ────────────────────────

fn enterRawModePosix(self: *Terminal) !void {
    const current = try posix.tcgetattr(self.state.host_fd);
    self.state.original_termios = current;

    var raw = current;

    // Input: disable break, CR->NL, parity, strip, flow control
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;

    // Output: disable post-processing
    raw.oflag.OPOST = false;

    // Control: 8-bit chars
    raw.cflag.CSIZE = .CS8;

    // Local: disable echo, canonical mode, signals, extended
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;

    // Read returns immediately with whatever is available
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(self.state.host_fd, .FLUSH, raw);
}

fn exitRawModePosix(self: *Terminal) void {
    if (self.state.original_termios) |original| {
        posix.tcsetattr(self.state.host_fd, .FLUSH, original) catch {};
        self.state.original_termios = null;
    }
}

fn getSizePosix(self: *const Terminal) !TermSize {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(self.state.host_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return error.IoctlFailed;
    return .{ .rows = ws.row, .cols = ws.col };
}

fn runLoopPosix(self: *Terminal, pty: *const Pty) !void {
    const POLLIN: i16 = 0x001;
    const POLLERR: i16 = 0x008;
    const POLLHUP: i16 = 0x010;

    var fds = [2]posix.pollfd{
        .{ .fd = self.state.host_fd, .events = POLLIN, .revents = 0 },
        .{ .fd = pty.master, .events = POLLIN, .revents = 0 },
    };

    var buf: [4096]u8 = undefined;

    while (true) {
        const ready = try posix.poll(&fds, -1);
        if (ready == 0) continue;

        // Host terminal -> PTY (user typing)
        if (fds[0].revents & POLLIN != 0) {
            const n = posix.read(self.state.host_fd, &buf) catch break;
            if (n == 0) break;
            _ = pty.write(buf[0..n]) catch break;
        }
        if (fds[0].revents & (POLLHUP | POLLERR) != 0) break;

        // PTY -> Host terminal (program output)
        if (fds[1].revents & POLLIN != 0) {
            const n = pty.read(&buf) catch break;
            if (n == 0) break;
            _ = std.c.write(posix.STDOUT_FILENO, &buf, n);
        }
        if (fds[1].revents & (POLLHUP | POLLERR) != 0) break;
    }
}

// ── Windows implementation ──────────────────────────────────────

const HANDLE = *anyopaque;
const DWORD = u32;

// Console mode flags
const ENABLE_ECHO_INPUT: DWORD = 0x0004;
const ENABLE_LINE_INPUT: DWORD = 0x0002;
const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;

const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));

const COORD = extern struct { X: i16, Y: i16 };
const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: u16,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

const WAIT_OBJECT_0: DWORD = 0;
const WAIT_TIMEOUT_VAL: DWORD = 0x00000102;
const INFINITE: DWORD = 0xFFFFFFFF;

const INPUT_RECORD = extern struct {
    EventType: u16,
    Event: extern union { KeyEvent: KEY_EVENT_RECORD, padding: [16]u8 },
};
const KEY_EVENT: u16 = 0x0001;
const KEY_EVENT_RECORD = extern struct {
    bKeyDown: i32,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    uChar: extern union { UnicodeChar: u16, AsciiChar: u8 },
    dwControlKeyState: u32,
};

extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.c) HANDLE;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *DWORD) callconv(.c) c_int;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: DWORD) callconv(.c) c_int;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.c) c_int;
extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]INPUT_RECORD, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.c) c_int;
extern "kernel32" fn WaitForMultipleObjects(nCount: DWORD, lpHandles: [*]const HANDLE, bWaitAll: c_int, dwMilliseconds: DWORD) callconv(.c) DWORD;
extern "kernel32" fn WriteConsoleW(hConsoleOutput: HANDLE, lpBuffer: [*]const u8, nNumberOfCharsToWrite: DWORD, lpNumberOfCharsWritten: ?*DWORD, lpReserved: ?*anyopaque) callconv(.c) c_int;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?[*]u8, nBufferSize: DWORD, lpBytesRead: ?*DWORD, lpTotalBytesAvail: ?*DWORD, lpBytesLeftThisMessage: ?*DWORD) callconv(.c) c_int;

fn enterRawModeWin32(self: *Terminal) !void {
    if (GetConsoleMode(self.state.stdin_handle, &self.state.original_mode) == 0)
        return error.GetConsoleModeFailed;

    // Raw mode: disable echo and line input, enable VT input sequences
    const raw_mode = (self.state.original_mode & ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT)) | ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT;

    if (SetConsoleMode(self.state.stdin_handle, raw_mode) == 0)
        return error.SetConsoleModeFailed;

    // Enable VT processing on output so ESC sequences render correctly
    var out_mode: DWORD = 0;
    if (GetConsoleMode(self.state.stdout_handle, &out_mode) != 0) {
        _ = SetConsoleMode(self.state.stdout_handle, out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
}

fn exitRawModeWin32(self: *Terminal) void {
    if (self.state.original_mode != 0) {
        _ = SetConsoleMode(self.state.stdin_handle, self.state.original_mode);
        self.state.original_mode = 0;
    }
}

fn getSizeWin32(self: *const Terminal) !TermSize {
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (GetConsoleScreenBufferInfo(self.state.stdout_handle, &info) == 0)
        return error.GetConsoleScreenBufferInfoFailed;
    const cols: u16 = @intCast(info.srWindow.Right - info.srWindow.Left + 1);
    const rows: u16 = @intCast(info.srWindow.Bottom - info.srWindow.Top + 1);
    return .{ .rows = rows, .cols = cols };
}

/// Windows raw mode I/O loop.
/// Waits on both stdin (console input) and PTY stdout (child output)
/// using WaitForMultipleObjects — single syscall, no busy-wait.
fn runLoopWin32(self: *Terminal, pty: *const Pty) !void {
    var buf: [4096]u8 = undefined;
    const handles = [2]HANDLE{ self.state.stdin_handle, pty.stdout_read };

    while (true) {
        const rc = WaitForMultipleObjects(2, &handles, 0, INFINITE);

        if (rc == WAIT_OBJECT_0) {
            // Console input ready — read key events
            var input_records: [16]INPUT_RECORD = undefined;
            var events_read: DWORD = 0;
            if (ReadConsoleInputW(self.state.stdin_handle, &input_records, 16, &events_read) == 0) break;

            var i: usize = 0;
            while (i < events_read) : (i += 1) {
                if (input_records[i].EventType == KEY_EVENT) {
                    const key = input_records[i].Event.KeyEvent;
                    if (key.bKeyDown != 0) {
                        const ch = key.uChar.UnicodeChar;
                        if (ch != 0) {
                            // UTF-16 char -> UTF-8
                            const codepoint: u21 = @intCast(ch);
                            var utf8: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(codepoint, &utf8) catch continue;
                            _ = pty.write(utf8[0..len]) catch break;
                        }
                    }
                }
            }
        } else if (rc == WAIT_OBJECT_0 + 1) {
            // PTY output ready — read and write to console
            const n = pty.read(&buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => break,
            };
            if (n == 0) break;
            _ = WriteConsoleW(self.state.stdout_handle, &buf, @intCast(n), null, null);
        } else {
            // WAIT_TIMEOUT or WAIT_FAILED
            break;
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────

test "Terminal: init returns valid state" {
    const t = Terminal.init();
    if (builtin.os.tag == .windows) {
        _ = t.state.stdin_handle;
    } else {
        try std.testing.expectEqual(@as(posix.fd_t, 0), t.state.host_fd);
    }
}

test "Terminal: TermSize fields" {
    const size = TermSize{ .rows = 24, .cols = 80 };
    try std.testing.expectEqual(@as(u16, 24), size.rows);
    try std.testing.expectEqual(@as(u16, 80), size.cols);
}

test "Terminal: deinit is safe on fresh init" {
    var t = Terminal.init();
    t.deinit(); // Should not crash
}
