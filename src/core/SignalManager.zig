//! SIGWINCH signal handler for PTY resize propagation.
//!
//! Encapsulates the global mutable state required by POSIX signal handlers.
//! Signal handlers cannot access instance data, so file-scope vars hold the
//! PTY master fd and host fd that the handler needs for the TIOCSWINSZ ioctl.

const std = @import("std");
const posix = std.posix;

const SignalManager = @This();

// ── Module-level state (signal handlers can only access globals) ──

var g_pty_master_fd: posix.fd_t = -1;
var g_host_fd: posix.fd_t = posix.STDIN_FILENO;

// ── Instance (zero-size, provides a namespace for init/update) ──

/// Initialize the signal manager with PTY and host file descriptors.
pub fn init(pty_master_fd: posix.fd_t, host_fd: posix.fd_t) SignalManager {
    g_pty_master_fd = pty_master_fd;
    g_host_fd = host_fd;
    return .{};
}

/// Register the SIGWINCH handler. Call after init().
pub fn registerWinch(_: SignalManager) void {
    const SA_RESTART = 0x10000000;
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = SA_RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
}

/// Update the PTY master fd (e.g. when active pane changes).
pub fn updatePtyFd(_: SignalManager, fd: posix.fd_t) void {
    g_pty_master_fd = fd;
}

/// Update the host fd.
pub fn updateHostFd(_: SignalManager, fd: posix.fd_t) void {
    g_host_fd = fd;
}

// ── Signal handler (async-signal-safe: only ioctl, no allocations) ──

fn handleSigwinch(_: posix.SIG) callconv(.c) void {
    if (g_pty_master_fd < 0) return;
    var ws: posix.winsize = undefined;
    if (posix.system.ioctl(g_host_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return;
    _ = posix.system.ioctl(g_pty_master_fd, posix.T.IOCSWINSZ, @intFromPtr(&ws));
}

// ── Tests ──────────────────────────────────────────────────────────

test "SignalManager: init sets fds" {
    const sm = SignalManager.init(42, 7);
    _ = sm;
    try std.testing.expectEqual(@as(posix.fd_t, 42), g_pty_master_fd);
    try std.testing.expectEqual(@as(posix.fd_t, 7), g_host_fd);
}

test "SignalManager: updatePtyFd" {
    var sm = SignalManager.init(1, 0);
    sm.updatePtyFd(99);
    try std.testing.expectEqual(@as(posix.fd_t, 99), g_pty_master_fd);
}

test "SignalManager: updateHostFd" {
    var sm = SignalManager.init(1, 0);
    sm.updateHostFd(55);
    try std.testing.expectEqual(@as(posix.fd_t, 55), g_host_fd);
}
