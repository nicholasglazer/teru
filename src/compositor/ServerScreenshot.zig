//! Full-output PNG screenshot pipeline for teruwm.
//!
//! Composites every visible terminal pane's framebuffer + bars into a
//! single allocated ARGB buffer, then pushes through teru's png writer.
//! The two-pass walk (tiled then floating) mirrors wlroots' scene-
//! graph z-order — without it, E2E screenshot diffs disagree with
//! what the user sees on-screen.
//!
//! Does NOT capture external xdg clients (chromium, firefox) — their
//! pixels live in client-owned buffers that wlr_screencopy_v1 captures
//! via a separate path. For those, callers use grim + zxdg-output-
//! manager, exposed since v0.5.0.
//!
//! Split out of Server.zig as part of the 2026-04-16 modularization pass.

const std = @import("std");
const teru = @import("teru");
const Server = @import("Server.zig");

/// Shell-spawn variant: write a screenshot to `$HOME/Pictures/screenshot_<ts>.png`.
pub fn takeScreenshot(server: *Server) void {
    var path_buf: [256:0]u8 = undefined;
    const home = teru.compat.getenv("HOME") orelse "/tmp";
    const timestamp = teru.compat.monotonicNow();
    const path = std.fmt.bufPrint(&path_buf, "{s}/Pictures/screenshot_{d}.png", .{ home, timestamp }) catch return;
    path_buf[path.len] = 0;

    if (takeScreenshotToPath(server, path)) {
        std.debug.print("teruwm: screenshot → {s}\n", .{path});
    }
}

/// Named-path variant: used by MCP (teruwm_screenshot) + Server.takeScreenshot.
/// Returns true on PNG write success.
pub fn takeScreenshotToPath(server: *Server, path: []const u8) bool {
    const dims_ss = server.activeOutputDims();
    const out_w: u32 = dims_ss.w;
    const out_h: u32 = dims_ss.h;
    const total = @as(usize, out_w) * @as(usize, out_h);
    if (total == 0) return false;

    const pixels = server.zig_allocator.alloc(u32, total) catch return false;
    defer server.zig_allocator.free(pixels);

    // Clear to configured background color (visible through gaps).
    @memset(pixels, server.wm_config.bg_color);

    // Two-pass: tiled first, floating on top. Mirrors wlroots' scene
    // z-order. Without this, float/drag E2E snapshots diverge from
    // what the real compositor draws.
    const ws = server.layout_engine.active_workspace;
    for ([_]bool{ false, true }) |want_floating| {
        for (server.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| {
                const slot = server.nodes.findById(tp.node_id) orelse continue;
                if (server.nodes.workspace[slot] != ws) continue;
                if (server.nodes.floating[slot] != want_floating) continue;
                tp.render();
                blitRect(
                    pixels, out_w, out_h,
                    tp.renderer.framebuffer, tp.renderer.width, tp.renderer.height,
                    server.nodes.pos_x[slot], server.nodes.pos_y[slot],
                );
            }
        }
    }

    // Scratchpads live in the NodeRegistry with floating=true since
    // v0.4.18, so the walk above composited them at the right z-order.

    if (server.bar) |b| {
        if (b.top.enabled) {
            blitRect(pixels, out_w, out_h, b.top.renderer.framebuffer, b.output_width, b.bar_height, 0, 0);
        }
        if (b.bottom.enabled) {
            blitRect(pixels, out_w, out_h, b.bottom.renderer.framebuffer, b.output_width, b.bar_height, 0, @intCast(out_h - b.bar_height));
        }
    }

    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return false;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    teru.png.write(server.zig_allocator, @ptrCast(path_z[0..path.len :0]), pixels, out_w, out_h) catch return false;
    return true;
}

/// Generic ARGB framebuffer blit. Pure pixel math — no wlroots or
/// Server state. Lives here rather than in render/software.zig only
/// because it's the sole caller; move if a second consumer appears.
fn blitRect(dst: []u32, dst_w: u32, dst_h: u32, src: []const u32, src_w: u32, src_h: u32, off_x: i32, off_y: i32) void {
    if (off_x < 0 or off_y < 0) return;
    const ox: u32 = @intCast(off_x);
    const oy: u32 = @intCast(off_y);

    const rows = @min(src_h, dst_h -| oy);
    const cols = @min(src_w, dst_w -| ox);
    if (rows == 0 or cols == 0) return;

    for (0..rows) |y| {
        const dst_start = (@as(usize, oy) + y) * @as(usize, dst_w) + @as(usize, ox);
        const src_start = y * @as(usize, src_w);
        if (dst_start + cols > dst.len or src_start + cols > src.len) continue;
        @memcpy(dst[dst_start..][0..cols], src[src_start..][0..cols]);
    }
}
