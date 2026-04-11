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
const Ui = teru.Ui;
const LayoutEngine = teru.LayoutEngine;
const BarWidget = @import("BarWidget.zig");
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const compat = teru.compat;

// C stdlib externs (Zig 0.16 removed std.c.time/open/read/close)
const libc = struct {
    extern "c" fn time(timer: ?*i64) callconv(.c) i64;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int;
    extern "c" fn close(fd: c_int) callconv(.c) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;
};

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

pub fn create(server: *Server) ?*Bar {
    const allocator = server.zig_allocator;
    const cell_w: u32 = if (server.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (server.font_atlas) |fa| fa.cell_height else 16;
    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(server.output_layout)));
    const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(server.output_layout)));
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

    // Bottom bar disabled by default (user enables via config)
    bar.bottom.enabled = false;

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

/// Render both bars from compositor state.
pub fn render(self: *Bar, server: *Server) void {
    if (self.top.enabled) {
        self.renderBar(&self.top, server);
        wlr.wlr_scene_buffer_set_buffer_with_damage(self.top.scene_buffer, self.top.pixel_buffer, null);
    }
    if (self.bottom.enabled) {
        self.renderBar(&self.bottom, server);
        wlr.wlr_scene_buffer_set_buffer_with_damage(self.bottom.scene_buffer, self.bottom.pixel_buffer, null);
    }
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

    // Separator line (top pixel row for bottom bar, bottom for top bar)
    if (fb_w > 0 and total >= fb_w) {
        @memset(cpu.framebuffer[0..fb_w], s.selection_bg);
    }

    const text_y: usize = 2;

    // ── Left section ──
    var left_x: usize = 4;
    for (inst.left.widgets.items[0..inst.left.widgets.count]) |*w| {
        left_x = self.renderWidget(cpu, w, server, left_x, text_y, cw, fb_w / 3);
    }

    // ── Right section (render right-to-left) ──
    var right_buf: [256]u8 = undefined;
    var right_len: usize = 0;
    for (inst.right.widgets.items[0..inst.right.widgets.count]) |*w| {
        const text = self.evaluateWidget(w, server, &right_buf, right_len);
        right_len += text.len;
    }
    var right_x: usize = if (fb_w > right_len * cw + cw * 2) fb_w - right_len * cw - cw * 2 else 0;
    for (inst.right.widgets.items[0..inst.right.widgets.count]) |*w| {
        right_x = self.renderWidget(cpu, w, server, right_x, text_y, cw, fb_w);
    }

    // ── Center section ──
    var center_buf: [256]u8 = undefined;
    var center_len: usize = 0;
    for (inst.center.widgets.items[0..inst.center.widgets.count]) |*w| {
        const text = self.evaluateWidget(w, server, &center_buf, center_len);
        center_len += text.len;
    }
    var center_x: usize = if (fb_w > center_len * cw) (fb_w - center_len * cw) / 2 else 0;
    for (inst.center.widgets.items[0..inst.center.widgets.count]) |*w| {
        center_x = self.renderWidget(cpu, w, server, center_x, text_y, cw, fb_w);
    }
}

/// Render a single widget at position x, return new x.
fn renderWidget(_: *Bar, cpu: *SoftwareRenderer, w: *BarWidget.Widget, server: *Server, start_x: usize, y: usize, cw: usize, max_x: usize) usize {
    var x = start_x;
    const s = &cpu.scheme;

    switch (w.kind) {
        .workspaces => {
            for (0..10) |wi| {
                const ws = &server.layout_engine.workspaces[wi];
                const has_nodes = ws.node_ids.items.len > 0;
                const is_active = wi == server.layout_engine.active_workspace;
                if (!has_nodes and !is_active) continue;

                const ws_char: u8 = if (wi < 9) '1' + @as(u8, @intCast(wi)) else '0';
                const color = if (is_active) s.cursor else s.ansi[8];
                Ui.blitCharAt(cpu, ' ', x, y, s.bg);
                x += cw;
                Ui.blitCharAt(cpu, ws_char, x, y, color);
                x += cw;
                if (x >= max_x) break;
            }
            Ui.blitCharAt(cpu, ' ', x, y, s.bg);
            x += cw;
        },
        .title => {
            if (server.focused_terminal) |tp| {
                const title = if (tp.pane.vt.title_len > 0)
                    tp.pane.vt.title[0..tp.pane.vt.title_len]
                else
                    "shell";
                for (title) |c| {
                    if (c < 32 or c > 126) continue;
                    Ui.blitCharAt(cpu, c, x, y, s.fg);
                    x += cw;
                    if (x >= max_x) break;
                }
            } else if (server.focused_view) |view| {
                const title = wlr.miozu_xdg_toplevel_title(view.toplevel) orelse "window";
                var j: usize = 0;
                while (title[j] != 0 and j < 64) : (j += 1) {
                    Ui.blitCharAt(cpu, title[j], x, y, s.fg);
                    x += cw;
                    if (x >= max_x) break;
                }
            }
        },
        .layout => {
            const active_ws = server.layout_engine.getActiveWorkspace();
            const ch: u8 = switch (active_ws.layout) {
                .master_stack => 'M',
                .grid => 'G',
                .monocle => '#',
                .dishes => 'D',
                .accordion => 'A',
                .spiral => 'S',
                .three_col => '3',
                .columns => '|',
            };
            Ui.blitCharAt(cpu, '[', x, y, s.ansi[8]);
            x += cw;
            Ui.blitCharAt(cpu, ch, x, y, s.ansi[5]); // magenta
            x += cw;
            Ui.blitCharAt(cpu, ']', x, y, s.ansi[8]);
            x += cw;
        },
        .clock => {
            // HH:MM from monotonic timestamp (UTC offset approximation)
            const now_ns = compat.monotonicNow();
            const now_s: u64 = @intCast(@divTrunc(now_ns, 1_000_000_000));
            // Use raw C time() for wall clock
            const wall = libc.time(null);
            var buf: [16]u8 = undefined;
            const time_str = if (wall > 0) std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{
                @divTrunc(@mod(@as(u64, @intCast(wall)), 86400), 3600),
                @divTrunc(@mod(@as(u64, @intCast(wall)), 3600), 60),
            }) catch "??:??" else blk: {
                _ = now_s;
                break :blk "??:??";
            };
            for (time_str) |c| {
                Ui.blitCharAt(cpu, c, x, y, s.ansi[4]); // blue
                x += cw;
            }
        },
        .panes => {
            const count = server.nodes.countInWorkspace(server.layout_engine.active_workspace);
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d} panes", .{count}) catch "";
            for (text) |c| {
                Ui.blitCharAt(cpu, c, x, y, s.ansi[6]); // cyan
                x += cw;
            }
        },
        .mem => {
            x = renderMemWidget(cpu, x, y, cw, s);
        },
        .exec => {
            // Use cached output (updated by timer)
            for (w.cache[0..w.cache_len]) |c| {
                if (c < 32 or c > 126) continue;
                Ui.blitCharAt(cpu, c, x, y, s.fg);
                x += cw;
                if (x >= max_x) break;
            }
        },
        .text => {
            for (w.arg) |c| {
                if (c < 32 or c > 126) continue;
                Ui.blitCharAt(cpu, c, x, y, s.ansi[8]); // gray for separators
                x += cw;
                if (x >= max_x) break;
            }
        },
    }
    return x;
}

/// Evaluate a widget to text (for measuring width in right/center alignment).
fn evaluateWidget(_: *Bar, w: *BarWidget.Widget, server: *Server, buf: *[256]u8, offset: usize) []const u8 {
    _ = buf;
    _ = offset;
    return switch (w.kind) {
        .workspaces => "1 2 3 ", // approximate width
        .title => if (server.focused_terminal) |tp|
            (if (tp.pane.vt.title_len > 0) tp.pane.vt.title[0..tp.pane.vt.title_len] else "shell")
        else
            "window",
        .layout => "[M]",
        .clock => "00:00",
        .panes => "0 panes",
        .mem => "RAM: 00%",
        .exec => w.cache[0..w.cache_len],
        .text => w.arg,
    };
}

/// Read /proc/meminfo and render RAM percentage.
fn renderMemWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype) usize {
    var x = start_x;
    // Read /proc/meminfo (fast, no fork)
    var mem_buf: [512]u8 = undefined;
    const mem_str = blk: {
        // Use C open/read for simplicity (Zig 0.16 linux syscalls use usize fds)
        const fd = libc.open("/proc/meminfo", 0, 0);
        if (fd < 0) break :blk "RAM: ?%";
        defer _ = libc.close(fd);
        const n = libc.read(fd, &mem_buf, mem_buf.len);
        if (n <= 0) break :blk "RAM: ?%";
        const data = mem_buf[0..@as(usize, @intCast(n))];
        const total = parseMemLine(data, "MemTotal:") orelse break :blk "RAM: ?%";
        const available = parseMemLine(data, "MemAvailable:") orelse break :blk "RAM: ?%";
        if (total == 0) break :blk "RAM: 0%";
        const used_pct = 100 - (available * 100 / total);
        var pct_buf: [16]u8 = undefined;
        break :blk std.fmt.bufPrint(&pct_buf, "RAM: {d}%", .{used_pct}) catch "RAM: ?%";
    };
    for (mem_str) |c| {
        Ui.blitCharAt(cpu, c, x, y, s.ansi[2]); // green
        x += cw;
    }
    return x;
}

fn parseMemLine(data: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, data, key) orelse return null;
    var i = idx + key.len;
    // Skip whitespace
    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) i += 1;
    // Parse number
    var val: u64 = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        val = val * 10 + (data[i] - '0');
    }
    return val;
}

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
