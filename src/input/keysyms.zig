//! XKB keysym constants used by the keyboard event handler.
//! Replaces scattered inline const definitions in main.zig.

// Navigation
pub const Page_Up: u32 = 0xff55;
pub const Page_Down: u32 = 0xff56;
pub const Return: u32 = 0xff0d;
pub const Escape: u32 = 0xff1b;
pub const BackSpace: u32 = 0xff08;
pub const Tab: u32 = 0xff09;
pub const Delete: u32 = 0xffff;
pub const Home: u32 = 0xff50;
pub const End: u32 = 0xff57;
pub const Insert: u32 = 0xff63;

// Arrows
pub const Left: u32 = 0xff51;
pub const Up: u32 = 0xff52;
pub const Right: u32 = 0xff53;
pub const Down: u32 = 0xff54;

// Function keys
pub const F1: u32 = 0xffbe;
pub const F2: u32 = 0xffbf;
pub const F3: u32 = 0xffc0;
pub const F4: u32 = 0xffc1;
pub const F5: u32 = 0xffc2;
pub const F6: u32 = 0xffc3;
pub const F7: u32 = 0xffc4;
pub const F8: u32 = 0xffc5;
pub const F9: u32 = 0xffc6;
pub const F10: u32 = 0xffc7;
pub const F11: u32 = 0xffc8;
pub const F12: u32 = 0xffc9;

// Letters (for Ctrl+Shift+C/V copy/paste)
pub const C_upper: u32 = 0x0043;
pub const C_lower: u32 = 0x0063;
pub const V_upper: u32 = 0x0056;
pub const V_lower: u32 = 0x0076;

// Modifier masks (X11)
pub const CTRL_MASK: u32 = 4;
pub const SHIFT_MASK: u32 = 1;
pub const ALT_MASK: u32 = 8;

/// SS3-form arrow for application-cursor-keys (DECCKM) mode, or "" for a
/// non-arrow keysym. The windowed input path emits CSI arrows by default
/// (`keysymToEscape`); when the focused app has enabled DECCKM (`ESC[?1h`),
/// arrows must be SS3 (`ESC O x`) instead — readline / ncurses / Ink TUIs
/// (e.g. claude-code) rely on this for menu navigation.
pub fn ss3Arrow(keysym: u32) []const u8 {
    return switch (keysym) {
        Up => "\x1bOA",
        Down => "\x1bOB",
        Right => "\x1bOC",
        Left => "\x1bOD",
        else => "",
    };
}

/// Encode a key for the PTY from its XKB keysym, for paths where the host's
/// `xkb_state_key_get_utf8` produced nothing (arrows, navigation, F-keys) —
/// used by teruwm-native panes, which otherwise drop these keys entirely.
/// DECCKM-aware: arrows use SS3 (`ESC O x`) in application-cursor mode and CSI
/// (`ESC [ x`) otherwise, matching the MCP send_keys contract. "" = unmapped.
pub fn escapeForKeysym(keysym: u32, app_cursor: bool) []const u8 {
    return switch (keysym) {
        Return => "\r",
        BackSpace => "\x7f",
        Tab => "\t",
        Escape => "\x1b",
        Delete => "\x1b[3~",
        Up => if (app_cursor) "\x1bOA" else "\x1b[A",
        Down => if (app_cursor) "\x1bOB" else "\x1b[B",
        Right => if (app_cursor) "\x1bOC" else "\x1b[C",
        Left => if (app_cursor) "\x1bOD" else "\x1b[D",
        Home => "\x1b[H",
        End => "\x1b[F",
        Page_Up => "\x1b[5~",
        Page_Down => "\x1b[6~",
        Insert => "\x1b[2~",
        F1 => "\x1bOP",
        F2 => "\x1bOQ",
        F3 => "\x1bOR",
        F4 => "\x1bOS",
        F5 => "\x1b[15~",
        F6 => "\x1b[17~",
        F7 => "\x1b[18~",
        F8 => "\x1b[19~",
        F9 => "\x1b[20~",
        F10 => "\x1b[21~",
        F11 => "\x1b[23~",
        F12 => "\x1b[24~",
        else => "",
    };
}

test "keysym values match XKB spec" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0xff0d), Return);
    try std.testing.expectEqual(@as(u32, 0xff1b), Escape);
    try std.testing.expectEqual(@as(u32, 0x0043), C_upper);
    try std.testing.expectEqual(@as(u32, 0xff52), Up);
}

test "escapeForKeysym + ss3Arrow honour DECCKM" {
    const std = @import("std");
    // Arrows: CSI normally, SS3 under application-cursor-keys.
    try std.testing.expectEqualStrings("\x1b[A", escapeForKeysym(Up, false));
    try std.testing.expectEqualStrings("\x1bOA", escapeForKeysym(Up, true));
    try std.testing.expectEqualStrings("\x1b[D", escapeForKeysym(Left, false));
    try std.testing.expectEqualStrings("\x1bOD", escapeForKeysym(Left, true));
    // Nav / function keys have a single form.
    try std.testing.expectEqualStrings("\x1b[5~", escapeForKeysym(Page_Up, true));
    try std.testing.expectEqualStrings("\x1bOP", escapeForKeysym(F1, false));
    try std.testing.expectEqual(@as(usize, 0), escapeForKeysym(0x12345, true).len);
    // ss3Arrow only matches arrows.
    try std.testing.expectEqualStrings("\x1bOC", ss3Arrow(Right));
    try std.testing.expectEqual(@as(usize, 0), ss3Arrow(Return).len);
}
