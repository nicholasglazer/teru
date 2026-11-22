const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");
const build_options = @import("build_options");

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
    term: ?[]const u8 = null,
    /// Pre-built argv for -e / -- exec (overrides shell when set).
    exec_argv: ?[*:null]const ?[*:0]const u8 = null,
};

/// Attach to an existing PTY master fd (e.g., inherited across exec for compositor restart).
/// The shell is already running on the other end — no fork, no spawn.
pub fn attach(master_fd: posix.fd_t, child_pid: ?posix.pid_t) Pty {
    return .{
        .master = master_fd,
        .slave = 0,
        .child_pid = child_pid,
    };
}

pub fn spawn(opts: SpawnOptions) !Pty {
    const shell = opts.shell orelse getDefaultShell();

    // Open pseudoterminal master (posix_openpt works on both Linux and macOS)
    const pt_flags: u32 = @bitCast(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true });
    const master = posix_openpt(@intCast(pt_flags));
    if (master < 0) return error.OpenPtFailed;
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
    _ = posix.system.ioctl(master, compat.TIOCSWINSZ, @intFromPtr(&ws));

    // macOS: everything the child needs is prepared here, before fork. An
    // AppKit process has other threads, and a child of a multi-threaded
    // process may only make async-signal-safe calls until it execs; setenv
    // allocates, and could deadlock on a lock another thread held.
    const mac = builtin.os.tag == .macos;
    var env_block: if (mac) EnvBlock else void = undefined;
    const mac_env: if (mac) [*:null]const ?[*:0]const u8 else void = if (mac)
        buildChildEnv(&env_block, opts.env orelse std.c.environ, opts.cols, opts.rows, opts.term, true)
    else {};
    // A login shell, as Terminal.app starts one: a GUI app launched from
    // the Finder or Dock inherits launchd's bare PATH, and only a login
    // shell runs /etc/zprofile (path_helper) and ~/.zprofile (Homebrew).
    var argv0_buf: [256:0]u8 = undefined;
    const login_argv0: ?[*:0]const u8 = if (mac) loginArgv0(&argv0_buf, shell) else null;

    // Fork child process for the shell
    const fork_pid = compat.posixFork();
    if (fork_pid < 0) return error.ForkFailed;

    if (fork_pid == 0) {
        // ── Child process ────────────────────────────────────────
        _ = posix.system.close(master);

        // New session
        _ = posix.system.setsid();

        // Restore SIGPIPE to default — the parent ignores it process-wide
        // (compat.ignoreSigpipe) and SIG_IGN is inherited across execve; without
        // this the shell + its pipelines mishandle broken pipes. See
        // compat.resetSigpipeToDefault.
        compat.resetSigpipeToDefault();

        // Open slave as controlling terminal
        const slave = posix.openatZ(posix.AT.FDCWD, slave_path, .{ .ACCMODE = .RDWR }, 0) catch {
            compat.posixExit(1);
        };

        // Set controlling terminal
        _ = posix.system.ioctl(slave, compat.TIOCSCTTY, @as(usize, 0));

        // Redirect stdin/stdout/stderr to slave PTY
        _ = std.c.dup2(slave, posix.STDIN_FILENO);
        _ = std.c.dup2(slave, posix.STDOUT_FILENO);
        _ = std.c.dup2(slave, posix.STDERR_FILENO);
        if (slave > posix.STDERR_FILENO) _ = posix.system.close(slave);

        // Set window size on the slave side (via stdin which now points to the PTY)
        _ = posix.system.ioctl(posix.STDIN_FILENO, compat.TIOCSWINSZ, @intFromPtr(&ws));

        // Note: Do NOT disable ECHO here. The shell (bash/fish/zsh) sets
        // its own termios on startup including ECHO. Disabling it before
        // execve races with the shell's init and can leave ECHO permanently off.

        // Set environment
        if (mac) {
            // Built before fork; execvp below reads `environ` for PATH.
            std.c.environ = @ptrCast(@constCast(mac_env));
        } else {
            setChildEnv(opts.cols, opts.rows, opts.term);
        }

        // Change directory if specified
        if (opts.cwd) |cwd| {
            var cwd_buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
            if (cwd.len < cwd_buf.len) {
                @memcpy(cwd_buf[0..cwd.len], cwd);
                cwd_buf[cwd.len] = 0;
                _ = posix.system.chdir(&cwd_buf);
            }
        }

        // Exec: use exec_argv (-e command) if provided, otherwise shell
        if (opts.exec_argv) |exec_argv| {
            // execvp for PATH lookup (teru -e vim, teru -e htop, etc.)
            _ = execvp(exec_argv[0].?, exec_argv);
        } else {
            const env = if (mac) mac_env else opts.env orelse std.c.environ;
            var shell_buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
            if (shell.len >= shell_buf.len) compat.posixExit(1);
            @memcpy(shell_buf[0..shell.len], shell);
            shell_buf[shell.len] = 0;
            const shell_z: [*:0]const u8 = &shell_buf;
            const argv = [_:null]?[*:0]const u8{ login_argv0 orelse shell_z, null };
            _ = posix.system.execve(shell_z, &argv, @ptrCast(env));
        }
        compat.posixExit(1);
    }

    // ── Parent process ───────────────────────────────────────────
    // Note: ECHO is intentionally NOT disabled on the child side before
    // execve (see child comment above). DA1/DSR response echo is handled
    // by VtParser's CSI dispatch — it only replies to genuine queries
    // (param_count==0), not to echoed response bytes.

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
    _ = posix.system.ioctl(self.master, compat.TIOCSWINSZ, @intFromPtr(&ws));
}

/// Nudge the foreground process group with SIGWINCH so the app repaints.
/// Used after a hot-restore: the PTY is re-attached but the grid was
/// cleared, and an idle shell (which only paints on input or resize) would
/// otherwise show a blank pane. The kernel raises SIGWINCH on a TIOCSWINSZ
/// only when the size actually changes, so a same-size restore can't rely on
/// resize() — we signal explicitly. Target the terminal's current foreground
/// pgrp (so a running TUI gets it too), falling back to the child pid.
pub fn refresh(self: *const Pty) void {
    if (self.master < 0) return;
    var pgrp: posix.pid_t = 0;
    _ = posix.system.ioctl(self.master, compat.TIOCGPGRP, @intFromPtr(&pgrp));
    if (pgrp > 0) {
        posix.kill(-pgrp, posix.SIG.WINCH) catch {};
    } else if (self.child_pid) |pid| {
        posix.kill(pid, posix.SIG.WINCH) catch {};
    }
}

/// The PTY's current foreground process-group leader pid — the program the
/// user is actually interacting with (a TUI/agent like `claude`, `vim`,
/// `htop`), or the login shell when the pane is idle. Falls back to the child
/// shell pid when the tty reports no foreground pgrp (master closed, etc).
///
/// Session save uses this instead of `child_pid` so a restored pane
/// re-launches the command that was running, not just the bare shell.
pub fn foregroundPid(self: *const Pty) ?posix.pid_t {
    if (self.master >= 0) {
        var pgrp: posix.pid_t = 0;
        _ = posix.system.ioctl(self.master, compat.TIOCGPGRP, @intFromPtr(&pgrp));
        if (pgrp > 0) return pgrp;
    }
    return self.child_pid;
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
        const rc = std.c.waitpid(pid, &status, posix.W.NOHANG);
        return rc == 0; // 0 means still running
    }
    return false;
}

// ── Private helpers ──────────────────────────────────────────────

fn getDefaultShell() []const u8 {
    if (compat.getenv("SHELL")) |sh| return sh;
    if (builtin.os.tag == .macos) {
        // launchd may not set SHELL for an app started from the Finder.
        if (std.c.getpwuid(std.c.getuid())) |pw| {
            if (pw.shell) |sh| {
                const s = std.mem.sliceTo(sh, 0);
                if (s.len > 0) return s;
            }
        }
        return "/bin/zsh";
    }
    return "/bin/sh";
}

/// "-zsh" for "/bin/zsh": the argv[0] that tells a shell it is a login
/// shell. Null if it does not fit.
fn loginArgv0(buf: *[256:0]u8, shell: []const u8) ?[*:0]const u8 {
    const base = std.fs.path.basename(shell);
    if (base.len == 0 or base.len + 1 >= buf.len) return null;
    buf[0] = '-';
    @memcpy(buf[1..][0..base.len], base);
    buf[base.len + 1] = 0;
    return buf;
}

/// The child's environment, built in the parent: the inherited variables
/// plus teru's own, with no allocation.
pub const EnvBlock = struct {
    ptrs: [max_vars + 1]?[*:0]const u8,
    strings: [1024]u8,

    pub const max_vars = 1024;
};

/// Variables teru sets in every pane, replacing inherited ones.
const overridden_vars = [_][]const u8{ "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLUMNS", "LINES" };

fn envKey(entry: []const u8) []const u8 {
    const eq = std.mem.findScalar(u8, entry, '=') orelse return entry;
    return entry[0..eq];
}

/// Fill `block` with `base` minus the variables teru overrides, then
/// teru's TERM, COLORTERM, TERM_PROGRAM, TERM_PROGRAM_VERSION, COLUMNS and
/// LINES. With `ensure_lang`, adds LANG=en_US.UTF-8 when none of LANG,
/// LC_ALL and LC_CTYPE is set: a GUI app gets no locale from launchd, and
/// without one shells and editors mishandle anything beyond ASCII.
pub fn buildChildEnv(
    block: *EnvBlock,
    base: [*:null]const ?[*:0]const u8,
    cols: u16,
    rows: u16,
    term: ?[]const u8,
    ensure_lang: bool,
) [*:null]const ?[*:0]const u8 {
    var n: usize = 0;
    var has_locale = false;
    // Room for teru's own variables at the end.
    const reserve = overridden_vars.len + 1;
    var i: usize = 0;
    while (base[i]) |entry_z| : (i += 1) {
        const entry = std.mem.sliceTo(entry_z, 0);
        const key = envKey(entry);
        if (std.mem.eql(u8, key, "LANG") or std.mem.eql(u8, key, "LC_ALL") or std.mem.eql(u8, key, "LC_CTYPE")) has_locale = true;
        var skip = false;
        for (overridden_vars) |o| {
            if (std.mem.eql(u8, key, o)) skip = true;
        }
        if (skip) continue;
        if (n + reserve >= EnvBlock.max_vars) continue; // an absurd environment: drop the excess
        block.ptrs[n] = entry_z;
        n += 1;
    }

    var w = Appender{ .buf = &block.strings };
    const term_val = term orelse "xterm-256color";
    const added = [_]?[*:0]const u8{
        w.add("TERM", term_val),
        w.add("COLORTERM", "truecolor"),
        w.add("TERM_PROGRAM", "teru"),
        w.add("TERM_PROGRAM_VERSION", build_options.version),
        w.addInt("COLUMNS", cols),
        w.addInt("LINES", rows),
        if (ensure_lang and !has_locale) w.add("LANG", "en_US.UTF-8") else null,
    };
    for (added) |a| {
        if (a) |p| {
            block.ptrs[n] = p;
            n += 1;
        }
    }
    block.ptrs[n] = null;
    return @ptrCast(&block.ptrs);
}

/// Writes NUL-terminated KEY=VALUE strings into a fixed buffer.
const Appender = struct {
    buf: []u8,
    len: usize = 0,

    fn add(self: *Appender, key: []const u8, value: []const u8) ?[*:0]const u8 {
        const need = key.len + 1 + value.len + 1;
        if (self.len + need > self.buf.len) return null;
        const start = self.len;
        const out = self.buf[start..][0..need];
        @memcpy(out[0..key.len], key);
        out[key.len] = '=';
        @memcpy(out[key.len + 1 ..][0..value.len], value);
        out[need - 1] = 0;
        self.len += need;
        return @ptrCast(self.buf[start..].ptr);
    }

    fn addInt(self: *Appender, key: []const u8, value: u16) ?[*:0]const u8 {
        var num: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&num, "{d}", .{value}) catch return null;
        return self.add(key, s);
    }
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setChildEnv(cols: u16, rows: u16, term_override: ?[]const u8) void {
    if (term_override) |term_val| {
        var term_buf: [64:0]u8 = @splat(0);
        const tlen = @min(term_val.len, term_buf.len - 1);
        @memcpy(term_buf[0..tlen], term_val[0..tlen]);
        _ = setenv("TERM", &term_buf, 1);
    } else {
        _ = setenv("TERM", "xterm-256color", 1);
    }
    _ = setenv("COLORTERM", "truecolor", 1);
    _ = setenv("TERM_PROGRAM", "teru", 1);
    _ = setenv("TERM_PROGRAM_VERSION", @ptrCast(build_options.version.ptr), 1);

    var cols_buf: [8:0]u8 = @splat(0);
    var rows_buf: [8:0]u8 = @splat(0);
    _ = std.fmt.bufPrint(&cols_buf, "{d}", .{cols}) catch {};
    _ = std.fmt.bufPrint(&rows_buf, "{d}", .{rows}) catch {};
    _ = setenv("COLUMNS", &cols_buf, 1);
    _ = setenv("LINES", &rows_buf, 1);
}

// ── C interop for PTY functions ──────────────────────────────────

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

test "buildChildEnv: keeps the environment, overrides teru's variables" {
    const base = [_:null]?[*:0]const u8{ "HOME=/Users/a", "TERM=dumb", "PATH=/usr/bin:/bin", "COLUMNS=1" };
    var block: EnvBlock = undefined;
    const env = buildChildEnv(&block, &base, 120, 40, null, true);
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(std.testing.allocator);
    var i: usize = 0;
    while (env[i]) |e| : (i += 1) try got.append(std.testing.allocator, std.mem.sliceTo(e, 0));
    const want = [_][]const u8{
        "HOME=/Users/a",
        "PATH=/usr/bin:/bin",
        "TERM=xterm-256color",
        "COLORTERM=truecolor",
        "TERM_PROGRAM=teru",
        "TERM_PROGRAM_VERSION=" ++ build_options.version,
        "COLUMNS=120",
        "LINES=40",
        "LANG=en_US.UTF-8",
    };
    try std.testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "buildChildEnv: an existing locale is left alone; TERM override" {
    const base = [_:null]?[*:0]const u8{ "LC_CTYPE=UTF-8", "SHELL=/bin/zsh" };
    var block: EnvBlock = undefined;
    const env = buildChildEnv(&block, &base, 80, 24, "xterm-teru", true);
    var i: usize = 0;
    var saw_term = false;
    while (env[i]) |e| : (i += 1) {
        const entry = std.mem.sliceTo(e, 0);
        try std.testing.expect(!std.mem.startsWith(u8, entry, "LANG="));
        if (std.mem.eql(u8, entry, "TERM=xterm-teru")) saw_term = true;
    }
    try std.testing.expect(saw_term);
}

test "loginArgv0: dash and the shell's name" {
    var buf: [256:0]u8 = undefined;
    try std.testing.expectEqualStrings("-zsh", std.mem.sliceTo(loginArgv0(&buf, "/bin/zsh").?, 0));
    try std.testing.expectEqualStrings("-fish", std.mem.sliceTo(loginArgv0(&buf, "/opt/homebrew/bin/fish").?, 0));
    try std.testing.expect(loginArgv0(&buf, "") == null);
}
