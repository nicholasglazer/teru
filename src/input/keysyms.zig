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

// Letters (for Ctrl+Shift+C/V copy/paste)
pub const C_upper: u32 = 0x0043;
pub const C_lower: u32 = 0x0063;
pub const V_upper: u32 = 0x0056;
pub const V_lower: u32 = 0x0076;

// Modifier masks (X11)
pub const CTRL_MASK: u32 = 4;
pub const SHIFT_MASK: u32 = 1;
pub const ALT_MASK: u32 = 8;

test "keysym values match XKB spec" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0xff0d), Return);
    try std.testing.expectEqual(@as(u32, 0xff1b), Escape);
    try std.testing.expectEqual(@as(u32, 0x0043), C_upper);
}
