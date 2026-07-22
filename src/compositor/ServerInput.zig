//! Input-device setup + keyboard handling for teruwm.
//!
//! This file owns:
//!   * handleNewInput listener dispatch (keyboard vs. pointer routing).
//!   * Per-keyboard state (`Keyboard` struct with key / modifiers /
//!     destroy listeners — allocated in setupKeyboard, freed by the
//!     device-destroy listener).
//!   * XKB keymap setup with the three-layer fallback used by
//!     setupKeyboard, plus `refreshActiveKeymap` that captures the
//!     effective layout name for the `{keymap}` bar widget.
//!   * The big `handleKey` keybind-dispatch switch plus helpers
//!     (runMediaAction, applyScrollAction, tryRunSpawnChord) and the
//!     300-line `executeAction` action dispatcher.
//!   * `notifyActivity` — called from every real input event (here
//!     *and* from the cursor listeners, once ServerCursor lands); any
//!     idle-notify v1 subscriber (swayidle, gammastep, wlsunset) sees
//!     the activity ping.
//!
//! Functions take `*Server` directly (Zig 0.16 split pattern). Server
//! keeps thin pub delegators for external callers (WmMcpServer,
//! ServerListeners) so the public API is stable.

const std = @import("std");
const wlr = @import("wlr.zig");
const teru = @import("teru");
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");
const Session = @import("Session.zig");
const ServerClipboard = @import("ServerClipboard.zig");
const KeysOsd = @import("KeysOsd.zig");

const Keybinds = teru.Keybinds;
const KBAction = Keybinds.Action;
const KBMods = Keybinds.Mods;

// ── Signal-level dispatch ─────────────────────────────────────

pub fn handleNewInput(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_input", listener);
    const device: *wlr.wlr_input_device = @ptrCast(@alignCast(data orelse return));

    const device_type = wlr.miozu_input_device_type(device);

    if (device_type == wlr.WLR_INPUT_DEVICE_KEYBOARD) {
        setupKeyboard(server, device);
    } else if (device_type == wlr.WLR_INPUT_DEVICE_POINTER) {
        wlr.wlr_cursor_attach_input_device(server.cursor, device);
        // Turn on the laptop-touchpad defaults (tap-to-click + disable-while-
        // typing + natural scroll). libinput ships with every useful option
        // OFF; without this the touchpad feels broken even when clicks-via-
        // physical-button still work. natural_scroll is config-driven
        // (default ON) — set natural_scroll=false for traditional scrolling.
        wlr.miozu_configure_libinput_pointer(device, @intFromBool(server.wm_config.natural_scroll));
    }

    var caps: u32 = wlr.WL_SEAT_CAPABILITY_POINTER;
    caps |= wlr.WL_SEAT_CAPABILITY_KEYBOARD;
    wlr.wlr_seat_set_capabilities(server.seat, caps);
}

// notifyActivity lives on Server now — same one-liner, no cross-module
// hop from ServerCursor. Both ServerInput + ServerCursor call it via
// `server.notifyActivity()`.

// ── Per-keyboard state ────────────────────────────────────────

/// Allocated in setupKeyboard, freed by handleDestroy. Listeners are
/// embedded so @fieldParentPtr resolves the owning Keyboard in O(1).
pub const Keyboard = struct {
    server: *Server,
    device: *wlr.wlr_input_device,
    wlr_keyboard: *wlr.wlr_keyboard,
    key_listener: wlr.wl_listener,
    modifiers_listener: wlr.wl_listener,
    destroy_listener: wlr.wl_listener,

    fn handleKeyEvent(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
        const kb: *Keyboard = @fieldParentPtr("key_listener", listener);
        const event_ptr = data orelse return;

        const keycode = wlr.miozu_keyboard_key_keycode(event_ptr);
        const key_state = wlr.miozu_keyboard_key_state(event_ptr);
        const time = wlr.miozu_keyboard_key_time(event_ptr);
        const xkb_st = wlr.miozu_keyboard_xkb_state(kb.wlr_keyboard) orelse return;

        kb.server.notifyActivity();

        // Track Right-Alt held state across press/release. Keyed on the Alt_R
        // KEYSYM (0xffea), not the evdev keycode — a virtual keyboard (wtype)
        // generates its own keymap with arbitrary keycodes, but the keysym is
        // stable. MUST run before every swallow path below (area-select /
        // dispatch / PTY writes all `return` early) so a release is never
        // missed and ralt can't get stuck on.
        if (wlr.xkb_state_key_get_one_sym(xkb_st, keycode + 8) == wlr.XKB_KEY_Alt_R) {
            kb.server.ralt_held = (key_state == 1);
        }

        // Keystroke-OSD tap — MUST stay above every swallow path below
        // (area-select, keybind consumption, leader/launcher modes, PTY
        // writes) so the OSD sees every hardware key edge. Guarded by
        // `active` so the disabled path costs one bool check.
        if (kb.server.keys_osd.active) {
            const osd_sym = wlr.xkb_state_key_get_one_sym(xkb_st, keycode + 8);
            KeysOsd.feedFromXkb(kb.server, osd_sym, xkb_st, key_state == 1);
        }

        // While area-select is armed, the keyboard belongs to it: Escape
        // cancels and every key is swallowed so a chord can't leak to a
        // client mid-selection.
        if (kb.server.cursor_mode == .area_select) {
            if (key_state == 1) {
                const sym = wlr.xkb_state_key_get_one_sym(xkb_st, keycode + 8);
                if (sym == 0xff1b) kb.server.cancelAreaSelect(); // XKB_KEY_Escape
            }
            return;
        }

        // Release of the currently-repeating key disarms the timers.
        // Done before dispatch so a press of a different key can re-arm
        // cleanly in the same event.
        if (key_state == 0) {
            if (keycode == kb.server.keybind_repeat_keycode) {
                kb.server.cancelKeybindRepeat();
            }
            if (keycode == kb.server.terminal_repeat_keycode) {
                kb.server.cancelTerminalRepeat();
            }
        }

        if (key_state == 1) {
            if (handleKey(kb.server, keycode, xkb_st)) return;
        }

        if (kb.server.focused_terminal) |tp| {
            if (key_state == 1) {
                var buf: [8]u8 = undefined;
                const sym = wlr.xkb_state_key_get_one_sym(xkb_st, keycode + 8);
                const ctrl = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_CTRL, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;
                const logo = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;

                // $mod (Super) is a window-manager modifier, never terminal
                // input. A $mod-chord that reached here matched no keybind
                // (handleKey returned false), so swallow it — otherwise an
                // unbound combo like $mod+Q would leak its letter ("q") into
                // the shell, since xkb_state_key_get_utf8 still yields "q"
                // (Logo isn't a text-level modifier). Real terminal input
                // never holds Super.
                if (logo) {
                    kb.server.cancelTerminalRepeat();
                    return;
                }

                // Ctrl+Shift+C/V are no longer special-cased here: the
                // .shared keybind (Keybinds.zig loadDefaults) resolves them
                // to .copy_selection/.paste_clipboard, which executeAction
                // now handles — so handleKey consumed them above. If a user
                // UNBINDS the chord, it falls through to xkb utf8 encoding
                // (0x03/0x16 to the PTY) — intentional, matches other
                // terminals' rebindable copy/paste.

                // Pressing a different key while another is held-repeating
                // takes ownership; arm with the new byte sequence after
                // we write it.
                var repeat_bytes: []const u8 = &[_]u8{};

                if (ctrl and sym >= 'a' and sym <= 'z') {
                    buf[0] = @intCast(sym - 'a' + 1);
                    tp.writeInput(buf[0..1]);
                    repeat_bytes = buf[0..1];
                } else {
                    const len = wlr.xkb_state_key_get_utf8(xkb_st, keycode + 8, &buf, buf.len);
                    if (len > 0) {
                        const ulen: usize = @intCast(len);
                        // Meta/Alt → ESC-prefixed bytes (xterm metaSendsEscape).
                        // Without this, Alt+key reached a terminal app as the bare
                        // character — e.g. a nested teru's Alt+j pane-switch arrived
                        // as "j" and leaked into the shell. Left Alt is XKB's
                        // XKB_MOD_NAME_ALT (Mod1); AltGr is Mod5/Level3, so this
                        // does NOT touch AltGr character composition (é, €, …).
                        const alt = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_ALT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;
                        if (alt and ulen + 1 <= buf.len) {
                            var i: usize = ulen;
                            while (i > 0) : (i -= 1) buf[i] = buf[i - 1]; // shift right 1
                            buf[0] = 0x1b; // ESC
                            tp.writeInput(buf[0 .. ulen + 1]);
                            repeat_bytes = buf[0 .. ulen + 1];
                        } else {
                            tp.writeInput(buf[0..ulen]);
                            repeat_bytes = buf[0..ulen];
                        }
                    } else {
                        // Arrow / navigation / function keys: xkb_state_key_get_utf8
                        // returns 0 for these, so without this they're silently
                        // dropped in teruwm-native panes (e.g. arrows do nothing in
                        // claude-code's menus). Encode them ourselves, DECCKM-aware
                        // for arrows.
                        const esc = teru.keysyms.escapeForKeysym(@intCast(sym), tp.pane.vt.app_cursor_keys);
                        if (esc.len > 0) {
                            tp.writeInput(esc);
                            repeat_bytes = esc;
                        }
                    }
                }

                if (repeat_bytes.len > 0) {
                    kb.server.armTerminalRepeat(keycode, repeat_bytes);
                } else {
                    kb.server.cancelTerminalRepeat();
                }
            }
            return;
        }

        wlr.wlr_seat_keyboard_notify_key(kb.server.seat, time, keycode, key_state);
    }

    fn handleModifiers(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const kb: *Keyboard = @fieldParentPtr("modifiers_listener", listener);
        wlr.wlr_seat_set_keyboard(kb.server.seat, kb.wlr_keyboard);
        wlr.wlr_seat_keyboard_notify_modifiers(kb.server.seat, wlr.miozu_keyboard_modifiers_ptr(kb.wlr_keyboard));
        refreshActiveKeymap(kb.server, kb.wlr_keyboard);
        // Letting Super go mid-repeat should stop growing the master —
        // otherwise the timer keeps firing Mod+L actions even though
        // the user only meant to press Mod+L once then release Super.
        kb.server.cancelKeybindRepeat();
        // Modifier flip also ends a PTY-input repeat so e.g. holding
        // Ctrl then pressing `u` for one Ctrl+U doesn't keep repeating
        // after Ctrl is released.
        kb.server.cancelTerminalRepeat();
    }

    /// Device went away (unplug, runtime disable). Unhook listeners
    /// and drop the Keyboard from Server.keyboards.
    fn handleDestroy(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const kb: *Keyboard = @fieldParentPtr("destroy_listener", listener);
        const server = kb.server;

        // A keyboard destroyed mid-hold never delivers its release; clear the
        // tracked Right-Alt state so it can't get stuck on (e.g. a one-shot
        // virtual keyboard, or a device unplugged while held).
        server.ralt_held = false;

        wlr.wl_list_remove(&kb.key_listener.link);
        wlr.wl_list_remove(&kb.modifiers_listener.link);
        wlr.wl_list_remove(&kb.destroy_listener.link);

        for (server.keyboards.items, 0..) |entry, i| {
            if (entry == kb) {
                _ = server.keyboards.swapRemove(i);
                break;
            }
        }

        server.zig_allocator.destroy(kb);
    }
};

// ── Keymap setup ──────────────────────────────────────────────

/// Scratch buffer for the XKB code returned by extractLayoutCode.
/// Module-scope so the returned slice stays valid across the xkbcommon
/// free() — the caller copies it into Server.active_keymap_name_buf.
var keymap_raw_buf: [32]u8 = undefined;

/// Cache of the last (keymap, layout) we extracted a code for. handleModifiers
/// calls refreshActiveKeymap on EVERY modifier event, but the layout code only
/// changes when the layout group (or the keymap object) changes — so this
/// avoids serializing the entire ~tens-of-KB keymap to a heap string (and a
/// bar repaint) on every Shift/Ctrl/Alt press.
var cached_keymap_ptr: ?*wlr.xkb_keymap = null;
var cached_layout_idx: u32 = std.math.maxInt(u32);

/// Read the effective XKB layout CODE ("us", "ua", "us(dvorak)") from
/// the given keyboard and stash a copy in `active_keymap_name`.
pub fn refreshActiveKeymap(server: *Server, keyboard: *wlr.wlr_keyboard) void {
    const st = wlr.miozu_keyboard_xkb_state(keyboard) orelse return;
    const keymap = wlr.xkb_state_get_keymap(st) orelse return;
    const layout_idx = wlr.xkb_state_serialize_layout(st, wlr.XKB_STATE_LAYOUT_EFFECTIVE);

    // Nothing relevant changed since the last call — skip the expensive
    // extractLayoutCode (full-keymap serialize) and the bar repaint below.
    if (keymap == cached_keymap_ptr and layout_idx == cached_layout_idx) return;
    cached_keymap_ptr = keymap;
    cached_layout_idx = layout_idx;

    const short = extractLayoutCode(keymap, layout_idx);
    const name_slice: []const u8 = if (short.len > 0)
        short
    else blk: {
        const name_ptr = wlr.xkb_keymap_layout_get_name(keymap, layout_idx) orelse return;
        break :blk std.mem.sliceTo(name_ptr, 0);
    };

    const n = @min(name_slice.len, server.active_keymap_name_buf.len);
    @memcpy(server.active_keymap_name_buf[0..n], name_slice[0..n]);
    server.active_keymap_name = server.active_keymap_name_buf[0..n];

    if (server.bar) |b| _ = b.render(server);
}

/// Extract the Nth XKB layout code from the keymap's xkb_symbols
/// header. Format seen in practice: `pc_us(dvorak)_ua_2_inet(evdev)`.
/// Returns an empty slice on failure; caller falls back to friendly
/// layout name.
fn extractLayoutCode(keymap: *wlr.xkb_keymap, target_idx: u32) []const u8 {
    const raw_ptr = wlr.xkb_keymap_get_as_string(keymap, wlr.XKB_KEYMAP_FORMAT_TEXT_V1) orelse return "";
    defer wlr.free(@as(*anyopaque, @ptrCast(raw_ptr)));
    const raw = std.mem.sliceTo(raw_ptr, 0);

    const hdr = "xkb_symbols";
    const hdr_pos = std.mem.find(u8, raw, hdr) orelse return "";
    const q1 = std.mem.findScalarPos(u8, raw, hdr_pos + hdr.len, '"') orelse return "";
    const q2 = std.mem.findScalarPos(u8, raw, q1 + 1, '"') orelse return "";
    const sig = raw[q1 + 1 .. q2];

    var it = std.mem.splitScalar(u8, sig, '_');
    var idx: u32 = 0;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "pc") or std.mem.eql(u8, tok, "inet")) continue;
        if (tok[0] >= '0' and tok[0] <= '9') continue;
        if (tok.len < 2 or !std.ascii.isLower(tok[0]) or !std.ascii.isLower(tok[1])) continue;

        if (idx == target_idx) {
            const n = @min(tok.len, keymap_raw_buf.len);
            @memcpy(keymap_raw_buf[0..n], tok[0..n]);
            return keymap_raw_buf[0..n];
        }
        idx += 1;
    }
    return "";
}

pub fn setupKeyboard(server: *Server, device: *wlr.wlr_input_device) void {
    const keyboard = wlr.miozu_input_device_keyboard(device) orelse return;

    // Three-layer keymap resolution:
    //   1. teruwm [keyboard] section from WmConfig  (most specific)
    //   2. XKB_DEFAULT_* env vars (environment.d / shell)
    //   3. libxkbcommon built-in default (us QWERTY)
    //
    // Layer 1 sets struct fields directly; layers 2/3 are consulted
    // by libxkbcommon for any field we leave null. No [keyboard]
    // entries → pass NULL and fall through to env / default.
    const keymap = blk: {
        if (server.wm_config.hasXkbOverrides()) {
            const names = wlr.XkbRuleNames{
                .rules = server.wm_config.getXkbRules(),
                .model = server.wm_config.getXkbModel(),
                .layout = server.wm_config.getXkbLayout(),
                .variant = server.wm_config.getXkbVariant(),
                .options = server.wm_config.getXkbOptions(),
            };
            if (wlr.xkb_keymap_new_from_names(server.xkb_ctx, &names, 0)) |km| break :blk km;
            std.log.scoped(.input).warn("[keyboard] config invalid, falling back to env/defaults", .{});
        }
        break :blk wlr.xkb_keymap_new_from_names(server.xkb_ctx, null, 0) orelse return;
    };
    defer wlr.xkb_keymap_unref(keymap);

    _ = wlr.wlr_keyboard_set_keymap(keyboard, keymap);
    wlr.wlr_keyboard_set_repeat_info(keyboard, 25, 600);

    const kb = server.zig_allocator.create(Keyboard) catch return;
    kb.* = .{
        .server = server,
        .device = device,
        .wlr_keyboard = keyboard,
        .key_listener = .{ .link = .{ .prev = null, .next = null }, .notify = Keyboard.handleKeyEvent },
        .modifiers_listener = .{ .link = .{ .prev = null, .next = null }, .notify = Keyboard.handleModifiers },
        .destroy_listener = .{ .link = .{ .prev = null, .next = null }, .notify = Keyboard.handleDestroy },
    };

    wlr.wl_signal_add(wlr.miozu_keyboard_key(keyboard), &kb.key_listener);
    wlr.wl_signal_add(wlr.miozu_keyboard_modifiers(keyboard), &kb.modifiers_listener);
    wlr.wl_signal_add(wlr.miozu_input_device_destroy(device), &kb.destroy_listener);

    server.keyboards.append(server.zig_allocator, kb) catch {
        wlr.wl_list_remove(&kb.key_listener.link);
        wlr.wl_list_remove(&kb.modifiers_listener.link);
        wlr.wl_list_remove(&kb.destroy_listener.link);
        server.zig_allocator.destroy(kb);
        return;
    };

    wlr.wlr_seat_set_keyboard(server.seat, keyboard);
    refreshActiveKeymap(server, keyboard);

    std.log.scoped(.input).info("keyboard configured", .{});
}

// ── Keybind dispatch ──────────────────────────────────────────

/// Normalize an xkb keysym to the value teru Keybinds are stored against:
/// uppercase ASCII → lowercase (Shift'd 'J' → 'j'); Shift+number-row → base
/// digit (!→1 … )→0) so a bind on '1' still matches when Shift is held; and the
/// common control keysyms → their ASCII codes (both dispatch paths — ServerInput
/// here and the standalone u8 key_char path — deliver ASCII, so a bind stored as
/// the 0xff.. keysym would never match). Everything else passes through. Pure so
/// it's unit-testable without an xkb_state.
fn foldKeysym(sym: u32) u32 {
    if (sym >= 'A' and sym <= 'Z') return sym + 32;
    return switch (sym) {
        '!' => '1', '@' => '2', '#' => '3', '$' => '4', '%' => '5',
        '^' => '6', '&' => '7', '*' => '8', '(' => '9', ')' => '0',
        0xff0d => '\r', // Return → CR
        0xff1b => 0x1b, // Escape
        0xff09 => '\t', // Tab
        0xfe20 => '\t', // ISO_Left_Tab — xkb delivers this for Shift+Tab, so a
        // Mod+Shift+Tab bind (stored on '\t') needs it folded like the digit-row
        // shifts (!→1 …) above; without it, Mod+Shift+Tab was silently dead.
        0xff08 => 0x7f, // BackSpace → DEL
        else => sym,
    };
}

/// Assemble teru Keybinds.Mods from decoded modifier booleans. `ralt_held`
/// (Right-Alt, tracked by keysym because xkb collapses Alt_R onto Mod1) sets
/// the `ralt` bit; a `ralt+` bind parses to {alt, ralt} and RAlt held also
/// reports alt (Mod1), so both are set — matching KeyHandler.platformMods on the
/// standalone path. Pure so keybind-dispatch matching is unit-testable.
fn buildMods(alt: bool, shift: bool, ctrl: bool, super_: bool, ralt_held: bool) KBMods {
    return .{
        .alt = alt,
        .shift = shift,
        .ctrl = ctrl,
        .super_ = super_,
        .ralt = ralt_held,
    };
}

/// Translate an xkb keycode + modifier state into a teru Keybinds
/// lookup, then run the resulting action. Returns true if the key was
/// consumed (don't forward to the focused surface).
pub fn handleKey(server: *Server, keycode: u32, xkb_state_ptr: *wlr.xkb_state) bool {
    const sym = wlr.xkb_state_key_get_one_sym(xkb_state_ptr, keycode + 8);

    // VT switching (Ctrl+Alt+F1..F12) — handled first, never forwarded.
    if (sym >= wlr.XKB_KEY_XF86Switch_VT_1 and sym <= wlr.XKB_KEY_XF86Switch_VT_1 + 11) {
        if (server.session) |session| {
            _ = wlr.wlr_session_change_vt(session, @intCast(sym - wlr.XKB_KEY_XF86Switch_VT_1 + 1));
        }
        return true;
    }

    const key = foldKeysym(sym);

    const mods = buildMods(
        wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_ALT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0,
        wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0,
        wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_CTRL, wlr.XKB_STATE_MODS_EFFECTIVE) > 0,
        wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0,
        server.ralt_held,
    );

    // Launcher mode swallows EVERY key until deactivated — including ones it
    // doesn't act on. handleKey only consumes printable / Tab / Enter / Esc /
    // BackSpace; previously returning false for the rest (arrows, Home/End,
    // F-keys, unbound chords) fell through to keybind dispatch AND then to the
    // focused-terminal byte-input path below — so a stray key while the
    // launcher was open could fire a WM action or leak bytes into the shell
    // underneath. VT-switch (handled above) is the only intentional exception.
    if (server.launcher.active) {
        const consumed = server.launcher.handleKey(sym, server);
        // Enter on a COMMAND defers to us (the launcher can't see executeAction).
        const pending = server.launcher.pending_action;
        server.launcher.pending_action = null;
        if (consumed) server.renderLauncherBar();
        if (pending) |act| _ = executeAction(server, act);
        return true;
    }

    // Leader mode (Super+Space): route every key through the which-key keymap.
    // A key either descends into a group (re-render the hint), fires an action
    // (run + leave), or dismisses. The normalized `key` (lowercased ASCII,
    // space, Esc=0x1b) is what the keymap matches on; `mods.shift` lets the
    // keymap distinguish e.g. Shift+j (swap-next) from j (focus-next).
    if (server.leader.active) {
        // Double-tap the leader (Super+Space again) → fuzzy command palette
        // (the "LEADER LEADER" idiom): commands first, then $PATH apps, in the
        // bottom bar. Plain Space (no Super) stays the root `layout` action.
        if (key == ' ' and mods.super_) {
            server.leader.deactivate();
            server.renderLeaderHint(); // hide the which-key band
            server.launcher.seedCommands(server.leader.root);
            server.launcher.activate();
            server.renderLauncherBar();
            return true;
        }
        switch (server.leader.feedKey(key, mods.shift)) {
            .redraw => server.renderLeaderHint(),
            .dismiss => {
                server.leader.deactivate();
                server.renderLeaderHint(); // restore the normal bar
            },
            .run => |act| {
                server.leader.deactivate();
                server.renderLeaderHint(); // restore the normal bar before acting
                _ = executeAction(server, act);
            },
        }
        return true; // leader swallows every key while active
    }

    // Scratchpad: Alt+RAlt+1..9 picks scratchpad N.
    if (mods.alt and mods.ralt and key >= '1' and key <= '9') {
        server.toggleScratchpad(@intCast(key - '1'));
        return true;
    }

    const action = server.keybinds.lookup(.normal, mods, key) orelse {
        // An unbound key press breaks the current repeat — ensures that
        // typing into a terminal while Mod+L was held doesn't keep
        // resizing the master area.
        server.cancelKeybindRepeat();
        return false;
    };
    const consumed = executeAction(server, action);
    if (consumed) server.armKeybindRepeat(action, keycode);
    return consumed;
}

/// One of the XF86 media/brightness/volume shell-spawn actions.
fn runMediaAction(server: *Server, action: KBAction) void {
    const cmd: [*:0]const u8 = switch (action) {
        .volume_up => "wpctl set-volume @DEFAULT_SINK@ 5%+",
        .volume_down => "wpctl set-volume @DEFAULT_SINK@ 5%-",
        .volume_mute => "wpctl set-mute @DEFAULT_SINK@ toggle",
        .brightness_up => "brightnessctl set +5%",
        .brightness_down => "brightnessctl set 5%-",
        .media_play => "playerctl play-pause",
        .media_next => "playerctl next",
        .media_prev => "playerctl previous",
        else => return,
    };
    server.spawnProcess(cmd);
}

/// Scroll action applied to the focused terminal. Pure state mutation
/// + one re-render; layout engine + seat untouched.
fn applyScrollAction(tp: *TerminalPane, action: KBAction) void {
    switch (action) {
        .scroll_up_1, .scroll_up_half => {
            const lines: u32 = if (action == .scroll_up_half) tp.pane.grid.rows / 2 else 1;
            const max_offset: u32 = @intCast(tp.pane.scrollback.total_lines);
            if (max_offset == 0) return;
            tp.pane.scroll_offset = @min(tp.pane.scroll_offset + lines, max_offset);
        },
        .scroll_down_1, .scroll_down_half => {
            const lines: u32 = if (action == .scroll_down_half) tp.pane.grid.rows / 2 else 1;
            tp.pane.scroll_offset -|= lines;
        },
        .scroll_top => tp.pane.scroll_offset = @intCast(tp.pane.scrollback.total_lines),
        .scroll_bottom => tp.pane.scroll_offset = 0,
        else => return,
    }
    tp.pane.scroll_pixel = 0;
    // Full repaint next vsync (the scrollback overlay shifts the whole frame),
    // coalesced via the frame callback rather than rendered inline.
    tp.pane.grid.markAllDirty();
    tp.server.scheduleRender();
}

/// Resolve a `spawn_N` action variant to its configured command.
fn tryRunSpawnChord(server: *Server, action: KBAction) bool {
    const tag: u8 = @intFromEnum(action);
    const first: u8 = @intFromEnum(KBAction.spawn_0);
    const last: u8 = @intFromEnum(KBAction.spawn_31);
    if (tag < first or tag > last) return false;
    const slot: u8 = tag - first;
    const len: usize = server.spawn_table_len[slot];
    if (len > 0) server.spawnShell(server.spawn_table[slot][0..len]);
    return true;
}

/// Resolve a `scratchpad_N` action variant to the configured scratchpad
/// name and toggle. Unconfigured slots are silently ignored — the chord
/// is still "consumed" so it doesn't leak through to the client.
fn tryRunScratchpadChord(server: *Server, action: KBAction) bool {
    const tag: u8 = @intFromEnum(action);
    const first: u8 = @intFromEnum(KBAction.scratchpad_0);
    const last: u8 = @intFromEnum(KBAction.scratchpad_7);
    if (tag < first or tag > last) return false;
    const slot: u8 = tag - first;
    const len: usize = server.scratchpad_table_len[slot];
    if (len > 0) server.toggleScratchpadByName(server.scratchpad_table[slot][0..len]);
    return true;
}

/// Execute a keybind action. Shared by compositor keybinds and MCP
/// tools (WmMcpServer exposes this via teruwm_run_action).
pub fn executeAction(server: *Server, action: KBAction) bool {
    if (action.workspaceIndex()) |ws| {
        server.focusWorkspace(ws);
        return true;
    }

    if (action.moveToIndex()) |ws| {
        // Resolve from the actually-focused thing, not from the active
        // workspace's tiled-only `node_ids`. A floating window or a
        // browser (xdg toplevel) isn't in `node_ids`, so the old path
        // silently grabbed the master tile instead of the focused
        // window — user symptom was "Win+Shift+N does nothing on my
        // floating window / Chromium". Prefer focused_view (last-touched
        // xdg client) then focused_terminal; fall back to the tiled
        // active id only if neither is set.
        const nid: ?u64 = if (server.focused_view) |v| v.node_id
        else if (server.focused_terminal) |tp| tp.node_id
        else server.layout_engine.getActiveWorkspace().getActiveNodeId();
        if (nid) |id| server.moveNodeToWorkspace(id, ws);
        return true;
    }

    switch (action) {
        .spawn_terminal => {
            server.spawnTerminal(server.layout_engine.active_workspace);
            return true;
        },
        .window_close, .pane_close => {
            server.closeFocused();
            return true;
        },
        .compositor_quit => {
            std.log.scoped(.compositor).info("compositor_quit (Mod+Shift+Q or MCP)", .{});
            wlr.wl_display_terminate(server.display);
            return true;
        },
        .compositor_restart => {
            server.execRestart();
            return true;
        },
        .config_reload => {
            server.reloadWmConfig();
            return true;
        },
        .layout_cycle => {
            server.layout_engine.getActiveWorkspace().cycleLayout();
            server.arrangeworkspace(server.layout_engine.active_workspace);
            if (server.bar) |b| _ = b.render(server);
            return true;
        },
        .pane_focus_next => {
            // Includes floating windows in the cycle — workspace.focusNext
            // alone walks the tiled list only, so Win+J would skip any
            // float.
            server.cycleFocusAll(true);
            return true;
        },
        .pane_focus_prev => {
            server.cycleFocusAll(false);
            return true;
        },
        .pane_swap_next => {
            server.layout_engine.getActiveWorkspace().swapWithNext();
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .pane_swap_prev => {
            server.layout_engine.getActiveWorkspace().swapWithPrev();
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .pane_set_master => {
            server.layout_engine.getActiveWorkspace().promoteToMaster();
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .pane_swap_master => {
            server.layout_engine.getActiveWorkspace().swapWithMaster();
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .pane_rotate_slaves_up => {
            server.layout_engine.getActiveWorkspace().rotateSlaves(true);
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .pane_rotate_slaves_down => {
            server.layout_engine.getActiveWorkspace().rotateSlaves(false);
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .master_count_inc => {
            server.layout_engine.getActiveWorkspace().adjustMasterCount(1);
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .master_count_dec => {
            server.layout_engine.getActiveWorkspace().adjustMasterCount(-1);
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .pane_sink => {
            server.sinkFocused();
            return true;
        },
        .pane_sink_all => {
            server.sinkAllOnActiveWorkspace();
            return true;
        },
        .layout_reset => {
            const ws = server.layout_engine.getActiveWorkspace();
            ws.layout = .master_stack;
            ws.master_count = 1;
            server.arrangeworkspace(server.layout_engine.active_workspace);
            if (server.bar) |b| _ = b.render(server);
            return true;
        },
        .session_save => {
            Session.save(server, "default") catch |err| {
                std.log.scoped(.session).err("session save failed: {}", .{err});
            };
            return true;
        },
        .session_restore => {
            Session.restore(server, "default") catch |err| {
                std.log.scoped(.session).err("session restore failed: {}", .{err});
            };
            return true;
        },
        .workspace_toggle_last => {
            // Prefer per-output prev; fall back to legacy single-prev
            // for the headless-init window before any output attaches.
            const prev = if (server.focused_output) |out| out.prev_workspace else server.prev_workspace;
            if (prev) |p| server.focusWorkspace(p);
            return true;
        },
        .workspace_next_nonempty => {
            const start: u8 = server.activeWorkspace();
            var step: u8 = 1;
            while (step < 10) : (step += 1) {
                const cand: u8 = (start + step) % 10;
                if (server.nodes.countInWorkspace(cand) > 0) {
                    server.focusWorkspace(cand);
                    break;
                }
            }
            return true;
        },
        .focus_output_next => {
            server.focusNextOutput();
            return true;
        },
        .move_to_output_next => {
            server.moveFocusedToNextOutput();
            return true;
        },
        .resize_shrink_w => {
            const ws = server.layout_engine.getActiveWorkspace();
            ws.master_ratio = @max(0.1, ws.master_ratio - 0.05);
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .resize_grow_w => {
            const ws = server.layout_engine.getActiveWorkspace();
            ws.master_ratio = @min(0.9, ws.master_ratio + 0.05);
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        // Vertical resize aliases to master_count — in master-stack
        // that's the row count in the master zone; in accordion it's
        // the visible band size. Either way the visual effect is a
        // vertical redistribution.
        .resize_shrink_h => {
            server.layout_engine.getActiveWorkspace().adjustMasterCount(-1);
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        .resize_grow_h => {
            server.layout_engine.getActiveWorkspace().adjustMasterCount(1);
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        // Zoom at the WM level: master-ratio changes + xmonad-style
        // W.zoom (promote focused to master). Previously unimplemented
        // and falling through to the spawn-slot branch, where they
        // returned false — caught by e2e as "no visible change".
        .zoom_toggle => {
            server.layout_engine.getActiveWorkspace().swapWithMaster();
            server.arrangeworkspace(server.layout_engine.active_workspace);
            return true;
        },
        // `.zoom_in` / `.zoom_out` / `.zoom_reset` were byte-identical
        // to `.resize_grow_w` / `.resize_shrink_w` / (reset master
        // ratio). Removed as teruwm actions — they survive only as
        // teru-standalone font-zoom actions. Use resize_* in teruwm
        // configs. `.zoom_toggle` above (swap-with-master) stays — it
        // *is* a distinct compositor action.
        // Legacy alias — toggles both bars. Per-bar actions below are
        // preferred; this keeps old configs working.
        .toggle_status_bar => {
            if (server.bar) |b| {
                const new_enabled = !(b.top.enabled or b.bottom.enabled);
                b.top.enabled = new_enabled;
                b.bottom.enabled = new_enabled;
                b.updateVisibility();
                if (new_enabled) _ = b.render(server);
                for (0..server.layout_engine.workspaces.len) |ws| {
                    server.arrangeworkspace(@intCast(ws));
                }
            }
            return true;
        },
        .split_vertical, .split_horizontal => {
            // In teruwm both splits spawn a new terminal onto the
            // active workspace — the layout engine decides where it
            // lands. Teru standalone distinguishes the two (manual
            // H/V splits inside one window); the compositor's tiling
            // semantics don't need the distinction.
            server.spawnTerminal(server.layout_engine.active_workspace);
            return true;
        },
        .pane_focus_master => {
            // Route through the focus normalize point (A1) + reconcile. The
            // old Workspace.focusMaster() set only active_index=0; once A1
            // made click/cycle leave active_node non-null, that index-only
            // write was shadowed (updateFocusedTerminal reads active_node
            // first) so Mod+M targeted the stale pane. setFocus(node_ids[0])
            // sets both fields, and the updateFocusedTerminal call also fixes
            // the pre-existing no-repaint bug (focusMaster never repainted).
            const ws = server.layout_engine.getActiveWorkspace();
            if (ws.node_ids.items.len > 0) {
                ws.setFocus(ws.node_ids.items[0]);
                server.updateFocusedTerminal();
            }
            return true;
        },
        .float_toggle => {
            server.toggleFloat();
            return true;
        },
        .fullscreen_toggle => {
            server.toggleFullscreen();
            return true;
        },
        .leader_activate => {
            // Super+Space → open the Doom-style leader. The bar turns into the
            // which-key hint; subsequent keys are routed in handleKey above.
            server.leader.activate();
            server.renderLeaderHint();
            return true;
        },
        .launcher_toggle => {
            if (server.launcher.active) {
                server.launcher.deactivate();
                // bar.render() signature-skips when nothing the bar
                // cares about has changed — force it since the pixels
                // we need to overwrite are the launcher's leftovers.
                if (server.bar) |b| {
                    b.dirty = true;
                    _ = b.render(server);
                }
            } else {
                // Unified palette: leader commands (first) + $PATH apps.
                server.launcher.seedCommands(server.leader.root);
                server.launcher.activate();
                server.renderLauncherBar();
            }
            return true;
        },
        .screenshot => {
            server.takeScreenshot();
            return true;
        },
        .screenshot_area => {
            // Native drag-to-select: arm area-select mode. The next click-drag
            // draws the box and release crops it. No grim/slurp/layer-shell.
            server.beginAreaSelect();
            return true;
        },
        .screen_record => {
            // Toggle a screen recording via the standalone `kapsa` tool (spawns
            // ffmpeg / wf-recorder; not linked). Second press finalizes the file.
            // Needs `kapsa` on PATH; on Wayland, `wf-recorder` until kapsa's
            // native screencopy backend lands.
            server.spawnShell("kapsa toggle --preset product");
            return true;
        },
        .screenshot_pane => {
            if (server.focused_terminal) |tp| {
                tp.render();
                var path_buf: [256:0]u8 = undefined;
                const ts = teru.compat.monotonicNow();
                const name = if (server.nodes.findById(tp.node_id)) |s| server.nodes.getName(s) else "pane";
                const path = std.fmt.bufPrint(&path_buf, "/tmp/teruwm-pane-{s}-{d}.png", .{ name, ts }) catch return true;
                path_buf[path.len] = 0;
                // The pane name (settable via teruwm_set_name over MCP) is
                // interpolated into the path — a name containing `../` could
                // escape /tmp. Gate through the same allowlist the MCP
                // screenshot tools use before writing.
                if (!teru.compat.isSafeScreenshotPath(path)) return true;
                const png = teru.png;
                png.write(server.zig_allocator, @ptrCast(path_buf[0..path.len :0]), tp.renderer.framebuffer, tp.renderer.width, tp.renderer.height) catch return true;
                // Also copy to the Wayland clipboard, like .screenshot and
                // .screenshot_area do — the pane variant used to only write the
                // file, so "screenshot hotkey not saving to clipboard". teruwm
                // owns the seat, so this is a native data source (no wl-copy).
                const copied = wlr.miozu_set_clipboard_png_from_file(server.seat, server.display, path_buf[0..path.len :0].ptr) == 0;
                std.log.scoped(.compositor).info("pane screenshot → {s} (clipboard={})", .{ path, copied });
            }
            return true;
        },
        .keys_osd_toggle => {
            KeysOsd.toggle(server);
            return true;
        },
        .bar_toggle_top => {
            if (server.bar) |b| {
                b.top.enabled = !b.top.enabled;
                b.updateVisibility();
                if (b.top.enabled) _ = b.render(server);
                for (0..server.layout_engine.workspaces.len) |ws| {
                    server.arrangeworkspace(@intCast(ws));
                }
            }
            return true;
        },
        .bar_toggle_bottom => {
            if (server.bar) |b| {
                b.bottom.enabled = !b.bottom.enabled;
                b.updateVisibility();
                if (b.bottom.enabled) _ = b.render(server);
                for (0..server.layout_engine.workspaces.len) |ws| {
                    server.arrangeworkspace(@intCast(ws));
                }
            }
            return true;
        },
        .volume_up,
        .volume_down,
        .volume_mute,
        .brightness_up,
        .brightness_down,
        .media_play,
        .media_next,
        .media_prev,
        => {
            runMediaAction(server, action);
            return true;
        },
        .scroll_up_1,
        .scroll_up_half,
        .scroll_down_1,
        .scroll_down_half,
        .scroll_top,
        .scroll_bottom,
        => {
            if (server.focused_terminal) |tp| applyScrollAction(tp, action);
            return true;
        },
        // Native-pane clipboard. The `return false` when no terminal is
        // focused is load-bearing: it lets the chord fall through to
        // wlr_seat_keyboard_notify_key so Wayland clients keep their own
        // Ctrl+Shift+C/V (e.g. Chromium devtools / plain-paste).
        .copy_selection => {
            if (server.focused_terminal) |tp| {
                ServerClipboard.copySelection(server, tp);
                return true;
            }
            return false;
        },
        .paste_clipboard => {
            if (server.focused_terminal) |tp| {
                ServerClipboard.paste(server, tp);
                return true;
            }
            return false;
        },
        else => {
            if (tryRunScratchpadChord(server, action)) return true;
            return tryRunSpawnChord(server, action);
        },
    }
}

// ── Tests: keybind-dispatch decoding (pure, no xkb_state / no injection) ──
// These cover the logic behind the Tab/Escape/ralt dispatch fixes without a
// live compositor: foldKeysym (keysym→stored value) and buildMods (modifier
// decode), then an end-to-end keybinds.lookup so a regression in either the
// fold or the ralt-mod wiring fails the build.

test "foldKeysym: control keysyms → ASCII, letters → lowercase, digits un-shift" {
    const t = std.testing;
    try t.expectEqual(@as(u32, '\t'), foldKeysym(0xff09)); // Tab
    try t.expectEqual(@as(u32, '\t'), foldKeysym(0xfe20)); // ISO_Left_Tab (Shift+Tab) → Tab
    try t.expectEqual(@as(u32, 0x1b), foldKeysym(0xff1b)); // Escape
    try t.expectEqual(@as(u32, '\r'), foldKeysym(0xff0d)); // Return
    try t.expectEqual(@as(u32, 0x7f), foldKeysym(0xff08)); // BackSpace → DEL
    try t.expectEqual(@as(u32, 'a'), foldKeysym('A')); // Shift'd letter
    try t.expectEqual(@as(u32, '1'), foldKeysym('!')); // Shift+1
    try t.expectEqual(@as(u32, '0'), foldKeysym(')')); // Shift+0
    try t.expectEqual(@as(u32, 'q'), foldKeysym('q')); // plain ASCII passthrough
}

test "buildMods: RAlt held → {alt, ralt}; left-alt only → {alt}" {
    const t = std.testing;
    // RAlt held reports both alt (Mod1) and ralt — equals the Mods.RALT const.
    try t.expectEqual(Keybinds.Mods.RALT, buildMods(true, false, false, false, true));
    const alt_only = buildMods(true, false, false, false, false);
    try t.expect(alt_only.alt and !alt_only.ralt);
    const super_only = buildMods(false, false, false, true, false);
    try t.expect(super_only.super_ and !super_only.alt and !super_only.ralt);
}

test "dispatch: ralt+ bind requires RAlt (not left-alt); xkb Tab folds and matches" {
    const t = std.testing;
    var kb = Keybinds.Keybinds{}; // Keybinds is the file namespace; the struct is nested
    try t.expect(kb.add(.normal, Keybinds.Mods.RALT, 'h', .pane_focus_next));
    try t.expect(kb.add(.normal, Keybinds.Mods.SUPER, '\t', .pane_focus_prev));

    // RAlt held → {alt, ralt} → matches ralt+h (the fix that was dead before).
    try t.expectEqual(Keybinds.Action.pane_focus_next, kb.lookup(.normal, buildMods(true, false, false, false, true), 'h').?);
    // Left-alt only → {alt} → must NOT match ralt+h (negative control).
    try t.expect(kb.lookup(.normal, buildMods(true, false, false, false, false), 'h') == null);
    // Super + raw xkb Tab keysym (0xff09) → folds to '\t' → matches (Tab fix).
    try t.expectEqual(Keybinds.Action.pane_focus_prev, kb.lookup(.normal, buildMods(false, false, false, true, false), foldKeysym(0xff09)).?);
}
