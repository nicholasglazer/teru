//! Full-output PNG screenshot pipeline for teruwm.
//!
//! Composites every visible terminal pane's framebuffer, external
//! client windows, and bars into a single allocated ARGB buffer, then
//! pushes through teru's png writer. The two-pass walk (tiled then
//! floating) mirrors wlroots' scene-graph z-order — without it, E2E
//! screenshot diffs disagree with what the user sees on-screen.
//!
//! External clients (chromium, firefox, xwayland) are captured by
//! reading their committed buffers back from the renderer
//! (wlr_texture_read_pixels via miozu_capture_*_tree) — subsurfaces
//! and xdg popups included. Not captured: override-redirect X11
//! windows (never in the node registry) and the hardware cursor
//! plane. grim via wlr_screencopy_v1 remains available as before.
//!
//! Split out of Server.zig as part of the 2026-04-16 modularization pass.

const std = @import("std");
const teru = @import("teru");
const Server = @import("Server.zig");
const wlr = @import("wlr.zig");

/// Keybind variant (mod+w): write a full-output PNG natively to the configured
/// capture dir (default `$HOME/Pictures/teru`), plus a stable `latest.png`.
pub fn takeScreenshot(server: *Server) void {
    // Human-readable, sortable name: `teru-YYYY-MM-DD_HH-MM-SS.png`. (The old
    // monotonic-counter names reset every reboot and aren't chronological.)
    var ts_buf: [32]u8 = undefined;
    const ts = teru.compat.formatLocalTimestamp(&ts_buf);

    var dir_buf: [400]u8 = undefined;
    const dir = screenshotDir(server, &dir_buf) orelse return;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/teru-{s}.png", .{ dir, ts }) catch return;

    teru.compat.ensureParentDirC(path); // mkdir -p the capture dir

    // Maintain a stable `latest.png` in the same dir so it's trivial to
    // reference the most recent shot ("look at my latest screenshot").
    var latest_buf: [512]u8 = undefined;
    const latest: ?[]const u8 = std.fmt.bufPrint(&latest_buf, "{s}/latest.png", .{dir}) catch null;

    // Composite the output ONCE and write both the dated path and latest.png
    // from that single in-memory buffer. The composite step is a full per-pane
    // render; doing it twice (once per file) doubled the work on the
    // single-threaded wl_display loop for no benefit.
    if (compositeAndWrite(server, path, latest)) {
        std.log.scoped(.compositor).info("screenshot → {s}", .{path});
        // Also copy to the Wayland clipboard so it can be pasted into other apps.
        const copied = copyToClipboard(server, path);
        // On-screen feedback: mod+w is silent otherwise, so it feels like a
        // no-op even though the PNG saved. Pop a bar toast naming the file.
        // ASCII only — the {notify} marquee renders printable ASCII (32-126).
        var msg_buf: [200]u8 = undefined;
        const msg = if (copied)
            (std.fmt.bufPrint(&msg_buf, "Screenshot saved + copied to clipboard -> {s}", .{path}) catch "Screenshot saved + copied to clipboard")
        else
            (std.fmt.bufPrint(&msg_buf, "Screenshot saved -> {s}", .{path}) catch "Screenshot saved");
        server.setNotification("", msg, "", .normal, 2500);
    } else {
        server.setNotification("", "Screenshot failed (see log)", "", .critical, 4000);
    }
}

/// Resolve the capture directory: configured `screenshot_dir`, else
/// `$HOME/Pictures/screenshots` (matches the conventional screenshots folder).
/// Returns null only on bufPrint overflow.
fn screenshotDir(server: *Server, dir_buf: []u8) ?[]const u8 {
    const cfg = server.wm_config.screenshot_dir_buf[0..server.wm_config.screenshot_dir_len];
    if (cfg.len > 0) return cfg;
    const home = teru.compat.getenv("HOME") orelse "/tmp";
    return std.fmt.bufPrint(dir_buf, "{s}/Pictures/screenshots", .{home}) catch null;
}

/// Copy the PNG at `path` to the Wayland clipboard as `image/png`. Non-fatal:
/// returns false if the selection couldn't be set (the file is on disk either
/// way). teruwm owns the seat, so this is a native data source — no wl-copy.
fn copyToClipboard(server: *Server, path: []const u8) bool {
    var pz: [512:0]u8 = undefined;
    if (path.len >= pz.len) return false;
    @memcpy(pz[0..path.len], path);
    pz[path.len] = 0;
    return wlr.miozu_set_clipboard_png_from_file(server.seat, server.display, pz[0..path.len :0].ptr) == 0;
}

/// Named-path variant: used by MCP (teruwm_screenshot) + Server.takeScreenshot.
/// Returns true on PNG write success. Rejects paths containing `../`.
pub fn takeScreenshotToPath(server: *Server, path: []const u8) bool {
    return compositeAndWrite(server, path, null);
}

/// Composite the active output ONCE into a single pixel buffer, then encode it
/// to `path` and (if non-null) `also` — reusing the same composited buffer for
/// both. Returns true if `path` was written. Rejects paths containing `../`.
/// Pulling the composite out of the per-file loop is what kills mod+w's
/// double full-render: the second file used to re-composite from scratch.
fn compositeAndWrite(server: *Server, path: []const u8, also: ?[]const u8) bool {
    if (!teru.compat.isSafeScreenshotPath(path)) return false;
    const dims_ss = server.activeOutputDims();
    const out_w: u32 = dims_ss.w;
    const out_h: u32 = dims_ss.h;
    const total = @as(usize, out_w) * @as(usize, out_h);
    if (total == 0) return false;

    const pixels = server.zig_allocator.alloc(u32, total) catch return false;
    defer server.zig_allocator.free(pixels);

    compositeOutput(server, pixels, out_w, out_h);

    if (!writePng(server, path, pixels, out_w, out_h)) return false;

    // Secondary path (e.g. latest.png) shares the buffer; its failure is
    // non-fatal since the primary file is already on disk.
    if (also) |a| {
        if (teru.compat.isSafeScreenshotPath(a)) {
            _ = writePng(server, a, pixels, out_w, out_h);
        }
    }
    return true;
}

/// Encode `pixels` to `path` as PNG. Returns false on overflow or write error.
fn writePng(server: *Server, path: []const u8, pixels: []const u32, out_w: u32, out_h: u32) bool {
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
                // Only re-paint panes whose framebuffer is stale. A clean
                // pane (grid.dirty == false) is already current from the
                // last vsync render, so re-rendering it is pure wasted CPU
                // on the loop thread during capture. Grid content, selection
                // drags, and scroll all set grid.dirty (markRowDirty /
                // markAllDirty in ServerCursor), so dirty fully captures
                // "framebuffer needs repaint" — no stale-capture risk.
                if (tp.pane.grid.dirty) tp.render();
                blitRect(
                    pixels, out_w, out_h,
                    tp.renderer.framebuffer, tp.renderer.width, tp.renderer.height,
                    server.nodes.pos_x[slot], server.nodes.pos_y[slot],
                );
            }
        }
        // External clients in the same z-pass: read their committed
        // buffers back from the renderer and blit at the node rect.
        // Subsurfaces + xdg popups ride along inside the glue's
        // surface-tree walk. Tiled xwayland windows go through the
        // plain-surface variant; floating/override-redirect X11
        // windows never enter the node registry and are skipped.
        for (0..server.nodes.kind.len) |slot| {
            if (server.nodes.kind[slot] != .wayland_surface) continue;
            if (server.nodes.workspace[slot] != ws) continue;
            if (server.nodes.floating[slot] != want_floating) continue;
            const px = server.nodes.pos_x[slot];
            const py = server.nodes.pos_y[slot];
            if (server.nodes.xdg_toplevel[slot]) |tl| {
                const xdg = wlr.miozu_xdg_toplevel_base(tl) orelse continue;
                _ = wlr.miozu_capture_xdg_surface_tree(xdg, pixels.ptr, @intCast(out_w), @intCast(out_h), px, py);
            } else if (server.nodes.xwayland_surface[slot]) |xs| {
                const surface = wlr.miozu_xwayland_surface_surface(xs) orelse continue;
                _ = wlr.miozu_capture_surface_tree(surface, pixels.ptr, @intCast(out_w), @intCast(out_h), px, py);
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

    // Leader which-key panel — a bottom-anchored overlay scene buffer above the
    // bars. The scene scans it out on a real output; this manual composite must
    // include it so a screenshot during leader mode matches what's on screen.
    if (server.leader.active) {
        if (server.leader_panel) |*p| {
            const py: usize = if (out_h > p.height) out_h - p.height else 0;
            blitRect(pixels, out_w, out_h, p.renderer.framebuffer, p.width, p.height, 0, @intCast(py));
        }
    }

    // Keystroke OSD — same reasoning as the leader panel, but its buffer is
    // transparent outside the chips, so blend by alpha instead of memcpy
    // (blitRect would stamp the transparent margin as opaque black).
    if (server.keys_osd.isShown()) {
        const osd = &server.keys_osd;
        if (osd.renderer) |*r| {
            blitRectAlpha(pixels, out_w, out_h, r.framebuffer, osd.width, osd.height, osd.pos_x, osd.pos_y);
        }
    }
}

/// Crop a rectangular region of the composited output to a PNG. Used by the
/// native area-select (mod+ctrl+w): teruwm composites its own output, so it
/// crops directly — no grim/slurp/layer-shell. Saves to the configured shot
/// dir as `area-<ts>.png` and pops a toast. Returns true on write success.
/// Captures panes, bars, AND external clients (see compositeOutput).
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

    // Path: configured shot dir (default $HOME/Pictures/screenshots) /
    // area-YYYY-MM-DD_HH-MM-SS.png.
    var dir_buf: [400]u8 = undefined;
    const dir = screenshotDir(server, &dir_buf) orelse return false;
    var ts_buf: [32]u8 = undefined;
    const ts = teru.compat.formatLocalTimestamp(&ts_buf);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/area-{s}.png", .{ dir, ts }) catch return false;
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

    // Refresh latest.png so "latest screenshot" always points at the most
    // recent shot, regardless of which capture binding produced it.
    var latest_buf: [512:0]u8 = undefined;
    if (std.fmt.bufPrint(&latest_buf, "{s}/latest.png", .{dir})) |latest| {
        if (latest.len < latest_buf.len) {
            latest_buf[latest.len] = 0;
            teru.png.write(server.zig_allocator, @ptrCast(latest_buf[0..latest.len :0]), crop, cw, ch) catch {};
        }
    } else |_| {}

    // Copy the cropped PNG to the Wayland clipboard.
    const copied = copyToClipboard(server, path);
    var msg_buf: [200]u8 = undefined;
    const msg = if (copied)
        (std.fmt.bufPrint(&msg_buf, "Area saved + copied to clipboard ({d}x{d})", .{ cw, ch }) catch "Area saved + copied to clipboard")
    else
        (std.fmt.bufPrint(&msg_buf, "Area saved ({d}x{d}) -> {s}", .{ cw, ch, path }) catch "Area screenshot saved");
    server.setNotification("", msg, "", .normal, 2500);
    return true;
}

/// Generic ARGB framebuffer blit. Pure pixel math — no wlroots or
/// Server state. Lives here rather than in render/software.zig only
/// because it's the sole caller; move if a second consumer appears.
/// blitRect with per-pixel alpha blend — for overlay buffers that are
/// transparent outside their drawn content (keys OSD). Fully-opaque pixels
/// copy, fully-transparent skip, partials blend over the destination.
fn blitRectAlpha(dst: []u32, dst_w: u32, dst_h: u32, src: []const u32, src_w: u32, src_h: u32, off_x: i32, off_y: i32) void {
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
        for (0..cols) |x| {
            const s = src[src_start + x];
            const a: u32 = s >> 24;
            if (a == 0) continue;
            if (a == 0xff) {
                dst[dst_start + x] = s;
                continue;
            }
            const d = dst[dst_start + x];
            const inv: u32 = 255 - a;
            const r = ((s >> 16 & 0xff) * a + (d >> 16 & 0xff) * inv) / 255;
            const g = ((s >> 8 & 0xff) * a + (d >> 8 & 0xff) * inv) / 255;
            const b = ((s & 0xff) * a + (d & 0xff) * inv) / 255;
            dst[dst_start + x] = 0xff000000 | (r << 16) | (g << 8) | b;
        }
    }
}

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
