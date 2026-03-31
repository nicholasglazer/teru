//! Rendering tier auto-detection and unified renderer dispatch.
//!
//! Two-tier architecture:
//!   CPU  — SIMD software raster + X11 SHM (primary, works everywhere with display)
//!   TTY  — VT output to host terminal (SSH, server, container, --raw mode)
//!
//! No GPU/OpenGL tier — CPU SIMD rendering achieves <50μs per frame for
//! terminal workloads (5000 textured quads). The GPU would be idle 99.9%
//! of the time. Eliminating it removes 709 lines, 2 link deps, and EGL.

const std = @import("std");
const Grid = @import("../core/Grid.zig");
const SoftwareRenderer = @import("software.zig").SoftwareRenderer;
const compat = @import("../compat.zig");

// ── Tier detection ─────────────────────────────────────────────────

pub const RenderTier = enum {
    cpu, // X11/Wayland with SIMD software rendering
    tty, // No display server (SSH, pure console)

    pub fn label(self: RenderTier) []const u8 {
        return switch (self) {
            .cpu => "cpu (SIMD software)",
            .tty => "tty (VT escape codes)",
        };
    }
};

/// Detect the best rendering tier for the current environment.
pub fn detectTier() RenderTier {
    if (compat.getenv("DISPLAY") != null) return .cpu;
    if (compat.getenv("WAYLAND_DISPLAY") != null) return .cpu;
    return .tty;
}

// ── Unified renderer dispatch ──────────────────────────────────────

pub const Renderer = union(enum) {
    cpu: SoftwareRenderer,
    tty: void,

    pub fn render(self: *Renderer, grid: *const Grid) void {
        switch (self.*) {
            .cpu => |*cpu| cpu.render(grid),
            .tty => {},
        }
    }

    pub fn resize(self: *Renderer, width: u32, height: u32) void {
        switch (self.*) {
            // Framebuffer realloc: keep old size on OOM rather than crash
            .cpu => |*cpu| cpu.resize(width, height) catch {},
            .tty => {},
        }
    }

    pub fn updateAtlas(self: *Renderer, atlas_data: []const u8, atlas_width: u32, atlas_height: u32) void {
        switch (self.*) {
            .cpu => |*cpu| cpu.updateAtlas(atlas_data, atlas_width, atlas_height),
            .tty => {},
        }
    }

    pub fn deinit(self: *Renderer) void {
        switch (self.*) {
            .cpu => |*cpu| cpu.deinit(),
            .tty => {},
        }
    }

    pub fn initCpu(allocator: std.mem.Allocator, width: u32, height: u32, cell_width: u32, cell_height: u32) !Renderer {
        return .{ .cpu = try SoftwareRenderer.init(allocator, width, height, cell_width, cell_height) };
    }

    pub fn initCpuWithCursor(allocator: std.mem.Allocator, width: u32, height: u32, cell_width: u32, cell_height: u32, cursor_color: u32) !Renderer {
        return .{ .cpu = try SoftwareRenderer.initWithCursor(allocator, width, height, cell_width, cell_height, cursor_color) };
    }

    pub fn initTty() Renderer {
        return .{ .tty = {} };
    }

    pub fn getFramebuffer(self: *const Renderer) ?[]const u32 {
        return switch (self.*) {
            .cpu => |cpu| cpu.getFramebuffer(),
            .tty => null,
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "detectTier returns a valid tier" {
    const t = detectTier();
    _ = t.label();
}

test "RenderTier labels are distinct" {
    try std.testing.expect(!std.mem.eql(u8, RenderTier.cpu.label(), RenderTier.tty.label()));
}

test "Renderer CPU tier init and render" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 2, 3);
    defer grid.deinit(allocator);

    var renderer = try Renderer.initCpu(allocator, 24, 32, 8, 16);
    defer renderer.deinit();
    renderer.render(&grid);

    const fb = renderer.getFramebuffer();
    try std.testing.expect(fb != null);
    try std.testing.expectEqual(@as(usize, 24 * 32), fb.?.len);
}

test "Renderer TTY tier is a no-op" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 2, 3);
    defer grid.deinit(allocator);

    var renderer = Renderer.initTty();
    defer renderer.deinit();
    renderer.render(&grid);
    renderer.resize(100, 50);
    renderer.updateAtlas(&.{}, 0, 0);
    try std.testing.expectEqual(@as(?[]const u32, null), renderer.getFramebuffer());
}
