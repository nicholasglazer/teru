//! Native-pane clipboard for teruwm — Ctrl+Shift+C / Ctrl+Shift+V.
//!
//! Copy: the focused terminal's drag selection (falling back to the cursor
//! line, the pre-existing behavior) is published as a compositor-owned
//! wlr_data_source on the seat — so Wayland AND Xwayland clients can paste
//! it — and mirrored into the internal buffer. A "Copied to clipboard"
//! toast lands in the bar's `{notify}` widget, matching standalone teru's
//! status-bar feedback.
//!
//! Paste: reads the CURRENT seat selection. Three paths:
//!   * teruwm still owns it (own text source) → internal buffer, zero-copy,
//!     no pipe round-trip to ourselves.
//!   * a foreign client source → pipe + wlr_data_source_send + an async
//!     wl_event_loop fd read (never blocks the compositor), then teru's
//!     Clipboard.pasteText (binary guard + sanitise + bracketed wrap + the
//!     short-write retry that guarantees the closing `\x1b[201~`).
//!   * no selection / non-text selection → internal buffer fallback.
//!
//! Free functions over *Server, same split convention as ServerCursor /
//! ServerRestart. The in-flight paste state lives on Server (paste_* fields)
//! and MUST be drained on shutdown via cancelInflight — see Bar.cleanupExec
//! for the epoll-spin hazard this avoids.

const std = @import("std");
const teru = @import("teru");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");

/// Copy the focused terminal's selection (or cursor line) to the seat
/// selection + the internal buffer, and toast the result.
pub fn copySelection(server: *Server, tp: *TerminalPane) void {
    var buf: [65536]u8 = undefined;
    var n: usize = 0;
    if (tp.selection.active) {
        n = tp.selection.getText(&tp.pane.grid, tp.pane.grid.scrollback, &buf);
    }
    if (n == 0) {
        // No drag selection — keep the old cursor-line copy semantics.
        server.clipboardCopyCursorLine(tp);
        n = server.clipboard_len;
        if (n == 0) return;
        @memcpy(buf[0..n], server.clipboard_buf[0..n]);
    } else {
        // Mirror into the internal buffer (paste fast path + fallback).
        // Same 64 KiB capacity as the published selection — no truncation.
        const m = @min(n, server.clipboard_buf.len);
        @memcpy(server.clipboard_buf[0..m], buf[0..m]);
        server.clipboard_len = m;
    }

    if (wlr.miozu_set_clipboard_text(server.seat, server.display, &buf, n) != 0) {
        std.log.scoped(.compositor).warn("clipboard: failed to publish text selection", .{});
    }
    server.setNotification("", "Copied to clipboard", "", .normal, 1500);
}

/// Paste the internal buffer (our own last copy) through the same
/// sanitise/bracket/short-write-retry path foreign pastes get, so a
/// >4 KiB self-paste can't drop its closing `\x1b[201~` the way the old
/// fire-and-forget writeInput could.
fn pasteInternal(server: *Server, tp: *TerminalPane) void {
    if (server.clipboard_len == 0) return;
    teru.Clipboard.pasteText(&tp.pane, server.clipboard_buf[0..server.clipboard_len]);
    // Same echo-poll nudge TerminalPane.writeInput does.
    server.frames_since_pty_input = 0;
    server.scheduleRender();
}

/// Paste the current seat selection into `tp`'s PTY.
pub fn paste(server: *Server, tp: *TerminalPane) void {
    // One in-flight paste at a time; a new request supersedes the old.
    cancelInflight(server);

    const src = wlr.miozu_seat_selection_source(server.seat) orelse {
        pasteInternal(server, tp);
        return;
    };
    if (wlr.miozu_selection_is_own_text(server.seat) != 0) {
        pasteInternal(server, tp);
        return;
    }
    const mime = wlr.miozu_data_source_pick_text_mime(src) orelse {
        // Non-text selection (e.g. a screenshot PNG) — nothing a terminal
        // can take; fall back to the last internal text copy.
        pasteInternal(server, tp);
        return;
    };

    var fds: [2]c_int = .{ -1, -1 };
    if (std.c.pipe(&fds) != 0) return;

    // Read end: non-blocking (pasteReadable loops until EAGAIN/EOF) +
    // CLOEXEC (a shell forkExec'd or a hot-restart execve while a drain is
    // in flight must not inherit the pipe — an inherited read end would
    // also keep the foreign writer from ever seeing EPIPE). If the fcntl
    // setup fails, bail rather than risk a BLOCKING read wedging the
    // whole event loop in pasteReadable.
    const fl = std.c.fcntl(fds[0], std.posix.F.GETFL);
    const fd_ok = fl >= 0 and
        std.c.fcntl(fds[0], std.posix.F.SETFL, fl | teru.compat.O_NONBLOCK) >= 0 and
        std.c.fcntl(fds[0], std.posix.F.SETFD, @as(c_int, 1)) >= 0; // FD_CLOEXEC
    if (!fd_ok) {
        _ = std.posix.system.close(fds[0]);
        _ = std.posix.system.close(fds[1]);
        pasteInternal(server, tp);
        return;
    }

    // Hand the write end to the selection owner; it streams the bytes.
    // OWNERSHIP: wlr_data_source_send closes the fd (wlr_data_device.h:
    // "...then close it") — a Wayland client source closes synchronously
    // after marshalling, but an XWAYLAND source keeps it open for the
    // async INCR transfer. Closing it here ourselves broke X11-app →
    // native-pane paste (instant EOF) and double-closed a recyclable fd
    // number out from under wlroots' xwm.
    wlr.wlr_data_source_send(src, mime, fds[1]);

    const el = server.event_loop orelse {
        _ = std.posix.system.close(fds[0]);
        return;
    };
    server.paste_fd = fds[0];
    server.paste_len = 0;
    server.paste_target_node = tp.node_id;
    server.paste_event_source = wlr.wl_event_loop_add_fd(
        el,
        fds[0],
        wlr.WL_EVENT_READABLE,
        pasteReadable,
        @ptrCast(server),
    );
    if (server.paste_event_source == null) {
        _ = std.posix.system.close(fds[0]);
        server.paste_fd = -1;
    }
}

/// Accumulate pipe chunks until EOF, then deliver. Unlike the single-read
/// bar exec widgets, a paste can span many pipe buffers — keep reading
/// until read() returns 0 (EOF) or EAGAIN (more later).
fn pasteReadable(fd: c_int, mask: u32, data: ?*anyopaque) callconv(.c) c_int {
    _ = mask; // read() distinguishes data / EOF / EAGAIN; HANGUP co-occurs at EOF.
    const server: *Server = @ptrCast(@alignCast(data orelse return 0));
    while (true) {
        const remaining = server.paste_buf.len - server.paste_len;
        if (remaining == 0) {
            // Cap reached (64 KiB, same as teru's max paste) — deliver
            // truncated rather than buffering unboundedly.
            finishPaste(server);
            return 0;
        }
        const n = std.c.read(fd, server.paste_buf[server.paste_len..].ptr, remaining);
        if (n > 0) {
            server.paste_len += @intCast(n);
            continue;
        }
        if (n == 0) {
            finishPaste(server); // EOF — the full selection has arrived
            return 0;
        }
        switch (std.posix.errno(n)) {
            .INTR => continue,
            .AGAIN => return 0, // wait for the next READABLE
            else => {
                finishPaste(server); // deliver what we have
                return 0;
            },
        }
    }
}

/// Tear down the watcher, then write the accumulated text into the pane
/// that requested the paste — re-resolved by node id, since focus can
/// change while the pipe drains (pane gone → drop silently).
fn finishPaste(server: *Server) void {
    const len = server.paste_len;
    const target = server.paste_target_node;
    cancelInflight(server);
    if (len == 0) return;
    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            if (tp.node_id == target) {
                teru.Clipboard.pasteText(&tp.pane, server.paste_buf[0..len]);
                // Same echo-poll nudge TerminalPane.writeInput does.
                server.frames_since_pty_input = 0;
                server.scheduleRender();
                return;
            }
        }
    }
}

/// Cancel/tear down the in-flight paste watcher. Mirrors Bar.cleanupExec:
/// wl_event_source_remove is MANDATORY — libwayland ignores fd-callback
/// return values, so an EOF'd pipe left registered re-fires every dispatch
/// (100% CPU spin) and leaks the fd.
///
/// Shutdown: called from a main.zig defer registered AFTER the
/// wl_display_destroy defer, i.e. it runs BEFORE the display (and its
/// event loop) is destroyed. It must NOT run from Server.deinit — deinit
/// runs after wl_display_destroy, and wl_event_source_remove on a freed
/// event loop is a use-after-free write.
pub fn cancelInflight(server: *Server) void {
    if (server.paste_event_source) |es| _ = wlr.wl_event_source_remove(es);
    server.paste_event_source = null;
    if (server.paste_fd != -1) _ = std.posix.system.close(server.paste_fd);
    server.paste_fd = -1;
    server.paste_len = 0;
    server.paste_target_node = 0;
}
