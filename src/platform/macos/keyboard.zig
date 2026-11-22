//! macOS keyboard input translation.
//!
//! Turns IOKit virtual keycodes (kVK_*) into UTF-8 text and VT escape
//! sequences, following the keyboard layout selected in System Settings:
//! Dvorak, QWERTY, AZERTY, Russian or any other. teru has no layout setting
//! of its own. A keycode names a physical key position, so it is used
//! directly only for keys that never type text (arrows, F-keys, Return and
//! the like); everything else goes through the layout with UCKeyTranslate,
//! which also handles dead keys (Option+E then E gives é on a US layout).
//!
//! The layout is re-read on every key, so switching input source takes
//! effect on the next key. When macOS reports no layout data, a built-in
//! US table is used as a last resort; other hosts use it for the tests.
//!
//! Modifier state comes from the NSEvent modifierFlags the platform sends
//! (as `.wl_modifiers`) before every key event, not from tracking key
//! presses, so it cannot drift.
//!
//! Option: by default it types what macOS types with it (accents, and on
//! many layouts @ [ ] { }). `macos_option_as_alt` in teru.conf makes the
//! left, right or both Option keys send ESC+key instead (Meta, for readline
//! and Emacs). teru's own Alt bindings work either way: they are matched
//! before any text is produced. An Option combination that types nothing
//! is sent as Meta whatever the setting.
//!
//! Command never types into the terminal; Cmd+key is for bindings and the
//! menu bar.
//!
//! Public interface matches linux/keyboard.zig so the windowed mode can use
//! either module via comptime platform switch.

const std = @import("std");
const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;

// ── XKB keysyms (same values as linux/keyboard.zig) ──────────────────

const XKB_KEY_Return: u32 = 0xff0d;
const XKB_KEY_BackSpace: u32 = 0xff08;
const XKB_KEY_Tab: u32 = 0xff09;
const XKB_KEY_Clear: u32 = 0xff0b;
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
const XKB_KEY_KP_Enter: u32 = 0xff8d;
const XKB_KEY_KP_Multiply: u32 = 0xffaa;
const XKB_KEY_KP_Add: u32 = 0xffab;
const XKB_KEY_KP_Subtract: u32 = 0xffad;
const XKB_KEY_KP_Decimal: u32 = 0xffae;
const XKB_KEY_KP_Divide: u32 = 0xffaf;
const XKB_KEY_KP_0: u32 = 0xffb0;
const XKB_KEY_KP_Equal: u32 = 0xffbd;
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
const XKB_KEY_F13: u32 = 0xffca;
const XKB_KEY_F20: u32 = 0xffd1;

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

// Device-dependent bits in the low word of modifierFlags (IOLLEvent.h,
// NX_DEVICE*KEYMASK): which side of a modifier is down.
const dev_lctrl: u32 = 0x0001;
const dev_lshift: u32 = 0x0002;
const dev_rshift: u32 = 0x0004;
const dev_lcmd: u32 = 0x0008;
const dev_rcmd: u32 = 0x0010;
const dev_lalt: u32 = 0x0020;
const dev_ralt: u32 = 0x0040;
const dev_rctrl: u32 = 0x2000;

/// The modifier bits shared code tests, in X11 layout: Shift 0x1, Lock 0x2,
/// Control 0x4, Mod1 (Alt) 0x8, Mod4 (Super) 0x40. The input code tests some
/// modifiers by number, so the backend reports Option as Alt and Command as
/// Super in these bits, as the Win32 backend does.
pub const x11_shift: u32 = 0x01;
pub const x11_lock: u32 = 0x02;
pub const x11_control: u32 = 0x04;
pub const x11_alt: u32 = 0x08;
pub const x11_super: u32 = 0x40;

/// Translate NSEvent modifierFlags to the X11 bit layout.
pub fn x11Modifiers(raw: u32) u32 {
    var m: u32 = 0;
    if (raw & NSEventModifierFlagShift != 0) m |= x11_shift;
    if (raw & NSEventModifierFlagCapsLock != 0) m |= x11_lock;
    if (raw & NSEventModifierFlagControl != 0) m |= x11_control;
    if (raw & NSEventModifierFlagOption != 0) m |= x11_alt;
    if (raw & NSEventModifierFlagCommand != 0) m |= x11_super;
    return m;
}

/// For a flagsChanged event: whether the modifier key `keycode` went down
/// (true) or up (false). Null for keys that are not held modifiers (Caps
/// Lock, which reports its toggle state, and Fn) and for other keys.
///
/// The key's own device bit says which, so pressing right Shift while left
/// Shift is held reads as a press. Keyboards that set no device bits (some
/// remote-desktop and virtual devices) fall back to the class flag.
pub fn modifierTransition(keycode: u32, raw: u32) ?bool {
    const Bits = struct { own: u32, other: u32, class: u32 };
    const b: Bits = switch (keycode) {
        kVK_Shift => .{ .own = dev_lshift, .other = dev_rshift, .class = NSEventModifierFlagShift },
        kVK_RightShift => .{ .own = dev_rshift, .other = dev_lshift, .class = NSEventModifierFlagShift },
        kVK_Control => .{ .own = dev_lctrl, .other = dev_rctrl, .class = NSEventModifierFlagControl },
        kVK_RightControl => .{ .own = dev_rctrl, .other = dev_lctrl, .class = NSEventModifierFlagControl },
        kVK_Option => .{ .own = dev_lalt, .other = dev_ralt, .class = NSEventModifierFlagOption },
        kVK_RightOption => .{ .own = dev_ralt, .other = dev_lalt, .class = NSEventModifierFlagOption },
        kVK_Command => .{ .own = dev_lcmd, .other = dev_rcmd, .class = NSEventModifierFlagCommand },
        kVK_RightCommand => .{ .own = dev_rcmd, .other = dev_lcmd, .class = NSEventModifierFlagCommand },
        else => return null,
    };
    if (raw & (b.own | b.other) == 0) return raw & b.class != 0;
    return raw & b.own != 0;
}


// Keys the ANSI tables above leave out.
const kVK_ISO_Section: u8 = 0x0A;
const kVK_Function: u8 = 0x3F; // Fn
const kVK_F17: u8 = 0x40;
const kVK_ANSI_KeypadDecimal: u8 = 0x41;
const kVK_ANSI_KeypadMultiply: u8 = 0x43;
const kVK_ANSI_KeypadPlus: u8 = 0x45;
const kVK_ANSI_KeypadClear: u8 = 0x47;
const kVK_ANSI_KeypadDivide: u8 = 0x4B;
const kVK_ANSI_KeypadEnter: u8 = 0x4C;
const kVK_ANSI_KeypadMinus: u8 = 0x4E;
const kVK_F18: u8 = 0x4F;
const kVK_F19: u8 = 0x50;
const kVK_ANSI_KeypadEquals: u8 = 0x51;
const kVK_ANSI_Keypad0: u8 = 0x52;
const kVK_ANSI_Keypad1: u8 = 0x53;
const kVK_ANSI_Keypad2: u8 = 0x54;
const kVK_ANSI_Keypad3: u8 = 0x55;
const kVK_ANSI_Keypad4: u8 = 0x56;
const kVK_ANSI_Keypad5: u8 = 0x57;
const kVK_ANSI_Keypad6: u8 = 0x58;
const kVK_ANSI_Keypad7: u8 = 0x59;
const kVK_F20: u8 = 0x5A;
const kVK_ANSI_Keypad8: u8 = 0x5B;
const kVK_ANSI_Keypad9: u8 = 0x5C;
const kVK_F16: u8 = 0x6A;
const kVK_Help: u8 = 0x72; // where PC keyboards have Insert


// ── Carbon / CoreFoundation (macOS only; referenced only from code
//    behind `is_macos`, so other hosts never link them) ──────────────

const carbon = struct {
    extern "c" fn TISCopyCurrentKeyboardLayoutInputSource() ?*anyopaque;
    extern "c" fn TISCopyCurrentASCIICapableKeyboardLayoutInputSource() ?*anyopaque;
    extern "c" fn TISGetInputSourceProperty(source: *anyopaque, key: *const anyopaque) ?*const anyopaque;
    extern "c" fn TISCreateInputSourceList(properties: ?*const anyopaque, include_all_installed: u8) ?*const anyopaque;
    extern "c" const kTISPropertyUnicodeKeyLayoutData: *const anyopaque;
    extern "c" const kTISPropertyInputSourceID: *const anyopaque;
    extern "c" fn LMGetKbdType() u8;
    extern "c" fn UCKeyTranslate(
        layout: *const anyopaque,
        virtual_key_code: u16,
        key_action: u16,
        modifier_key_state: u32,
        keyboard_type: u32,
        key_translate_options: u32,
        dead_key_state: *u32,
        max_string_length: usize,
        actual_string_length: *usize,
        unicode_string: [*]u16,
    ) i32;

    extern "c" fn CFDataGetBytePtr(data: *const anyopaque) ?[*]const u8;
    extern "c" fn CFRetain(cf: *const anyopaque) *const anyopaque;
    extern "c" fn CFRelease(cf: *const anyopaque) void;
    extern "c" fn CFEqual(a: *const anyopaque, b: *const anyopaque) u8;
    extern "c" fn CFArrayGetCount(array: *const anyopaque) isize;
    extern "c" fn CFArrayGetValueAtIndex(array: *const anyopaque, index: isize) ?*const anyopaque;
    extern "c" fn CFStringCreateWithCString(allocator: ?*const anyopaque, str: [*:0]const u8, encoding: u32) ?*const anyopaque;
    extern "c" fn CFDictionaryCreate(allocator: ?*const anyopaque, keys: [*]const *const anyopaque, values: [*]const *const anyopaque, count: isize, key_callbacks: ?*const anyopaque, value_callbacks: ?*const anyopaque) ?*const anyopaque;
    // CFDictionaryKeyCallBacks / ValueCallBacks: only their address is used.
    extern "c" const kCFTypeDictionaryKeyCallBacks: [48]u8;
    extern "c" const kCFTypeDictionaryValueCallBacks: [40]u8;
    const kCFStringEncodingUTF8: u32 = 0x0800_0100;
};

const kUCKeyActionDown: u16 = 0;
const kUCKeyTranslateNoDeadKeysMask: u32 = 1;

/// UCKeyTranslate's modifierKeyState: Carbon EventModifiers shifted right
/// by 8. Control is never passed: it would make the layout return a
/// control code, and teru derives Ctrl+key from the layout's character.
const uc_cmd: u32 = 0x01;
const uc_shift: u32 = 0x02;
const uc_caps: u32 = 0x04;
const uc_option: u32 = 0x08;

/// Which Option keys act as Meta (ESC+key) instead of typing text.
pub const OptionAsAlt = enum { none, left, right, both };

/// A keyboard layout to translate keys with. On macOS `ctx` is the layout
/// data ('uchr') of an input source and `translateFn` is UCKeyTranslate.
/// The default is the built-in US table.
pub const Layout = struct {
    ctx: ?*const anyopaque = null,
    translateFn: TranslateFn = usFallbackTranslate,

    /// Translate `keycode` under `mod_state` (uc_* bits) into UTF-16 in
    /// `out`; returns the unit count. A dead key returns 0 and leaves a
    /// non-zero `dead_state`; `options` is 0 or kUCKeyTranslateNoDeadKeysMask.
    pub const TranslateFn = *const fn (ctx: ?*const anyopaque, keycode: u16, mod_state: u32, options: u32, dead_state: *u32, out: []u16) usize;

    pub fn translate(self: Layout, keycode: u16, mod_state: u32, options: u32, dead_state: *u32, out: []u16) usize {
        return self.translateFn(self.ctx, keycode, mod_state, options, dead_state, out);
    }

    /// True when this is real layout data, not the US fallback.
    fn isSystem(self: Layout) bool {
        return self.ctx != null;
    }
};

fn ucTranslate(ctx: ?*const anyopaque, keycode: u16, mod_state: u32, options: u32, dead_state: *u32, out: []u16) usize {
    var len: usize = 0;
    const status = carbon.UCKeyTranslate(ctx.?, keycode, kUCKeyActionDown, mod_state, carbon.LMGetKbdType(), options, dead_state, out.len, &len, out.ptr);
    if (status != 0) return 0;
    return @min(len, out.len);
}

/// The US ANSI table, for when macOS reports no layout data (and for the
/// tests on other hosts). No dead keys, nothing on Option.
fn usFallbackTranslate(_: ?*const anyopaque, keycode: u16, mod_state: u32, _: u32, _: *u32, out: []u16) usize {
    if (keycode >= 128 or out.len == 0) return 0;
    const shift = mod_state & uc_shift != 0;
    var ch = if (shift) us_fallback_shifted[keycode] else us_fallback[keycode];
    if (ch == 0) return 0;
    // Caps Lock capitalises letters only.
    if (!shift and mod_state & uc_caps != 0 and ch >= 'a' and ch <= 'z') ch -= 0x20;
    out[0] = ch;
    return 1;
}

/// A retained input source and the layout read from it.
const Source = struct {
    ref: ?*anyopaque = null,
    layout: Layout = .{},

    /// Take ownership of `fresh` (a TIS "Copy" result) unless it is the
    /// source already held. Returns true if the layout changed. The old
    /// source is released only after the new one is in place, since its
    /// layout data lives inside it.
    fn replace(self: *Source, fresh: ?*anyopaque) bool {
        const new = fresh orelse return false; // keep what we have
        if (self.ref) |old| {
            if (carbon.CFEqual(old, new) != 0) {
                carbon.CFRelease(new);
                return false;
            }
        }
        const old = self.ref;
        self.ref = new;
        self.layout = if (layoutData(new)) |data| .{ .ctx = data, .translateFn = ucTranslate } else .{};
        if (old) |o| carbon.CFRelease(o);
        return true;
    }

    fn release(self: *Source) void {
        if (self.ref) |r| carbon.CFRelease(r);
        self.* = .{};
    }

    fn layoutData(source: *anyopaque) ?*const anyopaque {
        const data = carbon.TISGetInputSourceProperty(source, carbon.kTISPropertyUnicodeKeyLayoutData) orelse return null;
        const bytes = carbon.CFDataGetBytePtr(data) orelse return null;
        return bytes;
    }
};

// ── Keyboard ─────────────────────────────────────────────────────────

pub const Keyboard = struct {
    /// NSEvent modifierFlags of the current key event.
    raw_flags: u32 = 0,
    /// UCKeyTranslate's dead-key state: non-zero while an accent waits for
    /// its letter.
    dead_key_state: u32 = 0,
    option_as_alt: OptionAsAlt = .none,
    /// The selected input source's layout, and the most recent
    /// ASCII-capable one (for Ctrl and bindings on Russian, Greek, …).
    current: Source = .{},
    ascii: Source = .{},
    /// Re-read the system's selected layout on each key. Off for tests,
    /// which supply a layout of their own.
    follow_system: bool = true,

    /// This module writes the ESC that Option-as-Meta sends; the windowed
    /// mode must not add another for Alt.
    pub const owns_meta_prefix = true;

    pub fn init() !Keyboard {
        var kb: Keyboard = .{};
        kb.refreshLayouts();
        return kb;
    }

    /// A keyboard that translates with `layout` and never consults the
    /// system. For tests.
    pub fn initWithLayout(layout: Layout) Keyboard {
        return .{ .follow_system = false, .current = .{ .layout = layout }, .ascii = .{ .layout = layout } };
    }

    /// On macOS there is no X11. Falls back to plain init().
    pub fn initFromX11(_: *anyopaque, _: u32) !Keyboard {
        return init();
    }

    pub fn deinit(self: *Keyboard) void {
        if (comptime is_macos) {
            if (self.follow_system) {
                self.current.release();
                self.ascii.release();
            }
        }
    }

    /// Called on focus-in. Modifiers held while another app had focus are
    /// forgotten (the next key brings the real state). A pending dead key is
    /// dropped too: the accent was typed into this window, but the user has
    /// been elsewhere since.
    pub fn resetState(self: *Keyboard) void {
        self.raw_flags = 0;
        self.dead_key_state = 0;
        self.refreshLayouts();
    }

    /// Modifier state comes from `updateModifiers`; key presses carry none.
    pub fn updateKey(_: *Keyboard, _: u32, _: bool) void {}

    /// `depressed` is the NSEvent modifierFlags the platform reports before
    /// every key event; the other parameters exist for xkb and are unused.
    pub fn updateModifiers(self: *Keyboard, depressed: u32, _: u32, _: u32, _: u32) void {
        self.raw_flags = depressed;
    }

    /// The keysym the shared key handling matches bindings against: an XKB
    /// keysym for keys that do not type text, otherwise the character the
    /// current layout gives the key with Shift (and Command, so a "Dvorak -
    /// QWERTY ⌘" layout gives QWERTY letters for Cmd bindings). Option,
    /// Control and Caps Lock do not change it. Characters beyond Latin-1
    /// are reported as 0x01000000 | codepoint, as xkb does.
    pub fn getKeysym(self: *Keyboard, keycode: u32) u32 {
        if (keycode >= 128) return 0;
        const kc: u16 = @intCast(keycode);
        if (isModifierKeycode(kc)) return 0;
        if (keycodeKeysym(kc)) |ks| return ks;
        self.refreshLayouts();
        var mods: u32 = 0;
        if (self.raw_flags & NSEventModifierFlagShift != 0) mods |= uc_shift;
        if (self.raw_flags & NSEventModifierFlagCommand != 0) mods |= uc_cmd;
        const cp = self.baseChar(kc, mods) orelse return 0;
        return if (cp < 0x100) cp else 0x0100_0000 | @as(u32, cp);
    }

    /// Translate a key press into bytes for the PTY. Modifier state must be
    /// current (see `updateModifiers`).
    pub fn processKey(self: *Keyboard, keycode: u32, buf: []u8) usize {
        if (keycode >= 128 or buf.len == 0) return 0;
        const kc: u16 = @intCast(keycode);
        // A modifier on its own types nothing, and must not disturb a
        // pending dead key.
        if (isModifierKeycode(kc)) return 0;
        const raw = self.raw_flags;
        if (raw & NSEventModifierFlagCommand != 0) return 0;
        self.refreshLayouts();

        const shift = raw & NSEventModifierFlagShift != 0;
        const caps = raw & NSEventModifierFlagCapsLock != 0;
        const ctrl = raw & NSEventModifierFlagControl != 0;
        const option = raw & NSEventModifierFlagOption != 0;
        const meta = option and optionIsMeta(raw, self.option_as_alt);

        // 1. Keys that never type text.
        if (keycodeKeysym(kc)) |ks| {
            if (!isKeypadTextKeysym(ks)) {
                // Backspace or Escape after an accent cancels the accent,
                // as in any macOS text field.
                if (self.dead_key_state != 0 and (kc == kVK_Delete or kc == kVK_Escape)) {
                    self.dead_key_state = 0;
                    return 0;
                }
                const esc = if (kc == kVK_Tab and shift) "\x1b[Z" else keysymToEscape(ks);
                // An accent typed before, say, Return stands on its own.
                var n = self.flushDeadKey(buf);
                n += copyInto(buf[n..], esc);
                return n;
            }
        }

        var mods: u32 = 0;
        if (shift) mods |= uc_shift;

        // 2. Ctrl: the control code of the character the layout puts on
        // the key, so Ctrl+C is wherever the layout's C is.
        if (ctrl) {
            if (self.baseChar(kc, mods)) |base| {
                if (base < 0x80) {
                    if (ctrlChar(@intCast(base))) |code| {
                        var n = self.flushDeadKey(buf);
                        if (meta) n += copyInto(buf[n..], "\x1b");
                        n += copyInto(buf[n..], &.{code});
                        return n;
                    }
                }
            }
            // No control code (Ctrl+1, say): type the key as usual.
        }

        if (caps) mods |= uc_caps;

        // 3. Option as Meta: ESC, then the key without Option.
        if (meta) return self.metaKey(kc, mods, buf);

        // 4. Text, composed with any pending dead key.
        if (option) mods |= uc_option;
        var units: [8]u16 = undefined;
        const n16 = self.textLayout().translate(kc, mods, 0, &self.dead_key_state, &units);
        if (n16 == 0) {
            // A dead key: the accent waits for the next key.
            if (self.dead_key_state != 0) return 0;
            // An Option combination that types nothing still means
            // something to the shell as Meta.
            if (option) return self.metaKey(kc, mods & ~uc_option, buf);
            return 0;
        }
        return utf16ToUtf8(units[0..n16], buf);
    }

    // ── Internals ───────────────────────────────────────────────────

    fn metaKey(self: *Keyboard, kc: u16, mods: u32, buf: []u8) usize {
        const base = self.baseChar(kc, mods) orelse return 0;
        var n = self.flushDeadKey(buf);
        n += copyInto(buf[n..], "\x1b");
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(base, &tmp) catch return n;
        n += copyInto(buf[n..], tmp[0..len]);
        return n;
    }

    /// The layout text is typed with: the selected one, or the ASCII-capable
    /// one when the selected source has no layout data.
    fn textLayout(self: *const Keyboard) Layout {
        return if (self.current.layout.isSystem() or !self.ascii.layout.isSystem())
            self.current.layout
        else
            self.ascii.layout;
    }

    /// The first character `kc` gives under `mods`, ignoring dead keys and
    /// without touching the pending one. Prefers an ASCII result, from the
    /// ASCII-capable layout when the selected one gives none: Ctrl+C and
    /// Alt+J have to mean something on a Russian layout too.
    fn baseChar(self: *Keyboard, kc: u16, mods: u32) ?u21 {
        const first = firstChar(self.textLayout(), kc, mods);
        if (first) |c| if (c < 0x80) return c;
        if (firstChar(self.ascii.layout, kc, mods)) |c| if (c < 0x80) return c;
        return first;
    }

    fn firstChar(layout: Layout, kc: u16, mods: u32) ?u21 {
        var scratch: u32 = 0;
        var units: [8]u16 = undefined;
        const n = layout.translate(kc, mods, kUCKeyTranslateNoDeadKeysMask, &scratch, &units);
        if (n == 0) return null;
        const cp = decodeFirst(units[0..n]) orelse return null;
        if (!isTextCodepoint(cp)) return null;
        return cp;
    }

    /// Release a pending dead key as its spacing accent. Translating Space
    /// makes the layout give it up.
    fn flushDeadKey(self: *Keyboard, buf: []u8) usize {
        if (self.dead_key_state == 0) return 0;
        var units: [8]u16 = undefined;
        const n16 = self.textLayout().translate(kVK_Space, 0, 0, &self.dead_key_state, &units);
        self.dead_key_state = 0;
        var kept: [8]u16 = undefined;
        var k: usize = 0;
        for (units[0..n16]) |u| {
            if (u == ' ') continue;
            kept[k] = u;
            k += 1;
        }
        return utf16ToUtf8(kept[0..k], buf);
    }

    /// Follow the input source selected in System Settings. Cheap when it
    /// has not changed: one TIS call and a comparison per source.
    fn refreshLayouts(self: *Keyboard) void {
        if (comptime !is_macos) return;
        if (!self.follow_system) return;
        if (self.current.replace(carbon.TISCopyCurrentKeyboardLayoutInputSource())) {
            // An accent from the previous layout means nothing in this one.
            self.dead_key_state = 0;
        }
        _ = self.ascii.replace(carbon.TISCopyCurrentASCIICapableKeyboardLayoutInputSource());
    }
};

/// Whether `raw` (NSEvent modifierFlags, Option held) has an Option key
/// that is set to act as Meta. Without side bits, Option counts as left.
pub fn optionIsMeta(raw: u32, setting: OptionAsAlt) bool {
    const left = raw & dev_lalt != 0 or raw & (dev_lalt | dev_ralt) == 0;
    const right = raw & dev_ralt != 0;
    return switch (setting) {
        .none => false,
        .left => left,
        .right => right,
        .both => true,
    };
}

/// kVK codes 0x36-0x3F: Command, Shift, Caps Lock, Option, Control on both
/// sides, and Fn.
fn isModifierKeycode(kc: u16) bool {
    return kc >= kVK_RightCommand and kc <= kVK_Function;
}

/// Keysyms for keys identified by position: everything that does not type
/// text, plus the keypad, whose keysyms keep Alt+keypad-1 apart from Alt+1.
fn keycodeKeysym(kc: u16) ?u32 {
    return switch (kc) {
        kVK_Return => XKB_KEY_Return,
        kVK_Tab => XKB_KEY_Tab,
        kVK_Delete => XKB_KEY_BackSpace,
        kVK_Escape => XKB_KEY_Escape,
        kVK_ForwardDelete => XKB_KEY_Delete,
        kVK_Help => XKB_KEY_Insert,
        kVK_UpArrow => XKB_KEY_Up,
        kVK_DownArrow => XKB_KEY_Down,
        kVK_LeftArrow => XKB_KEY_Left,
        kVK_RightArrow => XKB_KEY_Right,
        kVK_Home => XKB_KEY_Home,
        kVK_End => XKB_KEY_End,
        kVK_PageUp => XKB_KEY_Page_Up,
        kVK_PageDown => XKB_KEY_Page_Down,
        kVK_F1 => XKB_KEY_F1,
        kVK_F2 => XKB_KEY_F2,
        kVK_F3 => XKB_KEY_F3,
        kVK_F4 => XKB_KEY_F4,
        kVK_F5 => XKB_KEY_F5,
        kVK_F6 => XKB_KEY_F6,
        kVK_F7 => XKB_KEY_F7,
        kVK_F8 => XKB_KEY_F8,
        kVK_F9 => XKB_KEY_F9,
        kVK_F10 => XKB_KEY_F10,
        kVK_F11 => XKB_KEY_F11,
        kVK_F12 => XKB_KEY_F12,
        kVK_F13 => XKB_KEY_F13,
        kVK_F14 => XKB_KEY_F13 + 1,
        kVK_F15 => XKB_KEY_F13 + 2,
        kVK_F16 => XKB_KEY_F13 + 3,
        kVK_F17 => XKB_KEY_F13 + 4,
        kVK_F18 => XKB_KEY_F13 + 5,
        kVK_F19 => XKB_KEY_F13 + 6,
        kVK_F20 => XKB_KEY_F20,
        kVK_ANSI_KeypadEnter => XKB_KEY_KP_Enter,
        kVK_ANSI_KeypadClear => XKB_KEY_Clear,
        kVK_ANSI_Keypad0 => XKB_KEY_KP_0,
        kVK_ANSI_Keypad1 => XKB_KEY_KP_0 + 1,
        kVK_ANSI_Keypad2 => XKB_KEY_KP_0 + 2,
        kVK_ANSI_Keypad3 => XKB_KEY_KP_0 + 3,
        kVK_ANSI_Keypad4 => XKB_KEY_KP_0 + 4,
        kVK_ANSI_Keypad5 => XKB_KEY_KP_0 + 5,
        kVK_ANSI_Keypad6 => XKB_KEY_KP_0 + 6,
        kVK_ANSI_Keypad7 => XKB_KEY_KP_0 + 7,
        kVK_ANSI_Keypad8 => XKB_KEY_KP_0 + 8,
        kVK_ANSI_Keypad9 => XKB_KEY_KP_0 + 9,
        kVK_ANSI_KeypadDecimal => XKB_KEY_KP_Decimal,
        kVK_ANSI_KeypadMultiply => XKB_KEY_KP_Multiply,
        kVK_ANSI_KeypadPlus => XKB_KEY_KP_Add,
        kVK_ANSI_KeypadMinus => XKB_KEY_KP_Subtract,
        kVK_ANSI_KeypadDivide => XKB_KEY_KP_Divide,
        kVK_ANSI_KeypadEquals => XKB_KEY_KP_Equal,
        else => null,
    };
}

/// Keypad digits and operators type their character (from the layout).
fn isKeypadTextKeysym(ks: u32) bool {
    return (ks >= XKB_KEY_KP_Multiply and ks <= XKB_KEY_KP_0 + 9) or ks == XKB_KEY_KP_Equal;
}

/// Characters that belong in typed text. Layouts return C0 controls and
/// Apple's function-key private-use characters (U+F700-F8FF) for keys that
/// are handled by keycode, or by teru's own Ctrl mapping.
fn isTextCodepoint(cp: u21) bool {
    if (cp < 0x20 or cp == 0x7f) return false;
    if (cp >= 0xF700 and cp <= 0xF8FF) return false;
    return true;
}

fn decodeFirst(units: []const u16) ?u21 {
    var it = Utf16Iterator{ .units = units };
    return it.next();
}

const Utf16Iterator = struct {
    units: []const u16,
    i: usize = 0,

    /// Next codepoint; unpaired surrogates are skipped.
    fn next(self: *Utf16Iterator) ?u21 {
        while (self.i < self.units.len) {
            const hi: u21 = self.units[self.i];
            self.i += 1;
            if (hi >= 0xD800 and hi <= 0xDBFF) {
                if (self.i < self.units.len) {
                    const lo: u21 = self.units[self.i];
                    if (lo >= 0xDC00 and lo <= 0xDFFF) {
                        self.i += 1;
                        return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
                    }
                }
                continue;
            }
            if (hi >= 0xDC00 and hi <= 0xDFFF) continue;
            return hi;
        }
        return null;
    }
};

/// UTF-16 from the layout to UTF-8 for the PTY. Drops what is not text
/// (see isTextCodepoint) and stops before a character that does not fit.
pub fn utf16ToUtf8(units: []const u16, out: []u8) usize {
    var it = Utf16Iterator{ .units = units };
    var written: usize = 0;
    while (it.next()) |cp| {
        if (!isTextCodepoint(cp)) continue;
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
        if (written + len > out.len) break;
        _ = std.unicode.utf8Encode(cp, out[written..][0..len]) catch continue;
        written += len;
    }
    return written;
}

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

// ── US fallback tables ───────────────────────────────────────────────

/// Keycode -> unshifted character on a US ANSI keyboard. Used only when
/// macOS reports no layout data.
/// 0 means no printable mapping (modifier key, special key, etc).
const us_fallback: [128]u8 = blk: {
    var table: [128]u8 = @splat(0);
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
    table[kVK_ANSI_Keypad0] = '0';
    table[kVK_ANSI_Keypad1] = '1';
    table[kVK_ANSI_Keypad2] = '2';
    table[kVK_ANSI_Keypad3] = '3';
    table[kVK_ANSI_Keypad4] = '4';
    table[kVK_ANSI_Keypad5] = '5';
    table[kVK_ANSI_Keypad6] = '6';
    table[kVK_ANSI_Keypad7] = '7';
    table[kVK_ANSI_Keypad8] = '8';
    table[kVK_ANSI_Keypad9] = '9';
    table[kVK_ANSI_KeypadDecimal] = '.';
    table[kVK_ANSI_KeypadMultiply] = '*';
    table[kVK_ANSI_KeypadPlus] = '+';
    table[kVK_ANSI_KeypadMinus] = '-';
    table[kVK_ANSI_KeypadDivide] = '/';
    table[kVK_ANSI_KeypadEquals] = '=';
    break :blk table;
};

/// Keycode -> shifted character on a US ANSI keyboard.
const us_fallback_shifted: [128]u8 = blk: {
    var table: [128]u8 = @splat(0);
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
    table[kVK_ANSI_Keypad0] = '0';
    table[kVK_ANSI_Keypad1] = '1';
    table[kVK_ANSI_Keypad2] = '2';
    table[kVK_ANSI_Keypad3] = '3';
    table[kVK_ANSI_Keypad4] = '4';
    table[kVK_ANSI_Keypad5] = '5';
    table[kVK_ANSI_Keypad6] = '6';
    table[kVK_ANSI_Keypad7] = '7';
    table[kVK_ANSI_Keypad8] = '8';
    table[kVK_ANSI_Keypad9] = '9';
    table[kVK_ANSI_KeypadDecimal] = '.';
    table[kVK_ANSI_KeypadMultiply] = '*';
    table[kVK_ANSI_KeypadPlus] = '+';
    table[kVK_ANSI_KeypadMinus] = '-';
    table[kVK_ANSI_KeypadDivide] = '/';
    table[kVK_ANSI_KeypadEquals] = '=';
    break :blk table;
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
        ' ', '@', '`', '2' => 0x00, // Ctrl+Space = NUL
        '/' => 0x1f,
        else => null,
    };
}

// ── VT escape sequence mapping (shared with linux/keyboard.zig) ──────

fn keysymToEscape(keysym: u32) []const u8 {
    return switch (keysym) {
        XKB_KEY_Return, XKB_KEY_KP_Enter => "\r",
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
        // F13-F20 as a VT220 sends them.
        XKB_KEY_F13 => "\x1b[25~",
        XKB_KEY_F13 + 1 => "\x1b[26~",
        XKB_KEY_F13 + 2 => "\x1b[28~",
        XKB_KEY_F13 + 3 => "\x1b[29~",
        XKB_KEY_F13 + 4 => "\x1b[31~",
        XKB_KEY_F13 + 5 => "\x1b[32~",
        XKB_KEY_F13 + 6 => "\x1b[33~",
        XKB_KEY_F20 => "\x1b[34~",
        else => &.{},
    };
}

// ── Tests ────────────────────────────────────────────────────────────
//
// The tests below run on every host with the built-in US table or a test
// layout that has a dead key. The ones at the end load real macOS layouts
// and run only on a Mac (the CI macos job).

const testing = std.testing;

fn usKeyboard() Keyboard {
    return Keyboard.initWithLayout(.{});
}

/// A US layout with macOS's Option+E dead acute and two Option characters,
/// enough to exercise composition the way UCKeyTranslate does it.
fn deadKeyTranslate(_: ?*const anyopaque, keycode: u16, mod_state: u32, options: u32, dead_state: *u32, out: []u16) usize {
    var scratch: u32 = 0;
    if (mod_state & uc_option != 0) {
        switch (keycode) {
            kVK_ANSI_E => {
                if (options & kUCKeyTranslateNoDeadKeysMask != 0) {
                    out[0] = 0xB4; // ´
                    return 1;
                }
                if (dead_state.* != 0) { // accent twice: the accent itself
                    dead_state.* = 0;
                    out[0] = 0xB4;
                    return 1;
                }
                dead_state.* = 1;
                return 0;
            },
            kVK_ANSI_B => {
                out[0] = 0x222B; // ∫
                return 1;
            },
            else => return 0, // nothing on Option for the rest
        }
    }
    const n = usFallbackTranslate(null, keycode, mod_state, options, &scratch, out);
    if (dead_state.* == 0 or options & kUCKeyTranslateNoDeadKeysMask != 0) return n;
    dead_state.* = 0;
    if (n == 1 and out[0] == 'e') {
        out[0] = 0xE9; // é
        return 1;
    }
    if (n == 1 and out[0] == ' ') {
        out[0] = 0xB4;
        return 1;
    }
    // No composition: the accent, then the character.
    if (n == 1 and out.len >= 2) {
        out[1] = out[0];
        out[0] = 0xB4;
        return 2;
    }
    out[0] = 0xB4;
    return 1;
}

fn deadKeyKeyboard() Keyboard {
    return Keyboard.initWithLayout(.{ .translateFn = deadKeyTranslate });
}

fn press(kb: *Keyboard, flags: u32, kc: u8, buf: []u8) []const u8 {
    kb.updateModifiers(flags, 0, 0, 0);
    return buf[0..kb.processKey(kc, buf)];
}

const SHIFT = NSEventModifierFlagShift | dev_lshift;
const CTRL = NSEventModifierFlagControl | dev_lctrl;
const LOPT = NSEventModifierFlagOption | dev_lalt;
const ROPT = NSEventModifierFlagOption | dev_ralt;
const CMD = NSEventModifierFlagCommand | dev_lcmd;
const CAPS = NSEventModifierFlagCapsLock;

test "processKey: keys that do not type text" {
    var kb = usKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[A", press(&kb, 0, kVK_UpArrow, &buf));
    try testing.expectEqualStrings("\x1b[B", press(&kb, 0, kVK_DownArrow, &buf));
    try testing.expectEqualStrings("\x1b[C", press(&kb, 0, kVK_RightArrow, &buf));
    try testing.expectEqualStrings("\x1b[D", press(&kb, 0, kVK_LeftArrow, &buf));
    try testing.expectEqualStrings("\r", press(&kb, 0, kVK_Return, &buf));
    try testing.expectEqualStrings("\r", press(&kb, 0, kVK_ANSI_KeypadEnter, &buf));
    try testing.expectEqualStrings("\x7f", press(&kb, 0, kVK_Delete, &buf));
    try testing.expectEqualStrings("\t", press(&kb, 0, kVK_Tab, &buf));
    try testing.expectEqualStrings("\x1b[Z", press(&kb, SHIFT, kVK_Tab, &buf));
    try testing.expectEqualStrings("\x1b", press(&kb, 0, kVK_Escape, &buf));
    try testing.expectEqualStrings("\x1b[3~", press(&kb, 0, kVK_ForwardDelete, &buf));
    try testing.expectEqualStrings("\x1b[2~", press(&kb, 0, kVK_Help, &buf));
    try testing.expectEqualStrings("\x1b[H", press(&kb, 0, kVK_Home, &buf));
    try testing.expectEqualStrings("\x1b[F", press(&kb, 0, kVK_End, &buf));
    try testing.expectEqualStrings("\x1b[5~", press(&kb, 0, kVK_PageUp, &buf));
    try testing.expectEqualStrings("\x1b[6~", press(&kb, 0, kVK_PageDown, &buf));
    try testing.expectEqualStrings("\x1bOP", press(&kb, 0, kVK_F1, &buf));
    try testing.expectEqualStrings("\x1b[15~", press(&kb, 0, kVK_F5, &buf));
    try testing.expectEqualStrings("\x1b[25~", press(&kb, 0, kVK_F13, &buf));
    try testing.expectEqualStrings("\x1b[34~", press(&kb, 0, kVK_F20, &buf));
    try testing.expectEqualStrings("", press(&kb, 0, kVK_ANSI_KeypadClear, &buf));
}

test "processKey: text from the layout" {
    var kb = usKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("a", press(&kb, 0, kVK_ANSI_A, &buf));
    try testing.expectEqualStrings("A", press(&kb, SHIFT, kVK_ANSI_A, &buf));
    try testing.expectEqualStrings("!", press(&kb, SHIFT, kVK_ANSI_1, &buf));
    try testing.expectEqualStrings(" ", press(&kb, 0, kVK_Space, &buf));
    try testing.expectEqualStrings("7", press(&kb, 0, kVK_ANSI_Keypad7, &buf));
    try testing.expectEqualStrings("*", press(&kb, 0, kVK_ANSI_KeypadMultiply, &buf));
}

test "processKey: Caps Lock capitalises letters, not digits" {
    var kb = usKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("A", press(&kb, CAPS, kVK_ANSI_A, &buf));
    try testing.expectEqualStrings("1", press(&kb, CAPS, kVK_ANSI_1, &buf));
}

test "processKey: Ctrl gives control codes" {
    var kb = usKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x03", press(&kb, CTRL, kVK_ANSI_C, &buf));
    try testing.expectEqualStrings("\x01", press(&kb, CTRL, kVK_ANSI_A, &buf));
    try testing.expectEqualStrings("\x1a", press(&kb, CTRL, kVK_ANSI_Z, &buf));
    try testing.expectEqualStrings("\x03", press(&kb, CTRL | SHIFT, kVK_ANSI_C, &buf));
    try testing.expectEqualStrings("\x1b", press(&kb, CTRL, kVK_ANSI_LeftBracket, &buf));
    try testing.expectEqualStrings("\x00", press(&kb, CTRL, kVK_Space, &buf));
    // No control code for 1: the digit is typed.
    try testing.expectEqualStrings("1", press(&kb, CTRL, kVK_ANSI_1, &buf));
}

test "processKey: Ctrl follows the layout's letter, not the key position" {
    // A layout where the physical I key types c, as on Dvorak.
    const dvorak_i = struct {
        fn translate(_: ?*const anyopaque, kc: u16, mods: u32, opts: u32, dead: *u32, out: []u16) usize {
            if (kc == kVK_ANSI_I) {
                out[0] = if (mods & uc_shift != 0) 'C' else 'c';
                return 1;
            }
            if (kc == kVK_ANSI_C) {
                out[0] = if (mods & uc_shift != 0) 'J' else 'j';
                return 1;
            }
            return usFallbackTranslate(null, kc, mods, opts, dead, out);
        }
    };
    var kb = Keyboard.initWithLayout(.{ .translateFn = dvorak_i.translate });
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("c", press(&kb, 0, kVK_ANSI_I, &buf));
    try testing.expectEqualStrings("\x03", press(&kb, CTRL, kVK_ANSI_I, &buf));
    try testing.expectEqualStrings("\x0a", press(&kb, CTRL, kVK_ANSI_C, &buf));
    kb.updateModifiers(0, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'j'), kb.getKeysym(kVK_ANSI_C));
    kb.updateModifiers(SHIFT, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'J'), kb.getKeysym(kVK_ANSI_C));
}

test "processKey: Command types nothing, modifiers alone type nothing" {
    var kb = usKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("", press(&kb, CMD, kVK_ANSI_C, &buf));
    try testing.expectEqualStrings("", press(&kb, CMD, kVK_Return, &buf));
    for ([_]u8{ kVK_Shift, kVK_RightShift, kVK_Control, kVK_Option, kVK_RightOption, kVK_Command, kVK_CapsLock, kVK_Function }) |kc| {
        try testing.expectEqualStrings("", press(&kb, 0, kc, &buf));
    }
}

test "processKey: out of range keycode or empty buffer gives nothing" {
    var kb = usKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), kb.processKey(200, &buf));
    try testing.expectEqual(@as(usize, 0), kb.processKey(0xFFFF, &buf));
    var empty: [0]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), kb.processKey(kVK_ANSI_A, &empty));
}

test "processKey: dead key composes with the next letter" {
    var kb = deadKeyKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("", press(&kb, LOPT, kVK_ANSI_E, &buf));
    try testing.expect(kb.dead_key_state != 0);
    // Releasing Option (a modifier key event) keeps the accent waiting.
    try testing.expectEqualStrings("", press(&kb, 0, kVK_Option, &buf));
    try testing.expectEqualStrings("é", press(&kb, 0, kVK_ANSI_E, &buf));
    try testing.expectEqual(@as(u32, 0), kb.dead_key_state);
    // No composition: the accent, then the letter.
    _ = press(&kb, LOPT, kVK_ANSI_E, &buf);
    try testing.expectEqualStrings("´x", press(&kb, 0, kVK_ANSI_X, &buf));
}

test "processKey: dead key before a non-text key, Backspace and Escape" {
    var kb = deadKeyKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    _ = press(&kb, LOPT, kVK_ANSI_E, &buf);
    try testing.expectEqualStrings("´\r", press(&kb, 0, kVK_Return, &buf));
    try testing.expectEqual(@as(u32, 0), kb.dead_key_state);

    _ = press(&kb, LOPT, kVK_ANSI_E, &buf);
    try testing.expectEqualStrings("", press(&kb, 0, kVK_Delete, &buf));
    try testing.expectEqual(@as(u32, 0), kb.dead_key_state);

    _ = press(&kb, LOPT, kVK_ANSI_E, &buf);
    try testing.expectEqualStrings("", press(&kb, 0, kVK_Escape, &buf));
    try testing.expectEqualStrings("e", press(&kb, 0, kVK_ANSI_E, &buf));

    // Ctrl+C after an accent: the accent, then ^C.
    _ = press(&kb, LOPT, kVK_ANSI_E, &buf);
    try testing.expectEqualStrings("´\x03", press(&kb, CTRL, kVK_ANSI_C, &buf));
}

test "processKey: getKeysym does not consume a pending dead key" {
    var kb = deadKeyKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    _ = press(&kb, LOPT, kVK_ANSI_E, &buf);
    kb.updateModifiers(0, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'e'), kb.getKeysym(kVK_ANSI_E));
    try testing.expectEqualStrings("é", buf[0..kb.processKey(kVK_ANSI_E, &buf)]);
}

test "processKey: Option types text by default" {
    var kb = deadKeyKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("∫", press(&kb, LOPT, kVK_ANSI_B, &buf));
    try testing.expectEqualStrings("∫", press(&kb, ROPT, kVK_ANSI_B, &buf));
    // Option+F types nothing on this layout: it goes out as Meta.
    try testing.expectEqualStrings("\x1bf", press(&kb, LOPT, kVK_ANSI_F, &buf));
}

test "processKey: Option as Meta per side" {
    var kb = deadKeyKeyboard();
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    kb.option_as_alt = .left;
    try testing.expectEqualStrings("\x1bb", press(&kb, LOPT, kVK_ANSI_B, &buf));
    try testing.expectEqualStrings("\x1bB", press(&kb, LOPT | SHIFT, kVK_ANSI_B, &buf));
    try testing.expectEqualStrings("∫", press(&kb, ROPT, kVK_ANSI_B, &buf));
    // Meta on a dead-key position sends the base letter, no accent.
    try testing.expectEqualStrings("\x1be", press(&kb, LOPT, kVK_ANSI_E, &buf));
    try testing.expectEqual(@as(u32, 0), kb.dead_key_state);
    try testing.expectEqualStrings("\x1b\x03", press(&kb, LOPT | CTRL, kVK_ANSI_C, &buf));
    kb.option_as_alt = .right;
    try testing.expectEqualStrings("∫", press(&kb, LOPT, kVK_ANSI_B, &buf));
    try testing.expectEqualStrings("\x1bb", press(&kb, ROPT, kVK_ANSI_B, &buf));
    kb.option_as_alt = .both;
    try testing.expectEqualStrings("\x1bb", press(&kb, ROPT, kVK_ANSI_B, &buf));
}

test "optionIsMeta: sides" {
    try testing.expect(!optionIsMeta(LOPT, .none));
    try testing.expect(optionIsMeta(LOPT, .left));
    try testing.expect(!optionIsMeta(ROPT, .left));
    try testing.expect(optionIsMeta(ROPT, .right));
    try testing.expect(optionIsMeta(LOPT | ROPT, .right));
    try testing.expect(optionIsMeta(ROPT, .both));
    // No side bits: counts as left.
    try testing.expect(optionIsMeta(NSEventModifierFlagOption, .left));
    try testing.expect(!optionIsMeta(NSEventModifierFlagOption, .right));
}

test "getKeysym: keys by position, characters by layout" {
    var kb = usKeyboard();
    defer kb.deinit();
    try testing.expectEqual(XKB_KEY_Return, kb.getKeysym(kVK_Return));
    try testing.expectEqual(XKB_KEY_Up, kb.getKeysym(kVK_UpArrow));
    try testing.expectEqual(XKB_KEY_F5, kb.getKeysym(kVK_F5));
    try testing.expectEqual(XKB_KEY_Escape, kb.getKeysym(kVK_Escape));
    try testing.expectEqual(XKB_KEY_Insert, kb.getKeysym(kVK_Help));
    // The keypad is not the digit row.
    try testing.expectEqual(XKB_KEY_KP_0 + 1, kb.getKeysym(kVK_ANSI_Keypad1));
    try testing.expectEqual(@as(u32, 'a'), kb.getKeysym(kVK_ANSI_A));
    try testing.expectEqual(@as(u32, '1'), kb.getKeysym(kVK_ANSI_1));
    try testing.expectEqual(@as(u32, ' '), kb.getKeysym(kVK_Space));
    kb.updateModifiers(SHIFT, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'A'), kb.getKeysym(kVK_ANSI_A));
    try testing.expectEqual(@as(u32, '!'), kb.getKeysym(kVK_ANSI_1));
    // Neither Caps Lock, Control nor Option changes the keysym.
    kb.updateModifiers(CAPS | CTRL | LOPT, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'a'), kb.getKeysym(kVK_ANSI_A));
    // Modifier keys and unknown codes have none.
    try testing.expectEqual(@as(u32, 0), kb.getKeysym(kVK_Shift));
    try testing.expectEqual(@as(u32, 0), kb.getKeysym(200));
    try testing.expectEqual(@as(u32, 0), kb.getKeysym(0xFFFF));
}

test "getKeysym: beyond Latin-1 is reported the way xkb does" {
    const cyrillic = struct {
        fn translate(_: ?*const anyopaque, _: u16, _: u32, _: u32, _: *u32, out: []u16) usize {
            out[0] = 0x0441; // с
            return 1;
        }
    };
    var kb = Keyboard.initWithLayout(.{ .translateFn = cyrillic.translate });
    defer kb.deinit();
    try testing.expectEqual(@as(u32, 0x0100_0441), kb.getKeysym(kVK_ANSI_C));
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("с", press(&kb, 0, kVK_ANSI_C, &buf));
}

test "Ctrl and bindings fall back to the ASCII-capable layout" {
    const cyrillic = struct {
        fn translate(_: ?*const anyopaque, kc: u16, mods: u32, opts: u32, dead: *u32, out: []u16) usize {
            if (kc == kVK_ANSI_C) {
                out[0] = 0x0441; // с
                return 1;
            }
            return usFallbackTranslate(null, kc, mods, opts, dead, out);
        }
    };
    var kb = Keyboard.initWithLayout(.{ .ctx = @ptrFromInt(1), .translateFn = cyrillic.translate });
    kb.ascii = .{ .layout = .{ .ctx = @ptrFromInt(2) } };
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("с", press(&kb, 0, kVK_ANSI_C, &buf));
    try testing.expectEqualStrings("\x03", press(&kb, CTRL, kVK_ANSI_C, &buf));
    kb.updateModifiers(0, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'c'), kb.getKeysym(kVK_ANSI_C));
}

test "resetState forgets modifiers and a pending accent" {
    var kb = deadKeyKeyboard();
    defer kb.deinit();
    var buf: [8]u8 = undefined;
    _ = press(&kb, LOPT, kVK_ANSI_E, &buf);
    kb.resetState();
    try testing.expectEqual(@as(u32, 0), kb.raw_flags);
    try testing.expectEqual(@as(u32, 0), kb.dead_key_state);
    try testing.expectEqualStrings("e", buf[0..kb.processKey(kVK_ANSI_E, &buf)]);
}

test "utf16ToUtf8: surrogate pairs, non-text and short buffers" {
    var out: [16]u8 = undefined;
    // U+1F600 as a surrogate pair.
    try testing.expectEqualStrings("😀", out[0..utf16ToUtf8(&.{ 0xD83D, 0xDE00 }, &out)]);
    // A lone surrogate, a control character and Apple's F-key PUA dropped.
    try testing.expectEqualStrings("ab", out[0..utf16ToUtf8(&.{ 'a', 0xD83D, 0x01, 0xF700, 'b' }, &out)]);
    // Stops before a character that does not fit.
    var small: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), utf16ToUtf8(&.{ 'a', 0x00E9 }, &small));
}

test "ctrlChar: comprehensive mappings" {
    try testing.expectEqual(@as(?u8, 1), ctrlChar('a'));
    try testing.expectEqual(@as(?u8, 1), ctrlChar('A'));
    try testing.expectEqual(@as(?u8, 26), ctrlChar('z'));
    try testing.expectEqual(@as(?u8, 3), ctrlChar('c'));
    try testing.expectEqual(@as(?u8, 0x1b), ctrlChar('['));
    try testing.expectEqual(@as(?u8, 0x1c), ctrlChar('\\'));
    try testing.expectEqual(@as(?u8, 0x1d), ctrlChar(']'));
    try testing.expectEqual(@as(?u8, 0x00), ctrlChar(' '));
    try testing.expectEqual(@as(?u8, null), ctrlChar('!'));
    try testing.expectEqual(@as(?u8, null), ctrlChar('1'));
}

test "keysymToEscape: unknown keysym returns empty" {
    try testing.expectEqual(@as(usize, 0), keysymToEscape(0x12345).len);
}

// ── Real macOS layouts (macOS only) ──────────────────────────────────

/// Load an installed keyboard layout by input source ID, for the tests.
fn systemLayoutForTest(source_id: [*:0]const u8) ?Source {
    if (comptime !is_macos) return null;
    const id_str = carbon.CFStringCreateWithCString(null, source_id, carbon.kCFStringEncodingUTF8) orelse return null;
    defer carbon.CFRelease(id_str);
    const keys = [_]*const anyopaque{carbon.kTISPropertyInputSourceID};
    const values = [_]*const anyopaque{id_str};
    const props = carbon.CFDictionaryCreate(null, &keys, &values, 1, &carbon.kCFTypeDictionaryKeyCallBacks, &carbon.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer carbon.CFRelease(props);
    const list = carbon.TISCreateInputSourceList(props, 1) orelse return null;
    defer carbon.CFRelease(list);
    if (carbon.CFArrayGetCount(list) < 1) return null;
    const src = carbon.CFArrayGetValueAtIndex(list, 0) orelse return null;
    var s: Source = .{};
    _ = s.replace(@constCast(carbon.CFRetain(src)));
    if (!s.layout.isSystem()) {
        s.release();
        return null;
    }
    return s;
}

fn systemKeyboardForTest(current_id: [*:0]const u8, ascii_id: [*:0]const u8) !Keyboard {
    var current = systemLayoutForTest(current_id) orelse return error.SkipZigTest;
    const ascii = systemLayoutForTest(ascii_id) orelse {
        current.release();
        return error.SkipZigTest;
    };
    // Not following the system, so the refresh leaves these in place and
    // deinit does not release them: releaseTestKeyboard does.
    return .{ .current = current, .ascii = ascii, .follow_system = false };
}

fn releaseTestKeyboard(kb: *Keyboard) void {
    if (comptime is_macos) {
        kb.current.release();
        kb.ascii.release();
    }
}

test "macOS US layout: text, Ctrl and the Option+E dead key" {
    if (comptime !is_macos) return error.SkipZigTest;
    var kb = try systemKeyboardForTest("com.apple.keylayout.US", "com.apple.keylayout.US");
    defer releaseTestKeyboard(&kb);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("c", press(&kb, 0, kVK_ANSI_C, &buf));
    try testing.expectEqualStrings("C", press(&kb, SHIFT, kVK_ANSI_C, &buf));
    try testing.expectEqualStrings("\x03", press(&kb, CTRL, kVK_ANSI_C, &buf));
    try testing.expectEqualStrings("", press(&kb, LOPT, kVK_ANSI_E, &buf));
    try testing.expectEqualStrings("é", press(&kb, 0, kVK_ANSI_E, &buf));
    _ = press(&kb, LOPT, kVK_ANSI_E, &buf);
    try testing.expectEqualStrings("´\r", press(&kb, 0, kVK_Return, &buf));
    _ = press(&kb, LOPT, kVK_ANSI_E, &buf);
    try testing.expectEqualStrings("", press(&kb, 0, kVK_Delete, &buf));
    try testing.expectEqualStrings("1", press(&kb, CAPS, kVK_ANSI_1, &buf));
}

test "macOS Dvorak layout: letters follow the layout" {
    if (comptime !is_macos) return error.SkipZigTest;
    var kb = try systemKeyboardForTest("com.apple.keylayout.Dvorak", "com.apple.keylayout.Dvorak");
    defer releaseTestKeyboard(&kb);
    var buf: [16]u8 = undefined;
    // Dvorak's C is on the QWERTY I key; QWERTY's C key types J.
    try testing.expectEqualStrings("c", press(&kb, 0, kVK_ANSI_I, &buf));
    try testing.expectEqualStrings("\x03", press(&kb, CTRL, kVK_ANSI_I, &buf));
    kb.updateModifiers(0, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'j'), kb.getKeysym(kVK_ANSI_C));
    kb.updateModifiers(SHIFT, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'J'), kb.getKeysym(kVK_ANSI_C));
}

test "macOS Dvorak - QWERTY Command layout: Cmd bindings use QWERTY" {
    if (comptime !is_macos) return error.SkipZigTest;
    var kb = try systemKeyboardForTest("com.apple.keylayout.DVORAK-QWERTYCMD", "com.apple.keylayout.DVORAK-QWERTYCMD");
    defer releaseTestKeyboard(&kb);
    kb.updateModifiers(0, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'j'), kb.getKeysym(kVK_ANSI_C));
    kb.updateModifiers(CMD, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'c'), kb.getKeysym(kVK_ANSI_C));
}

test "macOS French layout: AZERTY letters and digits row" {
    if (comptime !is_macos) return error.SkipZigTest;
    var kb = try systemKeyboardForTest("com.apple.keylayout.French", "com.apple.keylayout.French");
    defer releaseTestKeyboard(&kb);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("a", press(&kb, 0, kVK_ANSI_Q, &buf));
    try testing.expectEqualStrings("&", press(&kb, 0, kVK_ANSI_1, &buf));
    try testing.expectEqualStrings("\x01", press(&kb, CTRL, kVK_ANSI_Q, &buf));
}

test "macOS Russian layout: Cyrillic text, Latin Ctrl" {
    if (comptime !is_macos) return error.SkipZigTest;
    var kb = try systemKeyboardForTest("com.apple.keylayout.Russian", "com.apple.keylayout.US");
    defer releaseTestKeyboard(&kb);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("с", press(&kb, 0, kVK_ANSI_C, &buf));
    try testing.expectEqualStrings("\x03", press(&kb, CTRL, kVK_ANSI_C, &buf));
    kb.updateModifiers(0, 0, 0, 0);
    try testing.expectEqual(@as(u32, 'c'), kb.getKeysym(kVK_ANSI_C));
}

test "macOS: the selected input source loads" {
    if (comptime !is_macos) return error.SkipZigTest;
    var kb = try Keyboard.init();
    defer kb.deinit();
    var buf: [16]u8 = undefined;
    // Whatever the runner's layout, Return is Return and the space bar types.
    try testing.expectEqualStrings("\r", press(&kb, 0, kVK_Return, &buf));
    try testing.expect(press(&kb, 0, kVK_Space, &buf).len > 0);
}

test "x11Modifiers: NSEvent flags to X11 bits" {
    try std.testing.expectEqual(@as(u32, 0), x11Modifiers(0));
    // Device bits alone (left Command's 0x8) must not read as Alt.
    try std.testing.expectEqual(@as(u32, 0), x11Modifiers(dev_lcmd | dev_rshift | dev_lctrl));
    try std.testing.expectEqual(x11_shift, x11Modifiers(NSEventModifierFlagShift | dev_lshift));
    try std.testing.expectEqual(x11_control | x11_shift, x11Modifiers(NSEventModifierFlagControl | NSEventModifierFlagShift));
    try std.testing.expectEqual(x11_alt, x11Modifiers(NSEventModifierFlagOption | dev_ralt));
    try std.testing.expectEqual(x11_super, x11Modifiers(NSEventModifierFlagCommand | dev_lcmd));
    try std.testing.expectEqual(x11_lock, x11Modifiers(NSEventModifierFlagCapsLock));
}

test "x11Modifiers: matches the shared modifier masks" {
    const kc = @import("../types.zig").keycodes;
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    try std.testing.expectEqual(kc.SHIFT_MASK, x11Modifiers(NSEventModifierFlagShift));
    try std.testing.expectEqual(kc.CTRL_MASK, x11Modifiers(NSEventModifierFlagControl));
    try std.testing.expectEqual(kc.ALT_MASK, x11Modifiers(NSEventModifierFlagOption));
    try std.testing.expectEqual(kc.SUPER_MASK, x11Modifiers(NSEventModifierFlagCommand));
}

test "modifierTransition: press and release from the device bit" {
    const shift = NSEventModifierFlagShift;
    try std.testing.expectEqual(@as(?bool, true), modifierTransition(kVK_Shift, shift | dev_lshift));
    try std.testing.expectEqual(@as(?bool, false), modifierTransition(kVK_Shift, 0));
    // Right Shift pressed while left is held: a press, though the class
    // flag was already set.
    try std.testing.expectEqual(@as(?bool, true), modifierTransition(kVK_RightShift, shift | dev_lshift | dev_rshift));
    // Left released while right stays down: a release.
    try std.testing.expectEqual(@as(?bool, false), modifierTransition(kVK_Shift, shift | dev_rshift));
    try std.testing.expectEqual(@as(?bool, true), modifierTransition(kVK_RightOption, NSEventModifierFlagOption | dev_ralt));
    try std.testing.expectEqual(@as(?bool, false), modifierTransition(kVK_RightOption, NSEventModifierFlagOption | dev_lalt));
    try std.testing.expectEqual(@as(?bool, true), modifierTransition(kVK_RightControl, NSEventModifierFlagControl | dev_rctrl));
    try std.testing.expectEqual(@as(?bool, true), modifierTransition(kVK_Command, NSEventModifierFlagCommand | dev_lcmd));
}

test "modifierTransition: no device bits falls back to the class flag" {
    try std.testing.expectEqual(@as(?bool, true), modifierTransition(kVK_Control, NSEventModifierFlagControl));
    try std.testing.expectEqual(@as(?bool, false), modifierTransition(kVK_Control, 0));
}

test "modifierTransition: Caps Lock, Fn and ordinary keys are not held modifiers" {
    try std.testing.expectEqual(@as(?bool, null), modifierTransition(kVK_CapsLock, NSEventModifierFlagCapsLock));
    try std.testing.expectEqual(@as(?bool, null), modifierTransition(0x3F, 0)); // kVK_Function
    try std.testing.expectEqual(@as(?bool, null), modifierTransition(kVK_ANSI_A, NSEventModifierFlagShift));
}
