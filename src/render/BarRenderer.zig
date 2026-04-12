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

    // Performance (compositor only)
    frame_avg_us: u64 = 0,
    frame_max_us: u64 = 0,
    pty_bytes_total: u64 = 0,

    // Active keyboard layout short name (e.g. "Us", "Ua", "Dv").
    // Populated by the compositor from the XKB layout name; empty in
    // standalone teru.
    keymap: []const u8 = "",
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
                // strftime: proper local-time formatting (was: UTC hours only).
                // w.arg is the format string, e.g. "%H:%M" or "%a %Y-%m-%d".
                var wall: i64 = libc.time(null);
                const tm_ptr = libc.localtime(&wall);
                var buf: [64]u8 = undefined;
                var fmt_z: [48]u8 = undefined;
                const fmt_slice = if (w.arg.len > 0 and w.arg.len < fmt_z.len - 1) blk: {
                    @memcpy(fmt_z[0..w.arg.len], w.arg);
                    fmt_z[w.arg.len] = 0;
                    break :blk fmt_z[0..w.arg.len :0];
                } else "%H:%M"[0..5 :0];
                const n = if (tm_ptr) |tm|
                    libc.strftime(&buf, buf.len, fmt_slice.ptr, tm)
                else
                    0;
                const time_str = if (n > 0) buf[0..n] else "??:??";
                for (time_str) |ch| {
                    if (ch < 32 or ch > 126) continue;
                    Ui.blitCharAt(cpu, ch, x, y, s.ansi[4]);
                    x += cw;
                    if (x >= max_x) break;
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
            .cpu => {
                x = renderCpuWidget(cpu, x, y, cw, s, max_x);
            },
            .cputemp => {
                x = renderCpuTempWidget(cpu, x, y, cw, s, max_x);
            },
            .battery => {
                x = renderBatteryWidget(cpu, x, y, cw, s, max_x);
            },
            .keymap => {
                const str = if (data.keymap.len > 0) data.keymap else "";
                for (str) |ch| {
                    if (ch < 32 or ch > 126) continue;
                    Ui.blitCharAt(cpu, ch, x, y, s.ansi[6]);
                    x += cw;
                    if (x >= max_x) break;
                }
            },
            .perf => {
                var buf: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}us/{d}us", .{
                    data.frame_avg_us, data.frame_max_us,
                }) catch "?us";
                for (text) |ch| {
                    const color: u32 = if (data.frame_avg_us > 100) s.ansi[1] // red if slow
                    else if (data.frame_avg_us > 50) s.ansi[3] // yellow
                    else s.ansi[2]; // green
                    Ui.blitCharAt(cpu, ch, x, y, color);
                    x += cw;
                    if (x >= max_x) break;
                }
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
            .cpu => 6 * cw,       // "99%  " worst case
            .cputemp => 6 * cw,   // "99C"
            .battery => 6 * cw,   // "100%"
            .keymap => @max(data.keymap.len, 2) * cw,
            .perf => 12 * cw,
            .exec => @as(usize, w.cache_len) * cw,
            .text => w.arg.len * cw,
        };
    }
    return total;
}

/// Read /proc/meminfo and render used-memory percentage. Just "N%" — the
/// caller's format string is responsible for any label ("RAM {mem}" etc).
fn renderMemWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype) usize {
    var x = start_x;
    var mem_buf: [512]u8 = undefined;
    var pct_buf: [16]u8 = undefined;
    const mem_str = blk: {
        const fd = libc.open("/proc/meminfo", 0, 0);
        if (fd < 0) break :blk "?%";
        defer _ = libc.close(fd);
        const n = libc.read(fd, &mem_buf, mem_buf.len);
        if (n <= 0) break :blk "?%";
        const data = mem_buf[0..@as(usize, @intCast(n))];
        const total = parseMemLine(data, "MemTotal:") orelse break :blk "?%";
        const available = parseMemLine(data, "MemAvailable:") orelse break :blk "?%";
        if (total == 0) break :blk "0%";
        const used_pct = 100 - (available * 100 / total);
        break :blk std.fmt.bufPrint(&pct_buf, "{d}%", .{used_pct}) catch "?%";
    };
    // Color ramp like xmobar Low/High thresholds
    const color: u32 = blk: {
        // Re-parse the digit to pick color (simple)
        var v: u32 = 0;
        for (mem_str) |ch| {
            if (ch >= '0' and ch <= '9') v = v * 10 + (ch - '0') else break;
        }
        break :blk if (v < 30) s.ansi[2] else if (v < 80) s.ansi[3] else s.ansi[1];
    };
    for (mem_str) |ch| {
        Ui.blitCharAt(cpu, ch, x, y, color);
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

// ── CPU % widget ────────────────────────────────────────────────
// Reads /proc/stat, stores previous totals, returns the diff-percentage.
// State is process-global (a bar typically has one instance per output).

var cpu_prev_total: u64 = 0;
var cpu_prev_idle: u64 = 0;

fn readCpuPct() ?u32 {
    var buf: [256]u8 = undefined;
    const fd = libc.open("/proc/stat", 0, 0);
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    const n = libc.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const data = buf[0..@as(usize, @intCast(n))];

    // Parse "cpu  user nice system idle iowait irq softirq steal ..."
    if (!std.mem.startsWith(u8, data, "cpu ")) return null;
    var it = std.mem.tokenizeAny(u8, data[4..], " \t\n");
    var fields: [8]u64 = .{0} ** 8;
    var nf: usize = 0;
    while (it.next()) |tok| : (nf += 1) {
        if (nf >= fields.len) break;
        fields[nf] = std.fmt.parseInt(u64, tok, 10) catch 0;
    }
    if (nf < 4) return null;

    var total: u64 = 0;
    for (fields[0..nf]) |v| total += v;
    const idle = fields[3] + if (nf > 4) fields[4] else 0;

    const total_diff = total -| cpu_prev_total;
    const idle_diff = idle -| cpu_prev_idle;
    cpu_prev_total = total;
    cpu_prev_idle = idle;

    if (total_diff == 0) return 0;
    const busy = total_diff -| idle_diff;
    return @intCast(@min(100, busy * 100 / total_diff));
}

fn renderCpuWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, max_x: usize) usize {
    var x = start_x;
    var buf: [16]u8 = undefined;
    const pct = readCpuPct() orelse {
        for ("?%") |ch| {
            Ui.blitCharAt(cpu, ch, x, y, s.ansi[8]);
            x += cw;
        }
        return x;
    };
    // Color ramp: green <30, yellow <70, red otherwise (matches xmobar Low/High)
    const color: u32 = if (pct < 30) s.ansi[2] else if (pct < 70) s.ansi[3] else s.ansi[1];
    const text = std.fmt.bufPrint(&buf, "{d}%", .{pct}) catch "?%";
    for (text) |ch| {
        Ui.blitCharAt(cpu, ch, x, y, color);
        x += cw;
        if (x >= max_x) break;
    }
    return x;
}

// ── CPU temperature widget ──────────────────────────────────────
// Walks /sys/class/hwmon/hwmon*/name, picks a CPU sensor (k10temp, coretemp,
// zenpower, thinkpad) and reads temp1_input (millidegrees).

fn renderCpuTempWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, max_x: usize) usize {
    var x = start_x;
    var buf: [16]u8 = undefined;
    const temp = readCpuTempC();
    const text = if (temp) |t| std.fmt.bufPrint(&buf, "{d}C", .{t}) catch "?C" else "?C";
    const color: u32 = if (temp) |t|
        (if (t < 60) s.ansi[2] else if (t < 80) s.ansi[3] else s.ansi[1])
    else
        s.ansi[8];
    for (text) |ch| {
        Ui.blitCharAt(cpu, ch, x, y, color);
        x += cw;
        if (x >= max_x) break;
    }
    return x;
}

fn readCpuTempC() ?u32 {
    var i: u8 = 0;
    while (i < 8) : (i += 1) {
        var name_path_buf: [64]u8 = undefined;
        const name_path = std.fmt.bufPrintZ(&name_path_buf, "/sys/class/hwmon/hwmon{d}/name", .{i}) catch continue;
        const fd = libc.open(name_path.ptr, 0, 0);
        if (fd < 0) continue;
        var name_buf: [32]u8 = undefined;
        const n = libc.read(fd, &name_buf, name_buf.len);
        _ = libc.close(fd);
        if (n <= 0) continue;
        const name = std.mem.trimEnd(u8, name_buf[0..@as(usize, @intCast(n))], " \n\t");

        // Prefer well-known CPU sensor names
        const is_cpu = std.mem.eql(u8, name, "k10temp") or
            std.mem.eql(u8, name, "coretemp") or
            std.mem.eql(u8, name, "zenpower") or
            std.mem.eql(u8, name, "thinkpad") or
            std.mem.eql(u8, name, "cpu_thermal");
        if (!is_cpu) continue;

        var temp_path_buf: [64]u8 = undefined;
        const temp_path = std.fmt.bufPrintZ(&temp_path_buf, "/sys/class/hwmon/hwmon{d}/temp1_input", .{i}) catch continue;
        const tfd = libc.open(temp_path.ptr, 0, 0);
        if (tfd < 0) continue;
        defer _ = libc.close(tfd);
        var tbuf: [16]u8 = undefined;
        const tn = libc.read(tfd, &tbuf, tbuf.len);
        if (tn <= 0) continue;
        const tstr = std.mem.trimEnd(u8, tbuf[0..@as(usize, @intCast(tn))], " \n\t");
        const milli = std.fmt.parseInt(u32, tstr, 10) catch continue;
        return milli / 1000;
    }
    return null;
}

// ── Battery widget ──────────────────────────────────────────────
// Reads /sys/class/power_supply/BAT*/capacity (+ status for charging arrow).

fn renderBatteryWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, max_x: usize) usize {
    var x = start_x;
    const b = readBattery();
    var buf: [16]u8 = undefined;
    const text = if (b) |bat|
        std.fmt.bufPrint(&buf, "{c}{d}%", .{ if (bat.charging) @as(u8, '+') else @as(u8, ' '), bat.percent }) catch "?"
    else
        "";
    // Color thresholds similar to xmobar (<20 red, <85 yellow else green)
    const color: u32 = if (b) |bat| (if (bat.percent < 20) s.ansi[1] else if (bat.percent < 50) s.ansi[3] else s.ansi[2]) else s.ansi[8];
    for (text) |ch| {
        Ui.blitCharAt(cpu, ch, x, y, color);
        x += cw;
        if (x >= max_x) break;
    }
    return x;
}

const Battery = struct { percent: u8, charging: bool };

fn readBattery() ?Battery {
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        var cap_path_buf: [96]u8 = undefined;
        const cap_path = std.fmt.bufPrintZ(&cap_path_buf, "/sys/class/power_supply/BAT{d}/capacity", .{i}) catch continue;
        const fd = libc.open(cap_path.ptr, 0, 0);
        if (fd < 0) continue;
        defer _ = libc.close(fd);
        var buf: [16]u8 = undefined;
        const n = libc.read(fd, &buf, buf.len);
        if (n <= 0) continue;
        const pct = std.fmt.parseInt(u8, std.mem.trimEnd(u8, buf[0..@as(usize, @intCast(n))], " \n\t"), 10) catch continue;

        var st_path_buf: [96]u8 = undefined;
        const st_path = std.fmt.bufPrintZ(&st_path_buf, "/sys/class/power_supply/BAT{d}/status", .{i}) catch return .{ .percent = pct, .charging = false };
        const sfd = libc.open(st_path.ptr, 0, 0);
        if (sfd < 0) return .{ .percent = pct, .charging = false };
        defer _ = libc.close(sfd);
        var sbuf: [16]u8 = undefined;
        const sn = libc.read(sfd, &sbuf, sbuf.len);
        const charging = sn > 0 and (std.mem.startsWith(u8, sbuf[0..@as(usize, @intCast(sn))], "Charging") or std.mem.startsWith(u8, sbuf[0..@as(usize, @intCast(sn))], "Full"));
        return .{ .percent = @min(pct, 100), .charging = charging };
    }
    return null;
}

const libc = struct {
    extern "c" fn time(timer: ?*i64) callconv(.c) i64;
    extern "c" fn localtime(timer: *const i64) callconv(.c) ?*tm;
    extern "c" fn strftime(s: [*]u8, max: usize, fmt: [*:0]const u8, t: *const tm) callconv(.c) usize;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int;
    extern "c" fn close(fd: c_int) callconv(.c) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;

    // Opaque — we only pass the pointer to strftime.
    pub const tm = extern struct {
        _fields: [9]c_int,
        _gmtoff: c_long,
        _zone: ?[*:0]const u8,
    };
};
