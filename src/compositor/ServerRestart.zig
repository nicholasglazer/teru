//! Hot-restart for teruwm — serialize + exec + restore.
//!
//! The xmonad-style "restart the WM without losing client state" trick:
//! we write the compositor's live state (pane count, workspace layouts,
//! per-pane PTY master fd + rows/cols + shell pid) to a state file,
//! clear FD_CLOEXEC on every PTY master so the fds survive the
//! execve(), then exec the new binary with `--restore`. On the other
//! side, `restoreSession` reads the state file and reattaches each
//! PTY fd as a TerminalPane — shells keep running without noticing.
//!
//! Split out of Server.zig as part of the 2026-04-16 modularization
//! pass. Functions take `*Server` directly to avoid the usingnamespace
//! patterns Zig 0.16 no longer supports.

const std = @import("std");
const teru = @import("teru");
const Pty = teru.Pty;
const Pane = teru.Pane;
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");

pub const restart_state_path = "/tmp/teruwm-restart.bin";

/// Save live state + exec the new binary. Returns only on exec failure
/// (FD_CLOEXEC is restored on that path). Callers usually treat the
/// non-exec return as a soft-fail and continue running the current
/// instance.
pub fn execRestart(server: *Server) void {
    // 64 KiB buffer: 13 bytes/pane + 13-byte header ⇒ cap at ~5000 panes.
    // Previous 4 KiB silently truncated beyond ~300.
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;
    var truncated = false;

    // Header: pane count
    var pane_count: u16 = 0;
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp != null) pane_count += 1;
    }
    var hdr: [2]u8 = undefined;
    std.mem.writeInt(u16, &hdr, pane_count, .little);
    writeBytes(&buf, &pos, &truncated, &hdr);

    // Active workspace
    writeBytes(&buf, &pos, &truncated, &[_]u8{server.layout_engine.active_workspace});

    // Per-workspace layouts (10 workspaces)
    for (0..10) |wi| {
        writeBytes(&buf, &pos, &truncated, &[_]u8{@intFromEnum(server.layout_engine.workspaces[wi].layout)});
    }

    // Track fds we cleared FD_CLOEXEC on so we can restore on exec-fail.
    var cleared_fds: std.ArrayListUnmanaged(i32) = .empty;
    defer cleared_fds.deinit(server.zig_allocator);

    // Per-pane data
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            const ws = if (server.nodes.findById(tp.node_id)) |slot| server.nodes.workspace[slot] else 0;
            const pty_fd: i32 = switch (tp.pane.backend) {
                .local => |p| p.master,
                .remote => -1,
            };
            const pid: i32 = switch (tp.pane.backend) {
                .local => |p| if (p.child_pid) |cp| @intCast(cp) else -1,
                .remote => -1,
            };
            var record: [13]u8 = undefined;
            record[0] = ws;
            std.mem.writeInt(i32, record[1..5], pty_fd, .little);
            std.mem.writeInt(u16, record[5..7], tp.pane.grid.rows, .little);
            std.mem.writeInt(u16, record[7..9], tp.pane.grid.cols, .little);
            std.mem.writeInt(i32, record[9..13], pid, .little);
            writeBytes(&buf, &pos, &truncated, &record);

            // Clear FD_CLOEXEC on pty master so it survives exec.
            if (pty_fd >= 0) {
                const flags = std.c.fcntl(pty_fd, std.posix.F.GETFD);
                if (flags >= 0 and (flags & 1) != 0) {
                    if (std.c.fcntl(pty_fd, std.posix.F.SETFD, flags & ~@as(c_int, 1)) >= 0) {
                        cleared_fds.append(server.zig_allocator, pty_fd) catch {};
                    }
                }
            }
        }
    }

    if (truncated) {
        std.debug.print("teruwm: restart state truncated at {d} bytes ({d} panes)\n", .{ pos, pane_count });
    }

    // Write state file
    const file = std.c.fopen(restart_state_path, "wb");
    if (file) |f| {
        _ = std.c.fwrite(buf[0..pos].ptr, 1, pos, f);
        _ = std.c.fclose(f);
    } else {
        std.debug.print("teruwm: failed to write restart state\n", .{});
        restoreCloexec(cleared_fds.items);
        return;
    }

    std.debug.print("teruwm: restarting ({d} panes saved)\n", .{pane_count});

    // exec the new binary
    const self_exe = "/proc/self/exe";
    var argv_buf: [3:null]?[*:0]const u8 = .{ @ptrCast(self_exe), @ptrCast("--restore"), null };
    _ = std.posix.system.execve(@ptrCast(self_exe), @ptrCast(&argv_buf), std.c.environ);

    // If exec returns, it failed — put FD_CLOEXEC back so the open PTY
    // masters don't leak into any future forked child.
    std.debug.print("teruwm: exec failed, continuing\n", .{});
    restoreCloexec(cleared_fds.items);
}

/// Restore terminal panes from a restart state file. PTY master fds
/// were inherited across exec(); the shells backing each one are
/// still running. One-shot: the state file is unlinked after read.
pub fn restoreSession(server: *Server, allocator: std.mem.Allocator) void {
    var buf: [65536]u8 = undefined;
    const file = std.c.fopen(restart_state_path, "rb") orelse {
        std.debug.print("teruwm: no restart state found\n", .{});
        return;
    };
    const n = std.c.fread(&buf, 1, buf.len, file);
    _ = std.c.fclose(file);

    _ = std.c.unlink(restart_state_path);

    if (n < 13) return;

    var pos: usize = 0;

    const pane_count = std.mem.readInt(u16, buf[pos..][0..2], .little);
    pos += 2;
    const active_ws = buf[pos];
    pos += 1;

    for (0..10) |wi| {
        if (pos < n) {
            server.layout_engine.workspaces[wi].layout = @enumFromInt(buf[pos]);
            pos += 1;
        }
    }

    std.debug.print("teruwm: restoring {d} panes (active ws={d})\n", .{ pane_count, active_ws });

    var restored: u16 = 0;
    for (0..pane_count) |_| {
        if (pos + 13 > n) break;

        const ws = buf[pos]; pos += 1;
        const pty_fd = std.mem.readInt(i32, buf[pos..][0..4], .little); pos += 4;
        const rows = std.mem.readInt(u16, buf[pos..][0..2], .little); pos += 2;
        const cols = std.mem.readInt(u16, buf[pos..][0..2], .little); pos += 2;
        const pid = std.mem.readInt(i32, buf[pos..][0..4], .little); pos += 4;

        if (pty_fd < 0) continue;

        const pty = Pty.attach(pty_fd, if (pid >= 0) @intCast(pid) else null);
        const spawn_config = Pane.SpawnConfig{};
        var pane = Pane.initWithPty(allocator, rows, cols, server.next_node_id, spawn_config, pty) catch continue;
        _ = &pane;

        const tp = TerminalPane.createRestored(server, ws, &pane) orelse continue;
        _ = tp;

        server.next_node_id += 1;
        restored += 1;
    }

    server.layout_engine.switchWorkspace(active_ws);
    server.setWorkspaceVisibility(active_ws, true);
    server.arrangeworkspace(active_ws);
    server.updateFocusedTerminal();
    if (server.bar) |b| b.render(server);

    std.debug.print("teruwm: restored {d}/{d} panes\n", .{ restored, pane_count });
}

// ── Private helpers ──────────────────────────────────────────

fn writeBytes(b: *[65536]u8, p: *usize, trunc: *bool, bytes: []const u8) void {
    if (p.* + bytes.len > b.len) { trunc.* = true; return; }
    @memcpy(b[p.*..][0..bytes.len], bytes);
    p.* += bytes.len;
}

fn restoreCloexec(fds: []const i32) void {
    for (fds) |fd| {
        const flags = std.c.fcntl(fd, std.posix.F.GETFD);
        if (flags >= 0) {
            _ = std.c.fcntl(fd, std.posix.F.SETFD, flags | @as(c_int, 1));
        }
    }
}
