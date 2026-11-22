//! Event plumbing for the macOS backend that needs no AppKit: the queue
//! between NSEvents and teru's events, and trackpad scroll accumulation.
//! Tested on every host.

const std = @import("std");
const types = @import("../types.zig");
const Event = types.Event;

/// One NSEvent can become several teru events (a key press is preceded by
/// the modifier state, a fast trackpad flick is several wheel steps), and
/// `pollEvents` hands out one at a time. The rest wait here, so nothing is
/// dropped the way the single return value used to drop the event that
/// revealed a resize.
pub const EventQueue = struct {
    events: [capacity]Event = undefined,
    head: usize = 0,
    count: usize = 0,

    pub const capacity = 64;

    pub fn push(self: *EventQueue, event: Event) void {
        if (self.count > 0) {
            // Only the latest pointer position matters.
            const last = &self.events[(self.head + self.count - 1) % capacity];
            if (event == .mouse_motion and last.* == .mouse_motion) {
                last.* = event;
                return;
            }
        }
        if (self.count == capacity) {
            // The caller is not draining. Drop the oldest.
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
        }
        self.events[(self.head + self.count) % capacity] = event;
        self.count += 1;
    }

    pub fn take(self: *EventQueue) ?Event {
        if (self.count == 0) return null;
        const event = self.events[self.head];
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        return event;
    }
};

/// Turns a trackpad's continuous scroll deltas (points, positive = up) into
/// wheel steps. Without it every one of the dozens of events a single swipe
/// produces was a full wheel step, which scrolled pages at a time.
pub const ScrollAccumulator = struct {
    pending: f64 = 0,

    /// Points of trackpad travel per wheel step: about one line of text at
    /// the default font size.
    pub const step_pt: f64 = 16.0;
    /// Most steps one event yields, so a corrupt delta cannot flood the queue.
    pub const max_steps: i32 = 8;

    /// Add a delta; returns the whole steps it completes (negative = down).
    pub fn feed(self: *ScrollAccumulator, delta_pt: f64) i32 {
        if (delta_pt == 0 or !std.math.isFinite(delta_pt)) return 0;
        // A change of direction starts over instead of first paying back
        // what was left from the other way.
        if (self.pending != 0 and (delta_pt > 0) != (self.pending > 0)) self.pending = 0;
        self.pending += delta_pt;
        const whole = @trunc(self.pending / step_pt);
        self.pending -= whole * step_pt;
        const limit: f64 = @floatFromInt(max_steps);
        return @intFromFloat(std.math.clamp(whole, -limit, limit));
    }

    pub fn reset(self: *ScrollAccumulator) void {
        self.pending = 0;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "EventQueue: first in, first out" {
    var q: EventQueue = .{};
    try std.testing.expect(q.take() == null);
    q.push(.focus_in);
    q.push(.{ .key_press = .{ .keycode = 1, .modifiers = 0 } });
    q.push(.close);
    try std.testing.expect(q.take().? == .focus_in);
    try std.testing.expectEqual(@as(u32, 1), q.take().?.key_press.keycode);
    try std.testing.expect(q.take().? == .close);
    try std.testing.expect(q.take() == null);
}

test "EventQueue: consecutive motion collapses to the latest" {
    var q: EventQueue = .{};
    q.push(.{ .mouse_motion = .{ .x = 1, .y = 1 } });
    q.push(.{ .mouse_motion = .{ .x = 2, .y = 3 } });
    q.push(.{ .key_press = .{ .keycode = 9, .modifiers = 0 } });
    q.push(.{ .mouse_motion = .{ .x = 4, .y = 4 } });
    const m = q.take().?.mouse_motion;
    try std.testing.expectEqual(@as(u32, 2), m.x);
    try std.testing.expectEqual(@as(u32, 3), m.y);
    try std.testing.expect(q.take().? == .key_press);
    try std.testing.expectEqual(@as(u32, 4), q.take().?.mouse_motion.x);
}

test "EventQueue: full queue drops the oldest" {
    var q: EventQueue = .{};
    for (0..EventQueue.capacity + 3) |i| {
        q.push(.{ .key_press = .{ .keycode = @intCast(i), .modifiers = 0 } });
    }
    try std.testing.expectEqual(@as(u32, 3), q.take().?.key_press.keycode);
    var n: usize = 1;
    while (q.take()) |_| n += 1;
    try std.testing.expectEqual(EventQueue.capacity, n);
}

test "ScrollAccumulator: small deltas add up to steps" {
    var s: ScrollAccumulator = .{};
    try std.testing.expectEqual(@as(i32, 0), s.feed(5));
    try std.testing.expectEqual(@as(i32, 0), s.feed(5));
    try std.testing.expectEqual(@as(i32, 1), s.feed(7)); // 17 pt
    try std.testing.expectEqual(@as(i32, 2), s.feed(31)); // 1 + 31 = 32 pt
    try std.testing.expectEqual(@as(i32, 0), s.feed(0));
}

test "ScrollAccumulator: direction change starts over" {
    var s: ScrollAccumulator = .{};
    try std.testing.expectEqual(@as(i32, 0), s.feed(15));
    try std.testing.expectEqual(@as(i32, -1), s.feed(-16));
    try std.testing.expectEqual(@as(i32, 0), s.feed(-15));
    s.reset();
    try std.testing.expectEqual(@as(i32, 0), s.feed(-15));
}

test "ScrollAccumulator: huge or invalid deltas are bounded" {
    var s: ScrollAccumulator = .{};
    try std.testing.expectEqual(ScrollAccumulator.max_steps, s.feed(1e9));
    try std.testing.expectEqual(@as(i32, 0), s.feed(std.math.nan(f64)));
    try std.testing.expectEqual(@as(i32, 0), s.feed(std.math.inf(f64)));
}
