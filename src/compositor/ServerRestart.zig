//! Hot-restart for teruwm — serialize + exec + restore.
//!
//! Restart the WM without losing client state: write live state
//! (pane count, per-workspace layout, per-pane PTY master fd + rows/
//! cols + shell pid) to a state file, clear FD_CLOEXEC on every PTY
//! master so the fds survive execve(), then exec the new binary with
//! `--restore`. `restoreSession` reads the state file and reattaches
//! each PTY fd as a TerminalPane — shells keep running without
//! noticing the compositor restart.
//!
//! Functions take `*Server` directly; Zig 0.16 has no usingnamespace
//! equivalent, so free-functions-on-Server is the idiomatic split.

const std = @import("std");
const teru = @import("teru");
const Pty = teru.Pty;
const Pane = teru.Pane;
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");
const wlr = @import("wlr.zig");

extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Prefer $XDG_RUNTIME_DIR (private, cleaned on logout) over /tmp.
/// Thin wrapper around compat.runtimeFilePath for the restart blob.
fn restartStatePath(buf: []u8) [:0]const u8 {
    return teru.compat.runtimeFilePath(buf, "teruwm-restart.bin") orelse
        @panic("restartStatePath: buffer too small");
}

/// Resolve the running binary's on-disk path via /proc/self/exe, stripping
/// the " (deleted)" suffix the kernel appends once the file has been
/// replaced (a rebuild + `install` swaps the inode under the running
/// process). exec'ing the bare "/proc/self/exe" symlink would re-run the
/// stale in-memory inode — the OLD code — so a hot-restart could never
/// pick up a fresh build. Re-resolving the path and exec'ing *that* gives
/// xmonad --restart semantics. Returns null (→ caller falls back to the
/// always-valid symlink) if the link can't be read or the path isn't
/// executable anymore.
fn resolveSelfExe(buf: *[4096:0]u8) ?[*:0]const u8 {
    const n = std.c.readlink("/proc/self/exe", buf, buf.len);
    if (n <= 0) return null;
    var len: usize = @intCast(n);
    const deleted = " (deleted)";
    if (len > deleted.len and std.mem.eql(u8, buf[len - deleted.len ..][0..deleted.len], deleted))
        len -= deleted.len;
    buf[len] = 0;
    if (std.c.access(buf, std.posix.X_OK) != 0) return null;
    return buf[0..len :0].ptr;
}

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
    var cleared_fds: std.ArrayList(i32) = .empty;
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
        std.log.scoped(.session).warn("restart state truncated at {d} bytes ({d} panes)", .{ pos, pane_count });
    }

    // Write state file
    var rpath_buf: [128:0]u8 = undefined;
    const rpath = restartStatePath(&rpath_buf);
    const file = std.c.fopen(rpath, "wb");
    if (file) |f| {
        _ = std.c.fwrite(buf[0..pos].ptr, 1, pos, f);
        _ = std.c.fclose(f);
    } else {
        std.log.scoped(.session).err("failed to write restart state", .{});
        restoreCloexec(cleared_fds.items);
        return;
    }

    std.log.scoped(.session).info("restarting ({d} panes saved)", .{pane_count});

    // exec the new binary — re-resolve the on-disk path so a rebuilt +
    // reinstalled teruwm is actually loaded (see resolveSelfExe). Falls
    // back to the bare /proc symlink if the path can't be resolved.
    var exe_buf: [4096:0]u8 = undefined;
    const self_exe: [*:0]const u8 = resolveSelfExe(&exe_buf) orelse "/proc/self/exe";

    // Drop teruwm's OWN compositor sockets from the environ before exec.
    // While running, teruwm setenv's WAYLAND_DISPLAY (its wl socket) and
    // DISPLAY (Xwayland) so client apps can connect. If those survive the
    // execve, wlr_backend_autocreate in the new process tries to NEST in
    // those now-dead sockets ("Could not connect to remote display") and the
    // compositor aborts — this killed hot-restart on a bare TTY (the headless
    // test masked it because WLR_BACKENDS=headless still won). Clearing them
    // makes autocreate re-select the session backend (DRM/TTY) exactly as the
    // original launch did. NOTE: a teruwm launched NESTED in another
    // X11/Wayland session would also fall back to DRM here — restart targets
    // the bare-TTY compositor; capturing+restoring the launch env would
    // generalise it.
    _ = unsetenv("WAYLAND_DISPLAY");
    _ = unsetenv("DISPLAY");

    // Release the DRM/logind seat IN-PROCESS before re-exec. On a bare TTY,
    // wlr_backend_autocreate took control of the seat (libseat TakeControl),
    // the DRM master, and each input device. execve replaces the process image
    // WITHOUT running destructors, so without this the old image still owns the
    // seat at exec time and the new image's autocreate fails to TakeControl →
    // BackendCreateFailed → the process exits → the whole session dies (this is
    // exactly why $mod+' "closed the session" on real hardware; headless has no
    // seat, so the e2e suite never hit it).
    //
    // Order is load-bearing: destroy the backend FIRST — it closes the DRM +
    // input device fds through the still-live session — THEN destroy the
    // session, whose close releases libseat control (logind ReleaseControl), the
    // one thing blocking the new TakeControl. shutting_down gates the output
    // frame/destroy handlers that fire during teardown (same invariant deinit
    // relies on, Server.zig:732 / Output.zig:272). PTY master fds were
    // FD_CLOEXEC-cleared above and are independent of wlroots, so they survive
    // this teardown and the execve — terminals keep running.
    server.shutting_down = true;
    wlr.wlr_backend_destroy(server.backend);
    if (server.session) |sess| wlr.wlr_session_destroy(sess);

    var argv_buf: [3:null]?[*:0]const u8 = .{ self_exe, @ptrCast("--restore"), null };
    _ = std.posix.system.execve(self_exe, @ptrCast(&argv_buf), std.c.environ);

    // exec returned → it failed, AND we've already torn down the backend/seat,
    // so there's no live display to fall back to (restoring FD_CLOEXEC would
    // only leave a blind, seat-less zombie). Exit; the parent shell shows the
    // error. A failed re-exec of a freshly built binary is rare and recoverable
    // (relaunch); limping on headless is not.
    std.log.scoped(.session).err("exec failed after seat teardown — exiting", .{});
    std.process.exit(1);
}

/// Restore terminal panes from a restart state file. PTY master fds
/// were inherited across exec(); the shells backing each one are
/// still running. One-shot: the state file is unlinked after read.
pub fn restoreSession(server: *Server, allocator: std.mem.Allocator) void {
    var buf: [65536]u8 = undefined;
    var rpath_buf: [128:0]u8 = undefined;
    const rpath = restartStatePath(&rpath_buf);
    const file = std.c.fopen(rpath, "rb") orelse {
        std.log.scoped(.session).info("no restart state found", .{});
        return;
    };
    const n = std.c.fread(&buf, 1, buf.len, file);
    _ = std.c.fclose(file);

    _ = std.c.unlink(rpath);

    if (n < 13) return;

    var pos: usize = 0;

    const pane_count = std.mem.readInt(u16, buf[pos..][0..2], .little);
    pos += 2;
    const active_ws = buf[pos];
    pos += 1;

    for (0..10) |wi| {
        if (pos < n) {
            // Clamp the restart-file byte before @enumFromInt: a corrupt or
            // version-mismatched /tmp/teruwm-restart.bin with an out-of-range
            // layout byte would otherwise panic. Mirror the teru attach path
            // (modes/common.zig). accordion is the highest Layout variant.
            const L = @TypeOf(server.layout_engine.workspaces[wi].layout);
            server.layout_engine.workspaces[wi].layout =
                @enumFromInt(@min(buf[pos], @intFromEnum(L.accordion)));
            pos += 1;
        }
    }

    std.log.scoped(.session).info("restoring {d} panes (active ws={d})", .{ pane_count, active_ws });

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

        const tp = TerminalPane.createRestored(server, ws, &pane) orelse {
            // createRestored does NOT free the caller-owned Pane on its
            // failure paths. Without this, a scene/renderer alloc failure
            // mid-restore leaks the Grid + Scrollback AND the inherited PTY
            // master fd (whose FD_CLOEXEC was cleared to survive exec) —
            // i.e. an orphaned shell that never receives SIGHUP/EOF.
            pane.deinit(allocator);
            continue;
        };
        _ = tp;

        server.next_node_id += 1;
        restored += 1;
    }

    server.layout_engine.switchWorkspace(active_ws);
    server.setWorkspaceVisibility(active_ws, true);
    server.arrangeworkspace(active_ws);
    server.updateFocusedTerminal();
    if (server.bar) |b| _ = b.render(server);

    std.log.scoped(.session).info("restored {d}/{d} panes", .{ restored, pane_count });
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
