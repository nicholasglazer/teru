//! Built-in base16 color themes.
//! Each theme defines 16 ANSI colors + semantic colors (bg, fg, cursor, etc.).
//! External themes are loaded from ~/.config/teru/themes/<name>.conf via Config.

const std = @import("std");
const ColorScheme = @import("Config.zig").ColorScheme;

/// Miozu — the default teru theme. Warm orange accent on dark blue-gray.
pub const miozu = ColorScheme{
    .ansi = ColorScheme.default_ansi,
    .bg = 0xFF232733,
    .fg = 0xFFD0D2DB,
    .cursor = 0xFFFF9837,
    .selection_bg = 0xFF3E4359,
    .border_active = 0xFFFF9837,
    .border_inactive = 0xFF3E4359,
};

/// Look up a built-in theme by name. Returns null if not found.
pub fn getBuiltin(name: []const u8) ?ColorScheme {
    if (std.mem.eql(u8, name, "miozu")) return miozu;
    return null;
}

/// Apply a base16 key (base00-base0F) to a ColorScheme.
/// Maps base16 slots to ANSI palette entries and semantic colors following
/// the standard base16 convention:
///   base00 → bg, color0
///   base01 → selection_bg
///   base02 → border_inactive
///   base03 → color8 (comments/bright black)
///   base04 → (unused)
///   base05 → fg, color7
///   base06 → color15 (light fg)
///   base07 → border_active
///   base08 → color1, color9 (red)
///   base09 → cursor (orange accent)
///   base0A → color3, color11 (yellow)
///   base0B → color2, color10 (green)
///   base0C → color6, color14 (cyan)
///   base0D → color4, color12 (blue)
///   base0E → color5, color13 (magenta)
///   base0F → (brown, unused in ANSI 0-15)
/// Returns true if the key was a valid base16 key.
pub fn applyBase16Key(scheme: *ColorScheme, key: []const u8, color: u32) bool {
    if (key.len != 6 or !std.mem.startsWith(u8, key, "base0")) return false;
    const hex_ch = key[5];
    const slot: u8 = switch (hex_ch) {
        '0'...'9' => hex_ch - '0',
        'A'...'F' => hex_ch - 'A' + 10,
        'a'...'f' => hex_ch - 'a' + 10,
        else => return false,
    };
    switch (slot) {
        0x00 => {
            scheme.bg = color;
            scheme.ansi[0] = color;
        },
        0x01 => {
            scheme.selection_bg = color;
        },
        0x02 => {
            scheme.border_inactive = color;
        },
        0x03 => {
            scheme.ansi[8] = color;
        },
        0x04 => {}, // unused
        0x05 => {
            scheme.fg = color;
            scheme.ansi[7] = color;
        },
        0x06 => {
            scheme.ansi[15] = color;
        },
        0x07 => {
            scheme.border_active = color;
        },
        0x08 => {
            scheme.ansi[1] = color;
            scheme.ansi[9] = color;
        },
        0x09 => {
            scheme.cursor = color;
        },
        0x0A => {
            scheme.ansi[3] = color;
            scheme.ansi[11] = color;
        },
        0x0B => {
            scheme.ansi[2] = color;
            scheme.ansi[10] = color;
        },
        0x0C => {
            scheme.ansi[6] = color;
            scheme.ansi[14] = color;
        },
        0x0D => {
            scheme.ansi[4] = color;
            scheme.ansi[12] = color;
        },
        0x0E => {
            scheme.ansi[5] = color;
            scheme.ansi[13] = color;
        },
        0x0F => {}, // brown, unused in ANSI 0-15
        else => unreachable,
    }
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

test "getBuiltin returns miozu" {
    try std.testing.expect(getBuiltin("miozu") != null);
}

test "getBuiltin returns null for removed/unknown themes" {
    try std.testing.expect(getBuiltin("nonexistent") == null);
    try std.testing.expect(getBuiltin("") == null);
    try std.testing.expect(getBuiltin("MIOZU") == null); // case-sensitive
    try std.testing.expect(getBuiltin("dracula") == null);
    try std.testing.expect(getBuiltin("gruvbox") == null);
    try std.testing.expect(getBuiltin("nord") == null);
}

test "miozu matches ColorScheme defaults" {
    const m = miozu;
    const d = ColorScheme{};
    try std.testing.expectEqual(d.bg, m.bg);
    try std.testing.expectEqual(d.fg, m.fg);
    try std.testing.expectEqual(d.cursor, m.cursor);
    try std.testing.expectEqual(d.selection_bg, m.selection_bg);
    try std.testing.expectEqual(d.ansi, m.ansi);
}

test "miozu has full alpha on all colors" {
    for (miozu.ansi) |color| {
        try std.testing.expectEqual(@as(u32, 0xFF), (color >> 24) & 0xFF);
    }
    try std.testing.expectEqual(@as(u32, 0xFF), (miozu.bg >> 24) & 0xFF);
    try std.testing.expectEqual(@as(u32, 0xFF), (miozu.fg >> 24) & 0xFF);
    try std.testing.expectEqual(@as(u32, 0xFF), (miozu.cursor >> 24) & 0xFF);
}

test "applyBase16Key maps base00 to bg and color0" {
    var scheme = ColorScheme{};
    try std.testing.expect(applyBase16Key(&scheme, "base00", 0xFF112233));
    try std.testing.expectEqual(@as(u32, 0xFF112233), scheme.bg);
    try std.testing.expectEqual(@as(u32, 0xFF112233), scheme.ansi[0]);
}

test "applyBase16Key maps base05 to fg and color7" {
    var scheme = ColorScheme{};
    try std.testing.expect(applyBase16Key(&scheme, "base05", 0xFFAABBCC));
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), scheme.fg);
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), scheme.ansi[7]);
}

test "applyBase16Key maps base08 to red (color1, color9)" {
    var scheme = ColorScheme{};
    try std.testing.expect(applyBase16Key(&scheme, "base08", 0xFFFF0000));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), scheme.ansi[1]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), scheme.ansi[9]);
}

test "applyBase16Key maps base09 to cursor" {
    var scheme = ColorScheme{};
    try std.testing.expect(applyBase16Key(&scheme, "base09", 0xFFFF8800));
    try std.testing.expectEqual(@as(u32, 0xFFFF8800), scheme.cursor);
}

test "applyBase16Key maps base0D to blue (color4, color12)" {
    var scheme = ColorScheme{};
    try std.testing.expect(applyBase16Key(&scheme, "base0D", 0xFF0088FF));
    try std.testing.expectEqual(@as(u32, 0xFF0088FF), scheme.ansi[4]);
    try std.testing.expectEqual(@as(u32, 0xFF0088FF), scheme.ansi[12]);
}

test "applyBase16Key maps base01 to selection_bg" {
    var scheme = ColorScheme{};
    try std.testing.expect(applyBase16Key(&scheme, "base01", 0xFF333333));
    try std.testing.expectEqual(@as(u32, 0xFF333333), scheme.selection_bg);
}

test "applyBase16Key maps base07 to border_active" {
    var scheme = ColorScheme{};
    try std.testing.expect(applyBase16Key(&scheme, "base07", 0xFFEEEEEE));
    try std.testing.expectEqual(@as(u32, 0xFFEEEEEE), scheme.border_active);
}

test "applyBase16Key accepts lowercase hex" {
    var scheme = ColorScheme{};
    try std.testing.expect(applyBase16Key(&scheme, "base0a", 0xFFFFFF00));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), scheme.ansi[3]); // yellow
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), scheme.ansi[11]);
}

test "applyBase16Key rejects invalid keys" {
    var scheme = ColorScheme{};
    try std.testing.expect(!applyBase16Key(&scheme, "base0G", 0xFF000000));
    try std.testing.expect(!applyBase16Key(&scheme, "base1", 0xFF000000));
    try std.testing.expect(!applyBase16Key(&scheme, "color0", 0xFF000000));
    try std.testing.expect(!applyBase16Key(&scheme, "", 0xFF000000));
    try std.testing.expect(!applyBase16Key(&scheme, "base10", 0xFF000000));
}
