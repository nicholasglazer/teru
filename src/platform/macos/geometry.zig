//! Pure geometry for the macOS backend: AppKit points to backing pixels.
//!
//! AppKit measures windows, views and mouse positions in points, with the
//! origin at the bottom left. The rest of teru works in framebuffer pixels
//! with the origin at the top left. On a Retina display one point is two
//! pixels. Nothing here calls AppKit, so it is tested on every host.

const std = @import("std");

/// Largest framebuffer side the backend reports. Far above any display,
/// and keeps a corrupt bounds value from asking the renderer for gigabytes.
pub const max_side_px: u32 = 16384;

/// `backingScaleFactor` as a whole number. macOS uses 1 or 2: the "scaled"
/// resolutions in System Settings are a 2x image the window server
/// resamples, so the factor itself is never fractional.
pub fn scaleFromBacking(factor: f64) u32 {
    if (!(factor >= 1.0)) return 1; // also NaN
    return @intFromFloat(@min(4.0, @round(factor)));
}

/// A length in points as whole backing pixels.
pub fn pixelSize(points: f64, scale: u32) u32 {
    if (!(points > 0.0)) return 0; // also NaN
    const px = @round(points * @as(f64, @floatFromInt(scale)));
    return @intFromFloat(@min(px, @as(f64, @floatFromInt(max_side_px))));
}

/// A length in pixels as points, for AppKit calls that take points.
pub fn pointSize(pixels: u32, scale: u32) f64 {
    return @as(f64, @floatFromInt(pixels)) / @as(f64, @floatFromInt(@max(scale, 1)));
}

pub const Pixel = struct { x: u32, y: u32 };

/// Map a position in view coordinates (points, origin bottom left) to a
/// framebuffer pixel (origin top left). `view_h_pt` is the view's height in
/// points; `px_w` x `px_h` the framebuffer size.
///
/// Outside the view the result is null, unless `clamp` is set: then it is
/// the nearest edge pixel. Clamping is for drags and releases, so a
/// selection dragged past the window edge still follows the pointer and
/// a button released outside still ends it.
pub fn viewPointToPixel(x_pt: f64, y_pt: f64, view_h_pt: f64, scale: u32, px_w: u32, px_h: u32, clamp: bool) ?Pixel {
    if (px_w == 0 or px_h == 0) return null;
    if (std.math.isNan(x_pt) or std.math.isNan(y_pt) or std.math.isNan(view_h_pt)) return null;
    const s: f64 = @floatFromInt(@max(scale, 1));
    const fx = @floor(x_pt * s);
    const fy = @floor((view_h_pt - y_pt) * s);
    const w: f64 = @floatFromInt(px_w);
    const h: f64 = @floatFromInt(px_h);
    // A view's edges belong to it: AppKit reports a pointer on the bottom
    // edge as y = 0, which lands one past the last row.
    if (!clamp and (fx < 0 or fy < 0 or fx > w or fy > h)) return null;
    return .{
        .x = @intFromFloat(std.math.clamp(fx, 0, w - 1)),
        .y = @intFromFloat(std.math.clamp(fy, 0, h - 1)),
    };
}

// ── Tests ────────────────────────────────────────────────────────────

test "scaleFromBacking: whole factors, clamped" {
    try std.testing.expectEqual(@as(u32, 1), scaleFromBacking(1.0));
    try std.testing.expectEqual(@as(u32, 2), scaleFromBacking(2.0));
    try std.testing.expectEqual(@as(u32, 2), scaleFromBacking(1.9999));
    try std.testing.expectEqual(@as(u32, 1), scaleFromBacking(0.0));
    try std.testing.expectEqual(@as(u32, 1), scaleFromBacking(-2.0));
    try std.testing.expectEqual(@as(u32, 1), scaleFromBacking(std.math.nan(f64)));
    try std.testing.expectEqual(@as(u32, 4), scaleFromBacking(9.0));
}

test "pixelSize: points to pixels" {
    try std.testing.expectEqual(@as(u32, 960), pixelSize(960, 1));
    try std.testing.expectEqual(@as(u32, 1920), pixelSize(960, 2));
    // A half-point view on a 2x screen is a whole number of pixels.
    try std.testing.expectEqual(@as(u32, 1281), pixelSize(640.5, 2));
    try std.testing.expectEqual(@as(u32, 0), pixelSize(0, 2));
    try std.testing.expectEqual(@as(u32, 0), pixelSize(-5, 2));
    try std.testing.expectEqual(@as(u32, 0), pixelSize(std.math.nan(f64), 2));
    try std.testing.expectEqual(max_side_px, pixelSize(1e12, 2));
}

test "pointSize: pixels back to points" {
    try std.testing.expectEqual(@as(f64, 960), pointSize(1920, 2));
    try std.testing.expectEqual(@as(f64, 800), pointSize(800, 1));
    try std.testing.expectEqual(@as(f64, 800), pointSize(800, 0));
}

test "viewPointToPixel: flips y and scales" {
    // 100x50 pt view at 2x: 200x100 px.
    const top_left = viewPointToPixel(0, 50, 50, 2, 200, 100, false).?;
    try std.testing.expectEqual(Pixel{ .x = 0, .y = 0 }, top_left);
    const mid = viewPointToPixel(10.25, 40, 50, 2, 200, 100, false).?;
    try std.testing.expectEqual(Pixel{ .x = 20, .y = 20 }, mid);
    // The bottom-right point is the last pixel, not one past it.
    const bottom_right = viewPointToPixel(100, 0, 50, 2, 200, 100, false).?;
    try std.testing.expectEqual(Pixel{ .x = 199, .y = 99 }, bottom_right);
    // At 1x the same view is 100x50 px.
    const one_x = viewPointToPixel(99.5, 0.5, 50, 1, 100, 50, false).?;
    try std.testing.expectEqual(Pixel{ .x = 99, .y = 49 }, one_x);
}

test "viewPointToPixel: outside is null unless clamped" {
    // Title bar: above the view.
    try std.testing.expect(viewPointToPixel(10, 60, 50, 2, 200, 100, false) == null);
    try std.testing.expect(viewPointToPixel(-1, 10, 50, 2, 200, 100, false) == null);
    try std.testing.expect(viewPointToPixel(101, 10, 50, 2, 200, 100, false) == null);
    try std.testing.expect(viewPointToPixel(10, -3, 50, 2, 200, 100, false) == null);
    try std.testing.expectEqual(Pixel{ .x = 20, .y = 0 }, viewPointToPixel(10, 60, 50, 2, 200, 100, true).?);
    try std.testing.expectEqual(Pixel{ .x = 0, .y = 99 }, viewPointToPixel(-40, -40, 50, 2, 200, 100, true).?);
    try std.testing.expectEqual(Pixel{ .x = 199, .y = 0 }, viewPointToPixel(500, 500, 50, 2, 200, 100, true).?);
}

test "viewPointToPixel: empty framebuffer or NaN gives null" {
    try std.testing.expect(viewPointToPixel(1, 1, 50, 2, 0, 100, true) == null);
    try std.testing.expect(viewPointToPixel(std.math.nan(f64), 1, 50, 2, 200, 100, true) == null);
}
