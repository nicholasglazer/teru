//! macOS keyboard input translation.
//!
//! Converts IOKit virtual keycodes (kVK_*) to UTF-8 text and VT escape
//! sequences. Uses static lookup tables — no Carbon/UCKeyTranslate dependency.
//! Tracks modifier state (Shift, Ctrl, Alt/Option, Cmd) manually.
//!
//! Public interface matches linux/keyboard.zig exactly so main.zig can use
//! either module via comptime platform switch.

const std = @import("std");

// ── XKB keysyms (same values as linux/keyboard.zig) ──────────────────

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

// XKB keysyms for ASCII range (used by getKeysym for printable keys)
const XKB_KEY_space: u32 = 0x0020;
// Latin-1 keysyms match Unicode codepoints for 0x20..0x7e

// ── IOKit virtual key codes (kVK_* from Carbon/Events.h) ─────────────

const kVK_ANSI_A: u8 = 0x00;
const kVK_ANSI_S: u8 = 0x01;
const kVK_ANSI_D: u8 = 0x02;
const kVK_ANSI_F: u8 = 0x03;
const kVK_ANSI_H: u8 = 0x04;
const kVK_ANSI_G: u8 = 0x05;
const kVK_ANSI_Z: u8 = 0x06;
const kVK_ANSI_X: u8 = 0x07;
const kVK_ANSI_C: u8 = 0x08;
const kVK_ANSI_V: u8 = 0x09;
// 0x0A = kVK_ISO_Section (international keyboards)
const kVK_ANSI_B: u8 = 0x0B;
const kVK_ANSI_Q: u8 = 0x0C;
const kVK_ANSI_W: u8 = 0x0D;
const kVK_ANSI_E: u8 = 0x0E;
const kVK_ANSI_R: u8 = 0x0F;
const kVK_ANSI_Y: u8 = 0x10;
const kVK_ANSI_T: u8 = 0x11;
const kVK_ANSI_1: u8 = 0x12;
const kVK_ANSI_2: u8 = 0x13;
const kVK_ANSI_3: u8 = 0x14;
const kVK_ANSI_4: u8 = 0x15;
const kVK_ANSI_6: u8 = 0x16;
const kVK_ANSI_5: u8 = 0x17;
const kVK_ANSI_Equal: u8 = 0x18;
const kVK_ANSI_9: u8 = 0x19;
const kVK_ANSI_7: u8 = 0x1A;
const kVK_ANSI_Minus: u8 = 0x1B;
const kVK_ANSI_8: u8 = 0x1C;
const kVK_ANSI_0: u8 = 0x1D;
const kVK_ANSI_RightBracket: u8 = 0x1E;
const kVK_ANSI_O: u8 = 0x1F;
const kVK_ANSI_U: u8 = 0x20;
const kVK_ANSI_LeftBracket: u8 = 0x21;
const kVK_ANSI_I: u8 = 0x22;
const kVK_ANSI_P: u8 = 0x23;
const kVK_Return: u8 = 0x24;
const kVK_ANSI_L: u8 = 0x25;
const kVK_ANSI_J: u8 = 0x26;
const kVK_ANSI_Quote: u8 = 0x27;
const kVK_ANSI_K: u8 = 0x28;
const kVK_ANSI_Semicolon: u8 = 0x29;
const kVK_ANSI_Backslash: u8 = 0x2A;
const kVK_ANSI_Comma: u8 = 0x2B;
const kVK_ANSI_Slash: u8 = 0x2C;
const kVK_ANSI_N: u8 = 0x2D;
const kVK_ANSI_M: u8 = 0x2E;
const kVK_ANSI_Period: u8 = 0x2F;
const kVK_Tab: u8 = 0x30;
const kVK_Space: u8 = 0x31;
const kVK_ANSI_Grave: u8 = 0x32;
const kVK_Delete: u8 = 0x33; // Backspace
const kVK_Escape: u8 = 0x35;

// Modifier keys
const kVK_Command: u8 = 0x37;
const kVK_Shift: u8 = 0x38;
const kVK_CapsLock: u8 = 0x39;
const kVK_Option: u8 = 0x3A;
const kVK_Control: u8 = 0x3B;
const kVK_RightCommand: u8 = 0x36;
const kVK_RightShift: u8 = 0x3C;
const kVK_RightOption: u8 = 0x3D;
const kVK_RightControl: u8 = 0x3E;

// Function/navigation keys
const kVK_F5: u8 = 0x60;
const kVK_F6: u8 = 0x61;
const kVK_F7: u8 = 0x62;
const kVK_F3: u8 = 0x63;
const kVK_F8: u8 = 0x64;
const kVK_F9: u8 = 0x65;
const kVK_F11: u8 = 0x67;
const kVK_F13: u8 = 0x69;
const kVK_F14: u8 = 0x6B;
const kVK_F10: u8 = 0x6D;
const kVK_F12: u8 = 0x6F;
const kVK_F15: u8 = 0x71;
const kVK_Home: u8 = 0x73;
const kVK_PageUp: u8 = 0x74;
const kVK_ForwardDelete: u8 = 0x75;
const kVK_F4: u8 = 0x76;
const kVK_End: u8 = 0x77;
const kVK_F2: u8 = 0x78;
const kVK_PageDown: u8 = 0x79;
const kVK_F1: u8 = 0x7A;
const kVK_LeftArrow: u8 = 0x7B;
const kVK_RightArrow: u8 = 0x7C;
const kVK_DownArrow: u8 = 0x7D;
const kVK_UpArrow: u8 = 0x7E;

// ── NSEventModifierFlags (from Cocoa NSEvent.h) ──────────────────────

const NSEventModifierFlagCapsLock: u32 = 1 << 16;
const NSEventModifierFlagShift: u32 = 1 << 17;
const NSEventModifierFlagControl: u32 = 1 << 18;
const NSEventModifierFlagOption: u32 = 1 << 19;
const NSEventModifierFlagCommand: u32 = 1 << 20;

// ── Static lookup tables ─────────────────────────────────────────────

/// IOKit keycode -> unshifted ASCII character (US ANSI layout).
/// 0 means no printable mapping (modifier key, special key, etc).
const iokit_to_char: [128]u8 = blk: {
    var table = [_]u8{0} ** 128;
    table[kVK_ANSI_A] = 'a';
    table[kVK_ANSI_S] = 's';
    table[kVK_ANSI_D] = 'd';
    table[kVK_ANSI_F] = 'f';
    table[kVK_ANSI_H] = 'h';
    table[kVK_ANSI_G] = 'g';
    table[kVK_ANSI_Z] = 'z';
    table[kVK_ANSI_X] = 'x';
    table[kVK_ANSI_C] = 'c';
    table[kVK_ANSI_V] = 'v';
    table[kVK_ANSI_B] = 'b';
    table[kVK_ANSI_Q] = 'q';
    table[kVK_ANSI_W] = 'w';
    table[kVK_ANSI_E] = 'e';
    table[kVK_ANSI_R] = 'r';
    table[kVK_ANSI_Y] = 'y';
    table[kVK_ANSI_T] = 't';
    table[kVK_ANSI_1] = '1';
    table[kVK_ANSI_2] = '2';
    table[kVK_ANSI_3] = '3';
    table[kVK_ANSI_4] = '4';
    table[kVK_ANSI_6] = '6';
    table[kVK_ANSI_5] = '5';
    table[kVK_ANSI_Equal] = '=';
    table[kVK_ANSI_9] = '9';
    table[kVK_ANSI_7] = '7';
    table[kVK_ANSI_Minus] = '-';
    table[kVK_ANSI_8] = '8';
    table[kVK_ANSI_0] = '0';
    table[kVK_ANSI_RightBracket] = ']';
    table[kVK_ANSI_O] = 'o';
    table[kVK_ANSI_U] = 'u';
    table[kVK_ANSI_LeftBracket] = '[';
    table[kVK_ANSI_I] = 'i';
    table[kVK_ANSI_P] = 'p';
    table[kVK_ANSI_L] = 'l';
    table[kVK_ANSI_J] = 'j';
    table[kVK_ANSI_Quote] = '\'';
    table[kVK_ANSI_K] = 'k';
    table[kVK_ANSI_Semicolon] = ';';
    table[kVK_ANSI_Backslash] = '\\';
    table[kVK_ANSI_Comma] = ',';
    table[kVK_ANSI_Slash] = '/';
    table[kVK_ANSI_N] = 'n';
    table[kVK_ANSI_M] = 'm';
    table[kVK_ANSI_Period] = '.';
    table[kVK_Space] = ' ';
    table[kVK_ANSI_Grave] = '`';
    break :blk table;
};

/// IOKit keycode -> shifted ASCII character (US ANSI layout).
const iokit_to_char_shifted: [128]u8 = blk: {
    var table = [_]u8{0} ** 128;
    // Letters -> uppercase
    table[kVK_ANSI_A] = 'A';
    table[kVK_ANSI_S] = 'S';
    table[kVK_ANSI_D] = 'D';
    table[kVK_ANSI_F] = 'F';
    table[kVK_ANSI_H] = 'H';
    table[kVK_ANSI_G] = 'G';
    table[kVK_ANSI_Z] = 'Z';
    table[kVK_ANSI_X] = 'X';
    table[kVK_ANSI_C] = 'C';
    table[kVK_ANSI_V] = 'V';
    table[kVK_ANSI_B] = 'B';
    table[kVK_ANSI_Q] = 'Q';
    table[kVK_ANSI_W] = 'W';
    table[kVK_ANSI_E] = 'E';
    table[kVK_ANSI_R] = 'R';
    table[kVK_ANSI_Y] = 'Y';
    table[kVK_ANSI_T] = 'T';
    table[kVK_ANSI_O] = 'O';
    table[kVK_ANSI_U] = 'U';
    table[kVK_ANSI_I] = 'I';
    table[kVK_ANSI_P] = 'P';
    table[kVK_ANSI_L] = 'L';
    table[kVK_ANSI_J] = 'J';
    table[kVK_ANSI_K] = 'K';
    table[kVK_ANSI_N] = 'N';
    table[kVK_ANSI_M] = 'M';
    // Digits -> symbols
    table[kVK_ANSI_1] = '!';
    table[kVK_ANSI_2] = '@';
    table[kVK_ANSI_3] = '#';
    table[kVK_ANSI_4] = '$';
    table[kVK_ANSI_5] = '%';
    table[kVK_ANSI_6] = '^';
    table[kVK_ANSI_7] = '&';
    table[kVK_ANSI_8] = '*';
    table[kVK_ANSI_9] = '(';
    table[kVK_ANSI_0] = ')';
    // Punctuation -> shifted variants
    table[kVK_ANSI_Equal] = '+';
    table[kVK_ANSI_Minus] = '_';
    table[kVK_ANSI_RightBracket] = '}';
    table[kVK_ANSI_LeftBracket] = '{';
    table[kVK_ANSI_Quote] = '"';
    table[kVK_ANSI_Semicolon] = ':';
    table[kVK_ANSI_Backslash] = '|';
    table[kVK_ANSI_Comma] = '<';
    table[kVK_ANSI_Slash] = '?';
    table[kVK_ANSI_Period] = '>';
    table[kVK_ANSI_Grave] = '~';
    table[kVK_Space] = ' ';
    break :blk table;
};

/// IOKit keycode -> XKB keysym for special (non-printable) keys.
/// 0 means no special keysym (check iokit_to_char instead).
const iokit_to_keysym: [128]u32 = blk: {
    var table = [_]u32{0} ** 128;
    table[kVK_Return] = XKB_KEY_Return;
    table[kVK_Tab] = XKB_KEY_Tab;
    table[kVK_Delete] = XKB_KEY_BackSpace;
    table[kVK_Escape] = XKB_KEY_Escape;
    table[kVK_ForwardDelete] = XKB_KEY_Delete;
    table[kVK_UpArrow] = XKB_KEY_Up;
    table[kVK_DownArrow] = XKB_KEY_Down;
    table[kVK_LeftArrow] = XKB_KEY_Left;
    table[kVK_RightArrow] = XKB_KEY_Right;
    table[kVK_Home] = XKB_KEY_Home;
    table[kVK_End] = XKB_KEY_End;
    table[kVK_PageUp] = XKB_KEY_Page_Up;
    table[kVK_PageDown] = XKB_KEY_Page_Down;
    table[kVK_F1] = XKB_KEY_F1;
    table[kVK_F2] = XKB_KEY_F2;
    table[kVK_F3] = XKB_KEY_F3;
    table[kVK_F4] = XKB_KEY_F4;
    table[kVK_F5] = XKB_KEY_F5;
    table[kVK_F6] = XKB_KEY_F6;
    table[kVK_F7] = XKB_KEY_F7;
    table[kVK_F8] = XKB_KEY_F8;
    table[kVK_F9] = XKB_KEY_F9;
    table[kVK_F10] = XKB_KEY_F10;
    table[kVK_F11] = XKB_KEY_F11;
    table[kVK_F12] = XKB_KEY_F12;
    break :blk table;
};

// ── Keyboard struct ──────────────────────────────────────────────────

pub const Keyboard = struct {
    /// Modifier state tracked from updateKey / updateModifiers calls.
    /// Left and right sides tracked independently so releasing one side
    /// while the other is held does not clear the modifier.
    mods: Modifiers = .{},
    /// Caps Lock state (toggled on each press).
    caps_lock: bool = false,

    const Modifiers = struct {
        left_shift: bool = false,
        right_shift: bool = false,
        left_ctrl: bool = false,
        right_ctrl: bool = false,
        left_alt: bool = false,
        right_alt: bool = false,
        left_cmd: bool = false,
        right_cmd: bool = false,

        inline fn shift(self: Modifiers) bool {
            return self.left_shift or self.right_shift;
        }
        inline fn ctrl(self: Modifiers) bool {
            return self.left_ctrl or self.right_ctrl;
        }
        inline fn alt(self: Modifiers) bool {
            return self.left_alt or self.right_alt;
        }
        inline fn cmd(self: Modifiers) bool {
            return self.left_cmd or self.right_cmd;
        }
    };

    /// Initialize keyboard. No system resources needed — pure lookup tables.
    pub fn init() !Keyboard {
        return .{};
    }

    /// On macOS there is no X11. Falls back to plain init().
    pub fn initFromX11(_: *anyopaque, _: u32) !Keyboard {
        return init();
    }

    pub fn deinit(_: *Keyboard) void {
        // No resources to free.
    }

    /// Reset all modifier state. Call on focus-in to clear stuck modifiers.
    pub fn resetState(self: *Keyboard) void {
        self.mods = .{};
        self.caps_lock = false;
    }

    /// Get the keysym for a keycode without changing state.
    /// Returns an XKB-compatible keysym: special keys use 0xff** range,
    /// printable keys use their Unicode codepoint (matching XKB Latin-1).
    pub fn getKeysym(self: *Keyboard, keycode: u32) u32 {
        if (keycode >= 128) return 0;
        const kc: u7 = @intCast(keycode);

        // Check special keys first
        const special = iokit_to_keysym[kc];
        if (special != 0) return special;

        // Printable key: return the character as a keysym.
        // XKB Latin-1 keysyms are identical to Unicode codepoints for 0x20..0x7e.
        const shifted = self.mods.shift() or self.caps_lock;
        const ch = if (shifted) iokit_to_char_shifted[kc] else iokit_to_char[kc];
        if (ch != 0) return @intCast(ch);

        return 0;
    }

    /// Feed a key event to track modifier state.
    /// keycode is the raw IOKit virtual keycode from NSEvent.
    pub fn updateKey(self: *Keyboard, keycode: u32, pressed: bool) void {
        if (keycode >= 128) return;
        const kc: u7 = @intCast(keycode);
        switch (kc) {
            kVK_Shift => self.mods.left_shift = pressed,
            kVK_RightShift => self.mods.right_shift = pressed,
            kVK_Control => self.mods.left_ctrl = pressed,
            kVK_RightControl => self.mods.right_ctrl = pressed,
            kVK_Option => self.mods.left_alt = pressed,
            kVK_RightOption => self.mods.right_alt = pressed,
            kVK_Command => self.mods.left_cmd = pressed,
            kVK_RightCommand => self.mods.right_cmd = pressed,
            kVK_CapsLock => {
                if (pressed) self.caps_lock = !self.caps_lock;
            },
            else => {},
        }
    }

    /// Sync modifier state from NSEvent modifierFlags bitmask.
    /// On macOS the parameters map to:
    ///   depressed = NSEvent.modifierFlags (bitmask of currently-held modifiers)
    ///   latched, locked, group = unused (pass 0)
    pub fn updateModifiers(self: *Keyboard, depressed: u32, _: u32, _: u32, _: u32) void {
        // NSEvent modifierFlags doesn't distinguish left/right, so we set
        // the left side to represent the bitmask state. Individual left/right
        // tracking is handled by updateKey from key press/release events.
        const s = (depressed & NSEventModifierFlagShift) != 0;
        self.mods.left_shift = s;
        self.mods.right_shift = false;
        const c = (depressed & NSEventModifierFlagControl) != 0;
        self.mods.left_ctrl = c;
        self.mods.right_ctrl = false;
        const a = (depressed & NSEventModifierFlagOption) != 0;
        self.mods.left_alt = a;
        self.mods.right_alt = false;
        const m = (depressed & NSEventModifierFlagCommand) != 0;
        self.mods.left_cmd = m;
        self.mods.right_cmd = false;
        self.caps_lock = (depressed & NSEventModifierFlagCapsLock) != 0;
    }

    /// Translate a raw IOKit keycode to bytes for the PTY.
    /// Modifier state must be up to date via updateKey() before calling.
    pub fn processKey(self: *Keyboard, keycode: u32, buf: []u8) usize {
        if (keycode >= 128 or buf.len == 0) return 0;
        const kc: u7 = @intCast(keycode);

        // 1. Special keys -> VT escape sequences (independent of modifiers)
        const keysym = iokit_to_keysym[kc];
        if (keysym != 0) {
            const esc = keysymToEscape(keysym);
            if (esc.len > 0 and esc.len <= buf.len) {
                @memcpy(buf[0..esc.len], esc);
                return esc.len;
            }
        }

        // 2. Printable keys
        const shifted = self.mods.shift() or self.caps_lock;
        const ch = if (shifted) iokit_to_char_shifted[kc] else iokit_to_char[kc];
        if (ch == 0) return 0;

        // 3. Ctrl modifier: Ctrl+A..Z -> 0x01..0x1a, Ctrl+[ -> 0x1b, etc.
        if (self.mods.ctrl()) {
            if (ctrlChar(ch)) |ctrl_ch| {
                buf[0] = ctrl_ch;
                return 1;
            }
        }

        // 4. Regular character output
        buf[0] = ch;
        return 1;
    }
};

// ── Ctrl character mapping ───────────────────────────────────────────

/// Map a printable character to its Ctrl equivalent.
/// Ctrl+A..Z -> 0x01..0x1A, Ctrl+[ -> ESC (0x1B), Ctrl+\ -> 0x1C,
/// Ctrl+] -> 0x1D, Ctrl+^ -> 0x1E, Ctrl+_ -> 0x1F, Ctrl+Space -> 0x00.
/// Returns null if no Ctrl mapping exists for the character.
fn ctrlChar(ch: u8) ?u8 {
    return switch (ch) {
        'a'...'z' => ch - 'a' + 1,
        'A'...'Z' => ch - 'A' + 1,
        '[' => 0x1b, // ESC
        '\\' => 0x1c,
        ']' => 0x1d,
        '^', '6' => 0x1e,
        '_', '-' => 0x1f,
        ' ', '@', '`' => 0x00, // Ctrl+Space = NUL
        '/' => 0x1f,
        else => null,
    };
}

// ── VT escape sequence mapping (shared with linux/keyboard.zig) ──────

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

// ── Tests ────────────────────────────────────────────────────────────

test "lookup table: all letters mapped" {
    // Every letter a-z must have an unshifted entry
    const letter_codes = [_]u8{
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E,
        kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J,
        kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O,
        kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T,
        kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y,
        kVK_ANSI_Z,
    };
    for (letter_codes) |kc| {
        const ch = iokit_to_char[kc];
        try std.testing.expect(ch >= 'a' and ch <= 'z');
        const shifted = iokit_to_char_shifted[kc];
        try std.testing.expect(shifted >= 'A' and shifted <= 'Z');
        // Shifted must be uppercase of unshifted
        try std.testing.expectEqual(ch - 32, shifted);
    }
}

test "lookup table: digits and shifted symbols" {
    // Digit keys produce digits unshifted and standard symbols shifted
    try std.testing.expectEqual(@as(u8, '1'), iokit_to_char[kVK_ANSI_1]);
    try std.testing.expectEqual(@as(u8, '!'), iokit_to_char_shifted[kVK_ANSI_1]);
    try std.testing.expectEqual(@as(u8, '2'), iokit_to_char[kVK_ANSI_2]);
    try std.testing.expectEqual(@as(u8, '@'), iokit_to_char_shifted[kVK_ANSI_2]);
    try std.testing.expectEqual(@as(u8, '0'), iokit_to_char[kVK_ANSI_0]);
    try std.testing.expectEqual(@as(u8, ')'), iokit_to_char_shifted[kVK_ANSI_0]);
}

test "lookup table: punctuation" {
    try std.testing.expectEqual(@as(u8, '['), iokit_to_char[kVK_ANSI_LeftBracket]);
    try std.testing.expectEqual(@as(u8, '{'), iokit_to_char_shifted[kVK_ANSI_LeftBracket]);
    try std.testing.expectEqual(@as(u8, ']'), iokit_to_char[kVK_ANSI_RightBracket]);
    try std.testing.expectEqual(@as(u8, '}'), iokit_to_char_shifted[kVK_ANSI_RightBracket]);
    try std.testing.expectEqual(@as(u8, '-'), iokit_to_char[kVK_ANSI_Minus]);
    try std.testing.expectEqual(@as(u8, '_'), iokit_to_char_shifted[kVK_ANSI_Minus]);
    try std.testing.expectEqual(@as(u8, '='), iokit_to_char[kVK_ANSI_Equal]);
    try std.testing.expectEqual(@as(u8, '+'), iokit_to_char_shifted[kVK_ANSI_Equal]);
}

test "lookup table: special keys to keysyms" {
    try std.testing.expectEqual(XKB_KEY_Return, iokit_to_keysym[kVK_Return]);
    try std.testing.expectEqual(XKB_KEY_BackSpace, iokit_to_keysym[kVK_Delete]);
    try std.testing.expectEqual(XKB_KEY_Tab, iokit_to_keysym[kVK_Tab]);
    try std.testing.expectEqual(XKB_KEY_Escape, iokit_to_keysym[kVK_Escape]);
    try std.testing.expectEqual(XKB_KEY_Delete, iokit_to_keysym[kVK_ForwardDelete]);
    try std.testing.expectEqual(XKB_KEY_Up, iokit_to_keysym[kVK_UpArrow]);
    try std.testing.expectEqual(XKB_KEY_Down, iokit_to_keysym[kVK_DownArrow]);
    try std.testing.expectEqual(XKB_KEY_Left, iokit_to_keysym[kVK_LeftArrow]);
    try std.testing.expectEqual(XKB_KEY_Right, iokit_to_keysym[kVK_RightArrow]);
    try std.testing.expectEqual(XKB_KEY_Home, iokit_to_keysym[kVK_Home]);
    try std.testing.expectEqual(XKB_KEY_End, iokit_to_keysym[kVK_End]);
    try std.testing.expectEqual(XKB_KEY_Page_Up, iokit_to_keysym[kVK_PageUp]);
    try std.testing.expectEqual(XKB_KEY_Page_Down, iokit_to_keysym[kVK_PageDown]);
    try std.testing.expectEqual(XKB_KEY_F1, iokit_to_keysym[kVK_F1]);
    try std.testing.expectEqual(XKB_KEY_F12, iokit_to_keysym[kVK_F12]);
}

test "getKeysym: returns keysym for special keys" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    try std.testing.expectEqual(XKB_KEY_Return, kb.getKeysym(kVK_Return));
    try std.testing.expectEqual(XKB_KEY_Up, kb.getKeysym(kVK_UpArrow));
    try std.testing.expectEqual(XKB_KEY_F5, kb.getKeysym(kVK_F5));
}

test "getKeysym: returns ASCII for printable keys" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    // Unshifted: lowercase
    try std.testing.expectEqual(@as(u32, 'a'), kb.getKeysym(kVK_ANSI_A));
    try std.testing.expectEqual(@as(u32, '1'), kb.getKeysym(kVK_ANSI_1));
    try std.testing.expectEqual(@as(u32, ' '), kb.getKeysym(kVK_Space));
}

test "getKeysym: shift produces uppercase/symbols" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_Shift, true);
    try std.testing.expectEqual(@as(u32, 'A'), kb.getKeysym(kVK_ANSI_A));
    try std.testing.expectEqual(@as(u32, '!'), kb.getKeysym(kVK_ANSI_1));
    kb.updateKey(kVK_Shift, false);
    try std.testing.expectEqual(@as(u32, 'a'), kb.getKeysym(kVK_ANSI_A));
}

test "getKeysym: out of range returns 0" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    try std.testing.expectEqual(@as(u32, 0), kb.getKeysym(200));
    try std.testing.expectEqual(@as(u32, 0), kb.getKeysym(0xFFFF));
}

test "updateKey: modifier tracking" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    try std.testing.expect(!kb.mods.shift());
    kb.updateKey(kVK_Shift, true);
    try std.testing.expect(kb.mods.shift());
    kb.updateKey(kVK_Shift, false);
    try std.testing.expect(!kb.mods.shift());

    kb.updateKey(kVK_Control, true);
    try std.testing.expect(kb.mods.ctrl());
    kb.updateKey(kVK_RightControl, true);
    try std.testing.expect(kb.mods.ctrl());
    kb.updateKey(kVK_Control, false);
    // Right ctrl still held
    try std.testing.expect(kb.mods.ctrl());
}

test "updateKey: caps lock toggles" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    try std.testing.expect(!kb.caps_lock);
    kb.updateKey(kVK_CapsLock, true);
    try std.testing.expect(kb.caps_lock);
    kb.updateKey(kVK_CapsLock, false); // release does not toggle
    try std.testing.expect(kb.caps_lock);
    kb.updateKey(kVK_CapsLock, true); // second press toggles off
    try std.testing.expect(!kb.caps_lock);
}

test "updateModifiers: sync from NSEvent modifierFlags" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateModifiers(NSEventModifierFlagShift | NSEventModifierFlagControl, 0, 0, 0);
    try std.testing.expect(kb.mods.shift());
    try std.testing.expect(kb.mods.ctrl());
    try std.testing.expect(!kb.mods.alt());
    try std.testing.expect(!kb.mods.cmd());
    kb.updateModifiers(0, 0, 0, 0);
    try std.testing.expect(!kb.mods.shift());
    try std.testing.expect(!kb.mods.ctrl());
}

test "resetState: clears everything" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_Shift, true);
    kb.updateKey(kVK_Control, true);
    kb.updateKey(kVK_CapsLock, true);
    try std.testing.expect(kb.mods.shift());
    try std.testing.expect(kb.mods.ctrl());
    try std.testing.expect(kb.caps_lock);
    kb.resetState();
    try std.testing.expect(!kb.mods.shift());
    try std.testing.expect(!kb.mods.ctrl());
    try std.testing.expect(!kb.caps_lock);
}

test "processKey: arrow keys produce VT escape sequences" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;

    const up_len = kb.processKey(kVK_UpArrow, &buf);
    try std.testing.expectEqual(@as(usize, 3), up_len);
    try std.testing.expectEqualStrings("\x1b[A", buf[0..up_len]);

    const down_len = kb.processKey(kVK_DownArrow, &buf);
    try std.testing.expectEqualStrings("\x1b[B", buf[0..down_len]);

    const right_len = kb.processKey(kVK_RightArrow, &buf);
    try std.testing.expectEqualStrings("\x1b[C", buf[0..right_len]);

    const left_len = kb.processKey(kVK_LeftArrow, &buf);
    try std.testing.expectEqualStrings("\x1b[D", buf[0..left_len]);
}

test "processKey: Return produces CR" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_Return, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\r'), buf[0]);
}

test "processKey: Backspace (kVK_Delete) produces DEL (0x7f)" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_Delete, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x7f), buf[0]);
}

test "processKey: Tab produces HT" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_Tab, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '\t'), buf[0]);
}

test "processKey: Escape produces ESC" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_Escape, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x1b), buf[0]);
}

test "processKey: Forward Delete produces CSI 3~" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_ForwardDelete, &buf);
    try std.testing.expectEqualStrings("\x1b[3~", buf[0..n]);
}

test "processKey: F1 produces SS3 P" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_F1, &buf);
    try std.testing.expectEqualStrings("\x1bOP", buf[0..n]);
}

test "processKey: F5 produces CSI 15~" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_F5, &buf);
    try std.testing.expectEqualStrings("\x1b[15~", buf[0..n]);
}

test "processKey: regular letter" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_ANSI_A, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 'a'), buf[0]);
}

test "processKey: shifted letter" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_Shift, true);
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_ANSI_A, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
}

test "processKey: caps lock letter" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_CapsLock, true); // toggle on
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_ANSI_A, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
}

test "processKey: Ctrl+C produces 0x03" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_Control, true);
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_ANSI_C, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x03), buf[0]);
}

test "processKey: Ctrl+A produces 0x01" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_Control, true);
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_ANSI_A, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
}

test "processKey: Ctrl+Z produces 0x1a" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_Control, true);
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_ANSI_Z, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x1a), buf[0]);
}

test "processKey: Ctrl+[ produces ESC (0x1b)" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_Control, true);
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_ANSI_LeftBracket, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x1b), buf[0]);
}

test "processKey: Ctrl+Space produces NUL" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_Control, true);
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_Space, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
}

test "processKey: space produces space" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_Space, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, ' '), buf[0]);
}

test "processKey: shifted digit produces symbol" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.updateKey(kVK_Shift, true);
    var buf: [32]u8 = undefined;
    const n = kb.processKey(kVK_ANSI_1, &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(u8, '!'), buf[0]);
}

test "processKey: out of range keycode returns 0" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), kb.processKey(200, &buf));
    try std.testing.expectEqual(@as(usize, 0), kb.processKey(0xFFFF, &buf));
}

test "processKey: modifier key alone produces nothing" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), kb.processKey(kVK_Shift, &buf));
    try std.testing.expectEqual(@as(usize, 0), kb.processKey(kVK_Control, &buf));
    try std.testing.expectEqual(@as(usize, 0), kb.processKey(kVK_Option, &buf));
    try std.testing.expectEqual(@as(usize, 0), kb.processKey(kVK_Command, &buf));
}

test "processKey: empty buffer returns 0" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [0]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), kb.processKey(kVK_ANSI_A, &buf));
}

test "processKey: Home/End produce VT sequences" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;

    const home_len = kb.processKey(kVK_Home, &buf);
    try std.testing.expectEqualStrings("\x1b[H", buf[0..home_len]);

    const end_len = kb.processKey(kVK_End, &buf);
    try std.testing.expectEqualStrings("\x1b[F", buf[0..end_len]);
}

test "processKey: PageUp/PageDown produce VT sequences" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [32]u8 = undefined;

    const pgup_len = kb.processKey(kVK_PageUp, &buf);
    try std.testing.expectEqualStrings("\x1b[5~", buf[0..pgup_len]);

    const pgdn_len = kb.processKey(kVK_PageDown, &buf);
    try std.testing.expectEqualStrings("\x1b[6~", buf[0..pgdn_len]);
}

test "ctrlChar: comprehensive mappings" {
    // Letters
    try std.testing.expectEqual(@as(?u8, 1), ctrlChar('a'));
    try std.testing.expectEqual(@as(?u8, 1), ctrlChar('A'));
    try std.testing.expectEqual(@as(?u8, 26), ctrlChar('z'));
    try std.testing.expectEqual(@as(?u8, 26), ctrlChar('Z'));
    try std.testing.expectEqual(@as(?u8, 3), ctrlChar('c'));
    // Special
    try std.testing.expectEqual(@as(?u8, 0x1b), ctrlChar('['));
    try std.testing.expectEqual(@as(?u8, 0x1c), ctrlChar('\\'));
    try std.testing.expectEqual(@as(?u8, 0x1d), ctrlChar(']'));
    try std.testing.expectEqual(@as(?u8, 0x00), ctrlChar(' '));
    // No mapping
    try std.testing.expectEqual(@as(?u8, null), ctrlChar('!'));
    try std.testing.expectEqual(@as(?u8, null), ctrlChar('1'));
}

test "keysymToEscape: all F-keys mapped" {
    const f_keys = [_]struct { sym: u32, esc: []const u8 }{
        .{ .sym = XKB_KEY_F1, .esc = "\x1bOP" },
        .{ .sym = XKB_KEY_F2, .esc = "\x1bOQ" },
        .{ .sym = XKB_KEY_F3, .esc = "\x1bOR" },
        .{ .sym = XKB_KEY_F4, .esc = "\x1bOS" },
        .{ .sym = XKB_KEY_F5, .esc = "\x1b[15~" },
        .{ .sym = XKB_KEY_F6, .esc = "\x1b[17~" },
        .{ .sym = XKB_KEY_F7, .esc = "\x1b[18~" },
        .{ .sym = XKB_KEY_F8, .esc = "\x1b[19~" },
        .{ .sym = XKB_KEY_F9, .esc = "\x1b[20~" },
        .{ .sym = XKB_KEY_F10, .esc = "\x1b[21~" },
        .{ .sym = XKB_KEY_F11, .esc = "\x1b[23~" },
        .{ .sym = XKB_KEY_F12, .esc = "\x1b[24~" },
    };
    for (f_keys) |fk| {
        const esc = keysymToEscape(fk.sym);
        try std.testing.expectEqualStrings(fk.esc, esc);
    }
}

test "keysymToEscape: unknown keysym returns empty" {
    const esc = keysymToEscape(0x12345);
    try std.testing.expectEqual(@as(usize, 0), esc.len);
}
