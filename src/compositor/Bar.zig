//! Configurable dual status bar for the miozu compositor.
//!
//! Renders top and/or bottom bars as wlr_scene_buffers. Each bar has
//! left/center/right sections containing parsed widget format strings.
//! Widgets are evaluated from compositor state (workspaces, title, etc.)
//! or from cached shell command output ({exec:N:cmd}).
//!
//! Config (teru.conf):
//!   [bar.top]
//!   left = {workspaces}
//!   center = {title}
//!   right = {clock}
//!
//!   [bar.bottom]
//!   left = {exec:2:sensors | grep Tctl}
//!   center = {panes}
//!   right = {mem}

const std = @import("std");
const teru = @import("teru");
const SoftwareRenderer = teru.render.SoftwareRenderer;
const BarWidget = teru.render.BarWidget;
const BarRenderer = teru.render.BarRenderer;
const BarData = BarRenderer.BarData;
const LayoutEngine = teru.LayoutEngine;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const Bar = @This();

const Section = struct {
    widgets: BarWidget.WidgetList = .{},
};

const BarInstance = struct {
    renderer: SoftwareRenderer,
    pixel_buffer: *wlr.wlr_buffer,
    scene_buffer: *wlr.wlr_scene_buffer,
    left: Section = .{},
    center: Section = .{},
    right: Section = .{},
    enabled: bool = false,
};

top: BarInstance,
bottom: BarInstance,
bar_height: u32,
output_width: u32,
output_height: u32,

/// Last-render signature — render() skips the SIMD blit + buffer
/// commit when nothing user-visible has changed. Call sites
/// (focus-change, ws-switch, push-widget update) each invoked
/// render() multiple times per action; perf review flagged the
/// redundant ~400 µs per spurious call. Bar content is deterministic
/// from a handful of fields — hashing them is cheaper than rendering.
last_top_sig: u64 = 0,
last_bottom_sig: u64 = 0,
/// Forces the next render regardless of signature. Set on config
/// reload + dimension change; cleared by the first render after.
dirty: bool = true,

pub fn create(server: *Server) ?*Bar {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const dims = server.activeOutputDims();
    const out_w: u32 = dims.w;
    const out_h: u32 = dims.h;
    const bar_h: u32 = cell_h + 4;

    const bar = allocator.create(Bar) catch return null;

    // Create top bar
    bar.top = createBarInstance(server, allocator, out_w, bar_h, cell_w, cell_h, 0) orelse {
        allocator.destroy(bar);
        return null;
    };

    // Create bottom bar
    bar.bottom = createBarInstance(server, allocator, out_w, bar_h, cell_w, cell_h, @intCast(out_h - bar_h)) orelse {
        allocator.destroy(bar);
        return null;
    };

    bar.bar_height = bar_h;
    bar.output_width = out_w;
    bar.output_height = out_h;

    // Set default widget layout
    bar.top.left.widgets = BarWidget.parse(BarWidget.default_top_left);
    bar.top.center.widgets = BarWidget.parse(BarWidget.default_top_center);
    bar.top.right.widgets = BarWidget.parse(BarWidget.default_top_right);
    bar.top.enabled = true;

    // Bottom bar enabled by default with system info widgets
    bar.bottom.left.widgets = BarWidget.parse(BarWidget.default_bottom_left);
    bar.bottom.right.widgets = BarWidget.parse(BarWidget.default_bottom_right);
    bar.bottom.enabled = true;

    return bar;
}

fn createBarInstance(server: *Server, allocator: std.mem.Allocator, width: u32, height: u32, cell_w: u32, cell_h: u32, y_pos: c_int) ?BarInstance {
    const pixel_buffer = wlr.miozu_pixel_buffer_create(@intCast(width), @intCast(height)) orelse return null;
    const scene_tree_root = wlr.miozu_scene_tree(server.scene) orelse return null;
    const scene_buffer = wlr.wlr_scene_buffer_create(scene_tree_root, pixel_buffer) orelse return null;

    if (wlr.miozu_scene_buffer_node(scene_buffer)) |node| {
        wlr.wlr_scene_node_set_position(node, 0, y_pos);
    }

    var renderer = SoftwareRenderer.init(allocator, width, height, cell_w, cell_h) catch return null;
    if (wlr.miozu_pixel_buffer_data(pixel_buffer)) |data| {
        const needed = @as(usize, width) * @as(usize, height);
        if (needed > 0) renderer.framebuffer = data[0..needed];
    }
    if (server.font_atlas) |fa| {
        renderer.glyph_atlas = fa.atlas_data;
        renderer.atlas_width = fa.atlas_width;
        renderer.atlas_height = fa.atlas_height;
    }

    return BarInstance{
        .renderer = renderer,
        .pixel_buffer = pixel_buffer,
        .scene_buffer = scene_buffer,
    };
}

/// Show/hide each bar's scene node to match `.enabled`.
/// Call this after toggling `bar.top.enabled` or `bar.bottom.enabled`.
pub fn updateVisibility(self: *Bar) void {
    if (wlr.miozu_scene_buffer_node(self.top.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, self.top.enabled);
    }
    if (wlr.miozu_scene_buffer_node(self.bottom.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, self.bottom.enabled);
    }
}

/// Render both bars from compositor state.
pub fn render(self: *Bar, server: *Server) void {
    const sig = self.barSignature(server);
    const force = self.dirty;
    self.dirty = false;

    if (self.top.enabled and (force or sig != self.last_top_sig)) {
        self.renderBar(&self.top, server);
        wlr.wlr_scene_buffer_set_buffer_with_damage(self.top.scene_buffer, self.top.pixel_buffer, null);
        self.last_top_sig = sig;
    }
    if (self.bottom.enabled and (force or sig != self.last_bottom_sig)) {
        self.renderBar(&self.bottom, server);
        wlr.wlr_scene_buffer_set_buffer_with_damage(self.bottom.scene_buffer, self.bottom.pixel_buffer, null);
        self.last_bottom_sig = sig;
    }
}

/// Cheap u64 fingerprint of the user-visible bar state. Collisions
/// are benign (missed repaint on a field that didn't actually move
/// the displayed value — e.g. sub-microsecond avg-frame drift that
/// rounds to the same rendered digit). Intentionally omits perf
/// microstats so sub-µs frame jitter doesn't cause sustained redraw.
fn barSignature(self: *Bar, server: *Server) u64 {
    _ = self;
    const prime: u64 = 0x9e3779b97f4a7c15;
    var h: u64 = prime;
    h ^= @intCast(server.layout_engine.active_workspace);
    h *%= prime;

    // Workspace occupancy + urgency bitfield, one pass. Urgency reads
    // the pre-maintained per-ws counter (O(1)) instead of rescanning
    // 256 slots.
    var ws_bits: u64 = 0;
    for (0..10) |wi| {
        if (server.layout_engine.workspaces[wi].node_ids.items.len > 0)
            ws_bits |= (@as(u64, 1) << @intCast(wi));
        if (server.nodes.urgent_count_per_ws[wi] > 0)
            ws_bits |= (@as(u64, 1) << @intCast(wi + 16));
    }
    h ^= ws_bits;
    h *%= prime;

    // Layout char + pane count + title (pointer-identity check — when
    // a client retitles, the buffer address typically changes, and
    // even false collisions on the pointer mean "same title").
    const active_ws = server.layout_engine.getActiveWorkspace();
    h ^= @intFromEnum(active_ws.layout);
    h *%= prime;
    h ^= server.nodes.countInWorkspace(server.layout_engine.active_workspace);
    h *%= prime;
    if (server.focused_terminal) |tp| {
        h ^= @intFromPtr(&tp.pane.vt.title);
        h ^= tp.pane.vt.title_len;
    }
    h *%= prime;

    // Keymap name — changes on layout switch.
    h ^= @intFromPtr(server.active_keymap_name.ptr);
    h ^= server.active_keymap_name.len;
    h *%= prime;

    // Push widget used-mask, with a cheap short-circuit: if the first
    // slot's unused and the internal push_widget_count (maintained by
    // set/deletePushWidget) is zero, skip the 32-slot iteration.
    if (server.countPushWidgets() > 0) {
        var pw_mask: u64 = 0;
        for (server.push_widgets, 0..) |w, i| {
            if (w.used) pw_mask |= (@as(u64, 1) << @intCast(i % 64));
        }
        h ^= pw_mask;
    }
    return h;
}

fn renderBar(self: *Bar, inst: *BarInstance, server: *Server) void {
    const cpu = &inst.renderer;
    const s = &cpu.scheme;
    const cw: usize = cpu.cell_width;
    const fb_w: usize = self.output_width;
    const bar_h: usize = self.bar_height;

    // Clear bar background
    const total = @min(fb_w * bar_h, cpu.framebuffer.len);
    @memset(cpu.framebuffer[0..total], s.bg);

    // Separator line
    if (fb_w > 0 and total >= fb_w) {
        @memset(cpu.framebuffer[0..fb_w], s.selection_bg);
    }

    // Build BarData from compositor state
    const data = self.buildBarData(server);
    const text_y: usize = 2;

    // ── Left section ──
    _ = BarRenderer.renderWidgets(cpu, inst.left.widgets.items[0..inst.left.widgets.count], &data, 4, text_y, fb_w / 3);

    // ── Right section ──
    const right_w = BarRenderer.measureWidgets(inst.right.widgets.items[0..inst.right.widgets.count], &data, cw);
    const right_x: usize = if (fb_w > right_w + cw * 2) fb_w - right_w - cw * 2 else 0;
    _ = BarRenderer.renderWidgets(cpu, inst.right.widgets.items[0..inst.right.widgets.count], &data, right_x, text_y, fb_w);

    // ── Center section ──
    const center_w = BarRenderer.measureWidgets(inst.center.widgets.items[0..inst.center.widgets.count], &data, cw);
    const center_x: usize = if (fb_w > center_w) (fb_w - center_w) / 2 else 0;
    _ = BarRenderer.renderWidgets(cpu, inst.center.widgets.items[0..inst.center.widgets.count], &data, center_x, text_y, fb_w);
}

/// Build BarData from compositor state.
fn buildBarData(_: *Bar, server: *Server) BarData {
    var data = BarData{};
    data.workspace_active = server.layout_engine.active_workspace;

    for (0..10) |wi| {
        data.workspace_has_nodes[wi] = server.layout_engine.workspaces[wi].node_ids.items.len > 0;
        data.workspace_urgent[wi] = server.nodes.anyUrgentOnWorkspace(@intCast(wi));
    }

    if (server.focused_terminal) |tp| {
        data.title = if (tp.pane.vt.title_len > 0) tp.pane.vt.title[0..tp.pane.vt.title_len] else "shell";
    }

    const active_ws = server.layout_engine.getActiveWorkspace();
    data.layout_char = switch (active_ws.layout) {
        .master_stack => 'M',
        .grid => 'G',
        .monocle => '#',
        .dishes => 'D',
        .accordion => 'A',
        .spiral => 'S',
        .three_col => '3',
        .columns => '|',
    };

    data.pane_count = server.nodes.countInWorkspace(server.layout_engine.active_workspace);

    // Performance stats
    data.frame_avg_us = server.perf.avgFrameUs();
    data.frame_max_us = server.perf.frame_time_max_us;
    if (data.frame_max_us == std.math.maxInt(u64)) data.frame_max_us = 0;
    data.pty_bytes_total = server.perf.pty_bytes;

    // Active keyboard layout short name. xkb layout names look like
    // "English (US)", "Ukrainian", "English (Dvorak)"; we shorten them.
    data.keymap = shortKeymap(server.active_keymap_name);

    // Color thresholds come from the user's config file ([bar.thresholds]).
    data.thresholds = server.wm_config.bar_thresholds;

    // Push widgets registered via MCP. Pass the whole fixed-size array;
    // the renderer filters by `used` and matches on name.
    data.push_widgets = &server.push_widgets;

    return data;
}

/// Thread-local storage for the short form returned by shortKeymap.
threadlocal var keymap_buf: [8]u8 = undefined;

/// Format an XKB layout identifier for display in the bar.
/// Prefers the raw code extracted upstream from xkb_keymap_get_as_string
/// (`us`, `ua`, `us(dvorak)`). If a variant is present, uses the variant
/// (Us(dvorak) → Dv). Otherwise uppercases the first letter:
///   "us" → "Us", "ua" → "Ua", "us(dvorak)" → "Dv"
///   "English (US)" (friendly-name fallback) → "Us"
fn shortKeymap(name: []const u8) []const u8 {
    if (name.len == 0) return "";

    // Prefer the variant in parens if there is one.
    var src: []const u8 = name;
    if (std.mem.lastIndexOfScalar(u8, name, '(')) |lp| {
        if (std.mem.indexOfScalarPos(u8, name, lp + 1, ')')) |rp| {
            if (rp > lp + 1) src = name[lp + 1 .. rp];
        }
    }

    var i: usize = 0;
    while (i < src.len and !std.ascii.isAlphabetic(src[i])) i += 1;
    if (i >= src.len) return "";

    keymap_buf[0] = std.ascii.toUpper(src[i]);
    if (i + 1 < src.len and std.ascii.isAlphabetic(src[i + 1])) {
        keymap_buf[1] = std.ascii.toLower(src[i + 1]);
        return keymap_buf[0..2];
    }
    return keymap_buf[0..1];
}

test "shortKeymap raw xkb codes" {
    // Raw codes from xkb_keymap_get_as_string
    try std.testing.expectEqualStrings("Us", shortKeymap("us"));
    try std.testing.expectEqualStrings("Ua", shortKeymap("ua"));
    try std.testing.expectEqualStrings("Dv", shortKeymap("us(dvorak)"));
    try std.testing.expectEqualStrings("Co", shortKeymap("us(colemak)"));
    // Friendly-name fallback
    try std.testing.expectEqualStrings("Dv", shortKeymap("English (Dvorak)"));
    try std.testing.expectEqualStrings("Us", shortKeymap("English (US)"));
    try std.testing.expectEqualStrings("Uk", shortKeymap("Ukrainian"));
    try std.testing.expectEqualStrings("", shortKeymap(""));
}

// Widget rendering moved to libteru's src/render/BarRenderer.zig (shared with standalone teru).

/// Get the total height consumed by enabled bars.
pub fn totalHeight(self: *Bar) u32 {
    var h: u32 = 0;
    if (self.top.enabled) h += self.bar_height;
    if (self.bottom.enabled) h += self.bar_height;
    return h;
}

/// Get the Y offset for tiling (below top bar).
pub fn tilingOffsetY(self: *Bar) u32 {
    return if (self.top.enabled) self.bar_height else 0;
}

/// Configure from format strings (called after config load).
pub fn configure(self: *Bar, top_left: ?[]const u8, top_center: ?[]const u8, top_right: ?[]const u8, bottom_left: ?[]const u8, bottom_center: ?[]const u8, bottom_right: ?[]const u8) void {
    if (top_left) |s| self.top.left.widgets = BarWidget.parse(s);
    if (top_center) |s| self.top.center.widgets = BarWidget.parse(s);
    if (top_right) |s| self.top.right.widgets = BarWidget.parse(s);

    if (bottom_left) |s| { self.bottom.left.widgets = BarWidget.parse(s); self.bottom.enabled = true; }
    if (bottom_center) |s| { self.bottom.center.widgets = BarWidget.parse(s); self.bottom.enabled = true; }
    if (bottom_right) |s| { self.bottom.right.widgets = BarWidget.parse(s); self.bottom.enabled = true; }
}
