//! System clipboard integration via xclip.
//!
//! Provides copy/paste operations by forking xclip as a child process.
//! Uses shared fork+exec helpers from compat.zig to avoid duplication.

const std = @import("std");
const posix = std.posix;
const compat = @import("../compat.zig");
const Pty = @import("../pty/Pty.zig");

/// Copy text to the system clipboard via xclip (fork + pipe stdin).
pub fn copy(text: []const u8) void {
    const argv = [_:null]?[*:0]const u8{
        "/usr/bin/xclip",
        "-selection",
        "clipboard",
    };
    compat.forkExecPipeStdin(&argv, text);
}

/// Paste from the system clipboard via xclip, writing output to the PTY.
pub fn paste(pty: *const Pty) void {
    const argv = [_:null]?[*:0]const u8{
        "/usr/bin/xclip",
        "-selection",
        "clipboard",
        "-o",
    };
    compat.forkExecReadStdout(&argv, pty.master);
}
