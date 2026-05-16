//! Key-repeat machinery for teruwm — compositor keybind repeat (hold
//! Mod+L to keep resizing) and terminal-input repeat (hold a key in a
//! focused native pane). Two wl_event_loop timers, armed on press and
//! disarmed on release. Server.zig keeps thin delegators; the live
//! timer sources are torn down in Server.deinit.

const std = @import("std");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const teru = @import("teru");
const KBAction = teru.Keybinds.Action;

/// True if holding the keybind should keep firing the action. Excludes
/// toggles / one-shots — repeating those either does nothing or (worse)
/// bounces state back and forth (float_toggle, launcher_toggle). The
/// whitelist is what an xmonad/sway user holds to tune the layout:
/// resize, focus/swap cycle, master-count, zoom, workspace step.
fn isRepeatableAction(action: KBAction) bool {
    return switch (action) {
        .resize_shrink_w, .resize_grow_w, .resize_shrink_h, .resize_grow_h,
        .pane_focus_next, .pane_focus_prev,
        .pane_swap_next, .pane_swap_prev,
        .pane_rotate_slaves_up, .pane_rotate_slaves_down,
        .master_count_inc, .master_count_dec,
        .workspace_next_nonempty, .workspace_toggle_last,
        => true,
        else => false,
    };
}

/// Timer callback that re-dispatches the armed keybind action. Returns
/// 0 from wayland-server's callback ABI; the timer stays armed with
/// whatever `update(ms)` set last.
fn keybindRepeatTick(data: ?*anyopaque) callconv(.c) c_int {
    const server: *Server = @ptrCast(@alignCast(data orelse return 0));
    const action = server.keybind_repeat_action orelse return 0;
    // Dispatch through the same path a fresh press would. executeAction
    // is in ServerInput; we go through a Server method to keep the
    // cross-module boundary clean.
    _ = server.executeAction(action);
    if (server.keybind_repeat_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, server.keybind_repeat_rate_ms);
    }
    return 0;
}

/// Arm the repeat timer for an action attached to `keycode`. Cancels
/// any prior repeat first — pressing a new keybind while holding the
/// old one replaces the target.
pub fn armKeybindRepeat(server: *Server, action: KBAction, keycode: u32) void {
    if (!isRepeatableAction(action)) {
        cancelKeybindRepeat(server);
        return;
    }
    if (server.keybind_repeat_src == null) {
        const loop = server.event_loop orelse return;
        server.keybind_repeat_src = wlr.wl_event_loop_add_timer(loop, keybindRepeatTick, @ptrCast(server));
        if (server.keybind_repeat_src == null) return;
    }
    server.keybind_repeat_keycode = keycode;
    server.keybind_repeat_action = action;
    if (server.keybind_repeat_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, server.keybind_repeat_delay_ms);
    }
}

/// Disarm the repeat timer. Called on key release (matching keycode),
/// modifier-state change, or different key press.
pub fn cancelKeybindRepeat(server: *Server) void {
    if (server.keybind_repeat_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, 0);
    }
    server.keybind_repeat_keycode = 0;
    server.keybind_repeat_action = null;
}

/// Re-send the stored terminal input bytes to the currently focused
/// pane. Rearms itself for the next tick unless canceled.
fn terminalRepeatTick(data: ?*anyopaque) callconv(.c) c_int {
    const server: *Server = @ptrCast(@alignCast(data orelse return 0));
    if (server.terminal_repeat_len == 0) return 0;
    if (server.focused_terminal) |tp| {
        tp.writeInput(server.terminal_repeat_bytes[0..server.terminal_repeat_len]);
    }
    if (server.terminal_repeat_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, server.keybind_repeat_rate_ms);
    }
    return 0;
}

/// Arm the terminal-input repeat timer. Called from the key press path
/// in ServerInput.handleKeyEvent after bytes are written to the focused
/// terminal. Cancels any prior repeat first — typing a new character
/// while holding an old one replaces the target, same semantics as
/// libinput/xkb repeat for Wayland clients.
pub fn armTerminalRepeat(server: *Server, keycode: u32, bytes: []const u8) void {
    if (bytes.len == 0 or bytes.len > server.terminal_repeat_bytes.len) {
        cancelTerminalRepeat(server);
        return;
    }
    if (server.terminal_repeat_src == null) {
        const loop = server.event_loop orelse return;
        server.terminal_repeat_src = wlr.wl_event_loop_add_timer(loop, terminalRepeatTick, @ptrCast(server));
        if (server.terminal_repeat_src == null) return;
    }
    @memcpy(server.terminal_repeat_bytes[0..bytes.len], bytes);
    server.terminal_repeat_len = @intCast(bytes.len);
    server.terminal_repeat_keycode = keycode;
    if (server.terminal_repeat_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, server.keybind_repeat_delay_ms);
    }
}

pub fn cancelTerminalRepeat(server: *Server) void {
    if (server.terminal_repeat_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, 0);
    }
    server.terminal_repeat_len = 0;
    server.terminal_repeat_keycode = 0;
}
