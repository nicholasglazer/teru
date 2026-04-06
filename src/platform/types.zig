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
    mouse_motion: struct { x: u32, y: u32 },
    resize: struct { width: u32, height: u32 },
    wl_modifiers: ModifiersEvent,
    close,
    focus_in,
    focus_out,
    expose,
    none,
};

pub const Size = struct { width: u32, height: u32 };

/// X11 connection info for keyboard layout query.
pub const X11Info = struct { conn: *anyopaque, root: u32 };
