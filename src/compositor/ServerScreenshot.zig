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

/// Keybind variant (mod+w): write a full-output PNG natively to the configured
/// capture dir (default `$HOME/Pictures/teru`), plus a stable `latest.png`.
pub fn takeScreenshot(server: *Server) void {
    const home = teru.compat.getenv("HOME") orelse "/tmp";
    const timestamp = teru.compat.monotonicNow();

    // Capture directory: configured `screenshot_dir`, else $HOME/Pictures/teru.
    // Created on demand so the first shot never fails.
    var dir_buf: [400]u8 = undefined;
    const cfg = server.wm_config.screenshot_dir_buf[0..server.wm_config.screenshot_dir_len];
    const dir = if (cfg.len > 0) cfg else (std.fmt.bufPrint(&dir_buf, "{s}/Pictures/teru", .{home}) catch return);

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/teru-{d}.png", .{ dir, timestamp }) catch return;

    teru.compat.ensureParentDirC(path); // mkdir -p the capture dir

    if (takeScreenshotToPath(server, path)) {
        std.log.scoped(.compositor).info("screenshot → {s}", .{path});
        // Maintain a stable `latest.png` in the same dir so it's trivial to
        // reference the most recent shot ("look at my latest screenshot"). A
        // screenshot is a rare, user-initiated action, so re-compositing once
        // more here is fine and keeps latest.png a real, valid PNG.
        var latest_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&latest_buf, "{s}/latest.png", .{dir})) |latest| {
            _ = takeScreenshotToPath(server, latest);
        } else |_| {}
    }
}

/// Named-path variant: used by MCP (teruwm_screenshot) + Server.takeScreenshot.
/// Returns true on PNG write success. Rejects paths containing `../`.
pub fn takeScreenshotToPath(server: *Server, path: []const u8) bool {
    if (!teru.compat.isSafeScreenshotPath(path)) return false;
    const dims_ss = server.activeOutputDims();
    const out_w: u32 = dims_ss.w;
    const out_h: u32 = dims_ss.h;
    const total = @as(usize, out_w) * @as(usize, out_h);
    if (total == 0) return false;

    const pixels = server.zig_allocator.alloc(u32, total) catch return false;
    defer server.zig_allocator.free(pixels);

    // Clear to configured background color (visible through gaps).
    teru.compat.memsetU32(pixels, server.wm_config.bg_color);

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
