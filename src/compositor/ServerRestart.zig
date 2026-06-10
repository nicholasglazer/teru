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
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

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

    // Write state file: fixed records first (the v1 region an old reader
    // understands), then the v2 display-memory section appended after.
    var rpath_buf: [128:0]u8 = undefined;
    const rpath = restartStatePath(&rpath_buf);
    const file = std.c.fopen(rpath, "wb");
    if (file) |f| {
        _ = std.c.fwrite(buf[0..pos].ptr, 1, pos, f);
        // A truncated v1 region means the reader's record loop stops early
        // and would mis-parse appended snapshot bytes as pane records
        // (garbage pty_fds). Only append the section when the records are
        // complete; a truncated blob degrades to the jiggle path instead.
        if (!truncated) writeSnapshotSection(server, f);
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

    // XWayland + seat teardown — the SAME sequence the quit path runs (see
    // Server.destroyXwayland / Server.releaseSeat for the full rationale). Here
    // it's performed in-process because execve never runs main's defers:
    //   • destroyXwayland unlinks the :0 lock/socket so the re-exec'd instance
    //     reclaims :0 (an in-place exec KEEPS the PID, so a lazy-XWayland lock
    //     naming this live PID would push the new server to :1, :2, … and
    //     eventually fail — DISPLAY=:0 in the shells would go stale).
    //   • releaseSeat detaches the keyboard before destroying the backend
    //     (wlr_keyboard_finish's release-all notify into a still-attached seat
    //     was the 2026-06-04 --restore SIGSEGV), then drops libseat control so
    //     the new image's TakeControl succeeds. Without it $mod+' "closed the
    //     session" on real hardware (headless has no seat, so tests never hit it).
    server.destroyXwayland();
    server.releaseSeat();

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
///
/// Display memory: the v2 blob carries a per-pane VT replay snapshot
/// (see writeSnapshotSection), fed through each fresh pane's parser so
/// content, cursor, pen, and interaction modes come back without any
/// app cooperation. Panes without a snapshot (old-writer blob, remote
/// backend, alloc failure) get the TIOCSWINSZ jiggle instead.
pub fn restoreSession(server: *Server, allocator: std.mem.Allocator) void {
    var rpath_buf: [128:0]u8 = undefined;
    const rpath = restartStatePath(&rpath_buf);
    const file = std.c.fopen(rpath, "rb") orelse {
        std.log.scoped(.session).info("no restart state found", .{});
        return;
    };

    // Read the WHOLE blob. The v2 snapshot section doesn't fit the old
    // 64 KiB stack buffer (a large pane's stream alone can exceed it), so
    // size the file and heap-read it; fall back to the stack buffer (and
    // therefore the jiggle path) if sizing or allocation fails.
    const SEEK_SET: c_int = 0;
    const SEEK_END: c_int = 2;
    _ = fseek(file, 0, SEEK_END);
    const fsize = ftell(file);
    _ = fseek(file, 0, SEEK_SET);

    var stack_buf: [65536]u8 = undefined;
    var heap_buf: ?[]u8 = null;
    defer if (heap_buf) |h| allocator.free(h);

    const blob_cap: usize = 16 * 1024 * 1024; // sanity bound for a corrupt size
    var want: usize = stack_buf.len;
    if (fsize > 0) want = @min(@as(usize, @intCast(fsize)), blob_cap);
    var dst: []u8 = stack_buf[0..@min(want, stack_buf.len)];
    if (want > stack_buf.len) {
        if (allocator.alloc(u8, want)) |h| {
            heap_buf = h;
            dst = h;
        } else |_| {}
    }

    const n = std.c.fread(dst.ptr, 1, dst.len, file);
    _ = std.c.fclose(file);
    _ = std.c.unlink(rpath);

    const blob = dst[0..n];
    if (blob.len < 13) return;

    var pos: usize = 0;

    const pane_count = std.mem.readInt(u16, blob[pos..][0..2], .little);
    pos += 2;
    const active_ws = blob[pos];
    pos += 1;

    for (0..10) |wi| {
        if (pos < blob.len) {
            // Clamp the restart-file byte before @enumFromInt: a corrupt or
            // version-mismatched /tmp/teruwm-restart.bin with an out-of-range
            // layout byte would otherwise panic. Mirror the teru attach path
            // (modes/common.zig). accordion is the highest Layout variant.
            const L = @TypeOf(server.layout_engine.workspaces[wi].layout);
            server.layout_engine.workspaces[wi].layout =
                @enumFromInt(@min(blob[pos], @intFromEnum(L.accordion)));
            pos += 1;
        }
    }

    std.log.scoped(.session).info("restoring {d} panes (active ws={d})", .{ pane_count, active_ws });

    // Track each record's restored pane so the v2 snapshot section (same
    // entry order) can be matched back up. null = record skipped/failed.
    var tps_stack: [256]?*TerminalPane = @splat(null);
    var tps_heap: ?[]?*TerminalPane = null;
    defer if (tps_heap) |h| allocator.free(h);
    var tps: []?*TerminalPane = tps_stack[0..@min(pane_count, tps_stack.len)];
    if (pane_count > tps_stack.len) {
        if (allocator.alloc(?*TerminalPane, pane_count)) |h| {
            for (h) |*slot| slot.* = null;
            tps_heap = h;
            tps = h;
        } else |_| {}
    }

    var restored: u16 = 0;
    for (0..pane_count) |i| {
        if (pos + 13 > blob.len) break;

        const raw_ws = blob[pos]; pos += 1;
        // A scratchpad pane is serialized with HIDDEN_WS (0xFF), but the tiling
        // engine only has workspaces 0..<len. Restoring it as-is makes
        // createRestored index workspaces[255] → "index out of bounds" PANIC,
        // which aborts the re-exec'd binary BEFORE it can take/restore the
        // display — a frozen TTY on $mod+' for anyone with a scratchpad open.
        // Remap any out-of-range workspace to the active one: the shell comes
        // back as a normal window instead of crashing the restart. (Scratchpad
        // identity isn't in the save format, so it can't be fully restored yet.)
        const ws: u8 = if (raw_ws < server.layout_engine.workspaces.len) raw_ws else active_ws;
        const pty_fd = std.mem.readInt(i32, blob[pos..][0..4], .little); pos += 4;
        // Clamp to ≥1: a corrupt blob with rows/cols 0 would build an empty
        // Grid whose first snapshot-feed glyph write is an index-OOB panic —
        // aborting the re-exec'd binary AFTER the seat was released (frozen
        // TTY). Same hazard class as the ws=0xFF scratchpad clamp above.
        const rows = @max(1, std.mem.readInt(u16, blob[pos..][0..2], .little)); pos += 2;
        const cols = @max(1, std.mem.readInt(u16, blob[pos..][0..2], .little)); pos += 2;
        const pid = std.mem.readInt(i32, blob[pos..][0..4], .little); pos += 4;

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
        if (i < tps.len) tps[i] = tp;

        server.next_node_id += 1;
        restored += 1;
    }

    server.layout_engine.switchWorkspace(active_ws);
    server.setWorkspaceVisibility(active_ws, true);
    server.arrangeworkspace(active_ws);
    server.updateFocusedTerminal();

    // ── v2 display-memory section ──────────────────────────────
    // Replay each pane's snapshot through its fresh parser; jiggle any
    // pane that has no usable snapshot. An old-writer blob has no section
    // at all → jiggle everything (the pre-v2 behavior, upgraded from the
    // same-size SIGWINCH that Node/Ink apps ignore).
    //
    // Runs AFTER arrangeworkspace deliberately: arrange's resize path
    // (TerminalPane.resize → Grid.resize) resets the scroll region and
    // discards the alt-screen backup even at unchanged rows/cols (the
    // framebuffer pixel dims differ from the tile rect almost always).
    // Feeding first would let arrange wipe the just-restored DECSTBM/alt
    // state; feeding after, the snapshot lands on the final geometry.
    var any_jiggled = false;
    if (pos + 5 <= blob.len and std.mem.eql(u8, blob[pos..][0..4], "TWMG") and blob[pos + 4] == 1) {
        var spos = pos + 5;
        for (0..pane_count) |i| {
            if (spos + 4 > blob.len) {
                // Truncated section — jiggle the panes we can't replay.
                if (i < tps.len) {
                    for (tps[i..]) |maybe_tp| if (maybe_tp) |tp| {
                        jiggleDown(tp);
                        any_jiggled = true;
                    };
                }
                break;
            }
            const slen: usize = std.mem.readInt(u32, blob[spos..][0..4], .little);
            spos += 4;
            // Width-proof bounds form (slen is untrusted u32; spos ≤ blob.len
            // is guaranteed by the check above, so the subtraction is safe).
            if (slen > blob.len - spos) {
                if (i < tps.len) {
                    for (tps[i..]) |maybe_tp| if (maybe_tp) |tp| {
                        jiggleDown(tp);
                        any_jiggled = true;
                    };
                }
                break;
            }
            if (i < tps.len) {
                if (tps[i]) |tp| {
                    if (slen > 0) {
                        tp.pane.vt.feed(blob[spos..][0..slen]);
                        tp.pane.grid.markAllDirty();
                    } else {
                        jiggleDown(tp);
                        any_jiggled = true;
                    }
                }
            }
            spos += slen;
        }
    } else {
        for (tps) |maybe_tp| if (maybe_tp) |tp| {
            jiggleDown(tp);
            any_jiggled = true;
        };
    }
    // Phase 2 of the jiggle fires from a ~60 ms timer: two back-to-back
    // TIOCSWINSZ calls coalesce into ONE pending SIGWINCH whose handler
    // samples the FINAL (unchanged) size — Node/Ink would swallow it and
    // stay blank, the original bug. The delay makes the shrunken size
    // actually observable before the restore (the tmux trick).
    if (any_jiggled) armJiggleTimer(server);

    // Belt-and-suspenders SIGWINCH so shells re-sync their idea of the
    // screen (fish repaints its prompt onto the restored grid). Apps that
    // ignore same-size WINCH (Node/Ink) are covered by the snapshot replay
    // or the jiggle above, not by this.
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| switch (tp.pane.backend) {
            .local => |*p| p.refresh(),
            .remote => {},
        };
    }

    server.scheduleRender();
    if (server.bar) |b| _ = b.render(server);

    std.log.scoped(.session).info("restored {d}/{d} panes", .{ restored, pane_count });
}

// ── Private helpers ──────────────────────────────────────────

/// v2 blob section: per-pane VT replay snapshots ("display memory").
/// Appended after the fixed records, so an OLD reader (which stops after
/// pane_count records) silently ignores it, and a NEW reader on an OLD
/// blob falls back to the SIGWINCH jiggle. Entry order matches the record
/// loop exactly: one `[u32 len][stream]` per serialized pane; len 0 means
/// "no snapshot" (remote backend / alloc failure) → reader jiggles that
/// pane instead. The stream itself is plain VT bytes (see
/// VtParser.dumpReplaySnapshot), so a version-skewed or corrupt snapshot
/// degrades to garbled text in one pane — never a parser crash.
fn writeSnapshotSection(server: *Server, f: *std.c.FILE) void {
    _ = std.c.fwrite("TWMG\x01", 1, 5, f);
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            var wrote = false;
            if (tp.pane.backend == .local) {
                const need = teru.VtParser.replaySnapshotBufSize(tp.pane.grid.rows, tp.pane.grid.cols);
                if (server.zig_allocator.alloc(u8, need)) |sbuf| {
                    defer server.zig_allocator.free(sbuf);
                    const slen = tp.pane.vt.dumpReplaySnapshot(sbuf);
                    var lenb: [4]u8 = undefined;
                    std.mem.writeInt(u32, &lenb, @intCast(slen), .little);
                    _ = std.c.fwrite(&lenb, 1, 4, f);
                    if (slen > 0) _ = std.c.fwrite(sbuf.ptr, 1, slen, f);
                    wrote = true;
                } else |_| {}
            }
            if (!wrote) {
                const zero: [4]u8 = .{ 0, 0, 0, 0 };
                _ = std.c.fwrite(&zero, 1, 4, f);
            }
        }
    }
}

/// Phase 1 of the repaint jiggle: shrink the PTY winsize by one column
/// (kernel raises a real SIGWINCH, and the app's size query now returns a
/// DIFFERENT size). Phase 2 — restoring the true size — runs from a ~60 ms
/// timer (armJiggleTimer): doing both ioctls back-to-back coalesces into a
/// single pending SIGWINCH whose handler samples the final (unchanged)
/// size, which Node's tty layer (and therefore Ink/claude) swallows —
/// exactly the "restored pane stays blank until a real resize" symptom
/// this exists to fix. Legacy fallback for blobs without a v2 snapshot;
/// the snapshot path repaints from display memory, no app cooperation.
fn jiggleDown(tp: *TerminalPane) void {
    switch (tp.pane.backend) {
        .local => |*p| {
            const rows = tp.pane.grid.rows;
            const cols = tp.pane.grid.cols;
            if (cols >= 2) {
                p.resize(rows, cols - 1);
            } else {
                p.resize(rows + 1, cols);
            }
        },
        .remote => {},
    }
}

/// Arm the one-shot phase-2 timer that re-asserts every local pane's true
/// grid dimensions ~60 ms after jiggleDown. Idempotent payload: it simply
/// sets each PTY winsize to the pane's current grid dims, so no per-pane
/// bookkeeping is needed and a pane closed in the window is skipped
/// naturally (it's gone from terminal_panes).
fn armJiggleTimer(server: *Server) void {
    const el = server.event_loop orelse return;
    if (server.jiggle_timer_src == null) {
        server.jiggle_timer_src = wlr.wl_event_loop_add_timer(el, jiggleTimerCb, @ptrCast(server));
    }
    if (server.jiggle_timer_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, 60);
    }
}

fn jiggleTimerCb(data: ?*anyopaque) callconv(.c) c_int {
    const server: *Server = @ptrCast(@alignCast(data orelse return 0));
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| switch (tp.pane.backend) {
            .local => |*p| p.resize(tp.pane.grid.rows, tp.pane.grid.cols),
            .remote => {},
        };
    }
    // One-shot: remove the source (a fired timer stays registered but
    // disarmed; removing keeps Server.deinit from touching it after the
    // event loop is gone).
    if (server.jiggle_timer_src) |src| {
        _ = wlr.wl_event_source_remove(src);
        server.jiggle_timer_src = null;
    }
    return 0;
}

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
