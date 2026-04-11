//! Shared bar widget renderer for teru + teruwm.
//!
//! Renders parsed BarWidget lists into a SoftwareRenderer framebuffer.
//! Uses a BarData struct for widget content — both standalone teru
//! (Multiplexer) and the compositor (Server) populate this identically.
//! Zero compositor dependencies — pure rendering logic.

const std = @import("std");
const SoftwareRenderer = @import("software.zig").SoftwareRenderer;
const Ui = @import("Ui.zig");
const BarWidget = @import("BarWidget.zig");
const compat = @import("../compat.zig");

/// Data provider for bar widgets. Populated by the caller (Multiplexer or Server).
pub const BarData = struct {
    // Workspace state
    workspace_active: u8 = 0,
    workspace_has_nodes: [10]bool = [_]bool{false} ** 10,
    workspace_names: [10][]const u8 = [_][]const u8{
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
    },

    // Focused pane/window
    title: []const u8 = "shell",

    // Layout
    layout_char: u8 = 'M',

    // Pane count
    pane_count: u16 = 0,
};

/// Render a section (left/center/right) of widgets into the framebuffer.
pub fn renderWidgets(
    cpu: *SoftwareRenderer,
    widgets: []BarWidget.Widget,
    data: *const BarData,
    start_x: usize,
    y: usize,
    max_x: usize,
) usize {
    var x = start_x;
    const cw: usize = cpu.cell_width;
    const s = &cpu.scheme;

    for (widgets) |*w| {
        switch (w.kind) {
            .workspaces => {
                for (0..10) |wi| {
                    if (!data.workspace_has_nodes[wi] and wi != data.workspace_active) continue;
                    const ws_char: u8 = if (wi < 9) '1' + @as(u8, @intCast(wi)) else '0';
                    const color = if (wi == data.workspace_active) s.cursor else s.ansi[8];
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
                for (data.title) |ch| {
                    if (ch < 32 or ch > 126) continue;
                    Ui.blitCharAt(cpu, ch, x, y, s.fg);
                    x += cw;
                    if (x >= max_x) break;
                }
            },
            .layout => {
                Ui.blitCharAt(cpu, '[', x, y, s.ansi[8]);
                x += cw;
                Ui.blitCharAt(cpu, data.layout_char, x, y, s.ansi[5]);
                x += cw;
                Ui.blitCharAt(cpu, ']', x, y, s.ansi[8]);
                x += cw;
            },
            .clock => {
                const wall = libc.time(null);
                var buf: [16]u8 = undefined;
                const time_str = if (wall > 0) std.fmt.bufPrint(&buf, "{d}:{d:0>2}", .{
                    @divTrunc(@mod(@as(u64, @intCast(wall)), 86400), 3600),
                    @divTrunc(@mod(@as(u64, @intCast(wall)), 3600), 60),
                }) catch "??:??" else "??:??";
                for (time_str) |ch| {
                    Ui.blitCharAt(cpu, ch, x, y, s.ansi[4]);
                    x += cw;
                }
            },
            .panes => {
                var buf: [16]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d} panes", .{data.pane_count}) catch "";
                for (text) |ch| {
                    Ui.blitCharAt(cpu, ch, x, y, s.ansi[6]);
                    x += cw;
                }
            },
            .mem => {
                x = renderMemWidget(cpu, x, y, cw, s);
            },
            .exec => {
                for (w.cache[0..w.cache_len]) |ch| {
                    if (ch < 32 or ch > 126) continue;
                    Ui.blitCharAt(cpu, ch, x, y, s.fg);
                    x += cw;
                    if (x >= max_x) break;
                }
            },
            .text => {
                for (w.arg) |ch| {
                    if (ch < 32 or ch > 126) continue;
                    Ui.blitCharAt(cpu, ch, x, y, s.ansi[8]);
                    x += cw;
                    if (x >= max_x) break;
                }
            },
        }
    }
    return x;
}

/// Measure the pixel width of rendered widgets (for centering/right-alignment).
pub fn measureWidgets(widgets: []BarWidget.Widget, data: *const BarData, cw: usize) usize {
    var total: usize = 0;
    for (widgets) |*w| {
        total += switch (w.kind) {
            .workspaces => blk: {
                var n: usize = 0;
                for (0..10) |wi| {
                    if (data.workspace_has_nodes[wi] or wi == data.workspace_active) n += 1;
                }
                break :blk (n * 2 + 1) * cw;
            },
            .title => data.title.len * cw,
            .layout => 3 * cw,
            .clock => 5 * cw,
            .panes => 8 * cw,
            .mem => 8 * cw,
            .exec => @as(usize, w.cache_len) * cw,
            .text => w.arg.len * cw,
        };
    }
    return total;
}

/// Read /proc/meminfo and render RAM percentage.
fn renderMemWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype) usize {
    var x = start_x;
    var mem_buf: [512]u8 = undefined;
    const mem_str = blk: {
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
    for (mem_str) |ch| {
        Ui.blitCharAt(cpu, ch, x, y, s.ansi[2]);
        x += cw;
    }
    return x;
}

fn parseMemLine(data: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.indexOf(u8, data, key) orelse return null;
    var i = idx + key.len;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) i += 1;
    var val: u64 = 0;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        val = val * 10 + (data[i] - '0');
    }
    return val;
}

const libc = struct {
    extern "c" fn time(timer: ?*i64) callconv(.c) i64;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int;
    extern "c" fn close(fd: c_int) callconv(.c) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;
};
