//! VR station mode.
//!
//! The problem this solves: a VR capture client mirrors the compositor's
//! internal panel with wlr-screencopy. wlr-screencopy frames are completed by
//! the compositor committing that output, so *disabling* the panel to save
//! power stops the frames and freezes the headset on its last picture
//! (measured: caps 0/60). Brightness is not a substitute: 0 on intel_backlight
//! still emits, because the LED string's hardware floor is not off.
//!
//! So VR mode swaps the *rendering target*: a wlroots headless output is
//! created at the panel's layout box with the panel's geometry and refresh,
//! the active workspace is shown there, and only then is the physical output
//! disabled — a full modeset, so i915 turns off the CRTC, the connector and the
//! panel power. The desktop keeps being composited into memory, the capture
//! client keeps receiving frames, and the panel draws no power and emits no
//! light.
//!
//! Note what this does NOT do: it does not add a second render. While VR mode
//! is on the headless output is the only output, so the compositor renders the
//! desktop exactly once — for the glasses.
const std = @import("std");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const Output = @import("Output.zig");
const log = std.log.scoped(.compositor);

pub const Status = struct {
    active: bool = false,
    output_name: []const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
    panel_name: []const u8 = "",
    panel_enabled: bool = false,
};

fn nameOf(o: *wlr.wlr_output) []const u8 {
    const p = wlr.miozu_output_name(o) orelse return "";
    return std.mem.span(p);
}

pub fn status(server: *Server) Status {
    var st = Status{ .active = server.vr_mode };
    if (server.headless_output) |o| {
        st.output_name = nameOf(o.wlr_output);
        st.width = @intCast(@max(1, wlr.miozu_output_width(o.wlr_output)));
        st.height = @intCast(@max(1, wlr.miozu_output_height(o.wlr_output)));
    }
    if (server.vr_panel) |p| {
        st.panel_name = nameOf(p.wlr_output);
        st.panel_enabled = wlr.miozu_output_enabled(p.wlr_output) != 0;
    }
    return st;
}

pub fn setMode(server: *Server, on: bool, panel_name: ?[]const u8) bool {
    if (on == server.vr_mode) return true;
    return if (on) enable(server, panel_name) else disable(server);
}

fn findPanel(server: *Server, override: ?[]const u8) ?*Output {
    for (server.outputs.items) |o| {
        const n = nameOf(o.wlr_output);
        if (override) |want| {
            if (std.mem.eql(u8, n, want)) return o;
        } else if (std.mem.startsWith(u8, n, "eDP-")) return o;
    }
    return null;
}

fn removeFromOutputs(server: *Server, out: *Output) void {
    for (server.outputs.items, 0..) |o, i| {
        if (o == out) {
            _ = server.outputs.orderedRemove(i);
            return;
        }
    }
}

fn enable(server: *Server, panel_name: ?[]const u8) bool {
    if (server.headless_backend != null) return true;
    const panel = findPanel(server, panel_name) orelse {
        log.err("vr_mode: no eDP-* output (pass panel=<name>)", .{});
        return false;
    };
    const loop = server.event_loop orelse return false;
    const w: i32 = @max(1, wlr.miozu_output_width(panel.wlr_output));
    const h: i32 = @max(1, wlr.miozu_output_height(panel.wlr_output));
    var refresh: i32 = wlr.miozu_output_refresh_mhz(panel.wlr_output);
    if (refresh <= 0) refresh = 60_000;
    // The headset is the only consumer of the mirror. Compositing faster than
    // it presents is wasted GPU that a fullscreen game wants; cap to the VR
    // refresh (vr_refresh_hz, default 72). 0 = inherit the panel's rate.
    if (server.wm_config.vr_refresh_hz > 0) {
        const cap: i32 = @as(i32, server.wm_config.vr_refresh_hz) * 1000;
        if (cap < refresh) refresh = cap;
    }

    var box: wlr.wlr_box = undefined;
    wlr.wlr_output_layout_get_box(server.output_layout, panel.wlr_output, &box);

    const backend = wlr.wlr_headless_backend_create(loop) orelse {
        log.err("vr_mode: headless backend create failed", .{});
        return false;
    };
    if (!wlr.wlr_backend_start(backend)) {
        wlr.wlr_backend_destroy(backend);
        log.err("vr_mode: headless backend start failed", .{});
        return false;
    }
    const hout = wlr.wlr_headless_add_output(backend, @intCast(w), @intCast(h)) orelse {
        wlr.wlr_backend_destroy(backend);
        log.err("vr_mode: headless output create failed", .{});
        return false;
    };
    const houtput = Output.create(server, hout, server.zig_allocator, .{
        .layout_pos = .{ .x = box.x, .y = box.y },
        .custom_mode = .{ .w = w, .h = h, .refresh_mhz = refresh },
    }) catch {
        wlr.wlr_backend_destroy(backend);
        log.err("vr_mode: headless Output setup failed", .{});
        return false;
    };

    server.headless_backend = backend;
    server.headless_output = houtput;
    server.vr_panel = panel;
    server.vr_panel_x = box.x;
    server.vr_panel_y = box.y;
    server.vr_mode = true;

    // The dead panel must stop being a workspace viewport: outputShowing()
    // and focusWorkspace() would otherwise keep a second workspace's scene
    // nodes enabled, and both workspaces would render into the mirror.
    removeFromOutputs(server, panel);
    server.focused_output = houtput;
    server.primary_output = hout;
    houtput.workspace = server.layout_engine.active_workspace;
    panel.workspace = server.layout_engine.active_workspace;
    server.arrangeworkspace(server.layout_engine.active_workspace);
    server.recomputeVisibility();

    // Full modeset off: set_enabled sets allow_reconfiguration, so the DRM
    // backend passes DRM_MODE_ATOMIC_ALLOW_MODESET; i915 disables the CRTC,
    // the DPMS/panel power and the backlight.
    if (wlr.miozu_output_commit_enabled(panel.wlr_output, 0) == 0)
        log.err("vr_mode: failed to power off '{s}'", .{nameOf(panel.wlr_output)});
    wlr.wlr_output_layout_remove(server.output_layout, panel.wlr_output);
    server.pushOutputManagerState();
    server.scheduleRender();
    log.info("vr_mode on: '{s}' off, capture on '{s}' ({d}x{d}@{d})", .{
        nameOf(panel.wlr_output), nameOf(hout), w, h, refresh,
    });
    return true;
}

fn disable(server: *Server) bool {
    if (!server.vr_mode) return true;
    if (server.vr_panel) |panel| {
        var already = false;
        for (server.outputs.items) |o| {
            if (o == panel) {
                already = true;
                break;
            }
        }
        if (!already) server.outputs.append(server.zig_allocator, panel) catch {};
        _ = wlr.wlr_output_layout_add(server.output_layout, panel.wlr_output, server.vr_panel_x, server.vr_panel_y);
        if (wlr.wlr_scene_get_scene_output(server.scene, panel.wlr_output)) |so|
            wlr.wlr_scene_output_set_position(so, server.vr_panel_x, server.vr_panel_y);
        panel.workspace = server.layout_engine.active_workspace;
        server.focused_output = panel;
        server.primary_output = panel.wlr_output;
        _ = wlr.miozu_output_commit_enabled(panel.wlr_output, 1);
    }
    server.vr_mode = false;
    if (server.headless_backend) |b| wlr.wlr_backend_destroy(b);
    server.headless_backend = null;
    server.headless_output = null;
    server.vr_panel = null;
    server.arrangeworkspace(server.layout_engine.active_workspace);
    server.recomputeVisibility();
    server.pushOutputManagerState();
    server.scheduleRender();
    log.info("vr_mode off: panel restored", .{});
    return true;
}
