//! Keysym → human-readable label resolution, pure Zig (no xkbcommon).
//!
//! Resolution order for `label()`:
//!   1. Named specials (Enter, Esc, F1…, arrows, media keys) — handwritten switch.
//!   2. Printable ASCII keysyms (0x20–0x7e) — identity.
//!   3. Algorithmic Unicode keysyms (0x01000000 | codepoint).
//!   4. Legacy keysym → Unicode via the generated table (Cyrillic, Greek, …).
//!   5. Fallback `0xNNNN` hex spelling.
//!
//! Non-ASCII output is valid UTF-8. Consumers whose renderer is ASCII-only
//! can use `Style.ascii`, which folds any non-ASCII codepoint to '?'.

const std = @import("std");
const unicode_table = @import("keysym_unicode.zig");

/// Label style. `.ascii` guarantees the returned label is pure ASCII
/// (non-ASCII codepoints fold to '?', arrows spell out as "Up"/"Down"/…).
/// `.pretty` may emit multi-byte UTF-8 (arrows ←↑→↓, real Cyrillic letters).
pub const Style = enum { ascii, pretty };

/// True for keysyms that are themselves modifiers (Shift, Ctrl, Super, …).
/// A combo display engine ignores these as standalone presses — only the
/// modifier *state* matters, carried alongside the non-modifier key.
pub fn isModifier(keysym: u32) bool {
    return switch (keysym) {
        0xffe1...0xffee => true, // Shift_L … Hyper_R (incl. Caps/Shift_Lock, Meta, Alt, Super)
        0xfe03, 0xfe04 => true, // ISO_Level3_Shift / ISO_Level3_Latch (AltGr)
        0xfe07, 0xfe08 => true, // ISO_Level5_Shift / Latch
        0xff7e => true, // Mode_switch (legacy group toggle)
        0xff7f => true, // Num_Lock
        else => false,
    };
}

/// Write the label for `keysym` into `buf`; returns the written slice.
/// `buf` should hold at least 16 bytes; longer names truncate safely.
pub fn label(keysym: u32, style: Style, buf: []u8) []const u8 {
    if (named(keysym, style)) |name| return copy(buf, name);

    // Printable ASCII identity range.
    if (keysym >= 0x20 and keysym <= 0x7e) {
        if (buf.len == 0) return buf[0..0];
        buf[0] = @intCast(keysym);
        return buf[0..1];
    }

    // Algorithmic Unicode keysyms: 0x01000000 | codepoint. Spec range starts
    // at U+0100, but accept any codepoint — some producers encode low ones too.
    if (keysym > 0x01000000 and keysym <= 0x0110ffff) {
        return writeCodepoint(@intCast(keysym & 0x00ff_ffff), style, buf);
    }

    // Legacy table (Latin-N, Cyrillic, Greek, …), sorted — binary search.
    if (lookupUnicode(keysym)) |cp| return writeCodepoint(cp, style, buf);

    // Last resort: hex spelling. Unknown but honest.
    return std.fmt.bufPrint(buf, "0x{x:0>4}", .{keysym}) catch copy(buf, "?");
}

fn lookupUnicode(keysym: u32) ?u21 {
    const t = &unicode_table.table;
    var lo: usize = 0;
    var hi: usize = t.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (t[mid].keysym == keysym) return t[mid].codepoint;
        if (t[mid].keysym < keysym) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn writeCodepoint(cp: u21, style: Style, buf: []u8) []const u8 {
    if (style == .ascii and cp > 0x7e) return copy(buf, "?");
    const n = std.unicode.utf8Encode(cp, buf) catch return copy(buf, "?");
    return buf[0..n];
}

fn copy(buf: []u8, name: []const u8) []const u8 {
    const n = @min(buf.len, name.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}

/// Fixed names for control/function keysyms. Returns null when the keysym
/// isn't a named special (then Unicode/ASCII resolution applies).
fn named(keysym: u32, style: Style) ?[]const u8 {
    return switch (keysym) {
        0x20 => "Space", // show the invisible one by name
        0xff0d => "Enter",
        0xff8d => "KP_Enter",
        0xff1b => "Esc",
        0xff09 => "Tab",
        0xfe20 => "Tab", // ISO_Left_Tab (Shift+Tab delivers this)
        0xff08 => "Backspace",
        0xffff => "Del",
        0xff63 => "Ins",
        0xff50 => "Home",
        0xff57 => "End",
        0xff55 => "PgUp",
        0xff56 => "PgDn",
        0xff51 => if (style == .pretty) "←" else "Left",
        0xff52 => if (style == .pretty) "↑" else "Up",
        0xff53 => if (style == .pretty) "→" else "Right",
        0xff54 => if (style == .pretty) "↓" else "Down",
        0xff61 => "Print",
        0xff14 => "ScrollLock",
        0xff13 => "Pause",
        0xff67 => "Menu",
        0xffe1 => "Shift",
        0xffe2 => "Shift",
        0xffe3 => "Ctrl",
        0xffe4 => "Ctrl",
        0xffe9 => "Alt",
        0xffea => "Alt",
        0xffeb => "Super",
        0xffec => "Super",
        0xffe5 => "CapsLock",
        0xff7f => "NumLock",
        0xfe03 => "AltGr",
        // F1..F35 (0xffbe..0xffe0; 0xffe1 is already Shift_L)
        0xffbe...0xffe0 => fkeyName(keysym),
        // Keypad
        0xffb0...0xffb9 => kpDigitName(keysym),
        0xffaa => "KP*",
        0xffab => "KP+",
        0xffad => "KP-",
        0xffae => "KP.",
        0xffaf => "KP/",
        0xffbd => "KP=",
        // Common XF86 media keys (from XF86keysym.h, stable values).
        0x1008ff11 => "VolDn",
        0x1008ff13 => "VolUp",
        0x1008ff12 => "Mute",
        0x1008ffb2 => "MicMute",
        0x1008ff02 => "BrightUp",
        0x1008ff03 => "BrightDn",
        0x1008ff14 => "Play",
        0x1008ff15 => "Stop",
        0x1008ff16 => "Prev",
        0x1008ff17 => "Next",
        else => null,
    };
}

/// F1..F35 names, precomputed so `named()` can return a static slice.
fn fkeyName(keysym: u32) []const u8 {
    const names = [_][]const u8{
        "F1",  "F2",  "F3",  "F4",  "F5",  "F6",  "F7",  "F8",  "F9",  "F10",
        "F11", "F12", "F13", "F14", "F15", "F16", "F17", "F18", "F19", "F20",
        "F21", "F22", "F23", "F24", "F25", "F26", "F27", "F28", "F29", "F30",
        "F31", "F32", "F33", "F34", "F35",
    };
    const idx = keysym - 0xffbe;
    if (idx >= names.len) return "F?";
    return names[idx];
}

fn kpDigitName(keysym: u32) []const u8 {
    const names = [_][]const u8{
        "KP0", "KP1", "KP2", "KP3", "KP4", "KP5", "KP6", "KP7", "KP8", "KP9",
    };
    return names[keysym - 0xffb0];
}

// ── Tests ────────────────────────────────────────────────────

test "label: printable ascii identity" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a", label('a', .ascii, &buf));
    try std.testing.expectEqualStrings("T", label('T', .ascii, &buf));
    try std.testing.expectEqualStrings("@", label('@', .ascii, &buf));
}

test "label: named specials" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Enter", label(0xff0d, .ascii, &buf));
    try std.testing.expectEqualStrings("Esc", label(0xff1b, .ascii, &buf));
    try std.testing.expectEqualStrings("Space", label(0x20, .ascii, &buf));
    try std.testing.expectEqualStrings("F11", label(0xffc8, .ascii, &buf));
    try std.testing.expectEqualStrings("VolUp", label(0x1008ff13, .ascii, &buf));
}

test "label: arrows differ by style" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Left", label(0xff51, .ascii, &buf));
    try std.testing.expectEqualStrings("←", label(0xff51, .pretty, &buf));
}

test "label: cyrillic via legacy table" {
    var buf: [16]u8 = undefined;
    // XK_Cyrillic_ve = 0x06d7 → U+0432 в
    try std.testing.expectEqualStrings("в", label(0x06d7, .pretty, &buf));
    // ascii style folds to '?'
    try std.testing.expectEqualStrings("?", label(0x06d7, .ascii, &buf));
    // XK_Ukrainian_i = 0x06a6 → U+0456 і
    try std.testing.expectEqualStrings("і", label(0x06a6, .pretty, &buf));
}

test "label: algorithmic unicode keysym" {
    var buf: [16]u8 = undefined;
    // 0x01000000 | U+00E9 é
    try std.testing.expectEqualStrings("é", label(0x010000e9, .pretty, &buf));
}

test "label: unknown keysym is hex" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0xfefe", label(0xfefe, .ascii, &buf));
}

test "isModifier" {
    try std.testing.expect(isModifier(0xffe1)); // Shift_L
    try std.testing.expect(isModifier(0xffeb)); // Super_L
    try std.testing.expect(isModifier(0xfe03)); // AltGr
    try std.testing.expect(!isModifier('a'));
    try std.testing.expect(!isModifier(0xff0d)); // Enter
}
