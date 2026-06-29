//! Pure mouse-event → terminal-report byte encoding (xterm mouse protocol:
//! tracking modes 1000/1002/1003, with SGR-1006 and legacy X10 framing).
//!
//! Shared by two callers that both need to hand a wheel/click to the program
//! running inside a pane:
//!   - standalone teru's windowed event loop (`src/input/mouse.zig`), and
//!   - the teruwm compositor's native terminal panes (`ServerCursor.zig`),
//!     which are `wlr_scene_buffer` nodes with no `wl_surface`, so the only
//!     way a mouse event reaches the app is a direct PTY write.
//!
//! Keeping the encoding here means the two paths can't drift: one byte layout,
//! one set of tests. The `encode*` functions are pure (no Pane, no I/O) — the
//! caller passes the pane's SGR flag and writes the returned bytes itself.

const std = @import("std");
const Pane = @import("../core/Pane.zig");

/// xterm mouse button codes (the value placed in the report).
pub const BTN_LEFT: u8 = 0;
pub const BTN_MIDDLE: u8 = 1;
pub const BTN_RIGHT: u8 = 2;
pub const BTN_WHEEL_UP: u8 = 64;
pub const BTN_WHEEL_DOWN: u8 = 65;
/// X10 legacy release sentinel (encoded as button 3).
const X10_RELEASE: u8 = 3;

/// True if the X10 legacy framing can represent (col,row) — it adds 32 to each
/// 1-based coordinate into a single byte, so the usable range is 1..223.
fn x10Fits(col: u16, row: u16) bool {
    return @as(u32, col) + 33 < 256 and @as(u32, row) + 33 < 256;
}

/// Encode a press / wheel report for `btn` at 0-based cell (col,row) into `buf`.
/// SGR (1006) framing when `sgr`, else legacy X10. Returns the slice, or null
/// if X10 can't represent the position.
pub fn encodePress(sgr: bool, btn: u8, col: u16, row: u16, buf: []u8) ?[]const u8 {
    if (sgr) {
        return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}M", .{ btn, col + 1, row + 1 }) catch null;
    }
    if (!x10Fits(col, row)) return null;
    buf[0] = 0x1b;
    buf[1] = '[';
    buf[2] = 'M';
    buf[3] = @intCast(@as(u32, btn) + 32);
    buf[4] = @intCast(@as(u32, col) + 33);
    buf[5] = @intCast(@as(u32, row) + 33);
    return buf[0..6];
}

/// Encode a button RELEASE report. SGR uses lowercase `m` with the real button;
/// X10 has no per-button release, so it always reports button 3.
pub fn encodeRelease(sgr: bool, btn: u8, col: u16, row: u16, buf: []u8) ?[]const u8 {
    if (sgr) {
        return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}m", .{ btn, col + 1, row + 1 }) catch null;
    }
    if (!x10Fits(col, row)) return null;
    buf[0] = 0x1b;
    buf[1] = '[';
    buf[2] = 'M';
    buf[3] = @intCast(@as(u32, X10_RELEASE) + 32);
    buf[4] = @intCast(@as(u32, col) + 33);
    buf[5] = @intCast(@as(u32, row) + 33);
    return buf[0..6];
}

/// Encode a motion report (modes 1002/1003). The motion bit is set; the button
/// bits carry left-held (`mouse_down`) vs none.
pub fn encodeMotion(sgr: bool, mouse_down: bool, col: u16, row: u16, buf: []u8) ?[]const u8 {
    if (sgr) {
        const btn: u8 = if (mouse_down) 32 else 35;
        return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}M", .{ btn, col + 1, row + 1 }) catch null;
    }
    if (!x10Fits(col, row)) return null;
    buf[0] = 0x1b;
    buf[1] = '[';
    buf[2] = 'M';
    buf[3] = if (mouse_down) 64 else 67;
    buf[4] = @intCast(@as(u32, col) + 33);
    buf[5] = @intCast(@as(u32, row) + 33);
    return buf[0..6];
}

/// Forward one wheel notch to the pane's program as a mouse report (button 64
/// up / 65 down) at 0-based cell (col,row). No-op returning false when the app
/// has no mouse tracking enabled — the caller then handles the wheel itself
/// (scrollback / zoom). Returns true when the wheel belonged to the app.
pub fn forwardWheel(pane: *const Pane, up: bool, col: u16, row: u16) bool {
    if (pane.vt.mouse_tracking == .none) return false;
    var buf: [32]u8 = undefined;
    const btn: u8 = if (up) BTN_WHEEL_UP else BTN_WHEEL_DOWN;
    if (encodePress(pane.vt.mouse_sgr, btn, col, row, &buf)) |seq| {
        _ = pane.ptyWrite(seq) catch {};
    }
    return true; // consumed regardless of whether X10 could frame the position
}

// ── Wheel routing ────────────────────────────────────────────────

/// One detent's worth of continuous (touchpad) axis travel, in libinput units.
/// Matches the ~15-units-per-detent the teruwm_scroll MCP tool documents.
pub const WHEEL_NOTCH_UNITS: f64 = 15.0;

/// What a vertical wheel event should do for a focused terminal pane.
pub const WheelAction = enum {
    scrollback, // not app-owned — caller scrolls its own scrollback history
    swallow, // app-owned but unscrollable here (alt screen, no handler)
    report, // emit `count` button-64/65 mouse reports (mouse tracking on)
    arrows, // emit `count` cursor-key presses (alternate-scroll on alt screen)
};

pub const WheelDecision = struct {
    action: WheelAction,
    up: bool, // physical scroll direction (true = up); apps decide their own polarity
    count: u32, // notches to emit (0 ⇒ still accumulating; unused for .scrollback)
};

/// Pure wheel routing for a terminal pane. The only state is `accum` — the
/// per-pane touchpad accumulator, advanced here so a continuous gesture emits
/// one notch per `WHEEL_NOTCH_UNITS` of travel. `delta` is the wlroots axis
/// delta (< 0 = scroll up); `discrete` is the v120 hi-res notch value
/// (120 == one detent; 0 for touchpad/continuous). Mirrors standalone teru's
/// precedence: mouse tracking wins over alternate-scroll, both win over local
/// scrollback, and the alt screen is never scrolled by the wheel.
pub fn classifyWheel(
    tracking: bool,
    alt_screen: bool,
    alt_scroll: bool,
    delta: f64,
    discrete: i32,
    accum: *f64,
) WheelDecision {
    const up = delta < 0;
    const app_owned = tracking or (alt_screen and alt_scroll);
    if (!app_owned) {
        accum.* = 0; // not forwarding — drop any partial touchpad travel
        return .{ .action = if (alt_screen) .swallow else .scrollback, .up = up, .count = 0 };
    }

    var count: u32 = 0;
    if (discrete != 0) {
        // Notched wheel: normalise v120 to whole notches (±1 fallback for a
        // non-zero sub-notch step), same as Pane.axisScrollPixels.
        const notches = @divTrunc(discrete, 120);
        count = if (notches != 0) @intCast(@abs(notches)) else 1;
        accum.* = 0;
    } else {
        // Touchpad / continuous: accumulate to whole detents.
        accum.* += delta;
        while (@abs(accum.*) >= WHEEL_NOTCH_UNITS) {
            count += 1;
            accum.* -= if (accum.* < 0) -WHEEL_NOTCH_UNITS else WHEEL_NOTCH_UNITS;
        }
    }
    return .{ .action = if (tracking) .report else .arrows, .up = up, .count = count };
}

// ── Tests ────────────────────────────────────────────────────────
// Byte-exact assertions lock the wire format so the standalone-teru and
// compositor paths stay identical.

test "encodePress: SGR wheel-up frames button 64 with 1-based coords" {
    var buf: [32]u8 = undefined;
    const s = encodePress(true, BTN_WHEEL_UP, 4, 9, &buf).?;
    try std.testing.expectEqualStrings("\x1b[<64;5;10M", s);
}

test "encodePress: X10 wheel-down adds the +32/+33 offsets" {
    var buf: [32]u8 = undefined;
    const s = encodePress(false, BTN_WHEEL_DOWN, 0, 0, &buf).?;
    // ESC [ M, btn 65+32=97, col 0+33=33, row 0+33=33
    try std.testing.expectEqualSlices(u8, &.{ 0x1b, '[', 'M', 97, 33, 33 }, s);
}

test "encodePress: X10 returns null past column 223" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(encodePress(false, BTN_LEFT, 250, 0, &buf) == null);
    // SGR has no such limit.
    try std.testing.expect(encodePress(true, BTN_LEFT, 250, 0, &buf) != null);
}

test "encodeRelease: SGR keeps button (lowercase m), X10 forces button 3" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[<2;3;4m", encodeRelease(true, BTN_RIGHT, 2, 3, &buf).?);
    const x10 = encodeRelease(false, BTN_RIGHT, 2, 3, &buf).?;
    try std.testing.expectEqualSlices(u8, &.{ 0x1b, '[', 'M', 35, 35, 36 }, x10);
}

test "encodeMotion: SGR sets motion bit, button-held vs none" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[<32;1;1M", encodeMotion(true, true, 0, 0, &buf).?);
    try std.testing.expectEqualStrings("\x1b[<35;1;1M", encodeMotion(true, false, 0, 0, &buf).?);
}

test "classifyWheel: normal screen + no tracking → local scrollback" {
    var accum: f64 = 0;
    const d = classifyWheel(false, false, false, -15.0, 120, &accum);
    try std.testing.expectEqual(WheelAction.scrollback, d.action);
}

test "classifyWheel: alt screen + no tracking + no alt-scroll → swallow (not invisible scrollback)" {
    var accum: f64 = 0;
    const d = classifyWheel(false, true, false, 15.0, 120, &accum);
    try std.testing.expectEqual(WheelAction.swallow, d.action);
}

test "classifyWheel: mouse tracking → report, one notch per v120 detent, direction from delta" {
    var accum: f64 = 0;
    const up = classifyWheel(true, true, false, -15.0, 120, &accum);
    try std.testing.expectEqual(WheelAction.report, up.action);
    try std.testing.expect(up.up);
    try std.testing.expectEqual(@as(u32, 1), up.count);

    const down2 = classifyWheel(true, false, false, 15.0, 240, &accum);
    try std.testing.expectEqual(WheelAction.report, down2.action);
    try std.testing.expect(!down2.up);
    try std.testing.expectEqual(@as(u32, 2), down2.count); // two detents
}

test "classifyWheel: low-res / sub-notch discrete still emits exactly one notch" {
    var accum: f64 = 0;
    const d = classifyWheel(true, false, false, -1.0, 1, &accum); // discrete=1 (not v120)
    try std.testing.expectEqual(@as(u32, 1), d.count);
}

test "classifyWheel: alt screen + alt-scroll, no tracking → arrows" {
    var accum: f64 = 0;
    const d = classifyWheel(false, true, true, -15.0, 120, &accum);
    try std.testing.expectEqual(WheelAction.arrows, d.action);
    try std.testing.expect(d.up);
    try std.testing.expectEqual(@as(u32, 1), d.count);
}

test "classifyWheel: touchpad accumulates — sub-detent emits nothing, then fires once per detent" {
    var accum: f64 = 0;
    // Below one detent: consumed but no notch yet.
    const partial = classifyWheel(true, true, false, -8.0, 0, &accum);
    try std.testing.expectEqual(WheelAction.report, partial.action);
    try std.testing.expectEqual(@as(u32, 0), partial.count);
    // Crossing the detent threshold emits exactly one.
    const fires = classifyWheel(true, true, false, -8.0, 0, &accum);
    try std.testing.expectEqual(@as(u32, 1), fires.count);
}

test "classifyWheel: switching away from app-owned resets the touchpad accumulator" {
    var accum: f64 = 10.0; // partial travel banked
    _ = classifyWheel(false, false, false, -1.0, 0, &accum);
    try std.testing.expectEqual(@as(f64, 0), accum);
}

test "forwardWheel: no-op (false) when tracking off, true when on" {
    // Spawns a real PTY (same pattern as the other Pane tests).
    var pane = try Pane.init(std.testing.allocator, 24, 80, 1, .{});
    defer pane.deinit(std.testing.allocator);
    pane.vt.mouse_tracking = .none;
    try std.testing.expect(!forwardWheel(&pane, true, 0, 0));
    pane.vt.mouse_tracking = .normal;
    pane.vt.mouse_sgr = true;
    try std.testing.expect(forwardWheel(&pane, true, 0, 0));
}
