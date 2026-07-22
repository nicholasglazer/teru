//! Targeted SIGCHLD reaper for teruwm's own direct forks.
//!
//! NEVER reap with waitpid(-1). wlroots' (lazy) Xwayland startup forks an
//! intermediate child that _exit(0)s immediately (xwayland/server.c
//! server_start), then blocking-waitpid()s that pid in xserver_handle_ready
//! once Xwayland signals readiness. A global waitpid(-1) reaper steals the
//! corpse first → wlroots gets ECHILD → it treats the (successful) startup
//! as failed, closes AND unlinks the X11 sockets, and never retries: every
//! X11 client for the rest of the session gets "Unable to open a connection
//! to X". (wlroots 0.18.3 xwayland/server.c:256-262; only EINTR is retried.)
//!
//! So teruwm only ever reaps pids it forked itself:
//!   • bar exec-widget shells (Bar.zig) — registered at fork time; the
//!     pipe's first line usually arrives before the shell exits, so the
//!     reap is inherently asynchronous
//!   • closed-pane shells — Pty.deinit sends SIGHUP but never waits;
//!     TerminalPane registers the pid at close
//! Self-exited pane shells are reaped synchronously by Pty.isAlive on PTY
//! EOF and never reach this registry (track() sees ECHILD and drops them).
//! Double-fork intermediates (ServerProcess.spawnProcess, compat.forkExec*)
//! are blocking-reaped inside the same event-loop callback that forks them
//! and must not be registered here.
//!
//! Single-threaded by construction: track()/sweep()/flushBeforeExec() all
//! run on the wl_event_loop (the SIGCHLD sweep is a signalfd source, not an
//! async signal handler), so no locking is needed.

const std = @import("std");
const posix = std.posix;

/// Generous bound: worst case is a bulk workspace close (dozens of pane
/// shells mid-SIGHUP) plus a handful of in-flight bar execs.
const max_tracked = 128;

var pending: [max_tracked]posix.pid_t = @splat(0);

/// Reap `pid` if it has already exited, otherwise remember it for the next
/// SIGCHLD sweep. Call only for children teruwm forked directly — never for
/// wlroots-internal pids.
pub fn track(pid: posix.pid_t) void {
    if (pid <= 0) return;
    // 0 → still running (track it); >0 → reaped right here; <0 (ECHILD) →
    // already reaped elsewhere (e.g. Pty.isAlive) — nothing to own.
    if (std.c.waitpid(pid, null, std.c.W.NOHANG) != 0) return;
    for (&pending) |*slot| {
        if (slot.* == 0) {
            slot.* = pid;
            return;
        }
    }
    // Registry full — not a state teruwm reaches in practice. Dropping the
    // pid leaks one zombie until process exit, which beats blocking the
    // event loop on a wait here.
    std.log.scoped(.compositor).warn("reaper registry full; pid {d} left unreaped", .{pid});
}

/// SIGCHLD sweep: WNOHANG-reap every tracked pid. Unknown children
/// (wlroots' Xwayland intermediate fork) are deliberately left alone.
pub fn sweep() void {
    for (&pending) |*slot| {
        if (slot.* == 0) continue;
        // 0 → still running, keep; anything else → reaped now or already
        // gone (ECHILD), release the slot either way.
        if (std.c.waitpid(slot.*, null, std.c.W.NOHANG) != 0) slot.* = 0;
    }
}

/// Hot-restart flush. The registry dies with this process image, but the
/// children survive execve (same PID, still our children) and the new image
/// would never reap them. Every tracked pid is already condemned — closed
/// panes got SIGHUP, bar execs are throwaway widget refreshes — so SIGKILL
/// them all, then reap with a BOUNDED wait: a child stuck in uninterruptible
/// sleep (bar exec on a hung NFS mount) ignores even SIGKILL until its I/O
/// returns, and a blocking waitpid there would freeze the restart forever.
/// A straggler is left as one zombie in the new image — annoying, not fatal.
/// Call immediately before execve.
pub fn flushBeforeExec() void {
    for (&pending) |*slot| {
        if (slot.* == 0) continue;
        posix.kill(slot.*, posix.SIG.KILL) catch {};
    }
    const compat = @import("teru").compat;
    var budget_ns: u64 = 200 * std.time.ns_per_ms; // whole-registry deadline
    for (&pending) |*slot| {
        if (slot.* == 0) continue;
        var reaped = std.c.waitpid(slot.*, null, std.c.W.NOHANG) != 0;
        while (!reaped and budget_ns > 0) {
            compat.sleepNs(1 * std.time.ns_per_ms);
            budget_ns -|= 1 * std.time.ns_per_ms;
            reaped = std.c.waitpid(slot.*, null, std.c.W.NOHANG) != 0;
        }
        if (!reaped) {
            std.log.scoped(.compositor).warn("reaper flush deadline hit; pid {d} survives into the next image as a zombie", .{slot.*});
        }
        slot.* = 0;
    }
}

test "track ignores already-reaped and non-positive pids" {
    // Non-positive pids must never enter the registry (waitpid(-1) is the
    // exact bug this module exists to prevent).
    track(0);
    track(-1);
    for (pending) |slot| try std.testing.expectEqual(@as(posix.pid_t, 0), slot);
}

test "sweep releases slots for vanished pids" {
    // A pid that is not a child of this process → waitpid returns -1
    // (ECHILD) → slot must be released, not retried forever.
    pending[3] = 999999;
    sweep();
    try std.testing.expectEqual(@as(posix.pid_t, 0), pending[3]);
}
