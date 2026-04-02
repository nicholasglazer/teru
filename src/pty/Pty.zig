const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const compat = @import("../compat.zig");

const Pty = @This();

master: posix.fd_t,
slave: posix.fd_t,
child_pid: ?posix.pid_t,

pub const SpawnOptions = struct {
    shell: ?[]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    cwd: ?[]const u8 = null,
    env: ?[*:null]const ?[*:0]const u8 = null,
};

pub fn spawn(opts: SpawnOptions) !Pty {
    const shell = opts.shell orelse getDefaultShell();

    // Open pseudoterminal master
    const master = try posix.openatZ(posix.AT.FDCWD, "/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
    errdefer _ = posix.system.close(master);

    // Grant and unlock slave
    if (grantpt(master) != 0) return error.GrantPtFailed;
    if (unlockpt(master) != 0) return error.UnlockPtFailed;

    // Get slave path
    const slave_path = ptsname(master) orelse return error.PtsnameFailed;

    // Set initial window size
    const ws = posix.winsize{
        .row = opts.rows,
        .col = opts.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    _ = posix.system.ioctl(master, posix.T.IOCSWINSZ, @intFromPtr(&ws));

    // Fork child process for the shell
    const fork_rc = linux.fork();
    const fork_pid: isize = @bitCast(fork_rc);
    if (fork_pid < 0) return error.ForkFailed;

    if (fork_pid == 0) {
        // ── Child process ────────────────────────────────────────
        _ = posix.system.close(master);

        // New session
        _ = posix.system.setsid();

        // Open slave as controlling terminal
        const slave = posix.openatZ(posix.AT.FDCWD, slave_path, .{ .ACCMODE = .RDWR }, 0) catch {
            linux.exit(1);
        };

        // Set controlling terminal
        _ = posix.system.ioctl(slave, posix.T.IOCSCTTY, @as(usize, 0));

        // Redirect stdin/stdout/stderr to slave PTY
        _ = std.c.dup2(slave, posix.STDIN_FILENO);
        _ = std.c.dup2(slave, posix.STDOUT_FILENO);
        _ = std.c.dup2(slave, posix.STDERR_FILENO);
        if (slave > posix.STDERR_FILENO) _ = posix.system.close(slave);

        // Set window size on the slave side (via stdin which now points to the PTY)
        _ = posix.system.ioctl(posix.STDIN_FILENO, posix.T.IOCSWINSZ, @intFromPtr(&ws));

        // Note: Do NOT disable ECHO here. The shell (bash/fish/zsh) sets
        // its own termios on startup including ECHO. Disabling it before
        // execve races with the shell's init and can leave ECHO permanently off.

        // Set environment
        setChildEnv(opts.cols, opts.rows);

        // Change directory if specified
        if (opts.cwd) |cwd| {
            var cwd_buf: [std.fs.max_path_bytes:0]u8 = undefined;
            if (cwd.len < cwd_buf.len) {
                @memcpy(cwd_buf[0..cwd.len], cwd);
                cwd_buf[cwd.len] = 0;
                _ = posix.system.chdir(&cwd_buf);
            }
        }

        // Exec shell (copy to null-terminated buffer)
        var shell_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        @memcpy(shell_buf[0..shell.len], shell);
        shell_buf[shell.len] = 0;
        const shell_z: [*:0]const u8 = &shell_buf;
        const argv = [_:null]?[*:0]const u8{ shell_z, null };
        const env = opts.env orelse std.c.environ;
        _ = posix.system.execve(shell_z, &argv, @ptrCast(env));
        linux.exit(1);
    }

    // ── Parent process ───────────────────────────────────────────
    // Note: ECHO is disabled on the child (slave) side before execve,
    // which is sufficient for the DA1/DSR exchange. Do NOT disable ECHO
    // from the parent (master) side — it races with the shell's termios
    // init and can leave ECHO permanently off.

    return Pty{
        .master = master,
        .slave = 0, // Parent doesn't need the slave fd
        .child_pid = @intCast(fork_pid),
    };
}

pub fn read(self: *const Pty, buf: []u8) !usize {
    return posix.read(self.master, buf);
}

pub fn write(self: *const Pty, data: []const u8) !usize {
    const rc = std.c.write(self.master, data.ptr, data.len);
    if (rc < 0) return error.WriteFailed;
    return @intCast(rc);
}

pub fn resize(self: *const Pty, rows: u16, cols: u16) void {
    const ws = posix.winsize{
        .row = rows,
        .col = cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    _ = posix.system.ioctl(self.master, posix.T.IOCSWINSZ, @intFromPtr(&ws));
}

pub fn waitForExit(self: *const Pty) !u32 {
    if (self.child_pid) |pid| {
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        return @bitCast(status);
    }
    return 0;
}

pub fn deinit(self: *Pty) void {
    // Signal child to terminate
    if (self.child_pid) |pid| {
        posix.kill(pid, posix.SIG.HUP) catch {};
    }
    _ = posix.system.close(self.master);
    self.master = -1;
    self.child_pid = null;
}

pub fn isAlive(self: *const Pty) bool {
    if (self.child_pid) |pid| {
        var status: c_int = 0;
        const WNOHANG = 1; // sys/wait.h
        const rc = std.c.waitpid(pid, &status, WNOHANG);
        return rc == 0; // 0 means still running
    }
    return false;
}

// ── Private helpers ──────────────────────────────────────────────

fn getDefaultShell() []const u8 {
    return compat.getenv("SHELL") orelse "/bin/sh";
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setChildEnv(cols: u16, rows: u16) void {
    _ = setenv("TERM", "xterm-256color", 1);
    _ = setenv("COLORTERM", "truecolor", 1);
    _ = setenv("TERM_PROGRAM", "teru", 1);
    _ = setenv("TERM_PROGRAM_VERSION", "0.1.4", 1);

    var cols_buf: [8:0]u8 = [_:0]u8{0} ** 8;
    var rows_buf: [8:0]u8 = [_:0]u8{0} ** 8;
    _ = std.fmt.bufPrint(&cols_buf, "{d}", .{cols}) catch {};
    _ = std.fmt.bufPrint(&rows_buf, "{d}", .{rows}) catch {};
    _ = setenv("COLUMNS", &cols_buf, 1);
    _ = setenv("LINES", &rows_buf, 1);
}

// ── C interop for PTY functions ──────────────────────────────────

extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
