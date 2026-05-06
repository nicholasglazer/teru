//! System clipboard integration (cross-platform).
//!
//! - Linux: wl-copy/wl-paste (Wayland) or xclip (X11) via fork+exec
//! - macOS: pbcopy/pbpaste via fork+exec
//! - Windows: Win32 clipboard API (OpenClipboard/SetClipboardData)
//!
//! Paste sanitisation
//! ──────────────────
//! Clipboard content is treated as untrusted bytes that may have been
//! placed there by a malicious page or process. Before writing to the
//! PTY we:
//!
//!   1. Strip NUL (0x00) and ESC (0x1B) — ESC could re-enter terminal
//!      escape state and run any DCS / OSC / CSI sequence.
//!   2. Strip embedded `\e[200~` and `\e[201~` byte sequences so a
//!      payload can't fake an end-of-paste marker mid-content and
//!      escape the bracketed-paste envelope.
//!   3. When DEC bracketed-paste mode (DECSET 2004) is OFF, strip
//!      every other C0 control except TAB / LF / CR (the shell can't
//!      treat the content atomically without bracketed paste, so a
//!      newline = "execute the line"; we keep LF/CR for editor-pane
//!      pastes where the shell is out of the picture, but block the
//!      rest of C0).
//!   4. When bracketed-paste IS on, we wrap the sanitised bytes with
//!      `\e[200~` / `\e[201~`. The shell / app sees one paste event
//!      and decides whether to execute, treat as literal, etc.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");
const Pane = @import("Pane.zig");

/// Maximum clipboard size we paste in one shot. Larger pastes are
/// truncated. 64 KiB covers virtually any human-driven paste; the
/// programmatic-paste case (large file dumps) belongs in `cat file`,
/// not the clipboard.
const max_paste_bytes: usize = 64 * 1024;

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

/// Copy text to the system clipboard.
pub fn copy(text: []const u8) void {
    switch (builtin.os.tag) {
        .linux => linuxCopy(text),
        .macos => macosCopy(text),
        .windows => windowsCopy(text),
        else => {},
    }
}

/// Paste from the system clipboard, sanitising and bracketing as
/// needed before writing to `pane`'s PTY.
pub fn paste(pane: *const Pane) void {
    var raw_buf: [max_paste_bytes]u8 = undefined;
    const captured = capture(&raw_buf);
    if (captured == 0) return;
    if (!looksLikeText(raw_buf[0..captured])) return;
    writeSanitised(pane, raw_buf[0..captured]);
}

/// Return true if the bytes look like UTF-8 text we can safely shove into
/// a PTY. Returns false for image/binary clipboards.
///
/// This is the X11 / xclip 0.13 backstop. xclip's `-t UTF8_STRING -o` is
/// supposed to reject mismatched targets, but in 0.13 (still the
/// distro-shipped version on Arch + Debian as of 2026) the target filter
/// is silently ignored on output — `-t` is honoured for input but
/// ignored for output, so requesting `UTF8_STRING` from an image-only
/// clipboard returns the raw PNG/JPEG bytes anyway. Without this guard,
/// pressing Ctrl+Shift+V after a screenshot copy would write 64 KB of
/// binary garbage into the PTY. The PTY master is `O_NONBLOCK`, so a
/// short write drops the trailing bytes (including the closing
/// `\x1b[201~`), which leaves bracketed-paste-aware TUIs (notably
/// claude-code) stuck mid-paste forever, looking like a hang.
///
/// Heuristic, not a parser:
///   - Reject any NUL byte (0x00)
///   - Reject too many high-bit bytes that aren't valid UTF-8 starts
///   - Allow tab / LF / CR; reject other C0 if present in bulk
fn looksLikeText(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var bad: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const ch = bytes[i];
        if (ch == 0) return false;
        if (ch < 0x20 and ch != 0x09 and ch != 0x0A and ch != 0x0D) {
            bad += 1;
        } else if (ch >= 0x80) {
            // Validate the UTF-8 multi-byte sequence starting at i.
            const seq_len = std.unicode.utf8ByteSequenceLength(ch) catch {
                bad += 1;
                continue;
            };
            if (i + seq_len > bytes.len) {
                bad += 1;
                continue;
            }
            _ = std.unicode.utf8Decode(bytes[i..][0..seq_len]) catch {
                bad += 1;
                continue;
            };
            i += seq_len - 1;
        }
    }
    // Tolerate a tiny amount of noise but reject anything visibly binary.
    // 0.5 % is enough headroom for stray control codes in legitimate text.
    return bad * 200 <= bytes.len;
}

/// Capture clipboard bytes into `buf`, returning how many bytes were
/// read. Cross-platform — picks the right paste tool per OS.
fn capture(buf: []u8) usize {
    return switch (builtin.os.tag) {
        .linux => linuxCapture(buf),
        .macos => macosCapture(buf),
        .windows => windowsCapture(buf),
        else => 0,
    };
}

/// Sanitise `text` and write it to the pane's PTY, wrapping with
/// `\e[200~` / `\e[201~` if bracketed-paste mode is enabled.
fn writeSanitised(pane: *const Pane, text: []const u8) void {
    const bracketed = pane.vt.bracketed_paste;
    var out_buf: [max_paste_bytes + 16]u8 = undefined;
    var pos: usize = 0;

    if (bracketed) {
        @memcpy(out_buf[pos..][0..paste_start.len], paste_start);
        pos += paste_start.len;
    }
    pos += sanitise(text, out_buf[pos..], bracketed);
    if (bracketed) {
        if (pos + paste_end.len <= out_buf.len) {
            @memcpy(out_buf[pos..][0..paste_end.len], paste_end);
            pos += paste_end.len;
        }
    }
    writeAllToPty(pane, out_buf[0..pos]);
}

/// Write every byte of `data` to the pane's PTY master, retrying on
/// short writes (PTY master is O_NONBLOCK and the kernel input buffer
/// is small — typically 4 KiB).
///
/// A single `pane.ptyWrite(64KiB)` writes ~one buffer's worth and
/// returns short; the caller used to discard the return value, dropping
/// the trailing bytes including the closing `\x1b[201~` marker. That
/// left bracketed-paste-aware apps stuck mid-paste forever (the
/// "freeze" symptom on Ctrl+Shift+V into claude-code).
///
/// Has a 1 s overall deadline so a wedged reader can't lock the UI
/// thread; remaining bytes are dropped if the deadline trips, which
/// breaks bracketed paste *for that paste only* — better than the UI
/// being unrecoverable. Drops include the closing marker, so the app
/// would see a partial paste; sending an explicit `\x1b[201~` after
/// the timeout closes the envelope to keep the app usable.
fn writeAllToPty(pane: *const Pane, data: []const u8) void {
    const deadline_ms: i64 = 1000;
    const start_ns = compat.monotonicNow();
    const POLLOUT: i16 = 0x004;
    var fd_array = [_]posix.pollfd{.{
        .fd = pane.ptyMasterFd(),
        .events = POLLOUT,
        .revents = 0,
    }};
    var written: usize = 0;
    while (written < data.len) {
        const elapsed_ns: i64 = @intCast(compat.monotonicNow() - start_ns);
        const remaining_ms: i32 = @intCast(@max(0, deadline_ms - @divFloor(elapsed_ns, 1_000_000)));
        if (remaining_ms == 0) break;
        const n = pane.ptyWrite(data[written..]) catch {
            // EAGAIN-ish: wait for the master fd to drain.
            fd_array[0].revents = 0;
            _ = posix.poll(&fd_array, remaining_ms) catch return;
            continue;
        };
        if (n == 0) break;
        written += n;
    }
    // If we dropped the closing marker, send one explicitly so the
    // receiving app exits its bracketed-paste accumulator. Better than
    // a permanent freeze.
    const trailing = data[@min(written, data.len)..];
    const dropped_close = std.mem.indexOf(u8, trailing, paste_end) != null;
    if (dropped_close) {
        _ = pane.ptyWrite(paste_end) catch {};
    }
}

/// Filter `src` into `dst`, returning bytes written. Strips NUL, ESC,
/// embedded paste markers, and (when not bracketed) C0 controls beyond
/// tab/LF/CR.
fn sanitise(src: []const u8, dst: []u8, bracketed: bool) usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len) : (i += 1) {
        const ch = src[i];

        // Embedded paste-end / paste-start markers ("\x1b[200~" / "\x1b[201~"):
        // skip the entire 6-byte sequence so a payload can't break the envelope.
        if (ch == 0x1B and i + 5 < src.len and src[i + 1] == '[' and
            src[i + 2] == '2' and src[i + 3] == '0' and
            (src[i + 4] == '0' or src[i + 4] == '1') and src[i + 5] == '~')
        {
            i += 5;
            continue;
        }

        // ESC and NUL are always dangerous. Drop.
        if (ch == 0x00 or ch == 0x1B) continue;

        // When not bracketed, C0 controls (other than TAB / LF / CR) are
        // dangerous. Drop. When bracketed, we trust the receiving app.
        if (!bracketed and ch < 0x20 and ch != 0x09 and ch != 0x0A and ch != 0x0D) {
            continue;
        }
        // 0x7F (DEL) is also untrusted in the non-bracketed case.
        if (!bracketed and ch == 0x7F) continue;

        if (j < dst.len) {
            dst[j] = ch;
            j += 1;
        } else {
            break;
        }
    }
    return j;
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

fn linuxCapture(buf: []u8) usize {
    // Request a TEXT MIME type explicitly. Without `-t`, wl-paste / xclip
    // emit whatever the clipboard owner offers — for images that's raw
    // binary (PNG, JPEG, ...) which can be many MB. Reading + draining
    // the pipe synchronously on the main thread blocks the event loop
    // for seconds, manifesting as a "terminal froze on Ctrl+Shift+V"
    // bug whenever the clipboard has an image but no text representation.
    //
    // With explicit text MIME requested:
    //   - clipboard owner offers text → we get the text (fast, bounded)
    //   - clipboard owner offers only image → tool exits with no output
    //   - both → tool returns the text representation (URL, alt text, …)
    return switch (detectLinux()) {
        .wayland => blk: {
            const argv = [_:null]?[*:0]const u8{
                "/usr/bin/wl-paste",
                "--no-newline",
                "--type",
                "text/plain;charset=utf-8",
            };
            const n = compat.forkExecCaptureStdout(&argv, buf);
            if (n != 0) break :blk n;
            // Fallback: some senders only advertise plain `text/plain`
            // (no charset) — try that before giving up.
            const argv2 = [_:null]?[*:0]const u8{
                "/usr/bin/wl-paste",
                "--no-newline",
                "--type",
                "text/plain",
            };
            break :blk compat.forkExecCaptureStdout(&argv2, buf);
        },
        .x11 => blk: {
            const argv = [_:null]?[*:0]const u8{
                "/usr/bin/xclip",
                "-selection",
                "clipboard",
                "-t",
                "UTF8_STRING",
                "-o",
            };
            const n = compat.forkExecCaptureStdout(&argv, buf);
            if (n != 0) break :blk n;
            // Fallback for senders that only advertise legacy STRING.
            const argv2 = [_:null]?[*:0]const u8{
                "/usr/bin/xclip",
                "-selection",
                "clipboard",
                "-t",
                "STRING",
                "-o",
            };
            break :blk compat.forkExecCaptureStdout(&argv2, buf);
        },
    };
}

// ── macOS (pbcopy / pbpaste) ───────────────────────────────────

fn macosCopy(text: []const u8) void {
    const argv = [_:null]?[*:0]const u8{"/usr/bin/pbcopy"};
    compat.forkExecPipeStdin(&argv, text);
}

fn macosCapture(buf: []u8) usize {
    const argv = [_:null]?[*:0]const u8{"/usr/bin/pbpaste"};
    return compat.forkExecCaptureStdout(&argv, buf);
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

fn windowsCapture(buf: []u8) usize {
    if (builtin.os.tag != .windows) return 0;

    if (OpenClipboard(null) == 0) return 0;
    defer _ = CloseClipboard();

    const hmem = GetClipboardData(CF_UNICODETEXT) orelse return 0;
    const wide_ptr = GlobalLock(hmem) orelse return 0;
    defer _ = GlobalUnlock(hmem);

    // Interpret as u16 slice — find null terminator.
    const u16_ptr: [*]const u16 = @ptrCast(@alignCast(wide_ptr));
    var wide_len: usize = 0;
    while (u16_ptr[wide_len] != 0) : (wide_len += 1) {
        if (wide_len >= 65536) break; // safety limit
    }

    // Convert UTF-16 to UTF-8 directly into the caller's buf.
    var utf8_len: usize = 0;
    var wi: usize = 0;
    while (wi < wide_len and utf8_len + 4 <= buf.len) {
        var codepoint: u21 = u16_ptr[wi];
        wi += 1;
        if (codepoint >= 0xD800 and codepoint <= 0xDBFF and wi < wide_len) {
            const low: u21 = u16_ptr[wi];
            if (low >= 0xDC00 and low <= 0xDFFF) {
                codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
                wi += 1;
            }
        }
        const seq_len = std.unicode.utf8CodepointSequenceLength(codepoint) catch continue;
        if (utf8_len + seq_len > buf.len) break;
        _ = std.unicode.utf8Encode(codepoint, buf[utf8_len..]) catch continue;
        utf8_len += seq_len;
    }
    return utf8_len;
}

// ── Tests ─────────────────────────────────────────────────────────

test "sanitise — strips NUL and ESC always" {
    var out: [64]u8 = undefined;
    const src = "ok\x00here\x1bnope";
    const n = sanitise(src, &out, false);
    try std.testing.expectEqualStrings("okherenope", out[0..n]);
}

test "sanitise — strips C0 controls when not bracketed" {
    var out: [64]u8 = undefined;
    const src = "hi\x01\x02\x03\nthere";
    const n = sanitise(src, &out, false);
    try std.testing.expectEqualStrings("hi\nthere", out[0..n]);
}

test "sanitise — preserves printable, tab, lf, cr when not bracketed" {
    var out: [64]u8 = undefined;
    const src = "abc\tdef\nghi\rjkl";
    const n = sanitise(src, &out, false);
    try std.testing.expectEqualStrings("abc\tdef\nghi\rjkl", out[0..n]);
}

test "sanitise — strips embedded paste-end marker" {
    var out: [64]u8 = undefined;
    const src = "before\x1b[201~after";
    const n = sanitise(src, &out, false);
    try std.testing.expectEqualStrings("beforeafter", out[0..n]);
}

test "sanitise — strips embedded paste-start marker" {
    var out: [64]u8 = undefined;
    const src = "before\x1b[200~after";
    const n = sanitise(src, &out, true);
    try std.testing.expectEqualStrings("beforeafter", out[0..n]);
}

test "sanitise — strips DEL when not bracketed" {
    var out: [64]u8 = undefined;
    const src = "x\x7fy";
    const n = sanitise(src, &out, false);
    try std.testing.expectEqualStrings("xy", out[0..n]);
}

test "sanitise — preserves C0 (other than NUL/ESC) in bracketed mode" {
    // App handles the paste atomically; we trust it.
    var out: [64]u8 = undefined;
    const src = "a\x01b\x02c";
    const n = sanitise(src, &out, true);
    try std.testing.expectEqualStrings("a\x01b\x02c", out[0..n]);
}

test "sanitise — handles trailing partial marker prefix" {
    var out: [64]u8 = undefined;
    // 4-byte prefix of paste marker — must NOT be consumed
    const src = "ok\x1b[20";
    const n = sanitise(src, &out, false);
    try std.testing.expectEqualStrings("ok[20", out[0..n]); // ESC stripped, [20 stays
}

test "looksLikeText — accepts plain ASCII" {
    try std.testing.expect(looksLikeText("hello world\n"));
}

test "looksLikeText — accepts valid UTF-8" {
    try std.testing.expect(looksLikeText("привіт ✓"));
}

test "looksLikeText — rejects PNG header" {
    // First bytes of a real PNG: \x89PNG\r\n\x1a\n
    try std.testing.expect(!looksLikeText("\x89PNG\r\n\x1a\nIHDR"));
}

test "looksLikeText — rejects NUL byte anywhere" {
    try std.testing.expect(!looksLikeText("hello\x00world"));
}

test "looksLikeText — rejects bulk control codes" {
    try std.testing.expect(!looksLikeText("a\x01\x02\x03\x04\x05\x06\x07b"));
}

test "looksLikeText — rejects empty input" {
    try std.testing.expect(!looksLikeText(""));
}

test "looksLikeText — tolerates a single stray control byte" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 'a');
    buf[100] = 0x01; // one control byte in 4 KB of text
    try std.testing.expect(looksLikeText(&buf));
}
