//! Windows keyboard input translation via Win32 API.
//! Converts Win32 virtual-key codes to UTF-8 text and VT escape sequences.
//! Uses ToUnicode for text input and a VK-to-keysym table for special keys.
//! Provides the same Keyboard interface as linux/keyboard.zig.

const std = @import("std");
const builtin = @import("builtin");

// ── Win32 externs (link against user32) ────────────────────────────

extern "user32" fn ToUnicode(
    wVirtKey: u32,
    wScanCode: u32,
    lpKeyState: *const [256]u8,
    pwszBuff: [*]u16,
    cchBuff: c_int,
    wFlags: u32,
) callconv(.c) c_int;

extern "user32" fn MapVirtualKeyW(uCode: u32, uMapType: u32) callconv(.c) u32;
extern "user32" fn GetKeyboardState(lpKeyState: *[256]u8) callconv(.c) c_int;
extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.c) i16;

// ToUnicode flag: translate without changing the layout's dead-key state
// (Windows 10 1607 and later).
const TOUNICODE_NO_STATE_CHANGE: u32 = 0x4;

/// Whether the active layout turns this key into text while Ctrl and Alt
/// are both held, which is what makes the pair AltGr and not a Ctrl+Alt
/// shortcut. On a US layout nothing does; on a German one Ctrl+Alt+Q is `@`.
/// A dead key counts: it is the start of text. Windows only.
pub fn ctrlAltProducesText(vk: u32, scan: u32) bool {
    var state: [256]u8 = undefined;
    if (GetKeyboardState(&state) == 0) return false;
    var units: [4]u16 = undefined;
    const n = ToUnicode(vk, scan, &state, &units, units.len, TOUNICODE_NO_STATE_CHANGE);
    if (n < 0) return true;
    return n > 0 and units[0] >= 0x20;
}

// MapVirtualKeyW map types: VK → scan code, VK → unshifted character
const MAPVK_VK_TO_VSC: u32 = 0;
const MAPVK_VK_TO_CHAR: u32 = 2;

// ── Windows Virtual Key codes ──────────────────────────────────────

const VK_BACK: u32 = 0x08;
const VK_TAB: u32 = 0x09;
const VK_RETURN: u32 = 0x0D;
const VK_SHIFT: u32 = 0x10;
const VK_CONTROL: u32 = 0x11;
const VK_MENU: u32 = 0x12; // Alt
const VK_ESCAPE: u32 = 0x1B;
const VK_SPACE: u32 = 0x20;
const VK_PRIOR: u32 = 0x21; // Page Up
const VK_NEXT: u32 = 0x22; // Page Down
const VK_END: u32 = 0x23;
const VK_HOME: u32 = 0x24;
const VK_LEFT: u32 = 0x25;
const VK_UP: u32 = 0x26;
const VK_RIGHT: u32 = 0x27;
const VK_DOWN: u32 = 0x28;
const VK_INSERT: u32 = 0x2D;
const VK_DELETE: u32 = 0x2E;

const VK_F1: u32 = 0x70;
const VK_F2: u32 = 0x71;
const VK_F3: u32 = 0x72;
const VK_F4: u32 = 0x73;
const VK_F5: u32 = 0x74;
const VK_F6: u32 = 0x75;
const VK_F7: u32 = 0x76;
const VK_F8: u32 = 0x77;
const VK_F9: u32 = 0x78;
const VK_F10: u32 = 0x79;
const VK_F11: u32 = 0x7A;
const VK_F12: u32 = 0x7B;

// ── XKB keysym constants (match linux/keyboard.zig) ────────────────

const XKB_KEY_Return: u32 = 0xff0d;
const XKB_KEY_BackSpace: u32 = 0xff08;
const XKB_KEY_Tab: u32 = 0xff09;
const XKB_KEY_Escape: u32 = 0xff1b;
const XKB_KEY_Delete: u32 = 0xffff;
const XKB_KEY_Up: u32 = 0xff52;
const XKB_KEY_Down: u32 = 0xff54;
const XKB_KEY_Right: u32 = 0xff53;
const XKB_KEY_Left: u32 = 0xff51;
const XKB_KEY_Home: u32 = 0xff50;
const XKB_KEY_End: u32 = 0xff57;
const XKB_KEY_Page_Up: u32 = 0xff55;
const XKB_KEY_Page_Down: u32 = 0xff56;
const XKB_KEY_Insert: u32 = 0xff63;
const XKB_KEY_F1: u32 = 0xffbe;
const XKB_KEY_F2: u32 = 0xffbf;
const XKB_KEY_F3: u32 = 0xffc0;
const XKB_KEY_F4: u32 = 0xffc1;
const XKB_KEY_F5: u32 = 0xffc2;
const XKB_KEY_F6: u32 = 0xffc3;
const XKB_KEY_F7: u32 = 0xffc4;
const XKB_KEY_F8: u32 = 0xffc5;
const XKB_KEY_F9: u32 = 0xffc6;
const XKB_KEY_F10: u32 = 0xffc7;
const XKB_KEY_F11: u32 = 0xffc8;
const XKB_KEY_F12: u32 = 0xffc9;

// Key state flag: high bit set means key is down
const KEY_DOWN_FLAG: u8 = 0x80;
// Toggled state flag: low bit set means toggle is on (Caps Lock, etc.)
const KEY_TOGGLED_FLAG: u8 = 0x01;

pub const Keyboard = struct {
    key_state: [256]u8,
    dead_key_state: u32,

    /// Initialize keyboard with zeroed state.
    pub fn init() !Keyboard {
        return .{
            .key_state = @splat(0),
            .dead_key_state = 0,
        };
    }

    /// No X11 on Windows — just return default init.
    pub fn initFromX11(_: *anyopaque, _: u32) !Keyboard {
        return init();
    }

    pub fn deinit(self: *Keyboard) void {
        _ = self;
    }

    /// Reset all key state. Call on focus-in to clear stuck modifiers.
    /// A pending dead key is kept: Windows holds it in the layout's own
    /// state, which this does not clear, and `dead_key_state` must keep
    /// saying so.
    pub fn resetState(self: *Keyboard) void {
        self.key_state = @splat(0);
    }

    /// Get the XKB-compatible keysym for a Windows virtual-key code.
    /// Maps VK codes to the same keysym values used by linux/keyboard.zig
    /// so that KeyHandler can treat both platforms uniformly.
    pub fn getKeysym(self: *Keyboard, keycode: u32) u32 {
        _ = self;
        // Punctuation keys have layout-dependent VK codes (VK_OEM_*) that
        // are not characters: VK_OEM_MINUS is 0xBD, not '-'. Ask the active
        // layout which unshifted character the key produces, which is the
        // keysym X11 reports for it. The top bit marks a dead key.
        // (Compiled only for Windows so the pure tests in this file link
        // on other hosts.)
        if (builtin.os.tag == .windows) {
            if (isOemKey(keycode)) {
                const ch = MapVirtualKeyW(keycode, MAPVK_VK_TO_CHAR) & 0x7FFF_FFFF;
                if (ch != 0) return ch;
            }
            return letterKeysym(vkToKeysym(keycode), GetKeyState(@intCast(VK_SHIFT)) < 0);
        }
        return vkToKeysym(keycode);
    }

    /// Track key press/release in the internal state array.
    pub fn updateKey(self: *Keyboard, keycode: u32, pressed: bool) void {
        if (keycode < 256) {
            if (pressed) {
                self.key_state[keycode] = KEY_DOWN_FLAG;
            } else {
                self.key_state[keycode] &= ~KEY_DOWN_FLAG;
            }
        }
    }

    /// Sync modifier state from platform. On Windows, the depressed
    /// bitmask maps to: bit 0 = Shift, bit 1 = Ctrl, bit 2 = Alt,
    /// bit 3 = Super. We translate these to virtual-key down flags.
    /// latched/locked/group are stored but not used by Win32.
    pub fn updateModifiers(self: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
        _ = latched;
        _ = locked;
        _ = group;

        // Set/clear modifier virtual keys based on depressed mask
        self.key_state[VK_SHIFT] = if (depressed & 0x01 != 0) KEY_DOWN_FLAG else 0;
        self.key_state[VK_CONTROL] = if (depressed & 0x02 != 0) KEY_DOWN_FLAG else 0;
        self.key_state[VK_MENU] = if (depressed & 0x04 != 0) KEY_DOWN_FLAG else 0;
    }

    /// Release a pending dead key as text into `buf` and return the byte
    /// count. Translating Space with no modifiers makes the layout give up
    /// the accent as its spacing character.
    fn flushDeadKey(self: *Keyboard, buf: []u8) usize {
        if (self.dead_key_state == 0) return 0;
        self.dead_key_state = 0;
        const idle: [256]u8 = @splat(0);
        var units: [4]u16 = undefined;
        const n = ToUnicode(VK_SPACE, MapVirtualKeyW(VK_SPACE, MAPVK_VK_TO_VSC), &idle, &units, units.len, 0);
        if (n <= 0) return 0;
        var written: usize = 0;
        for (units[0..@intCast(n)]) |unit| {
            if (unit == ' ' or (unit >= 0xD800 and unit <= 0xDFFF)) continue;
            const len = std.unicode.utf8CodepointSequenceLength(unit) catch continue;
            if (written + len > buf.len) break;
            _ = std.unicode.utf8Encode(unit, buf[written..][0..len]) catch continue;
            written += len;
        }
        return written;
    }

    /// Translate a virtual-key code to bytes for the PTY.
    /// Handles special keys (arrows, F-keys, etc.) via VT escape sequences,
    /// Ctrl+letter combos, and printable characters via ToUnicode.
    pub fn processKey(self: *Keyboard, keycode: u32, buf: []u8) usize {
        if (buf.len == 0) return 0;

        // Take the real key state for the message being handled: both
        // halves of AltGr (left Ctrl + right Alt), the left/right modifier
        // variants and the Caps Lock toggle, none of which the key-down
        // bookkeeping in `updateKey` can reconstruct.
        _ = GetKeyboardState(&self.key_state);

        // A modifier on its own produces no text. Do not pass it to
        // ToUnicode: that call consumes a pending dead key, so pressing
        // Shift between ^ and E would lose the accent.
        if (isModifierKey(keycode)) return 0;

        const ctrl_held = (self.key_state[VK_CONTROL] & KEY_DOWN_FLAG) != 0;
        const alt_held = (self.key_state[VK_MENU] & KEY_DOWN_FLAG) != 0;

        // Keys answered here never reach ToUnicode, which is what would
        // combine or release a pending dead key.
        const special = keysymToEscape(vkToKeysym(keycode));
        var direct: [1]u8 = undefined;
        const fixed: []const u8 = if (special.len > 0)
            special
        else if (ctrl_held and !alt_held and keycode >= 'A' and keycode <= 'Z') blk: {
            direct[0] = @intCast(keycode - 'A' + 1); // Ctrl+letter: 0x01-0x1A
            break :blk &direct;
        } else if (ctrl_held and !alt_held) blk: {
            direct[0] = switch (keycode) {
                VK_SPACE => 0x00, // Ctrl+Space = NUL
                0xDB => 0x1B, // VK_OEM_4, the '[' key: Ctrl+[ = ESC
                0xDC => 0x1C, // VK_OEM_5, the '\' key: Ctrl+\ = FS
                0xDD => 0x1D, // VK_OEM_6, the ']' key: Ctrl+] = GS
                else => break :blk "",
            };
            break :blk &direct;
        } else "";

        if (fixed.len > 0) {
            // An accent typed before, say, Enter stands on its own, as it
            // does in any Windows program: emit it, then the key. Left in
            // the layout it would attach to whatever letter came next.
            const accent = self.flushDeadKey(buf);
            const copy_len = @min(fixed.len, buf.len - accent);
            @memcpy(buf[accent..][0..copy_len], fixed[0..copy_len]);
            return accent + copy_len;
        }

        // Use ToUnicode for printable characters.
        // This handles all keyboard layouts, dead keys, AltGr, etc.
        const scan_code = MapVirtualKeyW(keycode, MAPVK_VK_TO_VSC);
        var utf16_buf: [4]u16 = undefined;
        const result = ToUnicode(
            keycode,
            scan_code,
            &self.key_state,
            &utf16_buf,
            4,
            0,
        );

        if (result > 0) {
            // Successful translation: convert UTF-16 to UTF-8
            const count: usize = @intCast(result);
            const utf16_slice = utf16_buf[0..count];
            var written: usize = 0;
            var i: usize = 0;
            while (i < utf16_slice.len) : (i += 1) {
                var codepoint: u21 = utf16_slice[i];
                // Characters outside the BMP arrive as a surrogate pair.
                if (codepoint >= 0xD800 and codepoint <= 0xDBFF and i + 1 < utf16_slice.len) {
                    const low: u21 = utf16_slice[i + 1];
                    if (low >= 0xDC00 and low <= 0xDFFF) {
                        codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
                        i += 1;
                    }
                }
                const len = std.unicode.utf8CodepointSequenceLength(codepoint) catch continue;
                if (written + len > buf.len) break;
                _ = std.unicode.utf8Encode(codepoint, buf[written..][0..len]) catch continue;
                written += len;
            }

            // Alt+key sends ESC then the character. Ctrl+Alt is AltGr: the
            // character it selected is the whole input, with no prefix.
            if (alt_held and !ctrl_held and written > 0 and written + 1 <= buf.len) {
                // Shift existing bytes right by 1
                @memmove(buf[1 .. written + 1], buf[0..written]);
                buf[0] = 0x1B;
                written += 1;
            }

            if (written > 0) {
                self.dead_key_state = 0;
                return written;
            }
        } else if (result < 0) {
            // Dead key (an accent waiting for its letter). Windows keeps it
            // in the keyboard layout's own state and combines it with the
            // next ToUnicode call, so there is nothing to do here but wait.
            // Calling ToUnicode again would discard the accent.
            self.dead_key_state = keycode;
            return 0;
        }

        return 0;
    }
};

/// X11 reports a letter key as its lowercase keysym unless Shift is held,
/// and the shared key handling relies on that (the leader table is
/// lowercase, with Shift selecting the capital entries). Windows key codes
/// for letters are always the capital. Caps Lock is not consulted: it
/// changes the text typed, not which binding a key means.
fn letterKeysym(keysym: u32, shift: bool) u32 {
    return if (keysym >= 'A' and keysym <= 'Z' and !shift) keysym + 0x20 else keysym;
}

/// Shift, Ctrl, Alt, Win, Caps Lock and their left/right variants.
fn isModifierKey(vk: u32) bool {
    return switch (vk) {
        VK_SHIFT, VK_CONTROL, VK_MENU => true,
        0x14 => true, // VK_CAPITAL
        0x5B, 0x5C => true, // VK_LWIN, VK_RWIN
        0x90, 0x91 => true, // VK_NUMLOCK, VK_SCROLL
        0xA0...0xA5 => true, // VK_LSHIFT ... VK_RMENU
        else => false,
    };
}

/// VK_OEM_1 ... VK_OEM_3, VK_OEM_4 ... VK_OEM_8, VK_OEM_102 and the two
/// Brazilian ABNT keys: the punctuation keys, whose character depends on
/// the keyboard layout.
fn isOemKey(vk: u32) bool {
    return switch (vk) {
        0xBA...0xC2, 0xDB...0xDF, 0xE2 => true, // 0xC1, 0xC2: the extra ABNT keys
        else => false,
    };
}

/// Map Windows virtual-key code to XKB-compatible keysym.
/// Returns the VK code itself for printable ASCII keys (A-Z, 0-9, etc.),
/// which matches XKB behavior for Latin-1 keysyms.
fn vkToKeysym(vk: u32) u32 {
    return switch (vk) {
        VK_RETURN => XKB_KEY_Return,
        VK_BACK => XKB_KEY_BackSpace,
        VK_TAB => XKB_KEY_Tab,
        VK_ESCAPE => XKB_KEY_Escape,
        VK_DELETE => XKB_KEY_Delete,
        VK_UP => XKB_KEY_Up,
        VK_DOWN => XKB_KEY_Down,
        VK_RIGHT => XKB_KEY_Right,
        VK_LEFT => XKB_KEY_Left,
        VK_HOME => XKB_KEY_Home,
        VK_END => XKB_KEY_End,
        VK_PRIOR => XKB_KEY_Page_Up,
        VK_NEXT => XKB_KEY_Page_Down,
        VK_INSERT => XKB_KEY_Insert,
        VK_F1 => XKB_KEY_F1,
        VK_F2 => XKB_KEY_F2,
        VK_F3 => XKB_KEY_F3,
        VK_F4 => XKB_KEY_F4,
        VK_F5 => XKB_KEY_F5,
        VK_F6 => XKB_KEY_F6,
        VK_F7 => XKB_KEY_F7,
        VK_F8 => XKB_KEY_F8,
        VK_F9 => XKB_KEY_F9,
        VK_F10 => XKB_KEY_F10,
        VK_F11 => XKB_KEY_F11,
        VK_F12 => XKB_KEY_F12,
        // Numeric keypad. Their VK codes (0x60-0x6F) collide with the
        // ASCII for ` and a-o, so without this Alt+Numpad* would run the
        // Alt+j binding. Report the XKB keypad keysyms instead.
        0x60...0x69 => 0xffb0 + (vk - 0x60), // VK_NUMPAD0-9 → KP_0-9
        0x6A => 0xffaa, // VK_MULTIPLY → KP_Multiply
        0x6B => 0xffab, // VK_ADD → KP_Add
        0x6C => 0xffac, // VK_SEPARATOR → KP_Separator
        0x6D => 0xffad, // VK_SUBTRACT → KP_Subtract
        0x6E => 0xffae, // VK_DECIMAL → KP_Decimal
        0x6F => 0xffaf, // VK_DIVIDE → KP_Divide
        0x5B => 0xffeb, // VK_LWIN → Super_L
        0x5C => 0xffec, // VK_RWIN → Super_R
        0x5D => 0xff67, // VK_APPS → Menu
        0x7C...0x87 => 0xffca + (vk - 0x7C), // VK_F13-F24
        // Space, digits and letters are the only keys whose VK code is
        // their character; it doubles as the XKB Latin-1 keysym.
        VK_SPACE, '0'...'9', 'A'...'Z' => vk,
        // Everything else has no keysym here. Passing the raw code on
        // would alias punctuation: VK_SNAPSHOT is 0x2C, a comma.
        else => 0,
    };
}

/// Convert XKB keysym to VT escape sequence.
/// Identical to the function in linux/keyboard.zig — pure logic,
/// no platform dependency.
fn keysymToEscape(keysym: u32) []const u8 {
    return switch (keysym) {
        XKB_KEY_Return => "\r",
        XKB_KEY_BackSpace => "\x7f",
        XKB_KEY_Tab => "\t",
        XKB_KEY_Escape => "\x1b",
        XKB_KEY_Delete => "\x1b[3~",
        XKB_KEY_Up => "\x1b[A",
        XKB_KEY_Down => "\x1b[B",
        XKB_KEY_Right => "\x1b[C",
        XKB_KEY_Left => "\x1b[D",
        XKB_KEY_Home => "\x1b[H",
        XKB_KEY_End => "\x1b[F",
        XKB_KEY_Page_Up => "\x1b[5~",
        XKB_KEY_Page_Down => "\x1b[6~",
        XKB_KEY_Insert => "\x1b[2~",
        XKB_KEY_F1 => "\x1bOP",
        XKB_KEY_F2 => "\x1bOQ",
        XKB_KEY_F3 => "\x1bOR",
        XKB_KEY_F4 => "\x1bOS",
        XKB_KEY_F5 => "\x1b[15~",
        XKB_KEY_F6 => "\x1b[17~",
        XKB_KEY_F7 => "\x1b[18~",
        XKB_KEY_F8 => "\x1b[19~",
        XKB_KEY_F9 => "\x1b[20~",
        XKB_KEY_F10 => "\x1b[21~",
        XKB_KEY_F11 => "\x1b[23~",
        XKB_KEY_F12 => "\x1b[24~",
        else => &.{},
    };
}

// ── Tests ──────────────────────────────────────────────────────────
// These test the pure-logic portions (keysym mapping, escape sequences,
// key state tracking). ToUnicode calls are not tested since they require
// the Win32 runtime.

test "vkToKeysym: special keys map to XKB keysyms" {
    try std.testing.expectEqual(XKB_KEY_Return, vkToKeysym(VK_RETURN));
    try std.testing.expectEqual(XKB_KEY_BackSpace, vkToKeysym(VK_BACK));
    try std.testing.expectEqual(XKB_KEY_Tab, vkToKeysym(VK_TAB));
    try std.testing.expectEqual(XKB_KEY_Escape, vkToKeysym(VK_ESCAPE));
    try std.testing.expectEqual(XKB_KEY_Delete, vkToKeysym(VK_DELETE));
    try std.testing.expectEqual(XKB_KEY_Up, vkToKeysym(VK_UP));
    try std.testing.expectEqual(XKB_KEY_Down, vkToKeysym(VK_DOWN));
    try std.testing.expectEqual(XKB_KEY_Left, vkToKeysym(VK_LEFT));
    try std.testing.expectEqual(XKB_KEY_Right, vkToKeysym(VK_RIGHT));
    try std.testing.expectEqual(XKB_KEY_Home, vkToKeysym(VK_HOME));
    try std.testing.expectEqual(XKB_KEY_End, vkToKeysym(VK_END));
    try std.testing.expectEqual(XKB_KEY_Page_Up, vkToKeysym(VK_PRIOR));
    try std.testing.expectEqual(XKB_KEY_Page_Down, vkToKeysym(VK_NEXT));
    try std.testing.expectEqual(XKB_KEY_Insert, vkToKeysym(VK_INSERT));
}

test "vkToKeysym: F-keys map to XKB F-key keysyms" {
    try std.testing.expectEqual(XKB_KEY_F1, vkToKeysym(VK_F1));
    try std.testing.expectEqual(XKB_KEY_F5, vkToKeysym(VK_F5));
    try std.testing.expectEqual(XKB_KEY_F12, vkToKeysym(VK_F12));
}

test "vkToKeysym: printable keys pass through as-is" {
    // VK_A = 0x41 = 'A'
    try std.testing.expectEqual(@as(u32, 'A'), vkToKeysym('A'));
    try std.testing.expectEqual(@as(u32, '0'), vkToKeysym('0'));
    try std.testing.expectEqual(@as(u32, ' '), vkToKeysym(VK_SPACE));
}

test "vkToKeysym: keypad keys do not alias letters" {
    try std.testing.expectEqual(@as(u32, 0xffb0), vkToKeysym(0x60)); // not '`'
    try std.testing.expectEqual(@as(u32, 0xffb9), vkToKeysym(0x69));
    try std.testing.expectEqual(@as(u32, 0xffaa), vkToKeysym(0x6A)); // not 'j'
    try std.testing.expectEqual(@as(u32, 0xffaf), vkToKeysym(0x6F)); // not 'o'
}

test "letterKeysym: lowercase unless Shift, other keysyms untouched" {
    try std.testing.expectEqual(@as(u32, 'd'), letterKeysym('D', false));
    try std.testing.expectEqual(@as(u32, 'D'), letterKeysym('D', true));
    try std.testing.expectEqual(@as(u32, '1'), letterKeysym('1', false));
    try std.testing.expectEqual(XKB_KEY_Return, letterKeysym(XKB_KEY_Return, false));
}

test "vkToKeysym: keys that are not characters have no character keysym" {
    try std.testing.expectEqual(@as(u32, 0xffeb), vkToKeysym(0x5B)); // Win, not '['
    try std.testing.expectEqual(@as(u32, 0xffec), vkToKeysym(0x5C)); // Win, not '\\'
    try std.testing.expectEqual(@as(u32, 0xff67), vkToKeysym(0x5D)); // Menu, not ']'
    try std.testing.expectEqual(@as(u32, 0), vkToKeysym(0x2C)); // PrintScreen, not ','
    try std.testing.expectEqual(@as(u32, 0), vkToKeysym(0x5F)); // Sleep, not '_'
    try std.testing.expectEqual(@as(u32, 0xffca), vkToKeysym(0x7C)); // F13, not '|'
}

test "modifier and OEM key classification" {
    try std.testing.expect(isModifierKey(VK_SHIFT));
    try std.testing.expect(isModifierKey(0xA5)); // VK_RMENU
    try std.testing.expect(!isModifierKey('A'));
    try std.testing.expect(!isModifierKey(VK_SPACE));
    try std.testing.expect(isOemKey(0xBD)); // VK_OEM_MINUS
    try std.testing.expect(isOemKey(0xDB)); // VK_OEM_4, '[' on a US layout
    try std.testing.expect(!isOemKey('A'));
    try std.testing.expect(isOemKey(0xC1)); // ABNT_C1
    try std.testing.expect(!isOemKey(0xC3));
}

test "keysymToEscape: special keys produce VT sequences" {
    try std.testing.expectEqualStrings("\r", keysymToEscape(XKB_KEY_Return));
    try std.testing.expectEqualStrings("\x7f", keysymToEscape(XKB_KEY_BackSpace));
    try std.testing.expectEqualStrings("\t", keysymToEscape(XKB_KEY_Tab));
    try std.testing.expectEqualStrings("\x1b", keysymToEscape(XKB_KEY_Escape));
    try std.testing.expectEqualStrings("\x1b[3~", keysymToEscape(XKB_KEY_Delete));
    try std.testing.expectEqualStrings("\x1b[A", keysymToEscape(XKB_KEY_Up));
    try std.testing.expectEqualStrings("\x1b[B", keysymToEscape(XKB_KEY_Down));
    try std.testing.expectEqualStrings("\x1b[C", keysymToEscape(XKB_KEY_Right));
    try std.testing.expectEqualStrings("\x1b[D", keysymToEscape(XKB_KEY_Left));
    try std.testing.expectEqualStrings("\x1b[H", keysymToEscape(XKB_KEY_Home));
    try std.testing.expectEqualStrings("\x1b[F", keysymToEscape(XKB_KEY_End));
    try std.testing.expectEqualStrings("\x1b[5~", keysymToEscape(XKB_KEY_Page_Up));
    try std.testing.expectEqualStrings("\x1b[6~", keysymToEscape(XKB_KEY_Page_Down));
    try std.testing.expectEqualStrings("\x1b[2~", keysymToEscape(XKB_KEY_Insert));
}

test "keysymToEscape: F-keys produce correct sequences" {
    try std.testing.expectEqualStrings("\x1bOP", keysymToEscape(XKB_KEY_F1));
    try std.testing.expectEqualStrings("\x1bOQ", keysymToEscape(XKB_KEY_F2));
    try std.testing.expectEqualStrings("\x1bOR", keysymToEscape(XKB_KEY_F3));
    try std.testing.expectEqualStrings("\x1bOS", keysymToEscape(XKB_KEY_F4));
    try std.testing.expectEqualStrings("\x1b[15~", keysymToEscape(XKB_KEY_F5));
    try std.testing.expectEqualStrings("\x1b[24~", keysymToEscape(XKB_KEY_F12));
}

test "keysymToEscape: unknown keysym returns empty" {
    try std.testing.expectEqual(@as(usize, 0), keysymToEscape(0x12345).len);
}

test "Keyboard: init and basic state" {
    var kb = try Keyboard.init();
    // All keys should be up after init
    for (kb.key_state) |state| {
        try std.testing.expectEqual(@as(u8, 0), state);
    }
    try std.testing.expectEqual(@as(u32, 0), kb.dead_key_state);
    kb.deinit();
}

test "Keyboard: updateKey tracks key state" {
    var kb = try Keyboard.init();
    defer kb.deinit();

    kb.updateKey('A', true);
    try std.testing.expectEqual(KEY_DOWN_FLAG, kb.key_state['A']);

    kb.updateKey('A', false);
    try std.testing.expectEqual(@as(u8, 0), kb.key_state['A']);
}

test "Keyboard: updateKey ignores out-of-range keycodes" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    // Should not crash for keycodes >= 256
    kb.updateKey(300, true);
    kb.updateKey(300, false);
}

test "Keyboard: updateModifiers sets modifier keys" {
    var kb = try Keyboard.init();
    defer kb.deinit();

    // depressed = Shift (0x01) | Ctrl (0x02)
    kb.updateModifiers(0x03, 0, 0, 0);
    try std.testing.expectEqual(KEY_DOWN_FLAG, kb.key_state[VK_SHIFT]);
    try std.testing.expectEqual(KEY_DOWN_FLAG, kb.key_state[VK_CONTROL]);
    try std.testing.expectEqual(@as(u8, 0), kb.key_state[VK_MENU]);

    // Release all
    kb.updateModifiers(0, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 0), kb.key_state[VK_SHIFT]);
    try std.testing.expectEqual(@as(u8, 0), kb.key_state[VK_CONTROL]);
}

test "Keyboard: resetState clears key state and keeps a pending dead key" {
    var kb = try Keyboard.init();
    defer kb.deinit();

    kb.updateKey('A', true);
    kb.updateKey(VK_SHIFT, true);
    kb.dead_key_state = 42;

    kb.resetState();

    try std.testing.expectEqual(@as(u8, 0), kb.key_state['A']);
    try std.testing.expectEqual(@as(u8, 0), kb.key_state[VK_SHIFT]);
    try std.testing.expect(kb.dead_key_state != 0);
}

test "Keyboard: getKeysym delegates to vkToKeysym" {
    var kb = try Keyboard.init();
    defer kb.deinit();

    try std.testing.expectEqual(XKB_KEY_Return, kb.getKeysym(VK_RETURN));
    try std.testing.expectEqual(XKB_KEY_Up, kb.getKeysym(VK_UP));
    try std.testing.expectEqual(@as(u32, 'A'), kb.getKeysym('A'));
}
