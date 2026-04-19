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
        // Turn on the laptop-touchpad defaults (tap-to-click + natural
        // scroll + disable-while-typing). libinput ships with every
        // useful option OFF; without this the touchpad feels broken
        // even when clicks-via-physical-button still work.
        wlr.miozu_configure_libinput_pointer(device);
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
                const shift = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;

                if (ctrl and shift and (sym == 'C' or sym == 'c')) {
                    kb.server.clipboardCopyCursorLine(tp);
                    return;
                }

                if (ctrl and shift and (sym == 'V' or sym == 'v')) {
                    kb.server.clipboardPaste(tp);
                    return;
                }

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
                        tp.writeInput(buf[0..@intCast(len)]);
                        repeat_bytes = buf[0..@intCast(len)];
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

/// Read the effective XKB layout CODE ("us", "ua", "us(dvorak)") from
/// the given keyboard and stash a copy in `active_keymap_name`.
pub fn refreshActiveKeymap(server: *Server, keyboard: *wlr.wlr_keyboard) void {
    const st = wlr.miozu_keyboard_xkb_state(keyboard) orelse return;
    const keymap = wlr.xkb_state_get_keymap(st) orelse return;
    const layout_idx = wlr.xkb_state_serialize_layout(st, wlr.XKB_STATE_LAYOUT_EFFECTIVE);

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

    if (server.bar) |b| b.render(server);
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
    const hdr_pos = std.mem.indexOf(u8, raw, hdr) orelse return "";
    const q1 = std.mem.indexOfScalarPos(u8, raw, hdr_pos + hdr.len, '"') orelse return "";
    const q2 = std.mem.indexOfScalarPos(u8, raw, q1 + 1, '"') orelse return "";
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
            std.debug.print("teruwm: [keyboard] config invalid, falling back to env/defaults\n", .{});
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

    std.debug.print("teruwm: keyboard configured\n", .{});
}

// ── Keybind dispatch ──────────────────────────────────────────

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

    // Normalize: uppercase ASCII → lowercase (Shift'd 'J' → 'j'),
    // Shift+number-row → base digit (!→1, @→2, …) so keybinds defined
    // against '1' still match when Shift is held — without this,
    // Mod+Shift+1..0 (move-pane-to-workspace) silently missed because
    // xkb delivers the shifted symbol, not the unmodified digit.
    // ASCII passes through, common xkb specials → ASCII equivalents,
    // everything else stays as the raw keysym (XF86/media keys).
    const key: u32 = if (sym >= 'A' and sym <= 'Z') sym + 32 else switch (sym) {
        '!' => '1', '@' => '2', '#' => '3', '$' => '4', '%' => '5',
        '^' => '6', '&' => '7', '*' => '8', '(' => '9', ')' => '0',
        0xff0d => '\r',
        0xff1b => 0x1b,
        0xff09 => '\t',
        0xff08 => 0x7f,
        else => if (sym >= 0x20 and sym <= 0x7e) sym else sym,
    };

    var mods = KBMods{};
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_ALT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.alt = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.shift = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_CTRL, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.ctrl = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.super_ = true;

    // Launcher mode swallows every key until deactivated.
    if (server.launcher.active) {
        if (server.launcher.handleKey(sym, server)) {
            server.renderLauncherBar();
            return true;
        }
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
    tp.pane.grid.dirty = true;
    tp.render();
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
    if (len > 0) server.toggleScratchpadByName(server.scratchpad_table[slot][0..len], null);
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
            std.debug.print("teruwm: compositor_quit (Mod+Shift+Q or MCP)\n", .{});
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
            if (server.bar) |b| b.render(server);
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
            if (server.bar) |b| b.render(server);
            return true;
        },
        .session_save => {
            Session.save(server, "default") catch |err| {
                std.debug.print("teruwm: session save failed: {}\n", .{err});
            };
            return true;
        },
        .session_restore => {
            Session.restore(server, "default") catch |err| {
                std.debug.print("teruwm: session restore failed: {}\n", .{err});
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
                if (new_enabled) b.render(server);
                for (0..server.layout_engine.workspaces.len) |ws| {
                    server.arrangeworkspace(@intCast(ws));
                }
            }
            return true;
        },
        .split_vertical => {
            server.spawnTerminal(server.layout_engine.active_workspace);
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
        .launcher_toggle => {
            if (server.launcher.active) {
                server.launcher.deactivate();
                // bar.render() signature-skips when nothing the bar
                // cares about has changed — force it since the pixels
                // we need to overwrite are the launcher's leftovers.
                if (server.bar) |b| {
                    b.dirty = true;
                    b.render(server);
                }
            } else {
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
            server.spawnShell(
                "mkdir -p \"$HOME/Pictures\" && grim -g \"$(slurp)\" \"$HOME/Pictures/teruwm-area-$(date +%s).png\"",
            );
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
                const png = teru.png;
                png.write(server.zig_allocator, @ptrCast(path_buf[0..path.len :0]), tp.renderer.framebuffer, tp.renderer.width, tp.renderer.height) catch return true;
                std.debug.print("teruwm: pane screenshot → {s}\n", .{path});
            }
            return true;
        },
        .bar_toggle_top => {
            if (server.bar) |b| {
                b.top.enabled = !b.top.enabled;
                b.updateVisibility();
                if (b.top.enabled) b.render(server);
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
                if (b.bottom.enabled) b.render(server);
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
        else => {
            if (tryRunScratchpadChord(server, action)) return true;
            return tryRunSpawnChord(server, action);
        },
    }
}
