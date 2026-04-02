//! Keyboard input translation via xkbcommon.
//! Converts raw XCB keycodes to UTF-8 text and named keys.
//! Reads the active keyboard layout from the X11 server (zero hardcoding).

const std = @import("std");
const compat = @import("../../compat.zig");

// ── xkbcommon externs (extern linkage against libxkbcommon) ─────────

const xkb_context = opaque {};
const xkb_keymap = opaque {};
const xkb_state = opaque {};
const xkb_keycode_t = u32;
const xkb_keysym_t = u32;

extern "xkbcommon" fn xkb_context_new(flags: u32) callconv(.c) ?*xkb_context;
extern "xkbcommon" fn xkb_context_unref(ctx: *xkb_context) callconv(.c) void;
extern "xkbcommon" fn xkb_keymap_new_from_names(ctx: *xkb_context, names: ?*const XkbRuleNames, flags: u32) callconv(.c) ?*xkb_keymap;
extern "xkbcommon" fn xkb_keymap_unref(keymap: *xkb_keymap) callconv(.c) void;
extern "xkbcommon" fn xkb_state_new(keymap: *xkb_keymap) callconv(.c) ?*xkb_state;
extern "xkbcommon" fn xkb_state_unref(state: *xkb_state) callconv(.c) void;
extern "xkbcommon" fn xkb_state_key_get_utf8(state: *xkb_state, key: xkb_keycode_t, buf: [*]u8, size: usize) callconv(.c) c_int;
extern "xkbcommon" fn xkb_state_key_get_one_sym(state: *xkb_state, key: xkb_keycode_t) callconv(.c) xkb_keysym_t;
extern "xkbcommon" fn xkb_state_update_key(state: *xkb_state, key: xkb_keycode_t, direction: u32) callconv(.c) u32;
extern "xkbcommon" fn xkb_state_update_mask(state: *xkb_state, depressed_mods: u32, latched_mods: u32, locked_mods: u32, depressed_layout: u32, latched_layout: u32, locked_layout: u32) callconv(.c) u32;

const XkbRuleNames = extern struct {
    rules: ?[*:0]const u8 = null,
    model: ?[*:0]const u8 = null,
    layout: ?[*:0]const u8 = null,
    variant: ?[*:0]const u8 = null,
    options: ?[*:0]const u8 = null,
};

const XKB_KEY_DOWN: u32 = 1;
const XKB_KEY_UP: u32 = 0;

// ── Common keysyms ─────────────────────────────────────────────────

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

pub const Keyboard = struct {
    ctx: *xkb_context,
    keymap: *xkb_keymap,
    state: *xkb_state,

    /// Initialize keyboard with the active system layout.
    /// Resolution order (first success wins):
    ///   1. XKB_DEFAULT_* env vars (set by some desktop environments)
    ///   2. System default (xkbcommon's built-in fallback)
    /// No hardcoded layouts. Works for any language/variant.
    pub fn init() !Keyboard {
        const ctx = xkb_context_new(0) orelse return error.XkbContextFailed;
        errdefer xkb_context_unref(ctx);

        // Pass null — xkbcommon checks XKB_DEFAULT_LAYOUT, XKB_DEFAULT_VARIANT,
        // XKB_DEFAULT_OPTIONS, XKB_DEFAULT_MODEL, XKB_DEFAULT_RULES env vars.
        // If none set, uses system/X11 defaults. This handles all layouts
        // (dvorak, colemak, azerty, CJK IME, etc.) without any hardcoding.
        const keymap = xkb_keymap_new_from_names(ctx, null, 0) orelse {
            return error.XkbKeymapFailed;
        };
        errdefer xkb_keymap_unref(keymap);

        const state = xkb_state_new(keymap) orelse {
            return error.XkbStateFailed;
        };

        return .{ .ctx = ctx, .keymap = keymap, .state = state };
    }

    /// Initialize keyboard with an explicit XCB connection.
    /// Queries _XKB_RULES_NAMES from the X root window to get the
    /// live layout (set by setxkbmap). Falls back to env vars / defaults.
    pub fn initFromX11(xcb_conn: *anyopaque, root_window: u32) !Keyboard {
        const ctx = xkb_context_new(0) orelse return error.XkbContextFailed;
        errdefer xkb_context_unref(ctx);

        // Try to read the active keymap from X11 root window property
        var names = XkbRuleNames{};
        var rmlvo_buf: [1024]u8 = undefined;
        if (queryX11Layout(xcb_conn, root_window, &rmlvo_buf)) |rmlvo| {
            names = rmlvo;
        }
        // If query failed, names stays all-null → xkbcommon uses defaults

        const keymap = xkb_keymap_new_from_names(ctx, &names, 0) orelse {
            // Fallback: try with pure defaults
            const fallback = xkb_keymap_new_from_names(ctx, null, 0) orelse {
                return error.XkbKeymapFailed;
            };
            const state = xkb_state_new(fallback) orelse return error.XkbStateFailed;
            return .{ .ctx = ctx, .keymap = fallback, .state = state };
        };
        errdefer xkb_keymap_unref(keymap);

        const state = xkb_state_new(keymap) orelse return error.XkbStateFailed;
        return .{ .ctx = ctx, .keymap = keymap, .state = state };
    }

    pub fn deinit(self: *Keyboard) void {
        xkb_state_unref(self.state);
        xkb_keymap_unref(self.keymap);
        xkb_context_unref(self.ctx);
    }

    /// Get the keysym for a keycode without updating key state.
    /// Use this to peek at the keysym before processKey() consumes it.
    /// Safe because xkb_state_key_get_one_sym is a pure query.
    pub fn getKeysym(self: *Keyboard, keycode: u32) u32 {
        return xkb_state_key_get_one_sym(self.state, keycode);
    }

    /// Sync xkbcommon state with X11 modifier/group state.
    /// Call this with the XCB key event's `state` field before processKey
    /// to keep the layout group (e.g., us vs ua) in sync with the X server.
    pub fn updateModifiers(self: *Keyboard, x11_state: u32) void {
        // X11 state field layout:
        // bits 0-7: base modifiers (Shift, Lock, Control, Mod1-5)
        // bits 13-14: group index (0-3)
        const base_mods = x11_state & 0xFF;
        const group: u32 = (x11_state >> 13) & 0x3;
        _ = xkb_state_update_mask(self.state, base_mods, 0, 0, group, 0, 0);
    }

    /// Translate a raw XCB keycode to bytes for the PTY.
    pub fn processKey(self: *Keyboard, keycode: u32, pressed: bool, buf: []u8) usize {
        if (pressed) {
            _ = xkb_state_update_key(self.state, keycode, XKB_KEY_DOWN);
        } else {
            _ = xkb_state_update_key(self.state, keycode, XKB_KEY_UP);
            return 0;
        }

        const keysym = xkb_state_key_get_one_sym(self.state, keycode);
        const special = keysymToEscape(keysym);
        if (special.len > 0) {
            @memcpy(buf[0..special.len], special);
            return special.len;
        }

        const n = xkb_state_key_get_utf8(self.state, keycode, buf.ptr, buf.len);
        if (n > 0) return @intCast(n);

        return 0;
    }
};

// ── X11 layout query (reads _XKB_RULES_NAMES from root window) ─────

// XCB externs for property query (already linked via libxcb)
const xcb_connection_t = opaque {};
const XcbCookie = extern struct { sequence: c_uint };

const XcbAtomReply = extern struct {
    response_type: u8, pad0: u8, sequence: u16, length: u32, atom: u32,
};

const XcbPropertyReply = extern struct {
    response_type: u8, format: u8, sequence: u16, length: u32,
    type_: u32, bytes_after: u32, value_len: u32, pad0: [12]u8,
};

extern "xcb" fn xcb_intern_atom(conn: *xcb_connection_t, only_if_exists: u8, name_len: u16, name: [*]const u8) callconv(.c) XcbCookie;
extern "xcb" fn xcb_intern_atom_reply(conn: *xcb_connection_t, cookie: XcbCookie, err: ?*?*anyopaque) callconv(.c) ?*XcbAtomReply;
extern "xcb" fn xcb_get_property(conn: *xcb_connection_t, delete: u8, window: u32, property: u32, type_: u32, long_offset: u32, long_length: u32) callconv(.c) XcbCookie;
extern "xcb" fn xcb_get_property_reply(conn: *xcb_connection_t, cookie: XcbCookie, err: ?*?*anyopaque) callconv(.c) ?*XcbPropertyReply;
extern "xcb" fn xcb_get_property_value(reply: *XcbPropertyReply) callconv(.c) ?[*]const u8;
extern "xcb" fn xcb_get_property_value_length(reply: *XcbPropertyReply) callconv(.c) c_int;

const XCB_ATOM_STRING: u32 = 31;

/// Query _XKB_RULES_NAMES property from the X11 root window.
/// Returns RMLVO names parsed from the null-separated value.
/// This property is set by setxkbmap and reflects the LIVE keyboard layout.
fn queryX11Layout(conn_opaque: *anyopaque, root: u32, buf: []u8) ?XkbRuleNames {
    const conn: *xcb_connection_t = @ptrCast(conn_opaque);

    // Intern _XKB_RULES_NAMES atom
    const atom_name = "_XKB_RULES_NAMES";
    const cookie = xcb_intern_atom(conn, 1, atom_name.len, atom_name.ptr);
    const reply = xcb_intern_atom_reply(conn, cookie, null) orelse return null;
    const atom = reply.atom;
    std.c.free(@ptrCast(@constCast(reply)));
    if (atom == 0) return null;

    // Get property value
    const prop_cookie = xcb_get_property(conn, 0, root, atom, XCB_ATOM_STRING, 0, 1024);
    const prop_reply = xcb_get_property_reply(conn, prop_cookie, null) orelse return null;
    defer std.c.free(@ptrCast(@constCast(prop_reply)));

    const value_ptr = xcb_get_property_value(prop_reply) orelse return null;
    const value_len: usize = @intCast(xcb_get_property_value_length(prop_reply));
    if (value_len == 0 or value_len > buf.len) return null;

    // Copy to our buffer (the reply will be freed)
    @memcpy(buf[0..value_len], value_ptr[0..value_len]);

    // _XKB_RULES_NAMES is 5 null-terminated strings:
    // rules\0model\0layout\0variant\0options\0
    var names = XkbRuleNames{};
    var field: u8 = 0;
    var start: usize = 0;
    for (0..value_len) |i| {
        if (buf[i] == 0) {
            if (i > start) {
                // Null-terminate in buf (already is, from the property)
                const str: [*:0]const u8 = @ptrCast(buf[start..].ptr);
                switch (field) {
                    0 => names.rules = str,
                    1 => names.model = str,
                    2 => names.layout = str,
                    3 => names.variant = str,
                    4 => names.options = str,
                    else => {},
                }
            }
            field += 1;
            start = i + 1;
        }
    }

    return names;
}

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
