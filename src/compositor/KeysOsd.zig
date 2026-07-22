//! Keystroke OSD — shows pressed key combos as a corner overlay, for
//! screencasts and streaming ("what did he just press?").
//!
//! The display logic (combo composition, combos-only privacy filter, repeat
//! collapse, linger/expiry) lives in the vendored `klava` engine; this file
//! is the teruwm consumer: a fixed-size `wlr_scene_buffer` overlay (mirrors
//! LeaderPanel's surface plumbing), fed from the top of `handleKeyEvent`, so
//! it sees every hardware key — including chords the compositor consumes and
//! keys swallowed by leader/launcher modes. The compositor's own xkb state
//! resolves keysyms, so the OSD shows the user's real layout (Dvorak, …) with
//! zero extra processes and zero /dev/input permissions.
//!
//! CPU discipline (.claude/rules and cpu-performance): ONE one-shot
//! wl_event_loop timer, armed only while entries are visible, re-armed to the
//! next expiry deadline; when the display empties, the node is disabled and
//! the timer stays disarmed. Idle cost with the OSD on but no typing: zero
//! wakeups. The timer source is released in Server.releaseTimers (NOT deinit
//! — the loop is already freed there).
//!
//! The buffer is transparent (ARGB 0x00000000) except for the drawn chips;
//! it's fixed-size, so feeding a key never reallocates — the render just
//! repaints the same buffer. Non-ASCII labels blit as '?' via klava's
//! `.ascii` style (Ui-blit-family renderers are ASCII-only today).

const std = @import("std");
const teru = @import("teru");
const klava = @import("klava");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const WmConfig = @import("WmConfig.zig");
const SoftwareRenderer = teru.render.SoftwareRenderer;

const KeysOsd = @This();

/// Widest the OSD can grow, in text cells (before glyph scaling).
const max_cells: usize = 64;
/// Vertical padding above/below the text row, in scaled pixels.
const v_pad: usize = 6;
/// Horizontal padding inside a chip, in cells (each side).
const chip_pad_cells: usize = 1;
/// Gap between chips, in cells.
const chip_gap_cells: usize = 1;
/// Margin from the output edges, in pixels.
const margin: i32 = 12;

engine: klava.Klava = .{},
/// Runtime on/off (keybind `keys_osd:toggle` / MCP). Startup value comes
/// from `wm_config.keys_osd` via applyConfig.
active: bool = false,

// Surface (null until first shown; re-created on output/scale change).
renderer: ?SoftwareRenderer = null,
pixel_buffer: ?*wlr.wlr_buffer = null,
scene_buffer: ?*wlr.wlr_scene_buffer = null,
width: u32 = 0,
height: u32 = 0,
/// Scene-layout position, cached for the screenshot composite.
pos_x: i32 = 0,
pos_y: i32 = 0,
scale: u32 = 2,
cell_w: u32 = 8,
cell_h: u32 = 16,

// ── Config / lifecycle ──────────────────────────────────────────

/// Apply `keys_osd_*` config at init and on hot-reload. Recreates the
/// surface so scale/position changes take effect immediately.
pub fn applyConfig(server: *Server) void {
    const cfg = &server.wm_config;
    const osd = &server.keys_osd;
    osd.engine.setOptions(.{
        .combos_only = cfg.keys_osd_combos_only,
        .linger_ms = cfg.keys_osd_linger_ms,
        .style = .ascii,
    });
    destroySurface(server);
    if (cfg.keys_osd and !osd.active) {
        osd.active = true;
    }
}

pub fn toggle(server: *Server) void {
    setActive(server, !server.keys_osd.active);
}

pub fn setActive(server: *Server, on: bool) void {
    const osd = &server.keys_osd;
    if (osd.active == on) return;
    osd.active = on;
    if (!on) {
        osd.engine.clear();
        disarmTimer(server);
        hide(osd);
        server.scheduleRender();
    }
    // On: nothing to draw yet — the surface appears on the first combo.
}

/// Tear down the scene node + buffer. Safe to call with none created.
pub fn destroySurface(server: *Server) void {
    const osd = &server.keys_osd;
    if (osd.scene_buffer) |sb| {
        if (wlr.miozu_scene_buffer_node(sb)) |node| wlr.wlr_scene_node_destroy(node);
    }
    if (osd.pixel_buffer) |pb| wlr.wlr_buffer_drop(pb);
    // renderer.framebuffer was adopted from the wlr buffer — not ours to free.
    osd.renderer = null;
    osd.pixel_buffer = null;
    osd.scene_buffer = null;
    osd.width = 0;
    osd.height = 0;
}

// ── Input feed ──────────────────────────────────────────────────

/// Tap for Keyboard.handleKeyEvent: resolve modifiers from the event's own
/// xkb state and feed the engine. Called only while `active`.
pub fn feedFromXkb(server: *Server, keysym: u32, xkb_st: *wlr.xkb_state, pressed: bool) void {
    const mods = klava.Mods{
        .super = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0,
        .ctrl = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_CTRL, wlr.XKB_STATE_MODS_EFFECTIVE) > 0,
        .alt = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_ALT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0,
        .shift = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0,
    };
    feed(server, keysym, mods, pressed);
}

/// Feed one key event (also the MCP test-tool entry point — same path as
/// the live tap, minus the xkb decode).
pub fn feed(server: *Server, keysym: u32, mods: klava.Mods, pressed: bool) void {
    const osd = &server.keys_osd;
    if (!osd.active) return;
    const now = nowMs();
    if (osd.engine.feed(.{ .keysym = keysym, .mods = mods, .pressed = pressed, .time_ms = now }) == .ignored) return;
    render(server, now);
    armTimer(server, now);
    server.scheduleRender();
}

// ── Expiry timer (one-shot, re-armed; never ticks while idle) ───

fn nowMs() u64 {
    return @intCast(@divTrunc(teru.compat.monotonicNow(), std.time.ns_per_ms));
}

fn armTimer(server: *Server, now: u64) void {
    const deadline = server.keys_osd.engine.nextDeadlineMs(now) orelse {
        disarmTimer(server);
        return;
    };
    if (server.keys_osd_timer_src == null) {
        const loop = server.event_loop orelse return;
        server.keys_osd_timer_src = wlr.wl_event_loop_add_timer(loop, onTimer, @ptrCast(server));
    }
    if (server.keys_osd_timer_src) |src| {
        // +1 so the deadline has strictly passed when the callback prunes.
        const delay_ms: c_int = @intCast(@min(deadline - now + 1, std.math.maxInt(c_int)));
        _ = wlr.wl_event_source_timer_update(src, delay_ms);
    }
}

fn disarmTimer(server: *Server) void {
    if (server.keys_osd_timer_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, 0);
    }
}

fn onTimer(data: ?*anyopaque) callconv(.c) c_int {
    const server: *Server = @ptrCast(@alignCast(data orelse return 0));
    const osd = &server.keys_osd;
    const now = nowMs();
    _ = osd.engine.pruneExpired(now);
    if (osd.engine.count() == 0) {
        hide(osd);
    } else {
        render(server, now);
        armTimer(server, now);
    }
    server.scheduleRender();
    return 0;
}

fn hide(osd: *KeysOsd) void {
    if (osd.scene_buffer) |sb| {
        if (wlr.miozu_scene_buffer_node(sb)) |node| wlr.wlr_scene_node_set_enabled(node, false);
    }
}

// ── Surface + render ────────────────────────────────────────────

/// True while the overlay is on screen (used by the screenshot composite).
pub fn isShown(osd: *const KeysOsd) bool {
    return osd.active and osd.scene_buffer != null and osd.engine.count() > 0;
}

fn ensureSurface(server: *Server) bool {
    const osd = &server.keys_osd;
    const cw: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const ch: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const scale: u32 = @max(1, @min(4, server.wm_config.keys_osd_scale));
    const dims = server.activeOutputDims();
    const margin2: u32 = @intCast(margin * 2);
    const width_cap: u32 = if (dims.w > margin2) dims.w - margin2 else dims.w;
    const want_w: u32 = @min(@as(u32, @intCast(max_cells * cw * scale)), width_cap);
    const want_h: u32 = @intCast(ch * scale + v_pad * 2);

    if (osd.renderer != null and osd.width == want_w and osd.height == want_h and osd.scale == scale) {
        positionSurface(server); // output may have changed size
        return true;
    }
    destroySurface(server);

    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(want_w), @intCast(want_h)) orelse return false;
    const root = wlr.miozu_scene_tree(server.scene) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return false;
    };
    const scene_buffer = wlr.wlr_scene_buffer_create(root, pixel_buffer) orelse {
        wlr.wlr_buffer_drop(pixel_buffer);
        return false;
    };

    var renderer = SoftwareRenderer.init(server.zig_allocator, want_w, want_h, cw, ch) catch {
        if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| wlr.wlr_scene_node_destroy(node);
        wlr.wlr_buffer_drop(pixel_buffer);
        return false;
    };
    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        const needed = @as(usize, want_w) * @as(usize, want_h);
        if (needed > 0) {
            server.zig_allocator.free(renderer.framebuffer); // adopt wlr memory
            renderer.framebuffer = data[0..needed];
        }
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }

    osd.renderer = renderer;
    osd.pixel_buffer = pixel_buffer;
    osd.scene_buffer = scene_buffer;
    osd.width = want_w;
    osd.height = want_h;
    osd.scale = scale;
    osd.cell_w = cw;
    osd.cell_h = ch;
    positionSurface(server);
    return true;
}

/// Anchor the surface to the configured corner, inset by the bars so the
/// OSD never sits on top of them.
fn positionSurface(server: *Server) void {
    const osd = &server.keys_osd;
    const sb = osd.scene_buffer orelse return;
    const dims = server.activeOutputDims();
    var top_inset: i32 = margin;
    var bottom_inset: i32 = margin;
    if (server.bar) |b| {
        if (b.top.enabled) top_inset += @intCast(b.bar_height);
        if (b.bottom.enabled) bottom_inset += @intCast(b.bar_height);
    }
    const w: i32 = @intCast(osd.width);
    const h: i32 = @intCast(osd.height);
    const out_w: i32 = @intCast(dims.w);
    const out_h: i32 = @intCast(dims.h);
    const pos: WmConfig.KeysOsdPos = server.wm_config.keys_osd_pos;
    osd.pos_x = switch (pos) {
        .bottom_right, .top_right => @max(0, out_w - w - margin),
        .bottom_left, .top_left => margin,
    };
    osd.pos_y = switch (pos) {
        .bottom_right, .bottom_left => @max(0, out_h - h - bottom_inset),
        .top_right, .top_left => top_inset,
    };
    if (wlr.miozu_scene_buffer_node(sb)) |node| {
        wlr.wlr_scene_node_set_position(node, osd.pos_x, osd.pos_y);
    }
}

/// Chip layout: which entries fit into `max_cells`, newest kept. Pure math
/// (unit-tested); returns how many of the newest entries to draw.
fn fittingEntries(labels: []const []const u8, budget_cells: usize) usize {
    var used: usize = 0;
    var n: usize = 0;
    var i = labels.len;
    while (i > 0) {
        i -= 1;
        const need = labels[i].len + chip_pad_cells * 2 + (if (n > 0) chip_gap_cells else 0);
        if (used + need > budget_cells) break;
        used += need;
        n += 1;
    }
    return n;
}

fn render(server: *Server, now: u64) void {
    const osd = &server.keys_osd;
    if (!ensureSurface(server)) return;
    const cpu = &(osd.renderer orelse return);
    const s = &cpu.scheme;

    // Transparent canvas; chips are the only opaque pixels.
    teru.compat.memsetU32(cpu.framebuffer, 0x00000000);

    // Collect visible display labels (oldest → newest).
    var texts: [8][64]u8 = undefined;
    var labels: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = osd.engine.iterator(now);
    while (it.next()) |entry| {
        if (n >= labels.len) break;
        labels[n] = entry.displayText(&texts[n]);
        n += 1;
    }
    if (n == 0) {
        hide(osd);
        return;
    }

    const scale: usize = osd.scale;
    const cw: usize = @as(usize, osd.cell_w) * scale;
    const budget_cells: usize = @as(usize, osd.width) / @max(1, cw);
    const keep = fittingEntries(labels[0..n], budget_cells);
    const first = n - keep;

    // Total width in cells, then right-align inside the fixed buffer.
    var total_cells: usize = 0;
    for (labels[first..n], 0..) |lab, i| {
        total_cells += lab.len + chip_pad_cells * 2 + (if (i > 0) chip_gap_cells else 0);
    }
    var x: usize = osd.width -| total_cells * cw;

    // Chips are fully opaque: wlroots treats scene-buffer ARGB as
    // PREMULTIPLIED, so partial alpha with unmultiplied RGB would blend
    // brighter than intended. Only 0x00 (skip) and 0xff (copy) are exact.
    const chip_bg = (s.bg & 0x00ff_ffff) | 0xff000000;
    for (labels[first..n], 0..) |lab, i| {
        if (i > 0) x += chip_gap_cells * cw;
        const chip_w = (lab.len + chip_pad_cells * 2) * cw;
        fillRect(cpu.framebuffer, osd.width, x, 0, chip_w, osd.height, chip_bg);
        // 2px accent baseline so chips read as UI, not stray text.
        fillRect(cpu.framebuffer, osd.width, x, @as(usize, osd.height) -| 2, chip_w, 2, s.cursor);
        var tx = x + chip_pad_cells * cw;
        for (lab) |chr| {
            blitCharScaled(cpu, chr, tx, v_pad, s.fg, scale);
            tx += cw;
        }
        x += chip_w;
    }

    if (osd.scene_buffer) |sb| {
        if (osd.pixel_buffer) |pb| wlr.wlr_scene_buffer_set_buffer_with_damage(sb, pb, null);
        if (wlr.miozu_scene_buffer_node(sb)) |node| {
            wlr.wlr_scene_node_set_enabled(node, true);
            // Re-raise every paint: windows mapped after the OSD's node would
            // otherwise stack above it (scene z = child order).
            wlr.wlr_scene_node_raise_to_top(node);
        }
    }
}

fn fillRect(fb: []u32, fb_w: u32, x: usize, y: usize, w: usize, h: usize, color: u32) void {
    const stride: usize = fb_w;
    var row = y;
    while (row < y + h) : (row += 1) {
        const start = row * stride + x;
        if (start >= fb.len) break;
        const end = @min(start + w, fb.len);
        if (end > start) teru.compat.memsetU32(fb[start..end], color);
    }
}

/// Ui.blitCharAt with nearest-neighbor integer upscaling (atlas stores one
/// size; the OSD wants bigger-than-bar text without re-rasterizing).
fn blitCharScaled(cpu: *SoftwareRenderer, char: u8, screen_x: usize, screen_y: usize, fg: u32, scale: usize) void {
    if (char < 32 or char >= 127) {
        // Non-ASCII bytes shouldn't reach here (klava .ascii style folds
        // them), but stay defensive: draw nothing rather than garbage.
        return;
    }
    if (cpu.atlas_width == 0 or cpu.glyph_atlas.len == 0) return;

    const cw: usize = cpu.cell_width;
    const ch: usize = cpu.cell_height;
    const aw: usize = cpu.atlas_width;
    const fb_w: usize = cpu.width;
    const fb_h: usize = cpu.height;

    const glyph_index: usize = char - 32;
    const glyphs_per_row = if (aw >= cw) aw / cw else return;
    const atlas_x = (glyph_index % glyphs_per_row) * cw;
    const atlas_y = (glyph_index / glyphs_per_row) * ch;

    const fg_r: u16 = @truncate((fg >> 16) & 0xFF);
    const fg_g: u16 = @truncate((fg >> 8) & 0xFF);
    const fg_b: u16 = @truncate(fg & 0xFF);

    for (0..ch * scale) |dy| {
        if (screen_y + dy >= fb_h) break;
        const sy = dy / scale;
        if (atlas_y + sy >= cpu.atlas_height) break;
        const atlas_row_offset = (atlas_y + sy) * aw + atlas_x;
        if (atlas_row_offset + cw > cpu.glyph_atlas.len) break;

        for (0..cw * scale) |dx| {
            if (screen_x + dx >= fb_w) break;
            const alpha: u16 = cpu.glyph_atlas[atlas_row_offset + dx / scale];
            if (alpha == 0) continue;
            const fb_idx = (screen_y + dy) * fb_w + (screen_x + dx);
            if (fb_idx >= cpu.framebuffer.len) continue;
            if (alpha == 255) {
                cpu.framebuffer[fb_idx] = fg | 0xff000000;
            } else {
                const bg = cpu.framebuffer[fb_idx];
                const bg_r: u16 = @truncate((bg >> 16) & 0xFF);
                const bg_g: u16 = @truncate((bg >> 8) & 0xFF);
                const bg_b: u16 = @truncate(bg & 0xFF);
                const inv: u16 = 255 - alpha;
                const r = (fg_r * alpha + bg_r * inv) / 255;
                const g = (fg_g * alpha + bg_g * inv) / 255;
                const b = (fg_b * alpha + bg_b * inv) / 255;
                cpu.framebuffer[fb_idx] = (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
            }
        }
    }
}

// ── Tests (pure math only — display paths run under the E2E harness) ──

test "fittingEntries keeps newest within budget" {
    const labels = [_][]const u8{ "Super+Enter", "Ctrl+Shift+T", "Ctrl+v x3" };
    // Plenty of room: all three fit. Costs: 13, 15(+1 gap? order: newest first),
    // walk is newest→oldest with pad 2 and gap 1 between kept chips.
    try std.testing.expectEqual(@as(usize, 3), fittingEntries(&labels, 64));
    // Tight: only the newest fits ("Ctrl+v x3" + 2 pad = 11).
    try std.testing.expectEqual(@as(usize, 1), fittingEntries(&labels, 12));
    // Nothing fits.
    try std.testing.expectEqual(@as(usize, 0), fittingEntries(&labels, 5));
}

test "fittingEntries exact boundary" {
    const labels = [_][]const u8{ "aa", "bb" };
    // newest "bb": 2+2=4; adding "aa": 2+2+1(gap)=5 → total 9.
    try std.testing.expectEqual(@as(usize, 2), fittingEntries(&labels, 9));
    try std.testing.expectEqual(@as(usize, 1), fittingEntries(&labels, 8));
}

test "klava engine is reachable through the vendored module" {
    var eng = klava.Klava.init(.{});
    _ = eng.feed(.{ .keysym = 'x', .mods = .{ .super = true }, .pressed = true, .time_ms = 10 });
    try std.testing.expectEqual(@as(usize, 1), eng.count());
}
