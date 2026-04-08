//! Shared platform event types.
//!
//! Canonical definitions for Event, KeyEvent, and Size used by all
//! platform backends (Linux, macOS, Windows). Each backend re-exports
//! these types instead of defining its own copies.

pub const KeyEvent = struct {
    keycode: u32,
    modifiers: u32,
};

pub const MouseButton = enum { left, middle, right, scroll_up, scroll_down };

pub const MouseEvent = struct {
    x: u32, // pixel x
    y: u32, // pixel y
    button: MouseButton,
    modifiers: u32 = 0, // keyboard modifiers (e.g., Ctrl, Shift)
};

pub const ModifiersEvent = struct {
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
};

pub const Event = union(enum) {
    key_press: KeyEvent,
    key_release: KeyEvent,
    mouse_press: MouseEvent,
    mouse_release: MouseEvent,
    mouse_motion: struct { x: u32, y: u32, modifiers: u32 = 0 },
    resize: struct { width: u32, height: u32 },
    wl_modifiers: ModifiersEvent,
    close,
    focus_in,
    focus_out,
    expose,
    none,
};

pub const Size = struct { width: u32, height: u32 };

/// Platform-native keycodes and modifier masks for global shortcuts.
/// Each platform maps physical key positions to its native keycode space.
/// Uses functions for digit keys because macOS IOKit keycodes are non-sequential.
pub const keycodes = switch (@import("builtin").os.tag) {
    .linux => LinuxKeycodes,
    .macos => MacosKeycodes,
    .windows => WindowsKeycodes,
    else => LinuxKeycodes,
};

// Linux: evdev keycode + 8 (XKB convention, shared by X11 and Wayland)
const LinuxKeycodes = struct {
    pub const RALT: u32 = 108;
    pub const ALT_MASK: u32 = 8; // Mod1Mask
    pub const CTRL_MASK: u32 = 4; // ControlMask
    pub const SHIFT_MASK: u32 = 1; // ShiftMask
    pub fn digitToWorkspace(keycode: u32) ?u8 {
        return if (keycode >= 10 and keycode <= 18) @intCast(keycode - 10) else null;
    }
};

// macOS: IOKit virtual key codes (kVK_* from Carbon/Events.h)
// Digit keycodes are non-sequential, so use explicit switch.
const MacosKeycodes = struct {
    pub const RALT: u32 = 61; // kVK_RightOption
    pub const ALT_MASK: u32 = 0x080000; // NSEventModifierFlagOption
    pub const CTRL_MASK: u32 = 0x040000; // NSEventModifierFlagControl
    pub const SHIFT_MASK: u32 = 0x020000; // NSEventModifierFlagShift
    pub fn digitToWorkspace(keycode: u32) ?u8 {
        return switch (keycode) {
            18 => 0, 19 => 1, 20 => 2, 21 => 3, 23 => 4, // kVK_ANSI_1-5
            22 => 5, 26 => 6, 28 => 7, 25 => 8, // kVK_ANSI_6-9
            else => null,
        };
    }
};

// Windows: virtual key codes (VK_*). Digits are 0x31-0x39.
const WindowsKeycodes = struct {
    pub const RALT: u32 = 0xA5; // VK_RMENU
    pub const ALT_MASK: u32 = 0x01; // MOD_ALT
    pub const CTRL_MASK: u32 = 0x02; // MOD_CONTROL
    pub const SHIFT_MASK: u32 = 0x04; // MOD_SHIFT
    pub fn digitToWorkspace(keycode: u32) ?u8 {
        return if (keycode >= 0x31 and keycode <= 0x39) @intCast(keycode - 0x31) else null;
    }
};

/// X11 connection info for keyboard layout query.
pub const X11Info = struct { conn: *anyopaque, root: u32 };
