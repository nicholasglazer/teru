//! Top-level platform abstraction.
//!
//! Selects the correct windowing backend at comptime based on the
//! target OS.  Linux: X11 (Wayland fallback planned), macOS: AppKit
//! via ObjC runtime, Windows: Win32 API.

const builtin = @import("builtin");

pub const Event = @import("types.zig").Event;
pub const KeyEvent = @import("types.zig").KeyEvent;
pub const MouseButton = @import("types.zig").MouseButton;
pub const MouseEvent = @import("types.zig").MouseEvent;
pub const Size = @import("types.zig").Size;
pub const X11Info = @import("types.zig").X11Info;

pub const Platform = if (builtin.os.tag == .linux)
    @import("linux/platform.zig").Platform
else if (builtin.os.tag == .macos)
    @import("macos/platform.zig").Platform
else if (builtin.os.tag == .windows)
    @import("windows/platform.zig").Platform
else
    @compileError("unsupported platform: " ++ @tagName(builtin.os.tag));
