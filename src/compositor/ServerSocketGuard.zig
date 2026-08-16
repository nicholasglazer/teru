//! Keeps teruwm's Wayland socket *reachable*, not merely bound.
//!
//! `wl_display_add_socket_auto` binds `$XDG_RUNTIME_DIR/wayland-N` and holds a
//! flock on `wayland-N.lock`. Both are **paths**, and libwayland unlinks them by
//! name in `wl_display_destroy`. So any process that removes those paths — a
//! stray `rm -f wayland-*.lock`, or a second compositor that grabbed the
//! now-unlocked name and then unlinked it on its own clean exit — leaves this
//! compositor listening on an fd whose path is gone.
//!
//! That failure is silent and total. Already-connected clients keep rendering,
//! so the session looks perfectly healthy, while every NEW client dies with
//! `ENOENT` inside `connect()` before it ever reaches us: no browser, no new
//! terminal, no `wtype`. Nothing is logged, because from libwayland's side
//! nothing happened. Observed live 2026-08-14 (teruwm pid 2308, ~21h in); the
//! only recovery was a full compositor restart, which costs every pane.
//!
//! The guard re-checks that path on a slow timer and repairs it if it vanished.
//!
//! Repair cannot simply re-bind the same name. `wl_display_add_socket_auto`
//! skips any name whose `.lock` it cannot flock, and the lock file we took at
//! startup is still there and still ours — so a re-bind lands on `wayland-1`
//! (measured, not assumed). That alone would not help: every shell already
//! running inherited `WAYLAND_DISPLAY=wayland-0`, and libwayland exposes no way
//! to drop a socket and reclaim the original name. So we bind the replacement
//! and then **symlink the original name onto it** — `connect(2)` resolves
//! symlinks, so old and new clients both land here.
//!
//! The watched path therefore stays the name clients actually use, for the life
//! of the process. `access(2)` follows symlinks, so a dangling link (someone
//! deleted the replacement) trips the guard exactly like a deleted socket.
//!
//! Known gap: this detects *deletion*, not *substitution*. If another
//! compositor takes over the name while we are still running, the path exists
//! and the guard stays quiet even though new clients are reaching the other
//! process. Catching that needs an inode comparison (`stat` at bind time vs.
//! now), which is worth adding if it is ever observed in the wild.

const std = @import("std");
const teru = @import("teru");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const compat = teru.compat;

const log = std.log.scoped(.compositor);

/// How often to confirm the socket path still exists. Deliberately slow: this
/// guards against an out-of-band `unlink`, not against anything on a hot path.
/// One `access(2)` per 15s is far below the noise floor, and the event-driven
/// alternative (an inotify watch on `$XDG_RUNTIME_DIR`) would cost an extra fd
/// plus event source to answer the same question.
const check_interval_ms: c_int = 15_000;

/// Record the socket we just bound and arm the guard. A null event loop
/// (pre-init, or a test harness) simply leaves the guard disarmed.
pub fn start(server: *Server, socket_name: []const u8) void {
    if (!setPath(server, socket_name)) return;

    const loop = server.event_loop orelse return;
    server.socket_guard_src = wlr.wl_event_loop_add_timer(loop, tick, @ptrCast(server));
    if (server.socket_guard_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, check_interval_ms);
    }
}

/// Store `$XDG_RUNTIME_DIR/<socket_name>` NUL-terminated in the server.
/// Returns false when the path is unavailable or too long to hold, in which
/// case the guard stays off rather than watching a truncated path.
fn setPath(server: *Server, socket_name: []const u8) bool {
    const runtime_dir = compat.getenv("XDG_RUNTIME_DIR") orelse {
        log.warn("XDG_RUNTIME_DIR unset — Wayland socket guard disabled", .{});
        return false;
    };

    // Format into all but the final byte: the field is zero-initialised and
    // never fully written, so the NUL terminator is always present.
    const room = server.wl_socket_path[0 .. server.wl_socket_path.len - 1];
    _ = std.fmt.bufPrint(room, "{s}/{s}", .{ runtime_dir, socket_name }) catch {
        log.warn("Wayland socket path too long — guard disabled", .{});
        server.wl_socket_path[0] = 0;
        return false;
    };
    return true;
}

fn tick(data: ?*anyopaque) callconv(.c) c_int {
    const server: *Server = @ptrCast(@alignCast(data orelse return 0));
    if (server.shutting_down) return 0;

    const path: [*:0]const u8 = @ptrCast(&server.wl_socket_path);
    if (wlr.access(path, wlr.F_OK) != 0 and !heal(server)) {
        // Re-bind failed and will keep failing. Leave the timer disarmed
        // (a wl timer is one-shot) instead of logging this every 15s forever.
        return 0;
    }

    if (server.socket_guard_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, check_interval_ms);
    }
    return 0;
}

/// Bind a replacement socket and point the original name at it. Returns false
/// if the display refuses a new socket — nothing further this process can do,
/// so the caller stops re-checking.
///
/// `server.wl_socket_path` is left untouched: it names what clients connect to,
/// which is precisely what we are restoring.
fn heal(server: *Server) bool {
    const path: [*:0]const u8 = @ptrCast(&server.wl_socket_path);
    log.err("Wayland socket {s} vanished from disk — new clients cannot connect; repairing", .{
        std.mem.sliceTo(&server.wl_socket_path, 0),
    });

    const sock = wlr.wl_display_add_socket_auto(server.display) orelse {
        log.err("binding a replacement Wayland socket failed — restart teruwm to recover", .{});
        return false;
    };
    const name = std.mem.sliceTo(sock, 0);

    // Relative target: the replacement always lands beside the original in
    // $XDG_RUNTIME_DIR, and a relative link survives the directory being
    // reached through a different path (a bind mount, a container view).
    if (wlr.symlink(sock, path) == 0) {
        log.warn("Wayland socket repaired: bound {s} and linked the original name to it", .{name});
        return true;
    }

    // EEXIST: a stale directory entry holds the name. The usual case is the
    // dangling link left by an earlier repair whose target was later deleted —
    // `symlink` refuses to overwrite it, so without this the original name
    // stays dead through every subsequent repair.
    //
    // Re-test before removing anything: we only clear the entry if it STILL
    // fails to resolve. If something recreated a working socket between the
    // tick's access() and now, it keeps it — never unlink a live socket.
    if (wlr.access(path, wlr.F_OK) != 0) {
        _ = wlr.unlink(path);
        if (wlr.symlink(sock, path) == 0) {
            log.warn("Wayland socket repaired: bound {s} and relinked the original name (cleared a stale entry)", .{name});
            return true;
        }
    }

    // Path is occupied by something live, or the directory is not writable.
    // The replacement socket still works, so at least hand new children a name
    // that resolves rather than leaving them pointed at nothing.
    _ = wlr.setenv("WAYLAND_DISPLAY", sock, 1);
    log.warn("bound replacement Wayland socket {s}, but could not link the original name to it — only new clients recover", .{name});
    return true;
}
