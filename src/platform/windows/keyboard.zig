//! Windows keyboard input translation via Win32 API.
//! Converts Win32 virtual-key codes to UTF-8 text and VT escape sequences.
//! Uses ToUnicode for text input and a VK-to-keysym table for special keys.
//! Provides the same Keyboard interface as linux/keyboard.zig.

const std = @import("std");

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

// MapVirtualKeyW map type: VK → scan code
const MAPVK_VK_TO_VSC: u32 = 0;

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
            .key_state = [_]u8{0} ** 256,
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
    pub fn resetState(self: *Keyboard) void {
        self.key_state = [_]u8{0} ** 256;
        self.dead_key_state = 0;
    }

    /// Get the XKB-compatible keysym for a Windows virtual-key code.
    /// Maps VK codes to the same keysym values used by linux/keyboard.zig
    /// so that KeyHandler can treat both platforms uniformly.
    pub fn getKeysym(self: *Keyboard, keycode: u32) u32 {
        _ = self;
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

    /// Translate a virtual-key code to bytes for the PTY.
    /// Handles special keys (arrows, F-keys, etc.) via VT escape sequences,
    /// Ctrl+letter combos, and printable characters via ToUnicode.
    pub fn processKey(self: *Keyboard, keycode: u32, buf: []u8) usize {
        if (buf.len == 0) return 0;

        // Check for special keys first (arrows, F-keys, Home, etc.)
        const keysym = vkToKeysym(keycode);
        const special = keysymToEscape(keysym);
        if (special.len > 0) {
            const copy_len = @min(special.len, buf.len);
            @memcpy(buf[0..copy_len], special[0..copy_len]);
            return copy_len;
        }

        const ctrl_held = (self.key_state[VK_CONTROL] & KEY_DOWN_FLAG) != 0;
        const alt_held = (self.key_state[VK_MENU] & KEY_DOWN_FLAG) != 0;

        // Ctrl+letter: produce control codes 0x01-0x1A
        if (ctrl_held and !alt_held and keycode >= 'A' and keycode <= 'Z') {
            buf[0] = @intCast(keycode - 'A' + 1);
            return 1;
        }

        // Ctrl+special combos
        if (ctrl_held and !alt_held) {
            switch (keycode) {
                VK_SPACE => {
                    buf[0] = 0x00; // Ctrl+Space = NUL
                    return 1;
                },
                0xDB => { // VK_OEM_4 = '[' key
                    buf[0] = 0x1B; // Ctrl+[ = ESC
                    return 1;
                },
                0xDC => { // VK_OEM_5 = '\' key
                    buf[0] = 0x1C; // Ctrl+\ = FS
                    return 1;
                },
                0xDD => { // VK_OEM_6 = ']' key
                    buf[0] = 0x1D; // Ctrl+] = GS
                    return 1;
                },
                else => {},
            }
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
            for (utf16_slice) |unit| {
                const codepoint: u21 = @intCast(unit);
                const len = std.unicode.utf8CodepointSequenceLength(codepoint) catch continue;
                if (written + len > buf.len) break;
                _ = std.unicode.utf8Encode(codepoint, buf[written..][0..len]) catch continue;
                written += len;
            }

            // If Alt is held, prepend ESC to the character
            if (alt_held and written > 0 and written + 1 <= buf.len) {
                // Shift existing bytes right by 1
                std.mem.copyBackwards(u8, buf[1 .. written + 1], buf[0..written]);
                buf[0] = 0x1B;
                written += 1;
            }

            if (written > 0) {
                self.dead_key_state = 0;
                return written;
            }
        } else if (result < 0) {
            // Dead key: ToUnicode returns -1 for dead keys (accents, etc.)
            // The dead key state is stored internally by ToUnicode.
            // We call it again to clear the internal state, then return 0
            // so the next keypress combines with it.
            self.dead_key_state = keycode;
            // Flush the dead key from Windows internal state
            _ = ToUnicode(keycode, scan_code, &self.key_state, &utf16_buf, 4, 0);
            return 0;
        }

        return 0;
    }
};

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
        // Printable ASCII keys: VK codes for A-Z are 0x41-0x5A,
        // 0-9 are 0x30-0x39 — same as their ASCII values.
        // Return them directly; they double as XKB Latin-1 keysyms.
        else => vk,
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

test "Keyboard: resetState clears everything" {
    var kb = try Keyboard.init();
    defer kb.deinit();

    kb.updateKey('A', true);
    kb.updateKey(VK_SHIFT, true);
    kb.dead_key_state = 42;

    kb.resetState();

    try std.testing.expectEqual(@as(u8, 0), kb.key_state['A']);
    try std.testing.expectEqual(@as(u8, 0), kb.key_state[VK_SHIFT]);
    try std.testing.expectEqual(@as(u32, 0), kb.dead_key_state);
}

test "Keyboard: getKeysym delegates to vkToKeysym" {
    var kb = try Keyboard.init();
    defer kb.deinit();

    try std.testing.expectEqual(XKB_KEY_Return, kb.getKeysym(VK_RETURN));
    try std.testing.expectEqual(XKB_KEY_Up, kb.getKeysym(VK_UP));
    try std.testing.expectEqual(@as(u32, 'A'), kb.getKeysym('A'));
}
