//! Stateless wlroots signal handlers for teruwm.
//!
//! Every `wl_listener` embedded on Server whose handler doesn't
//! belong to the cursor/click path (ServerCursor) or the input-
//! device setup path (ServerInput) lands here. These are thin:
//! each resolves *Server via @fieldParentPtr on the listener's
//! position on Server, then forwards to the real work (node
//! registration, manager state push, etc.).
//!
//! Keeping them in one module means Server.zig's field block +
//! registerListeners block stay readable; the 15 forwarders no
//! longer clutter the file.

const std = @import("std");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const XdgView = @import("XdgView.zig");
const XwaylandView = @import("XwaylandView.zig");

// ── Helper (duplicated from Server.zig so both call sites of
//     makeListener can resolve a fn pointer in either module) ──

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{
        .link = .{ .prev = null, .next = null },
        .notify = func,
    };
}

// ── Output attach ────────────────────────────────────────────

pub fn handleNewOutput(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_output", listener);
    const wlr_output: *wlr.wlr_output = @ptrCast(@alignCast(data orelse return));

    _ = Output.create(server, wlr_output, server.zig_allocator) catch {
        std.debug.print("teruwm: failed to create output\n", .{});
        return;
    };
    const first = (server.primary_output == null);
    if (first) server.primary_output = wlr_output;

    if (first and !server.autostart_fired) {
        server.autostart_fired = true;
        runAutostart(server);
    }

    // Announce the new head to wlr-output-management listeners so
    // config tools (kanshi, waybar's output module) resync.
    server.pushOutputManagerState();
}

/// Spawn each command from `wm_config.autostart` via /bin/sh.
/// Window placement is handled by the `[rules]` table on WM_CLASS.
fn runAutostart(server: *Server) void {
    if (server.wm_config.autostart_count == 0) return;
    for (server.wm_config.autostart[0..server.wm_config.autostart_count]) |*entry| {
        const cmd = entry.getCmd();
        std.debug.print("teruwm: autostart → {s}\n", .{cmd});
        server.spawnShell(cmd);
    }
}

// ── xdg_shell ────────────────────────────────────────────────

pub fn handleNewXdgToplevel(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_xdg_toplevel", listener);
    const toplevel: *wlr.wlr_xdg_toplevel = @ptrCast(@alignCast(data orelse return));
    _ = XdgView.create(server, toplevel);
}

/// Client requested focus via xdg_activation_v1. We don't steal
/// focus — mark the node urgent so the bar indicator flips and
/// agents polling teruwm_list_windows see the flag.
pub fn handleXdgActivation(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "xdg_activate", listener);
    const ev: *wlr.wlr_xdg_activation_v1_request_activate_event = @ptrCast(@alignCast(data orelse return));
    const surface = wlr.miozu_xdg_activation_event_surface(ev) orelse return;
    const toplevel = wlr.miozu_xdg_toplevel_from_surface(surface) orelse return;
    const slot = server.nodes.findByToplevel(toplevel) orelse return;

    // Already focused? Nothing urgent about it.
    if (server.focused_view) |v| {
        if (v.toplevel == toplevel) return;
    }

    if (server.nodes.markUrgent(slot)) {
        const nid = server.nodes.node_id[slot];
        const ws = server.nodes.workspace[slot];
        std.debug.print("teruwm: urgent node={d} ws={d}\n", .{ nid, ws });
        server.emitMcpEventKind("urgent", ",\"node_id\":{d},\"workspace\":{d}", .{ nid, ws });
        if (server.bar) |b| b.render(server);
        server.scheduleRender();
    }
}

/// xdg-decoration-v1: force server-side decoration (tiling WM has
/// no use for client titlebars). wlroots sends the configure on the
/// next commit. If the client later asks for client-side we ignore
/// it; the most-recent mode we set stays in effect.
pub fn handleNewXdgDecoration(_: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const dec: *wlr.wlr_xdg_toplevel_decoration_v1 = @ptrCast(@alignCast(data orelse return));
    _ = wlr.wlr_xdg_toplevel_decoration_v1_set_mode(dec, wlr.XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
}

// ── idle_inhibit_v1 ──────────────────────────────────────────
//
// Each inhibitor is a tiny heap-allocated tracker with its own
// destroy listener; Server holds an array of trackers so the
// shutdown path can free them before wl_display_destroy fires
// inhibitor-destroy on stale state.

pub const InhibitorTracker = struct {
    server: *Server,
    destroy_listener: wlr.wl_listener,
};

pub fn handleNewInhibitor(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_inhibitor", listener);
    const inhibitor: *wlr.wlr_idle_inhibitor_v1 = @ptrCast(@alignCast(data orelse return));

    const tracker = server.zig_allocator.create(InhibitorTracker) catch return;
    tracker.* = .{
        .server = server,
        .destroy_listener = makeListener(handleInhibitorDestroy),
    };
    wlr.wl_signal_add(wlr.miozu_idle_inhibitor_destroy(inhibitor), &tracker.destroy_listener);

    server.inhibitor_trackers.append(server.zig_allocator, tracker) catch {
        wlr.wl_list_remove(&tracker.destroy_listener.link);
        server.zig_allocator.destroy(tracker);
        return;
    };

    server.idle_inhibitor_count += 1;
    refreshIdleInhibited(server);
}

pub fn handleInhibitorDestroy(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const tracker: *InhibitorTracker = @fieldParentPtr("destroy_listener", listener);
    const server = tracker.server;

    // Server.deinit already freed us — skip to avoid dereferencing
    // torn-down wlr_idle_notifier during wl_display_destroy.
    if (server.shutting_down) return;

    server.idle_inhibitor_count -|= 1;
    refreshIdleInhibited(server);

    for (server.inhibitor_trackers.items, 0..) |t, i| {
        if (t == tracker) {
            _ = server.inhibitor_trackers.swapRemove(i);
            break;
        }
    }

    wlr.wl_list_remove(&tracker.destroy_listener.link);
    server.zig_allocator.destroy(tracker);
}

fn refreshIdleInhibited(server: *Server) void {
    if (server.idle_notifier) |n| {
        wlr.wlr_idle_notifier_v1_set_inhibited(n, server.idle_inhibitor_count > 0);
    }
}

// ── output_power_management_v1 ───────────────────────────────

pub fn handleOutputPowerSetMode(_: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const event: *wlr.wlr_output_power_v1_set_mode_event = @ptrCast(@alignCast(data orelse return));
    const output = wlr.miozu_output_power_event_output(event);
    const want_on = wlr.miozu_output_power_event_mode_on(event) != 0;
    const currently_on = wlr.miozu_output_enabled(output) != 0;
    if (want_on == currently_on) return;
    _ = wlr.miozu_output_commit_enabled(output, if (want_on) 1 else 0);
}

// ── virtual_keyboard_v1 / virtual_pointer_v1 ─────────────────

pub fn handleNewVirtualKeyboard(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_virtual_keyboard", listener);
    const vkbd: *wlr.wlr_virtual_keyboard_v1 = @ptrCast(@alignCast(data orelse return));
    const device = wlr.miozu_virtual_keyboard_input_device(vkbd);
    server.setupKeyboard(device);
}

pub fn handleNewVirtualPointer(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_virtual_pointer", listener);
    const event: *wlr.wlr_virtual_pointer_v1_new_pointer_event = @ptrCast(@alignCast(data orelse return));
    const device = wlr.miozu_virtual_pointer_new_pointer(event);
    wlr.wlr_cursor_attach_input_device(server.cursor, device);
}

// ── output_management_v1 ─────────────────────────────────────
//
// Two-phase — clients send a config, we test, they resend as apply,
// we commit. Both events hand us ownership of the cfg; the
// send_succeeded/send_failed helpers destroy it. On successful apply
// we push current state so observing clients (kanshi) resync.

pub fn handleOutputManagerApply(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "output_manager_apply", listener);
    const cfg: *wlr.wlr_output_configuration_v1 = @ptrCast(@alignCast(data orelse return));
    const ok = wlr.miozu_output_apply_config(server.output_layout, cfg, 0) != 0;
    if (ok) {
        wlr.miozu_output_config_send_succeeded(cfg);
        server.pushOutputManagerState();
    } else {
        wlr.miozu_output_config_send_failed(cfg);
    }
}

pub fn handleOutputManagerTest(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "output_manager_test", listener);
    const cfg: *wlr.wlr_output_configuration_v1 = @ptrCast(@alignCast(data orelse return));
    const ok = wlr.miozu_output_apply_config(server.output_layout, cfg, 1) != 0;
    if (ok) {
        wlr.miozu_output_config_send_succeeded(cfg);
    } else {
        wlr.miozu_output_config_send_failed(cfg);
    }
}

/// Broadcast current output state. Call after any output add,
/// destroy, mode change, or successful apply.
pub fn pushOutputManagerState(server: *Server) void {
    const mgr = server.output_manager orelse return;

    var buf: [16]*wlr.wlr_output = undefined;
    const n = @min(server.outputs.items.len, buf.len);
    for (0..n) |i| buf[i] = server.outputs.items[i].wlr_output;
    wlr.miozu_output_push_state(mgr, server.output_layout, &buf, @intCast(n));
}

// ── xwayland ─────────────────────────────────────────────────

pub fn handleNewXwaylandSurface(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_xwayland_surface", listener);
    const surface: *wlr.wlr_xwayland_surface = @ptrCast(@alignCast(data orelse return));
    _ = XwaylandView.create(server, surface);
}
