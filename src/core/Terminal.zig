const std = @import("std");
const posix = std.posix;
const Pty = @import("../pty/Pty.zig");

/// Raw terminal mode manager.
/// Saves and restores the host terminal's termios settings,
/// enabling pass-through of all input to the child PTY.
const Terminal = @This();

original_termios: ?posix.termios = null,
host_fd: posix.fd_t,

pub const TermSize = struct { rows: u16, cols: u16 };

pub fn init() Terminal {
    return .{ .host_fd = posix.STDIN_FILENO };
}

/// Switch the host terminal into raw mode.
pub fn enterRawMode(self: *Terminal) !void {
    const current = try posix.tcgetattr(self.host_fd);
    self.original_termios = current;

    var raw = current;

    // Input: disable break, CR→NL, parity, strip, flow control
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

    try posix.tcsetattr(self.host_fd, .FLUSH, raw);
}

/// Restore the host terminal to its original mode.
pub fn exitRawMode(self: *Terminal) void {
    if (self.original_termios) |original| {
        posix.tcsetattr(self.host_fd, .FLUSH, original) catch {};
        self.original_termios = null;
    }
}

/// Get the current terminal window size.
pub fn getSize(self: *const Terminal) !TermSize {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(self.host_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return error.IoctlFailed;
    return .{ .rows = ws.row, .cols = ws.col };
}

/// Main I/O loop: bridge host terminal ↔ child PTY.
/// Uses poll(2) for efficient multiplexing without threads.
pub fn runLoop(self: *Terminal, pty: *const Pty) !void {
    const POLLIN: i16 = 0x001;
    const POLLERR: i16 = 0x008;
    const POLLHUP: i16 = 0x010;

    var fds = [2]posix.pollfd{
        .{ .fd = self.host_fd, .events = POLLIN, .revents = 0 },
        .{ .fd = pty.master, .events = POLLIN, .revents = 0 },
    };

    var buf: [4096]u8 = undefined;

    while (true) {
        const ready = try posix.poll(&fds, -1);
        if (ready == 0) continue;

        // Host terminal → PTY (user typing)
        if (fds[0].revents & POLLIN != 0) {
            const n = posix.read(self.host_fd, &buf) catch break;
            if (n == 0) break;
            _ = pty.write(buf[0..n]) catch break;
        }
        if (fds[0].revents & (POLLHUP | POLLERR) != 0) break;

        // PTY → Host terminal (program output)
        if (fds[1].revents & POLLIN != 0) {
            const n = pty.read(&buf) catch break;
            if (n == 0) break;
            _ = std.c.write(posix.STDOUT_FILENO, &buf, n);
        }
        if (fds[1].revents & (POLLHUP | POLLERR) != 0) break;
    }
}

pub fn deinit(self: *Terminal) void {
    self.exitRawMode();
}
