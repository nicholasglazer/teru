//! System clipboard integration (cross-platform).
//!
//! - Linux: wl-copy/wl-paste (Wayland) or xclip (X11) via fork+exec
//! - macOS: pbcopy/pbpaste via fork+exec
//! - Windows: Win32 clipboard API (OpenClipboard/SetClipboardData)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");
const Pty = @import("../pty/Pty.zig");

/// Copy text to the system clipboard.
pub fn copy(text: []const u8) void {
    switch (builtin.os.tag) {
        .linux => linuxCopy(text),
        .macos => macosCopy(text),
        .windows => windowsCopy(text),
        else => {},
    }
}

/// Paste from the system clipboard, writing output to the PTY.
pub fn paste(pty: *const Pty) void {
    switch (builtin.os.tag) {
        .linux => linuxPaste(pty),
        .macos => macosPaste(pty),
        .windows => windowsPaste(pty),
        else => {},
    }
}

// ── Linux (Wayland / X11) ──────────────────────────────────────

const LinuxDisplay = enum { wayland, x11 };

fn detectLinux() LinuxDisplay {
    return if (compat.getenv("WAYLAND_DISPLAY") != null) .wayland else .x11;
}

fn linuxCopy(text: []const u8) void {
    switch (detectLinux()) {
        .wayland => {
            const argv = [_:null]?[*:0]const u8{"/usr/bin/wl-copy"};
            compat.forkExecPipeStdin(&argv, text);
        },
        .x11 => {
            const argv = [_:null]?[*:0]const u8{ "/usr/bin/xclip", "-selection", "clipboard" };
            compat.forkExecPipeStdin(&argv, text);
        },
    }
}

fn linuxPaste(pty: *const Pty) void {
    switch (detectLinux()) {
        .wayland => {
            const argv = [_:null]?[*:0]const u8{ "/usr/bin/wl-paste", "--no-newline" };
            compat.forkExecReadStdout(&argv, pty.master);
        },
        .x11 => {
            const argv = [_:null]?[*:0]const u8{ "/usr/bin/xclip", "-selection", "clipboard", "-o" };
            compat.forkExecReadStdout(&argv, pty.master);
        },
    }
}

// ── macOS (pbcopy / pbpaste) ───────────────────────────────────

fn macosCopy(text: []const u8) void {
    const argv = [_:null]?[*:0]const u8{"/usr/bin/pbcopy"};
    compat.forkExecPipeStdin(&argv, text);
}

fn macosPaste(pty: *const Pty) void {
    const argv = [_:null]?[*:0]const u8{"/usr/bin/pbpaste"};
    compat.forkExecReadStdout(&argv, pty.master);
}

// ── Windows (Win32 clipboard API) ──────────────────────────────

// Win32 clipboard API externs (link against user32/kernel32)
extern "user32" fn OpenClipboard(hWndNewOwner: ?*anyopaque) callconv(.c) c_int;
extern "user32" fn CloseClipboard() callconv(.c) c_int;
extern "user32" fn EmptyClipboard() callconv(.c) c_int;
extern "user32" fn SetClipboardData(uFormat: u32, hMem: ?*anyopaque) callconv(.c) ?*anyopaque;
extern "user32" fn GetClipboardData(uFormat: u32) callconv(.c) ?*anyopaque;
extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(.c) ?*anyopaque;
extern "kernel32" fn GlobalLock(hMem: *anyopaque) callconv(.c) ?[*]u8;
extern "kernel32" fn GlobalUnlock(hMem: *anyopaque) callconv(.c) c_int;
extern "kernel32" fn GlobalFree(hMem: *anyopaque) callconv(.c) ?*anyopaque;
const CF_UNICODETEXT: u32 = 13;
const GMEM_MOVEABLE: u32 = 0x0002;

fn windowsCopy(text: []const u8) void {
    if (builtin.os.tag != .windows) return;

    // Convert UTF-8 to UTF-16LE into a stack buffer (4096 u16 chars = 8192 bytes)
    var utf16_buf: [4096]u16 = undefined;
    var utf16_len: usize = 0;
    var i: usize = 0;
    while (i < text.len and utf16_len < utf16_buf.len - 1) {
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (i + cp_len > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i..][0..cp_len]) catch break;
        // Encode codepoint as UTF-16
        if (codepoint < 0x10000) {
            utf16_buf[utf16_len] = @intCast(codepoint);
            utf16_len += 1;
        } else if (utf16_len + 1 < utf16_buf.len - 1) {
            // Surrogate pair
            const cp = codepoint - 0x10000;
            utf16_buf[utf16_len] = @intCast(0xD800 + (cp >> 10));
            utf16_buf[utf16_len + 1] = @intCast(0xDC00 + (cp & 0x3FF));
            utf16_len += 2;
        } else break;
        i += cp_len;
    }
    // Null-terminate
    utf16_buf[utf16_len] = 0;

    const byte_size = (utf16_len + 1) * @sizeOf(u16);

    if (OpenClipboard(null) == 0) return;
    _ = EmptyClipboard();

    const hmem = GlobalAlloc(GMEM_MOVEABLE, byte_size) orelse {
        _ = CloseClipboard();
        return;
    };
    const ptr = GlobalLock(hmem) orelse {
        _ = GlobalFree(hmem);
        _ = CloseClipboard();
        return;
    };
    // Copy UTF-16 data including null terminator
    const src_bytes: [*]const u8 = @ptrCast(&utf16_buf);
    @memcpy(ptr[0..byte_size], src_bytes[0..byte_size]);
    _ = GlobalUnlock(hmem);

    _ = SetClipboardData(CF_UNICODETEXT, hmem);
    _ = CloseClipboard();
}

fn windowsPaste(pty: *const Pty) void {
    if (builtin.os.tag != .windows) return;

    if (OpenClipboard(null) == 0) return;
    defer _ = CloseClipboard();

    const hmem = GetClipboardData(CF_UNICODETEXT) orelse return;
    const wide_ptr = GlobalLock(hmem) orelse return;
    defer _ = GlobalUnlock(hmem);

    // Interpret as u16 slice -- find null terminator
    const u16_ptr: [*]const u16 = @ptrCast(@alignCast(wide_ptr));
    var wide_len: usize = 0;
    while (u16_ptr[wide_len] != 0) : (wide_len += 1) {
        if (wide_len >= 65536) break; // safety limit
    }

    // Convert UTF-16 to UTF-8 and write to PTY
    var utf8_buf: [8192]u8 = undefined;
    var utf8_len: usize = 0;
    var wi: usize = 0;
    while (wi < wide_len and utf8_len + 4 <= utf8_buf.len) {
        var codepoint: u21 = u16_ptr[wi];
        wi += 1;
        // Handle surrogate pairs
        if (codepoint >= 0xD800 and codepoint <= 0xDBFF and wi < wide_len) {
            const low: u21 = u16_ptr[wi];
            if (low >= 0xDC00 and low <= 0xDFFF) {
                codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
                wi += 1;
            }
        }
        // Encode as UTF-8
        const seq_len = std.unicode.utf8CodepointSequenceLength(codepoint) catch continue;
        if (utf8_len + seq_len > utf8_buf.len) break;
        _ = std.unicode.utf8Encode(codepoint, utf8_buf[utf8_len..]) catch continue;
        utf8_len += seq_len;
    }

    if (utf8_len > 0) {
        _ = std.c.write(pty.master, &utf8_buf, utf8_len);
    }
}
