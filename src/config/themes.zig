//! Built-in base16 color themes.
//! Each theme defines 16 ANSI colors + semantic colors (bg, fg, cursor, etc.).

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

/// Gruvbox Dark — retro groove color scheme by morhetz.
pub const gruvbox_dark = ColorScheme{
    .ansi = .{
        0xFF282828, // 0  black
        0xFFCC241D, // 1  red
        0xFF98971A, // 2  green
        0xFFD79921, // 3  yellow
        0xFF458588, // 4  blue
        0xFFB16286, // 5  magenta
        0xFF689D6A, // 6  cyan
        0xFFA89984, // 7  white
        0xFF928374, // 8  bright black
        0xFFFB4934, // 9  bright red
        0xFFB8BB26, // 10 bright green
        0xFFFABD2F, // 11 bright yellow
        0xFF83A598, // 12 bright blue
        0xFFD3869B, // 13 bright magenta
        0xFF8EC07C, // 14 bright cyan
        0xFFEBDBB2, // 15 bright white
    },
    .bg = 0xFF282828,
    .fg = 0xFFEBDBB2,
    .cursor = 0xFFD79921,
    .selection_bg = 0xFF3C3836,
    .border_active = 0xFFD79921,
    .border_inactive = 0xFF3C3836,
};

/// Dracula — a dark theme for code editors and terminals.
pub const dracula = ColorScheme{
    .ansi = .{
        0xFF21222C, // 0  black
        0xFFFF5555, // 1  red
        0xFF50FA7B, // 2  green
        0xFFF1FA8C, // 3  yellow
        0xFFBD93F9, // 4  blue
        0xFFFF79C6, // 5  magenta
        0xFF8BE9FD, // 6  cyan
        0xFFF8F8F2, // 7  white
        0xFF6272A4, // 8  bright black (comment)
        0xFFFF6E6E, // 9  bright red
        0xFF69FF94, // 10 bright green
        0xFFFFFFA5, // 11 bright yellow
        0xFFD6ACFF, // 12 bright blue
        0xFFFF92DF, // 13 bright magenta
        0xFFA4FFFF, // 14 bright cyan
        0xFFFFFFFF, // 15 bright white
    },
    .bg = 0xFF282A36,
    .fg = 0xFFF8F8F2,
    .cursor = 0xFFBD93F9,
    .selection_bg = 0xFF44475A,
    .border_active = 0xFFBD93F9,
    .border_inactive = 0xFF44475A,
};

/// Nord — an arctic, north-bluish color palette.
pub const nord = ColorScheme{
    .ansi = .{
        0xFF3B4252, // 0  black       (nord1)
        0xFFBF616A, // 1  red
        0xFFA3BE8C, // 2  green
        0xFFEBCB8B, // 3  yellow
        0xFF81A1C1, // 4  blue
        0xFFB48EAD, // 5  magenta
        0xFF88C0D0, // 6  cyan
        0xFFE5E9F0, // 7  white       (nord5)
        0xFF4C566A, // 8  bright black (nord3)
        0xFFBF616A, // 9  bright red
        0xFFA3BE8C, // 10 bright green
        0xFFEBCB8B, // 11 bright yellow
        0xFF81A1C1, // 12 bright blue
        0xFFB48EAD, // 13 bright magenta
        0xFF8FBCBB, // 14 bright cyan  (nord7)
        0xFFECEFF4, // 15 bright white (nord6)
    },
    .bg = 0xFF2E3440,
    .fg = 0xFFD8DEE9,
    .cursor = 0xFF88C0D0,
    .selection_bg = 0xFF434C5E,
    .border_active = 0xFF88C0D0,
    .border_inactive = 0xFF434C5E,
};

/// Solarized Dark — precision colors for machines and people by Ethan Schoonover.
pub const solarized_dark = ColorScheme{
    .ansi = .{
        0xFF073642, // 0  black       (base02)
        0xFFDC322F, // 1  red
        0xFF859900, // 2  green
        0xFFB58900, // 3  yellow
        0xFF268BD2, // 4  blue
        0xFFD33682, // 5  magenta
        0xFF2AA198, // 6  cyan
        0xFFEEE8D5, // 7  white       (base2)
        0xFF002B36, // 8  bright black (base03)
        0xFFCB4B16, // 9  bright red   (orange)
        0xFF586E75, // 10 bright green (base01)
        0xFF657B83, // 11 bright yellow(base00)
        0xFF839496, // 12 bright blue  (base0)
        0xFF6C71C4, // 13 bright magenta(violet)
        0xFF93A1A1, // 14 bright cyan  (base1)
        0xFFFDF6E3, // 15 bright white (base3)
    },
    .bg = 0xFF002B36,
    .fg = 0xFF839496,
    .cursor = 0xFF268BD2,
    .selection_bg = 0xFF073642,
    .border_active = 0xFF268BD2,
    .border_inactive = 0xFF073642,
};

/// Solarized Light — light variant of Solarized.
pub const solarized_light = ColorScheme{
    .ansi = .{
        0xFF073642, // 0  black       (base02)
        0xFFDC322F, // 1  red
        0xFF859900, // 2  green
        0xFFB58900, // 3  yellow
        0xFF268BD2, // 4  blue
        0xFFD33682, // 5  magenta
        0xFF2AA198, // 6  cyan
        0xFFEEE8D5, // 7  white       (base2)
        0xFF002B36, // 8  bright black (base03)
        0xFFCB4B16, // 9  bright red   (orange)
        0xFF586E75, // 10 bright green (base01)
        0xFF657B83, // 11 bright yellow(base00)
        0xFF839496, // 12 bright blue  (base0)
        0xFF6C71C4, // 13 bright magenta(violet)
        0xFF93A1A1, // 14 bright cyan  (base1)
        0xFFFDF6E3, // 15 bright white (base3)
    },
    .bg = 0xFFFDF6E3,
    .fg = 0xFF657B83,
    .cursor = 0xFF268BD2,
    .selection_bg = 0xFFEEE8D5,
    .border_active = 0xFF268BD2,
    .border_inactive = 0xFFEEE8D5,
};

/// Catppuccin Mocha — soothing pastel theme, darkest flavor.
pub const catppuccin_mocha = ColorScheme{
    .ansi = .{
        0xFF45475A, // 0  black       (surface1)
        0xFFF38BA8, // 1  red
        0xFFA6E3A1, // 2  green
        0xFFF9E2AF, // 3  yellow
        0xFF89B4FA, // 4  blue
        0xFFF5C2E7, // 5  magenta     (pink)
        0xFF94E2D5, // 6  cyan        (teal)
        0xFFBAC2DE, // 7  white       (subtext1)
        0xFF585B70, // 8  bright black (surface2)
        0xFFF38BA8, // 9  bright red
        0xFFA6E3A1, // 10 bright green
        0xFFF9E2AF, // 11 bright yellow
        0xFF89B4FA, // 12 bright blue
        0xFFF5C2E7, // 13 bright magenta
        0xFF94E2D5, // 14 bright cyan
        0xFFA6ADC8, // 15 bright white (subtext0)
    },
    .bg = 0xFF1E1E2E,
    .fg = 0xFFCDD6F4,
    .cursor = 0xFF89B4FA,
    .selection_bg = 0xFF313244,
    .border_active = 0xFF89B4FA,
    .border_inactive = 0xFF313244,
};

/// Tokyo Night — a clean dark theme inspired by Tokyo city lights.
pub const tokyonight = ColorScheme{
    .ansi = .{
        0xFF15161E, // 0  black
        0xFFF7768E, // 1  red
        0xFF9ECE6A, // 2  green
        0xFFE0AF68, // 3  yellow
        0xFF7AA2F7, // 4  blue
        0xFFBB9AF7, // 5  magenta
        0xFF7DCFFF, // 6  cyan
        0xFFA9B1D6, // 7  white
        0xFF414868, // 8  bright black (comment)
        0xFFF7768E, // 9  bright red
        0xFF9ECE6A, // 10 bright green
        0xFFE0AF68, // 11 bright yellow
        0xFF7AA2F7, // 12 bright blue
        0xFFBB9AF7, // 13 bright magenta
        0xFF7DCFFF, // 14 bright cyan
        0xFFC0CAF5, // 15 bright white
    },
    .bg = 0xFF1A1B26,
    .fg = 0xFFC0CAF5,
    .cursor = 0xFF7AA2F7,
    .selection_bg = 0xFF283457,
    .border_active = 0xFF7AA2F7,
    .border_inactive = 0xFF283457,
};

/// One Dark — Atom's iconic dark theme.
pub const onedark = ColorScheme{
    .ansi = .{
        0xFF282C34, // 0  black
        0xFFE06C75, // 1  red
        0xFF98C379, // 2  green
        0xFFE5C07B, // 3  yellow
        0xFF61AFEF, // 4  blue
        0xFFC678DD, // 5  magenta
        0xFF56B6C2, // 6  cyan
        0xFFABB2BF, // 7  white
        0xFF545862, // 8  bright black (comment)
        0xFFE06C75, // 9  bright red
        0xFF98C379, // 10 bright green
        0xFFE5C07B, // 11 bright yellow
        0xFF61AFEF, // 12 bright blue
        0xFFC678DD, // 13 bright magenta
        0xFF56B6C2, // 14 bright cyan
        0xFFD7DAE0, // 15 bright white
    },
    .bg = 0xFF282C34,
    .fg = 0xFFABB2BF,
    .cursor = 0xFF61AFEF,
    .selection_bg = 0xFF3E4452,
    .border_active = 0xFF61AFEF,
    .border_inactive = 0xFF3E4452,
};

/// Kanagawa — a dark theme inspired by Katsushika Hokusai's The Great Wave.
pub const kanagawa = ColorScheme{
    .ansi = .{
        0xFF16161D, // 0  black       (sumiInk0)
        0xFFC34043, // 1  red         (autumnRed)
        0xFF76946A, // 2  green       (autumnGreen)
        0xFFC0A36E, // 3  yellow      (boatYellow2)
        0xFF7E9CD8, // 4  blue        (crystalBlue)
        0xFF957FB8, // 5  magenta     (oniViolet)
        0xFF6A9589, // 6  cyan        (waveAqua1)
        0xFFDCD7BA, // 7  white       (fujiWhite)
        0xFF727169, // 8  bright black (fujiGray)
        0xFFE82424, // 9  bright red  (samuraiRed)
        0xFF98BB6C, // 10 bright green(springGreen)
        0xFFE6C384, // 11 bright yellow(carpYellow)
        0xFF7FB4CA, // 12 bright blue (springBlue)
        0xFFD27E99, // 13 bright magenta(sakuraPink)
        0xFF7AA89F, // 14 bright cyan (waveAqua2)
        0xFFC8C093, // 15 bright white(oldWhite)
    },
    .bg = 0xFF1F1F28,
    .fg = 0xFFDCD7BA,
    .cursor = 0xFF7E9CD8,
    .selection_bg = 0xFF2D4F67,
    .border_active = 0xFF7E9CD8,
    .border_inactive = 0xFF2D4F67,
};

/// Look up a built-in theme by name. Returns null if not found.
/// Accepts common aliases (e.g. "gruvbox" for "gruvbox_dark").
pub fn getBuiltin(name: []const u8) ?ColorScheme {
    if (std.mem.eql(u8, name, "miozu")) return miozu;
    if (std.mem.eql(u8, name, "gruvbox") or std.mem.eql(u8, name, "gruvbox_dark")) return gruvbox_dark;
    if (std.mem.eql(u8, name, "dracula")) return dracula;
    if (std.mem.eql(u8, name, "nord")) return nord;
    if (std.mem.eql(u8, name, "solarized_dark") or std.mem.eql(u8, name, "solarized-dark")) return solarized_dark;
    if (std.mem.eql(u8, name, "solarized_light") or std.mem.eql(u8, name, "solarized-light")) return solarized_light;
    if (std.mem.eql(u8, name, "catppuccin_mocha") or std.mem.eql(u8, name, "catppuccin-mocha") or std.mem.eql(u8, name, "catppuccin")) return catppuccin_mocha;
    if (std.mem.eql(u8, name, "tokyonight") or std.mem.eql(u8, name, "tokyo-night") or std.mem.eql(u8, name, "tokyo_night")) return tokyonight;
    if (std.mem.eql(u8, name, "onedark") or std.mem.eql(u8, name, "one-dark") or std.mem.eql(u8, name, "one_dark")) return onedark;
    if (std.mem.eql(u8, name, "kanagawa")) return kanagawa;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "getBuiltin returns known themes" {
    try std.testing.expect(getBuiltin("miozu") != null);
    try std.testing.expect(getBuiltin("gruvbox") != null);
    try std.testing.expect(getBuiltin("gruvbox_dark") != null);
    try std.testing.expect(getBuiltin("dracula") != null);
    try std.testing.expect(getBuiltin("nord") != null);
    try std.testing.expect(getBuiltin("solarized_dark") != null);
    try std.testing.expect(getBuiltin("solarized-dark") != null);
    try std.testing.expect(getBuiltin("solarized_light") != null);
    try std.testing.expect(getBuiltin("catppuccin_mocha") != null);
    try std.testing.expect(getBuiltin("catppuccin") != null);
    try std.testing.expect(getBuiltin("tokyonight") != null);
    try std.testing.expect(getBuiltin("tokyo-night") != null);
    try std.testing.expect(getBuiltin("onedark") != null);
    try std.testing.expect(getBuiltin("one-dark") != null);
    try std.testing.expect(getBuiltin("kanagawa") != null);
}

test "getBuiltin returns null for unknown" {
    try std.testing.expect(getBuiltin("nonexistent") == null);
    try std.testing.expect(getBuiltin("") == null);
    try std.testing.expect(getBuiltin("DRACULA") == null); // case-sensitive
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

test "dracula theme has correct bg" {
    const d = dracula;
    try std.testing.expectEqual(@as(u32, 0xFF282A36), d.bg);
    try std.testing.expectEqual(@as(u32, 0xFFF8F8F2), d.fg);
    try std.testing.expectEqual(@as(u32, 0xFFFF5555), d.ansi[1]); // red
    try std.testing.expectEqual(@as(u32, 0xFF50FA7B), d.ansi[2]); // green
}

test "solarized light has light bg" {
    const s = solarized_light;
    // bg should have high RGB values (light theme)
    const r = (s.bg >> 16) & 0xFF;
    const g = (s.bg >> 8) & 0xFF;
    const b = s.bg & 0xFF;
    try std.testing.expect(r > 200);
    try std.testing.expect(g > 200);
    try std.testing.expect(b > 200);
}

test "all themes have 16 ansi colors" {
    const all = [_]ColorScheme{
        miozu,
        gruvbox_dark,
        dracula,
        nord,
        solarized_dark,
        solarized_light,
        catppuccin_mocha,
        tokyonight,
        onedark,
        kanagawa,
    };
    for (all) |theme| {
        // Every ANSI color must have full alpha
        for (theme.ansi) |color| {
            try std.testing.expectEqual(@as(u32, 0xFF), (color >> 24) & 0xFF);
        }
        // Semantic colors must have full alpha
        try std.testing.expectEqual(@as(u32, 0xFF), (theme.bg >> 24) & 0xFF);
        try std.testing.expectEqual(@as(u32, 0xFF), (theme.fg >> 24) & 0xFF);
        try std.testing.expectEqual(@as(u32, 0xFF), (theme.cursor >> 24) & 0xFF);
    }
}
