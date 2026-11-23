//! Multiplexer key command handling.
//!
//! Contains the prefix-key state machine and mux command dispatch.
//! Extracted from main.zig for modularity — the event loop calls
//! into these helpers rather than inlining the logic.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const Multiplexer = @import("Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Hooks = @import("../config/Hooks.zig");
const compat = @import("../compat.zig");
const keysyms = @import("../input/keysyms.zig");

// ── Prefix key state ─────────────────────────────────────────────

pub const PrefixState = struct {
    awaiting: bool = false,
    timestamp_ns: i128 = 0,
    timeout_ns: i128 = 500_000_000, // configurable via prefix_timeout_ms

    pub fn activate(self: *PrefixState) void {
        self.awaiting = true;
        self.timestamp_ns = compat.nanoTimestamp();
    }

    pub fn isExpired(self: *const PrefixState) bool {
        if (!self.awaiting) return false;
        const elapsed = compat.nanoTimestamp() - self.timestamp_ns;
        return elapsed > self.timeout_ns;
    }

    pub fn reset(self: *PrefixState) void {
        self.awaiting = false;
    }
};

// ── Mux command result ──────────────────────────────────────────

/// Action returned by handleMuxCommand for the caller to act on.
pub const MuxAction = enum {
    none,
    enter_search,
    enter_vi_mode,
    panes_changed,
    split_horizontal,
    split_vertical,
    close_pane,
    zoom_in,
    zoom_out,
    zoom_reset,
    detach,
    toggle_zoom,
    copy_selection,
    paste_clipboard,
    toggle_status_bar,
};

// ── Mux command dispatch ─────────────────────────────────────────

fn writeMsg(msg: []const u8) void {
    if (builtin.os.tag == .windows) return;
    _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
}

/// Handle a multiplexer command after the prefix key (Ctrl+Space).
/// Returns an action the caller should handle (e.g., entering search mode).
pub fn handleMuxCommand(
    cmd: u8,
    mux: *Multiplexer,
    graph: *ProcessGraph,
    hooks: *const Hooks,
    running: *bool,
    grid_rows: u16,
    grid_cols: u16,
    io: Io,
    prefix_byte: u8,
) MuxAction {
    _ = grid_rows;
    _ = grid_cols;
    // Normalize Ctrl+letter (0x01-0x1A) to plain letter.
    // If user holds Ctrl while pressing the command key (e.g., Ctrl still
    // held after prefix), xkbcommon sends Ctrl+V (0x16) instead of 'v'.
    const key = if (cmd >= 1 and cmd <= 26) cmd + 0x60 else cmd;
    switch (key) {
        'c', '\\' => return .split_vertical,
        '-' => return .split_horizontal,
        'x' => {
            // Close active pane
            if (mux.getActivePane()) |pane| {
                const id = pane.id;
                mux.closePane(id);
                hooks.fire(.close);
                if (mux.panes.items.len == 0) {
                    running.* = false;
                    return .none;
                }
            }
            return .panes_changed;
        },
        'n' => mux.focusNext(),
        'p' => mux.focusPrev(),
        ' ' => {
            mux.cycleLayout();
            return .panes_changed;
        },
        'd' => {
            if (builtin.os.tag == .windows) {
                // There is nowhere to save the session to and nothing that
                // could restore it; quitting here would just kill the panes.
                mux.notify("detach is not supported on Windows yet");
                return .none;
            }
            // Detach: save session and exit. Path is under
            // $XDG_RUNTIME_DIR (private, cleaned on logout) — see
            // common.sessionPath.
            var path_buf: [256:0]u8 = undefined;
            const dir = compat.runtimeDir();
            const path = std.fmt.bufPrint(&path_buf, "{s}/teru-session.bin", .{dir}) catch {
                writeMsg("[teru] Session path too long, exiting anyway\n");
                running.* = false;
                return .none;
            };
            const pane_n = mux.panes.items.len;
            mux.saveSession(graph, path, io) catch {
                writeMsg("[teru] Session save failed, exiting anyway\n");
                running.* = false;
                return .none;
            };
            hooks.fire(.session_save);
            var dbuf: [256]u8 = undefined;
            const dmsg = std.fmt.bufPrint(&dbuf, "[teru] Session saved to {s} ({d} panes)\n[teru] Note: processes are not preserved. Use --attach to restore layout.\n", .{ path, pane_n }) catch "[teru] Session saved\n";
            writeMsg(dmsg);
            running.* = false;
        },
        '/' => {
            // Enter search mode (caller handles the UI)
            return .enter_search;
        },
        '1'...'9' => {
            // Switch workspace: key 1-9 → index 0-8
            mux.switchWorkspace(cmd - '1');
        },
        '0' => {
            // Switch workspace: key 0 → index 9 (10th workspace)
            mux.switchWorkspace(9);
        },
        'v' => return .enter_vi_mode,
        'z' => {
            mux.toggleZoom();
            return .panes_changed;
        },
        'H' => {
            mux.resizeActive(-2, 0);
            return .panes_changed;
        },
        'L' => {
            mux.resizeActive(2, 0);
            return .panes_changed;
        },
        'K' => {
            mux.resizeActive(0, -2);
            return .panes_changed;
        },
        'J' => {
            mux.resizeActive(0, 2);
            return .panes_changed;
        },
        else => {
            // Unknown command; forward the prefix + key to active pane
            if (mux.getActivePane()) |pane| {
                const pfx = [1]u8{prefix_byte};
                _ = pane.ptyWrite(&pfx) catch {};
                const byte = [1]u8{cmd};
                _ = pane.ptyWrite(&byte) catch {};
            }
        },
    }
    return .none;
}

// ── Config-driven key handling ──────────────────────────────

const KB = @import("../config/Keybinds.zig");
const kc = @import("../platform/types.zig").keycodes;

/// Convert platform modifier flags + RAlt state to Keybinds.Mods.
pub fn platformMods(modifiers: u32, ralt: bool) KB.Mods {
    var m = KB.Mods{};
    if (modifiers & kc.ALT_MASK != 0) m.alt = true;
    if (ralt) m.ralt = true;
    if (modifiers & kc.CTRL_MASK != 0) m.ctrl = true;
    if (modifiers & kc.SHIFT_MASK != 0) m.shift = true;
    // Command, so super+... bindings work in standalone teru on macOS.
    // Other systems keep ignoring Super here, as they always have.
    if (builtin.os.tag == .macos and modifiers & kc.SUPER_MASK != 0) m.super_ = true;
    return m;
}

/// Look up an action from the config-driven keybind table.
/// Returns the Action or null if the key should pass through.
pub fn lookupConfigAction(
    keybinds: *const KB.Keybinds,
    mode: KB.Mode,
    modifiers: u32,
    key_char: u8,
    ralt: bool,
) ?KB.Action {
    const mods = platformMods(modifiers, ralt);
    return keybinds.lookup(mode, mods, key_char);
}

/// Ctrl+\ (FS, 0x1C) in a window attached to a daemon session detaches it,
/// the same key the TUI client treats as detach (TuiInput.feed). A window
/// with no daemon has nothing to detach from, so the byte goes to the program
/// and the tty turns it into SIGQUIT as in any other terminal. Alt+Ctrl+\ is
/// not detach: the TUI client reads it as ESC+FS and forwards it.
/// `nested` is true while the focused pane shows a nested teru client (it
/// announced itself with OSC 9998;1 and is on the alternate screen): the
/// byte then goes to that client, so the innermost session detaches, as it
/// did before the outer window took the key.
pub fn isDetachKey(key_bytes: []const u8, modifiers: u32, attached: bool, nested: bool) bool {
    return attached and !nested and modifiers & kc.ALT_MASK == 0 and
        key_bytes.len == 1 and key_bytes[0] == 0x1c;
}

/// The leader / which-key chord in the windowed terminal: Alt+Space with no
/// other modifier. Shift, Ctrl and RAlt variants are separate bindings
/// (Alt+Shift+Space is layout_reset), so they must not open the leader.
pub fn isLeaderChord(modifiers: u32, ralt: bool, key_char: u8) bool {
    return key_char == ' ' and platformMods(modifiers, ralt).eql(KB.Mods.ALT);
}

pub const ScrollPage = enum { none, up, down };

/// Shift+PageUp / Shift+PageDown page through the scrollback. Plain
/// PageUp/PageDown, and any other modifier set, go to the program (less, vim
/// and htop use them). On the alternate screen there is no teru scrollback to
/// show, as with the mouse wheel, so Shift+PageUp/PageDown go to the program
/// there too. Mouse tracking does not change keyboard routing.
pub fn scrollbackPageKey(keysym: u32, modifiers: u32, ralt: bool, alt_screen: bool) ScrollPage {
    if (alt_screen) return .none;
    if (!platformMods(modifiers, ralt).eql(KB.Mods.SHIFT)) return .none;
    return switch (keysym) {
        keysyms.Page_Up => .up,
        keysyms.Page_Down => .down,
        else => .none,
    };
}

/// Execute a keybind Action's mux side effects (focus, swap, resize, etc).
/// Returns a MuxAction for things main.zig must handle (split, zoom, mode change).
pub fn executeAction(action: KB.Action, mux: *Multiplexer) MuxAction {
    return switch (action) {
        .pane_focus_next => { mux.focusNext(); return .panes_changed; },
        .pane_focus_prev => { mux.focusPrev(); return .panes_changed; },
        .pane_focus_master => { mux.focusMaster(); return .panes_changed; },
        .pane_set_master => { mux.setMaster(); return .panes_changed; },
        .pane_swap_next => { mux.swapPaneNext(); return .panes_changed; },
        .pane_swap_prev => { mux.swapPanePrev(); return .panes_changed; },
        // These three were bound by default (loadDefaults) but fell through the
        // `else => .none` below — dead keybinds in the multiplexer even though
        // the Multiplexer methods existed. Wire them up.
        .pane_swap_master => { mux.swapMaster(); return .panes_changed; },
        .pane_rotate_slaves_up => { mux.rotateSlaves(true); return .panes_changed; },
        .pane_rotate_slaves_down => { mux.rotateSlaves(false); return .panes_changed; },
        .layout_reset => { mux.resetLayout(); return .panes_changed; },
        .pane_close => .close_pane,
        .split_vertical => .split_vertical,
        .split_horizontal => .split_horizontal,
        .layout_cycle => { mux.cycleLayout(); return .panes_changed; },
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
        .zoom_reset => .zoom_reset,
        .zoom_toggle => { mux.toggleZoom(); return .toggle_zoom; },
        .resize_shrink_w => { mux.resizeActive(-2, 0); return .panes_changed; },
        .resize_grow_w => { mux.resizeActive(2, 0); return .panes_changed; },
        .resize_shrink_h => { mux.resizeActive(0, -2); return .panes_changed; },
        .resize_grow_h => { mux.resizeActive(0, 2); return .panes_changed; },
        .mode_normal => .none, // caller checks action directly for mode transitions
        .mode_prefix => .none,
        .mode_scroll => .enter_vi_mode,
        .mode_search => .enter_search,
        .session_detach => .detach,
        .toggle_status_bar => .toggle_status_bar,
        .copy_selection => .copy_selection,
        .paste_clipboard => .paste_clipboard,
        .workspace_1, .workspace_2, .workspace_3,
        .workspace_4, .workspace_5, .workspace_6,
        .workspace_7, .workspace_8, .workspace_9,
        .workspace_0 => {
            if (action.workspaceIndex()) |ws| mux.switchWorkspace(ws);
            return .panes_changed;
        },
        .workspace_toggle_last => if (mux.toggleLastWorkspace()) .panes_changed else .none,
        .pane_move_to_1, .pane_move_to_2, .pane_move_to_3,
        .pane_move_to_4, .pane_move_to_5, .pane_move_to_6,
        .pane_move_to_7, .pane_move_to_8, .pane_move_to_9,
        .pane_move_to_0 => {
            if (action.moveToIndex()) |ws| _ = mux.movePaneToWorkspace(ws);
            return .panes_changed;
        },
        else => .none,
    };
}

// ── Legacy global shortcuts (fallback when keybinds not loaded) ──

/// Handle global Alt+key shortcuts (no prefix required).
/// Digits use platform keycodes (layout-independent for number row).
/// Letters use keysyms so they match the active layout (QWERTY/Dvorak/etc).
///
/// ── Alt (navigate / act) ────────────────────────────────────
///   Alt+j / Alt+k   — focus next / prev pane
///   Alt+1-9         — switch workspace
///   Alt+c           — new pane (vertical split)
///   Alt+x           — close active pane
///   Alt+z           — toggle pane zoom (maximize)
///   Alt+Space       — cycle layout
///   Alt+/           — search
///   Alt+v           — vi mode (scrollback navigation)
///   Alt+d           — detach session
///   Alt+m           — focus master pane
///   Alt+b           — toggle status bar
///   Alt+Enter       — new pane (vertical split)
///   Alt+=           — zoom in (increase font size)
///   Alt+-           — zoom out (decrease font size)
///   Alt+\           — zoom reset (restore config font size)
///   Alt+0           — workspace 10
///
/// ── RAlt (modify / move) ────────────────────────────────────
///   RAlt+j / RAlt+k — swap pane next / prev
///   RAlt+h / RAlt+l — resize pane width (-2 / +2)
///   RAlt+c          — new pane (horizontal split)
///   RAlt+1-9        — move active pane to workspace
///   RAlt+Enter      — new pane (horizontal split)
///   RAlt+m          — mark active pane as master
///
/// Returns null if the key should pass through to the PTY.
pub fn handleGlobalKey(keycode: u32, modifiers: u32, key_char: u8, alt_enabled: bool, ralt: bool, mux: *Multiplexer) ?MuxAction {
    if (!alt_enabled or modifiers & kc.ALT_MASK == 0) return null;

    // Alt+1-9: switch workspace / RAlt+1-9: move pane to workspace
    if (kc.digitToWorkspace(keycode)) |target_ws| {
        if (ralt) _ = mux.movePaneToWorkspace(target_ws) else mux.switchWorkspace(target_ws);
        return .panes_changed;
    }

    // Letter/symbol shortcuts use keysym (matches active layout: Dvorak, QWERTY, etc)
    return switch (key_char) {
        'j' => { if (ralt) mux.swapPaneNext() else mux.focusNext(); return .panes_changed; },
        'k' => { if (ralt) mux.swapPanePrev() else mux.focusPrev(); return .panes_changed; },
        'h' => { if (ralt) { mux.resizeActive(-2, 0); return .panes_changed; } return null; },
        'l' => { if (ralt) { mux.resizeActive(2, 0); return .panes_changed; } return null; },
        'c' => if (ralt) .split_horizontal else .split_vertical,
        'x' => .close_pane,
        'z' => { mux.toggleZoom(); return .toggle_zoom; },
        ' ' => { mux.cycleLayout(); return .panes_changed; },
        '/' => .enter_search,
        'v' => .enter_vi_mode,
        'd' => .detach,
        'm' => { if (ralt) mux.setMaster() else mux.focusMaster(); return .panes_changed; },
        'b' => .toggle_status_bar,
        '\\' => .zoom_reset,
        '\r' => if (ralt) .split_horizontal else .split_vertical,
        '-' => .zoom_out,
        '=' => .zoom_in,
        else => null,
    };
}

// ── Tests ────────────────────────────────────────────────────────

test "PrefixState init is inactive" {
    const ps = PrefixState{};
    try std.testing.expect(!ps.awaiting);
    try std.testing.expect(!ps.isExpired());
}

test "PrefixState activate and reset" {
    var ps = PrefixState{};
    ps.activate();
    try std.testing.expect(ps.awaiting);
    try std.testing.expect(!ps.isExpired()); // just activated, not expired
    ps.reset();
    try std.testing.expect(!ps.awaiting);
}

test "handleGlobalKey returns null when disabled or no Alt" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(10, kc.ALT_MASK, 'j', false, false, &mux) == null);
    try std.testing.expect(handleGlobalKey(10, 0, 'j', true, false, &mux) == null);
    try std.testing.expect(handleGlobalKey(99, kc.ALT_MASK, 'q', true, false, &mux) == null);
}

test "handleGlobalKey Alt+digit switches workspace" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    const digit3_kc: u32 = comptime blk: {
        var k: u32 = 0;
        while (k < 256) : (k += 1) {
            if (kc.digitToWorkspace(k)) |ws| {
                if (ws == 2) break :blk k;
            }
        }
        unreachable;
    };
    const action = handleGlobalKey(digit3_kc, kc.ALT_MASK, '3', true, false, &mux);
    try std.testing.expect(action != null);
    try std.testing.expect(action.? == .panes_changed);
    try std.testing.expectEqual(@as(u8, 2), mux.active_workspace);
}

test "handleGlobalKey Alt+j/k focuses panes" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'j', true, false, &mux).? == .panes_changed);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'k', true, false, &mux).? == .panes_changed);
}

test "handleGlobalKey Alt+-/= zooms" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, '-', true, false, &mux).? == .zoom_out);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, '=', true, false, &mux).? == .zoom_in);
}

test "handleGlobalKey Alt+c splits" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'c', true, false, &mux).? == .split_vertical);
}

test "handleGlobalKey Alt+z/Space/d/v actions" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'z', true, false, &mux).? == .toggle_zoom);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, ' ', true, false, &mux).? == .panes_changed);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, '/', true, false, &mux).? == .enter_search);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'v', true, false, &mux).? == .enter_vi_mode);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'd', true, false, &mux).? == .detach);
    // Alt+0 is now workspace 10 (tested via digitToWorkspace with real keycode)
}

test "handleGlobalKey RAlt+j/k swaps panes" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'j', true, true, &mux).? == .panes_changed);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'k', true, true, &mux).? == .panes_changed);
}

test "handleGlobalKey RAlt+m marks master, Alt+m focuses" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'm', true, true, &mux).? == .panes_changed);
    try std.testing.expect(handleGlobalKey(0, kc.ALT_MASK, 'm', true, false, &mux).? == .panes_changed);
}

test "isDetachKey: Ctrl+\\ detaches only when attached to a daemon" {
    // Attached window: FS (Ctrl+\) detaches.
    try std.testing.expect(isDetachKey("\x1c", kc.CTRL_MASK, true, false));
    // No daemon: FS goes to the program (SIGQUIT), never swallowed.
    try std.testing.expect(!isDetachKey("\x1c", kc.CTRL_MASK, false, false));
    // A nested teru in the focused pane gets FS, so the inner client detaches.
    try std.testing.expect(!isDetachKey("\x1c", kc.CTRL_MASK, true, true));
    try std.testing.expect(!isDetachKey("\x1c", kc.CTRL_MASK, false, true));
    // Alt+Ctrl+\ is forwarded, as in the TUI client.
    try std.testing.expect(!isDetachKey("\x1c", kc.CTRL_MASK | kc.ALT_MASK, true, false));
    // Other keys, and FS inside a longer sequence, are not detach.
    try std.testing.expect(!isDetachKey("\\", 0, true, false));
    try std.testing.expect(!isDetachKey("\x1b\x1c", kc.CTRL_MASK, true, false));
    try std.testing.expect(!isDetachKey("", kc.CTRL_MASK, true, false));
}

test "isLeaderChord: exactly Alt+Space" {
    try std.testing.expect(isLeaderChord(kc.ALT_MASK, false, ' '));
    // Alt+Shift+Space is layout_reset, not the leader.
    try std.testing.expect(!isLeaderChord(kc.ALT_MASK | kc.SHIFT_MASK, false, ' '));
    try std.testing.expect(!isLeaderChord(kc.ALT_MASK | kc.CTRL_MASK, false, ' '));
    try std.testing.expect(!isLeaderChord(kc.ALT_MASK, true, ' ')); // RAlt
    try std.testing.expect(!isLeaderChord(0, false, ' '));
    try std.testing.expect(!isLeaderChord(kc.ALT_MASK, false, 'a'));
}

test "Alt+Shift+Space reaches layout_reset in the default keybinds" {
    var kb = KB.Keybinds{ .mod_key = KB.Mods.ALT };
    kb.loadDefaults();
    const mods = platformMods(kc.ALT_MASK | kc.SHIFT_MASK, false);
    try std.testing.expectEqual(KB.Action.layout_reset, kb.lookup(.normal, mods, ' ').?);
}

test "Alt+Tab, Alt+Shift+Tab and Alt+Escape reach the default keybinds" {
    const ks = keysyms;
    var kb = KB.Keybinds{ .mod_key = KB.Mods.ALT };
    kb.loadDefaults();
    const alt = platformMods(kc.ALT_MASK, false);
    const alt_shift = platformMods(kc.ALT_MASK | kc.SHIFT_MASK, false);
    try std.testing.expectEqual(KB.Action.pane_focus_next, kb.lookup(.normal, alt, ks.bindChar(ks.Tab)).?);
    // xkb reports Shift+Tab as ISO_Left_Tab.
    try std.testing.expectEqual(KB.Action.pane_focus_prev, kb.lookup(.normal, alt_shift, ks.bindChar(ks.ISO_Left_Tab)).?);
    try std.testing.expectEqual(KB.Action.workspace_toggle_last, kb.lookup(.normal, alt, ks.bindChar(ks.Escape)).?);
    // Unmodified Tab and Escape match nothing, so they still go to the program.
    try std.testing.expect(kb.lookup(.normal, platformMods(0, false), ks.bindChar(ks.Tab)) == null);
    try std.testing.expect(kb.lookup(.normal, platformMods(0, false), ks.bindChar(ks.Escape)) == null);
    try std.testing.expect(kb.lookup(.normal, platformMods(kc.SHIFT_MASK, false), ks.bindChar(ks.ISO_Left_Tab)) == null);
    // Esc after the prefix leaves prefix mode instead of being sent on.
    try std.testing.expectEqual(KB.Action.mode_normal, kb.lookup(.prefix, platformMods(0, false), ks.bindChar(ks.Escape)).?);
}

test "executeAction workspace_toggle_last returns to the previous workspace" {
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expect(executeAction(.workspace_toggle_last, &mux) == .none);
    mux.switchWorkspace(4);
    try std.testing.expect(executeAction(.workspace_toggle_last, &mux) == .panes_changed);
    try std.testing.expectEqual(@as(u8, 0), mux.active_workspace);
}

test "scrollbackPageKey: Shift+PageUp/Down scroll, plain PageUp/Down go to the program" {
    const ks = keysyms;
    const S = kc.SHIFT_MASK;
    try std.testing.expectEqual(ScrollPage.up, scrollbackPageKey(ks.Page_Up, S, false, false));
    try std.testing.expectEqual(ScrollPage.down, scrollbackPageKey(ks.Page_Down, S, false, false));
    // Plain keys belong to the program.
    try std.testing.expectEqual(ScrollPage.none, scrollbackPageKey(ks.Page_Up, 0, false, false));
    try std.testing.expectEqual(ScrollPage.none, scrollbackPageKey(ks.Page_Down, 0, false, false));
    // Other modifier sets are not the scrollback chord.
    try std.testing.expectEqual(ScrollPage.none, scrollbackPageKey(ks.Page_Up, S | kc.CTRL_MASK, false, false));
    try std.testing.expectEqual(ScrollPage.none, scrollbackPageKey(ks.Page_Up, S | kc.ALT_MASK, false, false));
    // Alternate screen (less, vim, htop): no scrollback, the program gets it.
    try std.testing.expectEqual(ScrollPage.none, scrollbackPageKey(ks.Page_Up, S, false, true));
    try std.testing.expectEqual(ScrollPage.none, scrollbackPageKey(ks.Page_Down, S, false, true));
    // Other keys never scroll.
    try std.testing.expectEqual(ScrollPage.none, scrollbackPageKey(ks.Up, S, false, false));
}

test "teru --help keybindings match the default table" {
    // Every chord `teru --help` lists, as the windowed terminal looks it up
    // (KeyHandler.lookupConfigAction on the defaults). Keep main.zig's list
    // and this test in step.
    var kb: KB.Keybinds = .{};
    kb.loadDefaults();
    kb.loadTerminalZoomDefaults();
    const A = kc.ALT_MASK;
    const S = kc.SHIFT_MASK;
    const Case = struct { mode: KB.Mode, mods: u32, key: u8, want: KB.Action };
    const cases = [_]Case{
        .{ .mode = .normal, .mods = A, .key = 'c', .want = .split_vertical },
        .{ .mode = .prefix, .mods = 0, .key = 'x', .want = .pane_close },
        .{ .mode = .normal, .mods = A, .key = 'j', .want = .pane_focus_next },
        .{ .mode = .normal, .mods = A, .key = 'k', .want = .pane_focus_prev },
        .{ .mode = .normal, .mods = A | S, .key = 'J', .want = .pane_swap_next },
        .{ .mode = .normal, .mods = A | S, .key = 'K', .want = .pane_swap_prev },
        .{ .mode = .normal, .mods = A, .key = 'h', .want = .resize_shrink_w },
        .{ .mode = .normal, .mods = A, .key = 'l', .want = .resize_grow_w },
        .{ .mode = .normal, .mods = A, .key = 'z', .want = .zoom_toggle },
        .{ .mode = .normal, .mods = A, .key = '1', .want = .workspace_1 },
        .{ .mode = .normal, .mods = A, .key = '0', .want = .workspace_0 },
        .{ .mode = .normal, .mods = A | S, .key = '!', .want = .pane_move_to_1 },
        .{ .mode = .prefix, .mods = 0, .key = ' ', .want = .layout_cycle },
        .{ .mode = .normal, .mods = A, .key = 'v', .want = .mode_scroll },
        .{ .mode = .normal, .mods = A, .key = '-', .want = .zoom_out },
        .{ .mode = .normal, .mods = A, .key = '\\', .want = .zoom_reset },
        .{ .mode = .normal, .mods = kc.CTRL_MASK, .key = ' ', .want = .mode_prefix },
        .{ .mode = .prefix, .mods = 0, .key = 'd', .want = .session_detach },
    };
    for (cases) |c| {
        const got = lookupConfigAction(&kb, c.mode, c.mods, c.key, false) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(c.want, got);
    }
    var mux = Multiplexer.init(std.testing.allocator);
    defer mux.deinit();
    try std.testing.expectEqual(MuxAction.detach, executeAction(.session_detach, &mux));
    // Alt+Space opens the leader; Ctrl+\ detaches an attached window.
    try std.testing.expect(isLeaderChord(A, false, ' '));
    try std.testing.expect(isDetachKey("\x1c", kc.CTRL_MASK, true, false));
    // Alt+D is the launcher in the shared table, which teru does not have:
    // it is not detach, so --help must not say so.
    try std.testing.expect(lookupConfigAction(&kb, .normal, A, 'd', false).? != .session_detach);
}
