//! Linux platform abstraction.
//!
//! Auto-detects Wayland vs X11 at runtime. CPU SIMD renderer blits
//! framebuffer to the window via xcb_put_image. No EGL or OpenGL.
//!
//! Build options (-Dx11=false or -Dwayland=false) allow building with
//! only one backend for minimal/embedded builds. When both are enabled
//! (the default), the runtime check for WAYLAND_DISPLAY selects Wayland
//! with X11 fallback.

const std = @import("std");
const build_options = @import("build_options");
const compat = @import("../../compat.zig");

const enable_x11 = build_options.enable_x11;
const enable_wayland = build_options.enable_wayland;

const x11 = if (enable_x11) @import("x11.zig") else struct {
    pub const X11Window = void;
};
const wayland = if (enable_wayland) @import("wayland.zig") else struct {
    pub const WaylandWindow = void;
};

const types = @import("../types.zig");
pub const KeyEvent = types.KeyEvent;
pub const MouseButton = types.MouseButton;
pub const MouseEvent = types.MouseEvent;
pub const Event = types.Event;
pub const Size = types.Size;
pub const X11Info = types.X11Info;

// When both backends are enabled, use a tagged union for runtime dispatch.
// When only one backend is enabled, the Platform is a thin wrapper around it
// with zero dispatch overhead (no branch, no union tag).

pub const Platform = if (enable_x11 and enable_wayland)
    DualPlatform
else if (enable_x11)
    X11Only
else
    WaylandOnly;

// ── Dual-backend: tagged union, runtime detection ───────────────

const DualPlatform = union(enum) {
    x11: x11.X11Window,
    wayland_: wayland.WaylandWindow,

    pub fn init(width: u32, height: u32, title: []const u8) !DualPlatform {
        if (compat.getenv("WAYLAND_DISPLAY") != null) {
            if (wayland.WaylandWindow.init(width, height, title)) |w| {
                return .{ .wayland_ = w };
            } else |_| {}
        }
        return .{ .x11 = try x11.X11Window.init(width, height, title) };
    }

    pub fn deinit(self: *DualPlatform) void {
        switch (self.*) {
            .x11 => |*w| w.deinit(),
            .wayland_ => |*w| w.deinit(),
        }
    }

    pub fn pollEvents(self: *DualPlatform) ?Event {
        return switch (self.*) {
            .x11 => |*w| w.pollEvents(),
            .wayland_ => |*w| w.pollEvents(),
        };
    }

    pub fn putFramebuffer(self: *DualPlatform, pixels: []const u32, width: u32, height: u32) void {
        switch (self.*) {
            .x11 => |*w| w.putFramebuffer(pixels, width, height),
            .wayland_ => |*w| w.putFramebuffer(pixels, width, height),
        }
    }

    pub fn setOpacity(self: *DualPlatform, opacity: f32) void {
        switch (self.*) {
            .x11 => |*w| w.setOpacity(opacity),
            .wayland_ => {}, // Wayland: compositor controls opacity
        }
    }

    pub fn setTitle(self: *DualPlatform, title: []const u8) void {
        switch (self.*) {
            .x11 => |*w| w.setTitle(title),
            .wayland_ => |*w| w.setTitle(title),
        }
    }

    pub fn getSize(self: *const DualPlatform) Size {
        return switch (self.*) {
            .x11 => |*w| w.getSize(),
            .wayland_ => |*w| w.getSize(),
        };
    }

    /// Get X11 connection info for keyboard layout query. Null on Wayland.
    pub fn getX11Info(self: *const DualPlatform) ?X11Info {
        return switch (self.*) {
            .x11 => |*w| w.getX11Info(),
            .wayland_ => null,
        };
    }
};

// ── X11-only: zero-cost wrapper ─────────────────────────────────

const X11Only = struct {
    inner: x11.X11Window,

    pub fn init(width: u32, height: u32, title: []const u8) !X11Only {
        return .{ .inner = try x11.X11Window.init(width, height, title) };
    }

    pub fn deinit(self: *X11Only) void {
        self.inner.deinit();
    }

    pub fn pollEvents(self: *X11Only) ?Event {
        return self.inner.pollEvents();
    }

    pub fn putFramebuffer(self: *X11Only, pixels: []const u32, width: u32, height: u32) void {
        self.inner.putFramebuffer(pixels, width, height);
    }

    pub fn setOpacity(self: *X11Only, opacity: f32) void {
        self.inner.setOpacity(opacity);
    }

    pub fn setTitle(self: *X11Only, title: []const u8) void {
        self.inner.setTitle(title);
    }

    pub fn getSize(self: *const X11Only) Size {
        return self.inner.getSize();
    }

    pub fn getX11Info(self: *const X11Only) ?X11Info {
        return self.inner.getX11Info();
    }
};

// ── Wayland-only: zero-cost wrapper ─────────────────────────────

const WaylandOnly = struct {
    inner: wayland.WaylandWindow,

    pub fn init(width: u32, height: u32, title: []const u8) !WaylandOnly {
        return .{ .inner = try wayland.WaylandWindow.init(width, height, title) };
    }

    pub fn deinit(self: *WaylandOnly) void {
        self.inner.deinit();
    }

    pub fn pollEvents(self: *WaylandOnly) ?Event {
        return self.inner.pollEvents();
    }

    pub fn putFramebuffer(self: *WaylandOnly, pixels: []const u32, width: u32, height: u32) void {
        self.inner.putFramebuffer(pixels, width, height);
    }

    pub fn setOpacity(_: *WaylandOnly, _: f32) void {}

    pub fn setTitle(self: *WaylandOnly, title: []const u8) void {
        self.inner.setTitle(title);
    }

    pub fn getSize(self: *const WaylandOnly) Size {
        return self.inner.getSize();
    }

    pub fn getX11Info(_: *const WaylandOnly) ?X11Info {
        return null; // Wayland uses wl_keyboard.keymap, not X11 properties
    }
};
