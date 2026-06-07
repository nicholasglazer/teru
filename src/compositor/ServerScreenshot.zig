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
        // On-screen feedback: mod+w is silent otherwise, so it feels like a
        // no-op even though the PNG saved. Pop a bar toast naming the dir.
        // ASCII only — the {notify} marquee renders printable ASCII (32-126).
        var msg_buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Screenshot saved -> {s}/latest.png", .{dir}) catch "Screenshot saved";
        server.setNotification("", msg, "", .normal, 2500);
    } else {
        server.setNotification("", "Screenshot failed (see log)", "", .critical, 4000);
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

    compositeOutput(server, pixels, out_w, out_h);

    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return false;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    teru.png.write(server.zig_allocator, @ptrCast(path_z[0..path.len :0]), pixels, out_w, out_h) catch return false;
    return true;
}

/// Composite the active workspace's panes + bars into `pixels` (full output
/// size). Shared by full-output and area screenshots. Clears to bg first.
fn compositeOutput(server: *Server, pixels: []u32, out_w: u32, out_h: u32) void {
    teru.compat.memsetU32(pixels, server.wm_config.bg_color);

    // Two-pass: tiled first, floating on top. Mirrors wlroots' scene
    // z-order. Without this, float/drag snapshots diverge from what the
    // real compositor draws.
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

    if (server.bar) |b| {
        if (b.top.enabled) {
            blitRect(pixels, out_w, out_h, b.top.renderer.framebuffer, b.output_width, b.bar_height, 0, 0);
        }
        if (b.bottom.enabled) {
            blitRect(pixels, out_w, out_h, b.bottom.renderer.framebuffer, b.output_width, b.bar_height, 0, @intCast(out_h - b.bar_height));
        }
    }
}

/// Crop a rectangular region of the composited output to a PNG. Used by the
/// native area-select (mod+shift+w): teruwm composites its own output, so it
/// crops directly — no grim/slurp/layer-shell. Saves to the configured shot
/// dir as `area-<ts>.png` and pops a toast. Returns true on write success.
/// (Does NOT capture external GUI clients — their pixels aren't in our
/// pane framebuffers; that needs wlr-screencopy.)
pub fn takeAreaScreenshot(server: *Server, rx: i32, ry: i32, rw: u32, rh: u32) bool {
    const dims = server.activeOutputDims();
    const out_w: u32 = dims.w;
    const out_h: u32 = dims.h;
    if (out_w == 0 or out_h == 0 or rw == 0 or rh == 0) return false;

    // Clamp the requested rect to the output bounds.
    const cx0: u32 = @intCast(@max(0, rx));
    const cy0: u32 = @intCast(@max(0, ry));
    if (cx0 >= out_w or cy0 >= out_h) return false;
    const cw: u32 = @min(rw, out_w - cx0);
    const ch: u32 = @min(rh, out_h - cy0);
    if (cw == 0 or ch == 0) return false;

    const full = server.zig_allocator.alloc(u32, @as(usize, out_w) * @as(usize, out_h)) catch return false;
    defer server.zig_allocator.free(full);
    compositeOutput(server, full, out_w, out_h);

    const crop = server.zig_allocator.alloc(u32, @as(usize, cw) * @as(usize, ch)) catch return false;
    defer server.zig_allocator.free(crop);
    for (0..ch) |y| {
        const src = (@as(usize, cy0) + y) * @as(usize, out_w) + @as(usize, cx0);
        const dst = y * @as(usize, cw);
        @memcpy(crop[dst..][0..cw], full[src..][0..cw]);
    }

    // Path: configured shot dir (default $HOME/Pictures/teru) / area-<ts>.png.
    const home = teru.compat.getenv("HOME") orelse "/tmp";
    var dir_buf: [400]u8 = undefined;
    const cfg = server.wm_config.screenshot_dir_buf[0..server.wm_config.screenshot_dir_len];
    const dir = if (cfg.len > 0) cfg else (std.fmt.bufPrint(&dir_buf, "{s}/Pictures/teru", .{home}) catch return false);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/area-{d}.png", .{ dir, teru.compat.monotonicNow() }) catch return false;
    teru.compat.ensureParentDirC(path);

    if (!teru.compat.isSafeScreenshotPath(path)) return false;
    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return false;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    teru.png.write(server.zig_allocator, @ptrCast(path_z[0..path.len :0]), crop, cw, ch) catch {
        server.setNotification("", "Area screenshot failed (see log)", "", .critical, 4000);
        return false;
    };
    std.log.scoped(.compositor).info("area screenshot {d}x{d} → {s}", .{ cw, ch, path });
    var msg_buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "Area saved ({d}x{d}) -> {s}", .{ cw, ch, path }) catch "Area screenshot saved";
    server.setNotification("", msg, "", .normal, 2500);
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
