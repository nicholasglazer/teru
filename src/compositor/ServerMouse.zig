//! Synthetic mouse trajectories for automation.
//!
//! The naive warp-then-press implementation (teruwm_test_move /
//! teruwm_test_drag) teleports the cursor in a single step, which
//! reads as "this is a bot" to any web page that looks at
//! mousemove distribution, velocity curves, or straight-line ratios.
//! This module produces a path that looks like a person moved the
//! mouse:
//!
//!   * Cubic Bezier interpolation between from and to, with the two
//!     control points offset perpendicular to the straight line by a
//!     random jitter (≈ 10-25% of travel distance). Produces a
//!     curve that overshoots and corrects like a real hand.
//!   * Ease-in-out cubic timing — slow acceleration, faster middle,
//!     slow deceleration. Constant-velocity paths are bot-tell #1.
//!   * Per-waypoint ±1–3 px tremor drawn from a normal-ish
//!     distribution (three-sample average of uniform noise).
//!   * Press + release timing within the path — press after ~20–35 %
//!     of the journey (so browsers see motion → hover → press,
//!     not warp → press), release at end.
//!
//! Timing model: each waypoint is emitted from a wl_event_loop TIMER
//! (`per_sample_ms` apart, ~60 Hz), NOT a busy `nanosleep`. teruwm is a
//! single-threaded compositor — sleeping between waypoints would PARK
//! the one event-loop thread for the whole gesture, so libinput (the
//! user's real touchpad/keyboard) goes unread for `duration_ms` and the
//! pointer visibly freezes then jumps. The timer keeps the loop
//! dispatching real input between every waypoint. Per-path state lives
//! in `Server.mouse_path`; the shared timer in `Server.mouse_path_timer_src`.
//!
//! Contract: humanized paths are ASYNCHRONOUS — `pathMove` returns once
//! the path is *scheduled* (after emitting waypoint 0) and the remaining
//! waypoints fire from the timer over ~`duration_ms`. Callers needing the
//! gesture complete must wait ~`duration_ms` (same async shape as
//! teruwm_restart). The teleport fallback (humanize=false, or sub-pixel
//! moves) is still synchronous and complete on return.
//!   * RNG seeds from monotonicNow, so successive paths vary.

const std = @import("std");
const teru = @import("teru");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const MAX_SAMPLES: u32 = 240;

/// In-flight humanized-path state, owned by `Server.mouse_path`. One path
/// runs at a time; starting another cancels the old (releasing any held
/// button first — see `cancelMousePath`) and reuses the timer source.
pub const MousePathState = struct {
    active: bool = false,
    // Bezier endpoints + control points (output-global pixel coords).
    fx: f64 = 0,
    fy: f64 = 0,
    tx: f64 = 0,
    ty: f64 = 0,
    c1x: f64 = 0,
    c1y: f64 = 0,
    c2x: f64 = 0,
    c2y: f64 = 0,
    dist: f64 = 0,
    samples: u32 = 0,
    idx: u32 = 0,
    per_sample_ms: u32 = 1,
    press_idx: u32 = std.math.maxInt(u32),
    button: ?u32 = null,
    super_held: bool = false,
    pressed: bool = false,
    // Snapshotted AFTER the setup draws (off1/off2/press jitter) so the
    // per-waypoint tremor sequence matches the original inline loop.
    prng: std.Random.DefaultPrng = undefined,
};

/// Move cursor from (from_x, from_y) to (to_x, to_y) along a humanised
/// Bezier path. If `button` is non-null, press it partway through the
/// path and release at the end. If `humanize` is false, fall back to
/// the teleport+warp path (two processCursorMotion calls).
///
/// Returns true when the move was SCHEDULED asynchronously (a humanized
/// path now driving from the timer), false when it completed
/// synchronously (teleport / sub-pixel fallback / degenerate sample
/// count).
pub fn pathMove(
    server: *Server,
    from_x: i32,
    from_y: i32,
    to_x: i32,
    to_y: i32,
    duration_ms: u32,
    humanize: bool,
    button: ?u32,
    super_held: bool,
) bool {
    if (!humanize) {
        teleport(server, from_x, from_y, to_x, to_y, button, super_held);
        return false;
    }
    return curvedPath(server, from_x, from_y, to_x, to_y, duration_ms, button, super_held);
}

// ── Private ──────────────────────────────────────────────────

fn teleport(server: *Server, fx: i32, fy: i32, tx: i32, ty: i32, button: ?u32, super_held: bool) void {
    const t0 = nowMs();
    wlr.wlr_cursor_warp_closest(server.cursor, null, @floatFromInt(fx), @floatFromInt(fy));
    server.processCursorMotion(t0);
    if (button) |b| {
        server.processCursorButton(b, 1, t0 +% 5, super_held);
        wlr.wlr_cursor_warp_closest(server.cursor, null, @floatFromInt(tx), @floatFromInt(ty));
        server.processCursorMotion(t0 +% 10);
        server.processCursorButton(b, 0, t0 +% 20, super_held);
    } else {
        wlr.wlr_cursor_warp_closest(server.cursor, null, @floatFromInt(tx), @floatFromInt(ty));
        server.processCursorMotion(t0 +% 10);
    }
}

/// Compute the curve, emit waypoint 0, and arm the timer for the rest.
/// Returns true if a timer was armed (async path in flight), false if the
/// move completed inline (degenerate / no event loop).
fn curvedPath(
    server: *Server,
    fx_i: i32,
    fy_i: i32,
    tx_i: i32,
    ty_i: i32,
    duration_ms: u32,
    button: ?u32,
    super_held: bool,
) bool {
    const fx: f64 = @floatFromInt(fx_i);
    const fy: f64 = @floatFromInt(fy_i);
    const tx: f64 = @floatFromInt(tx_i);
    const ty: f64 = @floatFromInt(ty_i);
    const dx = tx - fx;
    const dy = ty - fy;
    const dist = @sqrt(dx * dx + dy * dy);
    if (dist < 1.0) {
        teleport(server, fx_i, fy_i, tx_i, ty_i, button, super_held);
        return false;
    }

    // A fresh path supersedes any in-flight one — release a held button
    // first so we never leak a press, then reuse the (disarmed) timer.
    cancelMousePath(server);

    // RNG seeded from monotonic clock — path varies between calls
    // without needing a persistent Server field.
    const seed_raw = teru.compat.monotonicNow();
    var prng = std.Random.DefaultPrng.init(@bitCast(@as(i64, @truncate(seed_raw))));
    const rng = prng.random();

    // Perpendicular unit vector — direction of control-point offset.
    const perp_x = -dy / dist;
    const perp_y = dx / dist;

    // Two control points at 1/3 and 2/3 along the straight line,
    // each offset perpendicularly by a random ± 0.10..0.25 × dist.
    const off1 = (rng.float(f64) - 0.5) * dist * 0.35;
    const off2 = (rng.float(f64) - 0.5) * dist * 0.35;
    const c1x = fx + dx * 0.333 + perp_x * off1;
    const c1y = fy + dy * 0.333 + perp_y * off1;
    const c2x = fx + dx * 0.667 + perp_x * off2;
    const c2y = fy + dy * 0.667 + perp_y * off2;

    // Sample count: target ~60 Hz. Clamp to [8, 240] so a tiny move
    // still has some curve and a huge one doesn't burst. Compute in u64: a
    // hostile/huge MCP-supplied duration_ms would overflow `duration_ms * 60`
    // in u32 (panic) BEFORE the @min clamp could bound it.
    const samples: u32 = @intCast(@max(@as(u64, 8), @min(@as(u64, MAX_SAMPLES), @as(u64, duration_ms) * 60 / 1000)));
    const per_sample_ns: u64 = (@as(u64, duration_ms) * 1_000_000) / @max(1, samples);
    // wl_event_loop timers are millisecond-granularity; floor at 1ms
    // (0 would disarm the timer). ~16ms at the default 250ms/15-sample.
    const per_sample_ms: u32 = @intCast(@max(1, per_sample_ns / 1_000_000));

    // Button press roughly 25 % through the path (with jitter).
    const press_idx: u32 = if (button != null)
        @intCast(@min(samples - 1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(samples)) * (0.20 + rng.float(f64) * 0.15)))))
    else
        std.math.maxInt(u32);

    const st = &server.mouse_path;
    st.* = .{
        .active = true,
        .fx = fx,
        .fy = fy,
        .tx = tx,
        .ty = ty,
        .c1x = c1x,
        .c1y = c1y,
        .c2x = c2x,
        .c2y = c2y,
        .dist = dist,
        .samples = samples,
        .idx = 0,
        .per_sample_ms = per_sample_ms,
        .press_idx = press_idx,
        .button = button,
        .super_held = super_held,
        .pressed = false,
        // `prng` is advanced past the off1/off2/press_idx draws above, so
        // the per-waypoint tremor sequence is identical to the old loop.
        .prng = prng,
    };

    // Emit waypoint 0 inline (matches the original "sample then sleep"
    // cadence), then drive waypoints 1..samples-1 from the timer.
    emitSample(server, st, 0);
    st.idx = 1;

    if (samples <= 1) {
        finishPath(server, st);
        return false;
    }

    if (server.mouse_path_timer_src == null) {
        const loop = server.event_loop orelse {
            finishPath(server, st); // no loop (pre-init) → don't strand a half-applied path
            return false;
        };
        server.mouse_path_timer_src = wlr.wl_event_loop_add_timer(loop, mousePathTick, @ptrCast(server));
        if (server.mouse_path_timer_src == null) {
            finishPath(server, st);
            return false;
        }
    }
    if (server.mouse_path_timer_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, @intCast(per_sample_ms));
    }
    return true;
}

/// Compute + emit waypoint `i`: warp the cursor, notify motion, and fire
/// the button press when `i == press_idx`. Advances `st.prng` by the two
/// tremor draws exactly as the original inline loop did.
fn emitSample(server: *Server, st: *MousePathState, i: u32) void {
    const denom: f64 = @floatFromInt(@max(1, st.samples - 1));
    const u = @as(f64, @floatFromInt(i)) / denom;
    const t = easeInOutCubic(u);

    // Cubic Bezier evaluation
    const mt = 1.0 - t;
    const b = mt * mt * mt;
    const c = 3.0 * mt * mt * t;
    const d = 3.0 * mt * t * t;
    const e = t * t * t;
    const bx = b * st.fx + c * st.c1x + d * st.c2x + e * st.tx;
    const by = b * st.fy + c * st.c1y + d * st.c2y + e * st.ty;

    // Per-waypoint tremor. Three-sample average approximates a gaussian
    // with σ≈0.4 px for tremor_amp=1; scale up a bit on long moves.
    const tremor_amp = 1.5 + @min(2.0, st.dist / 500.0);
    // Re-derive the std.Random from st.prng each tick — do NOT cache it
    // across ticks (it holds a pointer to st.prng). The draws advance
    // st.prng in place, continuing the sequence from curvedPath's setup.
    const rng = st.prng.random();
    const jx = bx + tremor(rng, tremor_amp);
    const jy = by + tremor(rng, tremor_amp);

    wlr.wlr_cursor_warp_closest(server.cursor, null, jx, jy);
    server.processCursorMotion(nowMs());

    if (i == st.press_idx and !st.pressed) {
        if (st.button) |btn| server.processCursorButton(btn, 1, nowMs(), st.super_held);
        st.pressed = true;
    }
}

/// Last waypoint reached (or path cancelled): release a held button and
/// mark the path inactive. Does NOT touch the timer source.
fn finishPath(server: *Server, st: *MousePathState) void {
    if (st.button) |btn| {
        if (st.pressed) server.processCursorButton(btn, 0, nowMs() +% 5, st.super_held);
    }
    st.active = false;
}

/// Timer tick: emit the next waypoint and re-arm until the path is done.
/// Returns 0 per the wayland-server timer ABI; the source stays armed
/// with whatever `timer_update` set last (disarmed via 0 when finished).
fn mousePathTick(data: ?*anyopaque) callconv(.c) c_int {
    const server: *Server = @ptrCast(@alignCast(data orelse return 0));
    const st = &server.mouse_path;
    if (!st.active) return 0;

    emitSample(server, st, st.idx);
    st.idx += 1;

    if (st.idx >= st.samples) {
        finishPath(server, st);
        if (server.mouse_path_timer_src) |src| _ = wlr.wl_event_source_timer_update(src, 0);
        return 0;
    }
    if (server.mouse_path_timer_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, @intCast(st.per_sample_ms));
    }
    return 0;
}

/// Cancel any in-flight path, releasing a held button so a superseding
/// path never leaks a press. Leaves the timer source allocated but
/// disarmed for reuse (Server.deinit removes it).
fn cancelMousePath(server: *Server) void {
    const st = &server.mouse_path;
    if (st.active) finishPath(server, st);
    if (server.mouse_path_timer_src) |src| _ = wlr.wl_event_source_timer_update(src, 0);
}

fn easeInOutCubic(t: f64) f64 {
    if (t < 0.5) return 4.0 * t * t * t;
    const s = -2.0 * t + 2.0;
    return 1.0 - (s * s * s) / 2.0;
}

/// Three-sample average of [-1, 1] uniform — roughly gaussian with σ≈0.4.
fn tremor(rng: std.Random, amp: f64) f64 {
    const a = rng.float(f64) * 2.0 - 1.0;
    const b = rng.float(f64) * 2.0 - 1.0;
    const c = rng.float(f64) * 2.0 - 1.0;
    return ((a + b + c) / 3.0) * amp;
}

fn nowMs() u32 {
    const ns_per_ms: i128 = 1_000_000;
    const ns: i128 = teru.compat.monotonicNow();
    return @intCast(@mod(@divTrunc(ns, ns_per_ms), 0xFFFFFFFF));
}
