//! System clipboard integration.
//!
//! Auto-detects the display server and uses the appropriate clipboard tool:
//! - Wayland: wl-copy / wl-paste (from wl-clipboard package)
//! - X11: xclip
//!
//! Detection: WAYLAND_DISPLAY env var present → Wayland, otherwise X11.
//! Uses shared fork+exec helpers from compat.zig.

const std = @import("std");
const posix = std.posix;
const compat = @import("../compat.zig");
const Pty = @import("../pty/Pty.zig");

const DisplayServer = enum { wayland, x11 };

fn detect() DisplayServer {
    return if (compat.getenv("WAYLAND_DISPLAY") != null) .wayland else .x11;
}

/// Copy text to the system clipboard.
pub fn copy(text: []const u8) void {
    switch (detect()) {
        .wayland => {
            const argv = [_:null]?[*:0]const u8{
                "/usr/bin/wl-copy",
            };
            compat.forkExecPipeStdin(&argv, text);
        },
        .x11 => {
            const argv = [_:null]?[*:0]const u8{
                "/usr/bin/xclip",
                "-selection",
                "clipboard",
            };
            compat.forkExecPipeStdin(&argv, text);
        },
    }
}

/// Paste from the system clipboard, writing output to the PTY.
pub fn paste(pty: *const Pty) void {
    switch (detect()) {
        .wayland => {
            const argv = [_:null]?[*:0]const u8{
                "/usr/bin/wl-paste",
                "--no-newline",
            };
            compat.forkExecReadStdout(&argv, pty.master);
        },
        .x11 => {
            const argv = [_:null]?[*:0]const u8{
                "/usr/bin/xclip",
                "-selection",
                "clipboard",
                "-o",
            };
            compat.forkExecReadStdout(&argv, pty.master);
        },
    }
}
