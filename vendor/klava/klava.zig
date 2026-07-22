//! klava — keystroke display engine for screencasts and streaming overlays.
//!
//! Feed it key events (keysym + modifier state + press/release + timestamp);
//! it maintains a small ring of display entries — composed combo labels like
//! `Super+Shift+Enter`, repeat-collapsed (`Ctrl+V ×3`), expiring after a
//! configurable linger. Rendering is the consumer's job: a Wayland compositor
//! blits the entries into an overlay, a TUI prints them, a GUI draws chips.
//!
//! Design constraints, in order:
//!   - Zero allocations, zero dependencies (fixed buffers only) — safe to
//!     embed in a compositor's input path.
//!   - Privacy by default: `combos_only` suppresses plain and Shift-only
//!     typing, so ordinary text (and passwords) never reaches the overlay.
//!   - No internal timers: the consumer asks `nextDeadlineMs()` and arms its
//!     own one-shot timer. The engine never forces periodic wakeups.
//!
//! ```zig
//! var eng = klava.Klava.init(.{});
//! _ = eng.feed(.{ .keysym = 0xff0d, .mods = .{ .super = true }, .pressed = true, .time_ms = now });
//! var it = eng.iterator(now);
//! while (it.next()) |entry| draw(entry.text());
//! if (eng.nextDeadlineMs(now)) |deadline| armTimer(deadline - now);
//! ```

const std = @import("std");
pub const keysym = @import("keysym.zig");
pub const Style = keysym.Style;

/// Modifier state accompanying a key event. Layout-independent: the consumer
/// reads these from its input stack (xkb effective mods, evdev tracking, …).
pub const Mods = packed struct(u8) {
    super: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    _pad: u4 = 0,

    pub fn any(m: Mods) bool {
        return m.super or m.ctrl or m.alt or m.shift;
    }

    /// True when a non-Shift modifier is held — the privacy gate:
    /// Shift+letter still types text, so Shift alone doesn't count.
    pub fn combo(m: Mods) bool {
        return m.super or m.ctrl or m.alt;
    }
};

pub const KeyEvent = struct {
    /// X11/xkbcommon keysym (already layout-resolved by the consumer).
    keysym: u32,
    mods: Mods = .{},
    /// Only presses produce entries; releases are accepted and ignored so
    /// consumers can forward their whole event stream unfiltered.
    pressed: bool,
    /// Milliseconds on any monotonic clock; only differences are used.
    time_ms: u64,
};

/// Runtime-tunable behavior. All fields hot-swappable via `setOptions`.
pub const Options = struct {
    /// Show only Ctrl/Alt/Super combos; hide plain + Shift-only typing.
    combos_only: bool = true,
    /// Merge an immediately-repeated identical combo into one `×N` entry.
    collapse_repeats: bool = true,
    /// How long an entry stays visible after its last occurrence.
    linger_ms: u32 = 2500,
    /// Label style: `.ascii` (safe for ASCII-only renderers) or `.pretty`.
    style: Style = .ascii,
};

pub const FeedResult = enum {
    /// Event filtered out (release, bare modifier, or privacy gate).
    ignored,
    /// New entry appended — consumer should re-render.
    added,
    /// Newest entry collapsed (`count` bumped) — consumer should re-render.
    collapsed,
};

/// Engine over a fixed ring. `capacity` = retained entries (oldest evicted),
/// `label_cap` = max bytes per composed label (longer combos truncate).
pub fn Engine(comptime capacity: usize, comptime label_cap: usize) type {
    comptime std.debug.assert(capacity >= 1);
    comptime std.debug.assert(label_cap >= 24);
    return struct {
        const Self = @This();

        pub const Entry = struct {
            label_buf: [label_cap]u8 = undefined,
            label_len: u16 = 0,
            /// Occurrences collapsed into this entry (1 = single press).
            count: u32 = 1,
            /// Timestamp of the most recent occurrence.
            last_ms: u64 = 0,

            pub fn text(e: *const Entry) []const u8 {
                return e.label_buf[0..e.label_len];
            }

            /// Label with `×N` suffix when collapsed. `buf` ≥ label_cap + 12.
            pub fn displayText(e: *const Entry, buf: []u8) []const u8 {
                if (e.count <= 1) {
                    const n = @min(buf.len, e.label_len);
                    @memcpy(buf[0..n], e.label_buf[0..n]);
                    return buf[0..n];
                }
                return std.fmt.bufPrint(buf, "{s} x{d}", .{ e.text(), e.count }) catch e.text();
            }

            fn expiresAt(e: *const Entry, linger_ms: u32) u64 {
                return e.last_ms + linger_ms;
            }
        };

        opts: Options = .{},
        entries: [capacity]Entry = @splat(.{}),
        /// Index of the oldest live entry.
        head: usize = 0,
        /// Number of live entries.
        len: usize = 0,

        pub fn init(opts: Options) Self {
            return .{ .opts = opts };
        }

        pub fn setOptions(self: *Self, opts: Options) void {
            self.opts = opts;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.head = 0;
        }

        /// Feed one key event. Returns whether the display changed.
        pub fn feed(self: *Self, ev: KeyEvent) FeedResult {
            if (!ev.pressed) return .ignored;
            if (keysym.isModifier(ev.keysym)) return .ignored;
            if (self.opts.combos_only and !ev.mods.combo()) return .ignored;

            var label_buf: [label_cap]u8 = undefined;
            const lab = self.compose(ev, &label_buf);

            if (self.opts.collapse_repeats and self.len > 0) {
                const newest = self.at(self.len - 1);
                if (std.mem.eql(u8, newest.text(), lab)) {
                    newest.count +|= 1;
                    newest.last_ms = ev.time_ms;
                    return .collapsed;
                }
            }

            const slot = if (self.len < capacity) blk: {
                self.len += 1;
                break :blk self.at(self.len - 1);
            } else blk: {
                self.head = (self.head + 1) % capacity;
                break :blk self.at(self.len - 1);
            };
            slot.label_len = @intCast(lab.len);
            @memcpy(slot.label_buf[0..lab.len], lab);
            slot.count = 1;
            slot.last_ms = ev.time_ms;
            return .added;
        }

        /// Drop entries whose linger elapsed. Returns true if any were
        /// removed (consumer should re-render / hide).
        pub fn pruneExpired(self: *Self, now_ms: u64) bool {
            var removed = false;
            while (self.len > 0) {
                const oldest = self.at(0);
                if (oldest.expiresAt(self.opts.linger_ms) > now_ms) break;
                self.head = (self.head + 1) % capacity;
                self.len -= 1;
                removed = true;
            }
            if (self.len == 0) self.head = 0;
            return removed;
        }

        /// Earliest future expiry, or null when empty. Consumers arm ONE
        /// one-shot timer for `deadline - now`; no periodic polling.
        pub fn nextDeadlineMs(self: *const Self, now_ms: u64) ?u64 {
            if (self.len == 0) return null;
            const deadline = self.atConst(0).expiresAt(self.opts.linger_ms);
            return @max(deadline, now_ms);
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// Iterate live (non-expired) entries oldest → newest.
        pub fn iterator(self: *const Self, now_ms: u64) Iterator {
            return .{ .engine = self, .now_ms = now_ms };
        }

        pub const Iterator = struct {
            engine: *const Self,
            now_ms: u64,
            idx: usize = 0,

            pub fn next(it: *Iterator) ?*const Entry {
                while (it.idx < it.engine.len) {
                    const e = it.engine.atConst(it.idx);
                    it.idx += 1;
                    if (e.expiresAt(it.engine.opts.linger_ms) > it.now_ms) return e;
                }
                return null;
            }
        };

        fn at(self: *Self, i: usize) *Entry {
            return &self.entries[(self.head + i) % capacity];
        }

        fn atConst(self: *const Self, i: usize) *const Entry {
            return &self.entries[(self.head + i) % capacity];
        }

        /// Compose "Super+Ctrl+Alt+Shift+Key" into `buf`.
        fn compose(self: *const Self, ev: KeyEvent, buf: []u8) []const u8 {
            var w: usize = 0;
            if (ev.mods.super) w = append(buf, w, "Super+");
            if (ev.mods.ctrl) w = append(buf, w, "Ctrl+");
            if (ev.mods.alt) w = append(buf, w, "Alt+");
            if (ev.mods.shift) w = append(buf, w, "Shift+");
            var key_buf: [16]u8 = undefined;
            const key_label = keysym.label(ev.keysym, self.opts.style, &key_buf);
            w = append(buf, w, key_label);
            return buf[0..w];
        }

        fn append(buf: []u8, w: usize, s: []const u8) usize {
            const n = @min(buf.len - w, s.len);
            @memcpy(buf[w .. w + n], s[0..n]);
            return w + n;
        }
    };
}

/// Sensible default: 8 entries, 48-byte labels. ~500 bytes of state.
pub const Klava = Engine(8, 48);

// ── Tests ────────────────────────────────────────────────────

const t = std.testing;

fn press(sym: u32, mods: Mods, ms: u64) KeyEvent {
    return .{ .keysym = sym, .mods = mods, .pressed = true, .time_ms = ms };
}

test "combo composition and ordering" {
    var eng = Klava.init(.{});
    try t.expectEqual(FeedResult.added, eng.feed(press(0xff0d, .{ .super = true, .shift = true }, 100)));
    try t.expectEqualStrings("Super+Shift+Enter", eng.atConst(0).text());
    try t.expectEqual(FeedResult.added, eng.feed(press('T', .{ .ctrl = true, .shift = true }, 200)));
    try t.expectEqualStrings("Ctrl+Shift+T", eng.atConst(1).text());
}

test "privacy: plain and shift-only typing ignored, combos shown" {
    var eng = Klava.init(.{});
    try t.expectEqual(FeedResult.ignored, eng.feed(press('a', .{}, 1)));
    try t.expectEqual(FeedResult.ignored, eng.feed(press('A', .{ .shift = true }, 2)));
    try t.expectEqual(FeedResult.added, eng.feed(press('a', .{ .ctrl = true }, 3)));
    try t.expectEqual(@as(usize, 1), eng.count());
}

test "privacy off: everything shows" {
    var eng = Klava.init(.{ .combos_only = false });
    try t.expectEqual(FeedResult.added, eng.feed(press('a', .{}, 1)));
    try t.expectEqualStrings("a", eng.atConst(0).text());
}

test "bare modifiers and releases ignored" {
    var eng = Klava.init(.{});
    try t.expectEqual(FeedResult.ignored, eng.feed(press(0xffe3, .{ .ctrl = true }, 1))); // Ctrl_L press
    try t.expectEqual(FeedResult.ignored, eng.feed(.{ .keysym = 'a', .mods = .{ .ctrl = true }, .pressed = false, .time_ms = 2 }));
    try t.expectEqual(@as(usize, 0), eng.count());
}

test "repeat collapse" {
    var eng = Klava.init(.{});
    _ = eng.feed(press('v', .{ .ctrl = true }, 100));
    try t.expectEqual(FeedResult.collapsed, eng.feed(press('v', .{ .ctrl = true }, 200)));
    try t.expectEqual(FeedResult.collapsed, eng.feed(press('v', .{ .ctrl = true }, 300)));
    try t.expectEqual(@as(usize, 1), eng.count());
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Ctrl+v x3", eng.atConst(0).displayText(&buf));
    // Different combo breaks the run.
    try t.expectEqual(FeedResult.added, eng.feed(press('c', .{ .ctrl = true }, 400)));
    try t.expectEqual(@as(usize, 2), eng.count());
}

test "expiry: prune and deadline" {
    var eng = Klava.init(.{ .linger_ms = 1000 });
    _ = eng.feed(press('x', .{ .super = true }, 1000));
    _ = eng.feed(press('y', .{ .super = true }, 1600));
    try t.expectEqual(@as(?u64, 2000), eng.nextDeadlineMs(1700));
    try t.expect(!eng.pruneExpired(1999));
    try t.expect(eng.pruneExpired(2000)); // x expires exactly at 2000
    try t.expectEqual(@as(usize, 1), eng.count());
    try t.expectEqual(@as(?u64, 2600), eng.nextDeadlineMs(2100));
    try t.expect(eng.pruneExpired(9999));
    try t.expectEqual(@as(usize, 0), eng.count());
    try t.expectEqual(@as(?u64, null), eng.nextDeadlineMs(9999));
}

test "ring eviction keeps newest" {
    var eng = Engine(3, 32).init(.{ .collapse_repeats = false });
    _ = eng.feed(press('1', .{ .ctrl = true }, 1));
    _ = eng.feed(press('2', .{ .ctrl = true }, 2));
    _ = eng.feed(press('3', .{ .ctrl = true }, 3));
    _ = eng.feed(press('4', .{ .ctrl = true }, 4));
    try t.expectEqual(@as(usize, 3), eng.count());
    try t.expectEqualStrings("Ctrl+2", eng.atConst(0).text());
    try t.expectEqualStrings("Ctrl+4", eng.atConst(2).text());
}

test "iterator skips expired without pruning" {
    var eng = Klava.init(.{ .linger_ms = 500 });
    _ = eng.feed(press('a', .{ .alt = true }, 100));
    _ = eng.feed(press('b', .{ .alt = true }, 1000));
    var it = eng.iterator(700); // 'a' expired at 600, 'b' alive
    const first = it.next().?;
    try t.expectEqualStrings("Alt+b", first.text());
    try t.expectEqual(@as(?*const Klava.Entry, null), it.next());
    try t.expectEqual(@as(usize, 2), eng.count()); // untouched
}

test "label truncation is safe" {
    var eng = Engine(2, 24).init(.{});
    const r = eng.feed(press(0xff0d, .{ .super = true, .ctrl = true, .alt = true, .shift = true }, 1));
    try t.expectEqual(FeedResult.added, r);
    // "Super+Ctrl+Alt+Shift+Enter" (26 bytes) truncates to 24 without UB.
    try t.expectEqual(@as(usize, 24), eng.atConst(0).text().len);
}

test "options hot-swap" {
    var eng = Klava.init(.{});
    _ = eng.feed(press('a', .{}, 1));
    try t.expectEqual(@as(usize, 0), eng.count());
    eng.setOptions(.{ .combos_only = false });
    _ = eng.feed(press('a', .{}, 2));
    try t.expectEqual(@as(usize, 1), eng.count());
}

test "cyrillic combo pretty vs ascii" {
    var eng = Klava.init(.{ .style = .pretty });
    _ = eng.feed(press(0x06d7, .{ .ctrl = true }, 1)); // Cyrillic_ve
    try t.expectEqualStrings("Ctrl+в", eng.atConst(0).text());
    var eng2 = Klava.init(.{ .style = .ascii });
    _ = eng2.feed(press(0x06d7, .{ .ctrl = true }, 1));
    try t.expectEqualStrings("Ctrl+?", eng2.atConst(0).text());
}
