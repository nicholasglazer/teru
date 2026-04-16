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
//!   * Real wall-clock `nanosleep` between samples so velocity
//!     matches the curve. Target ~60 samples/sec.
//!   * Press + release timing within the path — press after ~20–35 %
//!     of the journey (so browsers see motion → hover → press,
//!     not warp → press), release at end.
//!
//! Caveats:
//!   * Blocks the wl_event_loop for `duration_ms` — callers pick a
//!     sensible value (default 250 ms). Keeps things simple vs
//!     spreading the path across frame callbacks.
//!   * RNG seeds from monotonicNow, so successive paths vary.

const std = @import("std");
const teru = @import("teru");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

/// Move cursor from (from_x, from_y) to (to_x, to_y) along a humanised
/// Bezier path. If `button` is non-null, press it partway through the
/// path and release at the end. If `humanize` is false, fall back to
/// the current teleport+warp path (two processCursorMotion calls).
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
) void {
    if (!humanize) {
        teleport(server, from_x, from_y, to_x, to_y, button, super_held);
        return;
    }
    curvedPath(server, from_x, from_y, to_x, to_y, duration_ms, button, super_held);
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

fn curvedPath(
    server: *Server,
    fx_i: i32, fy_i: i32, tx_i: i32, ty_i: i32,
    duration_ms: u32,
    button: ?u32,
    super_held: bool,
) void {
    const fx: f64 = @floatFromInt(fx_i);
    const fy: f64 = @floatFromInt(fy_i);
    const tx: f64 = @floatFromInt(tx_i);
    const ty: f64 = @floatFromInt(ty_i);
    const dx = tx - fx;
    const dy = ty - fy;
    const dist = @sqrt(dx * dx + dy * dy);
    if (dist < 1.0) {
        teleport(server, fx_i, fy_i, tx_i, ty_i, button, super_held);
        return;
    }

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
    // still has some curve and a huge one doesn't burst.
    const raw_samples: u32 = @max(8, @min(240, duration_ms * 60 / 1000));
    const samples: u32 = raw_samples;
    const per_sample_ns: u64 = (@as(u64, duration_ms) * 1_000_000) / @max(1, samples);

    // Button press roughly 25 % through the path (with jitter).
    const press_idx: u32 = if (button != null)
        @intCast(@min(samples - 1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(samples)) * (0.20 + rng.float(f64) * 0.15)))))
    else
        std.math.maxInt(u32);

    var i: u32 = 0;
    while (i < samples) : (i += 1) {
        const u = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(samples - 1));
        const t = easeInOutCubic(u);

        // Cubic Bezier evaluation
        const mt = 1.0 - t;
        const b = mt * mt * mt;
        const c = 3.0 * mt * mt * t;
        const d = 3.0 * mt * t * t;
        const e = t * t * t;
        const bx = b * fx + c * c1x + d * c2x + e * tx;
        const by = b * fy + c * c1y + d * c2y + e * ty;

        // Per-waypoint tremor. Three-sample average approximates
        // a gaussian with σ≈0.4 px for tremor_amp=1. Scale up a bit
        // on long moves (hand shakes more when reaching).
        const tremor_amp = 1.5 + @min(2.0, dist / 500.0);
        const jx = bx + tremor(rng, tremor_amp);
        const jy = by + tremor(rng, tremor_amp);

        wlr.wlr_cursor_warp_closest(server.cursor, null, jx, jy);
        server.processCursorMotion(nowMs());

        if (i == press_idx) {
            if (button) |btn| server.processCursorButton(btn, 1, nowMs(), super_held);
        }

        if (i + 1 < samples) teru.compat.sleepNs(per_sample_ns);
    }

    if (button) |btn| server.processCursorButton(btn, 0, nowMs() +% 5, super_held);
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
