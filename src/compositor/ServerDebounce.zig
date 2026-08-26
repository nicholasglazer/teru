//! Pointer-button debounce — a guard against contact chatter from a worn
//! micro-switch.
//!
//! A failing switch opens for a moment mid-hold, so the kernel reports a
//! RELEASE followed by a PRESS a few milliseconds later. Every client sees
//! the hold break: a game stops firing, a drag-select drops, a slider lets
//! go. libinput ships its own filter, but its release-side window is 12 ms
//! and only arms *after* it has already watched the button bounce once, so a
//! badly worn switch leaks straight through it.
//!
//! The filter holds a RELEASE for `mouse_debounce_ms`. If a PRESS for the
//! same button lands inside that window the pending release is dropped and
//! the press is swallowed, so the client never learns the hold broke.
//! Presses are never delayed — click latency is untouched.
//!
//! ## Why it only guards holds
//!
//! A window wide enough to catch real chatter is also wide enough to swallow
//! the gap in a fast double-click, merging two clicks into one long press.
//! So a release is only held when it ends a press that lasted at least
//! `mouse_debounce_hold_ms` — a tap's release goes straight through and
//! double-click spacing is never touched. This matches how the failure
//! actually presents: single clicks are fine, holds die.
//!
//! A swallowed press deliberately does *not* restart the hold clock. The
//! press time stays at the start of the original hold, so every later
//! fragment of a bouncing spray still counts as a hold and stays guarded,
//! with no separate "is this switch currently bouncing" latch to age out.
//!
//! Off by default. This is a workaround for failing hardware, not something
//! a healthy mouse should pay latency for.

const std = @import("std");
const wlr = @import("wlr.zig");
const teru = @import("teru");
const Server = @import("Server.zig");
const Cursor = @import("ServerCursor.zig");

const log = std.log.scoped(.compositor);

/// Buttons trackable at once — enough for every button on an ordinary mouse
/// (left/right/middle/side/extra).
pub const max_pending = 5;

/// A release held back, waiting to see whether the switch bounces.
pub const Pending = struct {
    button: u32 = 0,
    /// wlroots event time for the deferred release, already advanced by the
    /// window so the seat never sees a timestamp travel backwards.
    time: u32 = 0,
    deadline_ms: u64 = 0,
    active: bool = false,
};

/// When each held button went down, so a release can tell a tap from a hold.
pub const Press = struct {
    button: u32 = 0,
    at_ms: u64 = 0,
    active: bool = false,
};

fn nowMs() u64 {
    return @intCast(@divTrunc(teru.compat.monotonicNow(), std.time.ns_per_ms));
}

fn findPending(server: *Server, button: u32) ?*Pending {
    for (&server.debounce_pending) |*p| {
        if (p.active and p.button == button) return p;
    }
    return null;
}

fn findPress(server: *Server, button: u32) ?*Press {
    for (&server.debounce_press) |*p| {
        if (p.active and p.button == button) return p;
    }
    return null;
}

// ── Pure state machine (testable without a live Server) ────────

pub const Action = enum {
    /// Pass the event through untouched.
    forward,
    /// Stash the release and arm the timer; nothing reaches the client yet.
    hold_release,
    /// A press landed on top of a held release: the switch bounced. Drop
    /// both, leaving the client's view of the button continuously down.
    swallow_press,
};

pub fn decide(
    window_ms: u32,
    hold_min_ms: u32,
    state: u32,
    has_pending: bool,
    hold_ms: u64,
) Action {
    if (window_ms == 0) return .forward;
    if (state != 0) return if (has_pending) .swallow_press else .forward;
    // Release. Guard it only if it ends a real hold; a tap goes straight
    // through so double-click spacing is never merged.
    if (hold_ms < hold_min_ms) return .forward;
    return .hold_release;
}

/// Timestamp to report for a release we held back. Advancing it by the window
/// keeps the seat's clock monotonic: any motion event that arrived while the
/// release was parked carries a stamp below this one. Wrapping is deliberate —
/// wlroots event time is a u32 that rolls over about every 49.7 days.
pub fn deferredTime(time: u32, window_ms: u32) u32 {
    return time +% window_ms;
}

// ── Live filter ────────────────────────────────────────────────

/// Filter one pointer button event. Returns true when the event has been
/// consumed and the caller must not forward it.
pub fn gate(server: *Server, button: u32, state: u32, time: u32) bool {
    const window = server.wm_config.mouse_debounce_ms;
    if (window == 0) return false; // feature off: no state, no cost

    const now = nowMs();
    const pending = findPending(server, button);
    const press = findPress(server, button);
    const hold_ms: u64 = if (press) |p| now -| p.at_ms else 0;

    switch (decide(window, server.wm_config.mouse_debounce_hold_ms, state, pending != null, hold_ms)) {
        .swallow_press => {
            pending.?.active = false;
            server.debounce_suppressed += 1;
            // The hold clock is intentionally left alone — see the module
            // comment: the spray is one continuous hold, not a new press.
            log.info(
                "mouse debounce: bounce swallowed on button {d} after {d} ms of hold (total {d})",
                .{ button, hold_ms, server.debounce_suppressed },
            );
            rearm(server);
            return true;
        },
        .hold_release => {
            // Out of slots (more buttons down than a real mouse has) degrades
            // to passing the release through rather than losing it.
            const slot = blk: {
                for (&server.debounce_pending) |*p| {
                    if (!p.active) break :blk p;
                }
                break :blk null;
            } orelse return false;
            slot.* = .{
                .button = button,
                .time = deferredTime(time, window),
                .deadline_ms = now + window,
                .active = true,
            };
            rearm(server);
            return true;
        },
        .forward => {
            if (state != 0) {
                // A genuine press starts a new hold clock.
                if (press) |p| {
                    p.at_ms = now;
                } else for (&server.debounce_press) |*p| {
                    if (!p.active) {
                        p.* = .{ .button = button, .at_ms = now, .active = true };
                        break;
                    }
                }
            } else if (press) |p| {
                p.active = false; // hold over
            }
            return false;
        },
    }
}

/// Arm the timer for the earliest pending deadline, or disarm when nothing
/// is in flight. One shared timer covers all buttons.
fn rearm(server: *Server) void {
    var soonest: ?u64 = null;
    for (&server.debounce_pending) |*p| {
        if (!p.active) continue;
        if (soonest == null or p.deadline_ms < soonest.?) soonest = p.deadline_ms;
    }

    const deadline = soonest orelse {
        if (server.debounce_timer_src) |src| _ = wlr.wl_event_source_timer_update(src, 0);
        return;
    };

    if (server.debounce_timer_src == null) {
        const loop = server.event_loop orelse return;
        server.debounce_timer_src = wlr.wl_event_loop_add_timer(loop, onTimer, @ptrCast(server));
        if (server.debounce_timer_src == null) return;
    }
    const now = nowMs();
    // +1 so the deadline has strictly passed when the callback runs; a 0 delay
    // means "disarm" to wl_event_source_timer_update, never "fire now".
    const delay: c_int = @intCast(@min(
        if (deadline > now) deadline - now + 1 else 1,
        std.math.maxInt(c_int),
    ));
    _ = wlr.wl_event_source_timer_update(server.debounce_timer_src.?, delay);
}

/// Deadline reached with no bounce — the release was genuine, so forward it.
fn onTimer(data: ?*anyopaque) callconv(.c) c_int {
    const server: *Server = @ptrCast(@alignCast(data orelse return 0));
    const now = nowMs();
    for (&server.debounce_pending) |*p| {
        if (!p.active or p.deadline_ms > now) continue;
        const button = p.button;
        const time = p.time;
        // Clear before dispatching: processCursorButton can re-enter this
        // module, and it must not find a slot that is already spent.
        p.active = false;
        if (findPress(server, button)) |press| press.active = false;
        Cursor.processCursorButton(server, button, 0, time, null);
    }
    rearm(server);
    return 0;
}

/// Forward every held release immediately, so a button can't be left stuck
/// down when the filter is turned off by a config reload or on teardown.
pub fn flush(server: *Server) void {
    for (&server.debounce_pending) |*p| {
        if (!p.active) continue;
        const button = p.button;
        const time = p.time;
        p.active = false;
        if (findPress(server, button)) |press| press.active = false;
        Cursor.processCursorButton(server, button, 0, time, null);
    }
    rearm(server);
}

// ── Tests ──────────────────────────────────────────────────────

const testing = std.testing;

test "decide: a zero window forwards everything" {
    try testing.expectEqual(Action.forward, decide(0, 150, 1, false, 0));
    try testing.expectEqual(Action.forward, decide(0, 150, 0, false, 5_000));
    // Even with a stale pending entry, a zero window must not consume.
    try testing.expectEqual(Action.forward, decide(0, 150, 1, true, 0));
}

test "decide: a tap's release is never held, so double-click survives" {
    // 80 ms press = a click. Releasing it must reach the client immediately,
    // or the gap before the second click of a double-click gets swallowed.
    try testing.expectEqual(Action.forward, decide(60, 150, 0, false, 80));
}

test "decide: a hold's release is guarded" {
    try testing.expectEqual(Action.hold_release, decide(60, 150, 0, false, 150));
    try testing.expectEqual(Action.hold_release, decide(60, 150, 0, false, 2_000));
}

test "decide: hold threshold of zero guards every release" {
    try testing.expectEqual(Action.hold_release, decide(60, 0, 0, false, 0));
}

test "decide: press swallows only while a release is in flight" {
    // Bounce: the release is still parked, so this press is the switch
    // re-closing, not the user re-clicking.
    try testing.expectEqual(Action.swallow_press, decide(60, 150, 1, true, 2_000));
    // Genuine click: nothing parked, so it must reach the client.
    try testing.expectEqual(Action.forward, decide(60, 150, 1, false, 0));
}

test "deferredTime advances past any event queued during the hold" {
    try testing.expectEqual(@as(u32, 1060), deferredTime(1000, 60));
    // A motion event at t=1050 (inside the window) still sorts before the
    // release we finally emit, so the seat clock never goes backwards.
    try testing.expect(deferredTime(1000, 60) > 1050);
}

test "deferredTime wraps with the u32 event clock" {
    const near_wrap: u32 = std.math.maxInt(u32) - 5;
    try testing.expectEqual(@as(u32, 54), deferredTime(near_wrap, 60));
}
