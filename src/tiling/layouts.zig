//! Layout calculation algorithms for flat (non-tree) pane arrangements.
//!
//! Each function takes a count, screen rect, and optional parameters,
//! and returns an allocated array of Rects — one per pane.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rect = @import("types.zig").Rect;

pub fn masterStack(allocator: Allocator, count: usize, screen: Rect, ratio: f32) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        rects[0] = screen;
        return rects;
    }

    const master_w: u16 = @intFromFloat(@as(f32, @floatFromInt(screen.width)) * ratio);
    const stack_w: u16 = screen.width - master_w;
    const stack_count: u16 = @intCast(count - 1);

    rects[0] = .{ .x = screen.x, .y = screen.y, .width = master_w, .height = screen.height };

    const cell_h = screen.height / stack_count;
    const remainder = screen.height % stack_count;

    for (0..stack_count) |i| {
        const idx: u16 = @intCast(i);
        const extra: u16 = if (i == stack_count - 1) remainder else 0;
        rects[i + 1] = .{
            .x = screen.x + master_w,
            .y = screen.y + idx * cell_h,
            .width = stack_w,
            .height = cell_h + extra,
        };
    }

    return rects;
}

pub fn grid(allocator: Allocator, count: usize, screen: Rect) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        rects[0] = screen;
        return rects;
    }

    const cols = gridCols(count);
    const rows = (count + cols - 1) / cols;

    const cell_w: u16 = screen.width / @as(u16, @intCast(cols));
    const cell_h: u16 = screen.height / @as(u16, @intCast(rows));

    for (0..count) |i| {
        const col = i % cols;
        const row = i / cols;

        const is_last_col = (col == cols - 1);
        const is_last_row = (row == rows - 1);
        const w_extra: u16 = if (is_last_col) screen.width % @as(u16, @intCast(cols)) else 0;
        const h_extra: u16 = if (is_last_row) screen.height % @as(u16, @intCast(rows)) else 0;

        rects[i] = .{
            .x = screen.x + @as(u16, @intCast(col)) * cell_w,
            .y = screen.y + @as(u16, @intCast(row)) * cell_h,
            .width = cell_w + w_extra,
            .height = cell_h + h_extra,
        };
    }

    return rects;
}

pub fn monocle(allocator: Allocator, count: usize, screen: Rect, active: usize) ![]Rect {
    const rects = try allocator.alloc(Rect, count);
    for (0..count) |i| {
        rects[i] = if (i == active) screen else Rect.zero;
    }
    return rects;
}

pub fn dishes(allocator: Allocator, count: usize, screen: Rect, ratio: f32) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        rects[0] = screen;
        return rects;
    }

    const master_h: u16 = @intFromFloat(@as(f32, @floatFromInt(screen.height)) * ratio);
    const stack_h: u16 = screen.height -| master_h;
    const stack_count: u16 = @intCast(count - 1);

    rects[0] = .{ .x = screen.x, .y = screen.y, .width = screen.width, .height = master_h };

    const cell_w = screen.width / stack_count;
    const remainder = screen.width % stack_count;

    for (0..stack_count) |i| {
        const idx: u16 = @intCast(i);
        const extra: u16 = if (i == stack_count - 1) remainder else 0;
        rects[i + 1] = .{
            .x = screen.x + idx * cell_w,
            .y = screen.y + master_h,
            .width = cell_w + extra,
            .height = stack_h,
        };
    }

    return rects;
}

pub fn spiral(allocator: Allocator, count: usize, screen: Rect) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        rects[0] = screen;
        return rects;
    }

    var remaining = screen;
    for (0..count) |i| {
        if (i == count - 1) {
            rects[i] = remaining;
            break;
        }
        const is_vertical = (i % 2 == 0);
        if (is_vertical) {
            const w: u16 = @intFromFloat(@as(f32, @floatFromInt(remaining.width)) * 0.5);
            rects[i] = .{ .x = remaining.x, .y = remaining.y, .width = w, .height = remaining.height };
            remaining.x +|= w;
            remaining.width -|= w;
        } else {
            const h: u16 = @intFromFloat(@as(f32, @floatFromInt(remaining.height)) * 0.5);
            rects[i] = .{ .x = remaining.x, .y = remaining.y, .width = remaining.width, .height = h };
            remaining.y +|= h;
            remaining.height -|= h;
        }
    }

    return rects;
}

pub fn threeCol(allocator: Allocator, count: usize, screen: Rect, ratio: f32) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        rects[0] = screen;
        return rects;
    }

    if (count == 2) {
        const master_w: u16 = @intFromFloat(@as(f32, @floatFromInt(screen.width)) * ratio);
        const side_w: u16 = screen.width -| master_w;
        rects[0] = .{ .x = screen.x, .y = screen.y, .width = master_w, .height = screen.height };
        rects[1] = .{ .x = screen.x +| master_w, .y = screen.y, .width = side_w, .height = screen.height };
        return rects;
    }

    const master_w: u16 = @intFromFloat(@as(f32, @floatFromInt(screen.width)) * ratio);
    const side_total: u16 = screen.width -| master_w;
    const left_w: u16 = side_total / 2;
    const right_w: u16 = side_total -| left_w;
    const center_x: u16 = screen.x +| left_w;

    rects[0] = .{ .x = center_x, .y = screen.y, .width = master_w, .height = screen.height };

    var left_count: u16 = 0;
    var right_count: u16 = 0;
    for (1..count) |i| {
        if (i % 2 == 1) left_count += 1 else right_count += 1;
    }
    if (right_count == 0 and left_count > 1) {
        left_count -= 1;
        right_count = 1;
    }

    var left_idx: u16 = 0;
    var right_idx: u16 = 0;
    for (1..count) |i| {
        const is_left = if (right_count == 0) true else if (left_count == 0) false else (i % 2 == 1);
        if (is_left) {
            const cell_h = if (left_count > 0) screen.height / left_count else screen.height;
            const extra: u16 = if (left_idx == left_count - 1) screen.height % left_count else 0;
            rects[i] = .{ .x = screen.x, .y = screen.y +| left_idx * cell_h, .width = left_w, .height = cell_h + extra };
            left_idx += 1;
        } else {
            const cell_h = if (right_count > 0) screen.height / right_count else screen.height;
            const extra: u16 = if (right_idx == right_count - 1) screen.height % right_count else 0;
            rects[i] = .{ .x = center_x +| master_w, .y = screen.y +| right_idx * cell_h, .width = right_w, .height = cell_h + extra };
            right_idx += 1;
        }
    }

    return rects;
}

pub fn columns(allocator: Allocator, count: usize, screen: Rect) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        rects[0] = screen;
        return rects;
    }

    const col_count: u16 = @intCast(count);
    const col_w: u16 = screen.width / col_count;
    const remainder: u16 = screen.width % col_count;

    for (0..count) |i| {
        const idx: u16 = @intCast(i);
        const extra: u16 = if (i == count - 1) remainder else 0;
        rects[i] = .{ .x = screen.x + idx * col_w, .y = screen.y, .width = col_w + extra, .height = screen.height };
    }

    return rects;
}

pub fn accordion(allocator: Allocator, count: usize, screen: Rect, active: usize) ![]Rect {
    const rects = try allocator.alloc(Rect, count);

    if (count == 1) {
        rects[0] = screen;
        return rects;
    }

    const min_h: u16 = @min(2, screen.height / @as(u16, @intCast(count)));
    const collapsed_total: u16 = min_h * @as(u16, @intCast(count - 1));
    const active_h: u16 = screen.height -| collapsed_total;
    const clamped_active = @min(active, count - 1);

    var y: u16 = screen.y;
    for (0..count) |i| {
        const h: u16 = if (i == clamped_active) active_h else min_h;
        rects[i] = .{ .x = screen.x, .y = y, .width = screen.width, .height = h };
        y +|= h;
    }

    return rects;
}

/// Optimal column count for a grid of n items.
pub fn gridCols(n: usize) usize {
    if (n <= 1) return 1;
    var c: usize = 1;
    while (c * c < n) : (c += 1) {}
    return c;
}

// ── Tests ────────────────────────────────────────────────────────

const t = std.testing;

test "gridCols" {
    try t.expectEqual(@as(usize, 1), gridCols(1));
    try t.expectEqual(@as(usize, 2), gridCols(2));
    try t.expectEqual(@as(usize, 2), gridCols(3));
    try t.expectEqual(@as(usize, 2), gridCols(4));
    try t.expectEqual(@as(usize, 3), gridCols(5));
    try t.expectEqual(@as(usize, 3), gridCols(6));
    try t.expectEqual(@as(usize, 3), gridCols(9));
    try t.expectEqual(@as(usize, 4), gridCols(10));
}
