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
const PushWidget = @import("PushWidget.zig").PushWidget;
const WidgetClass = @import("PushWidget.zig").Class;
const compat = @import("../compat.zig");

/// Color-ramp thresholds for numeric widgets. Named after the *state
/// entered* at that value (`warning` / `critical`) rather than the
/// direction ("low" / "high"), following waybar, polybar and i3status.
/// The benefit: the naming works identically for widgets where "higher
/// is bad" (CPU, temperature) and those where "lower is bad" (battery).
///
/// Reading: "cpu_warning = 30" → CPU goes yellow at ≥30 %. "battery_
/// warning = 50" → battery goes yellow at ≤50 %. Both read naturally.
pub const Thresholds = struct {
    cpu_warning: u16 = 30,         cpu_critical: u16 = 70,
    cputemp_warning: u16 = 60,     cputemp_critical: u16 = 80,
    mem_warning: u16 = 30,         mem_critical: u16 = 80,
    battery_warning: u16 = 50,     battery_critical: u16 = 20,  // low % is bad
    watts_warning: u16 = 15,       watts_critical: u16 = 30,    // ignored when charging
    perf_us_warning: u32 = 50,     perf_us_critical: u32 = 100,
};

/// Pick green / yellow / red from the ColorScheme palette based on `v`
/// and its warning / critical thresholds. The `inverted` flag marks
/// widgets where lower is worse (battery): in that case `warning` is
/// the value at which state enters yellow from the high side and
/// `critical` is the value where it drops into red.
pub fn rampColor(v: i64, warning: i64, critical: i64, inverted: bool, s: anytype) u32 {
    const green = s.ansi[2];
    const yellow = s.ansi[3];
    const red = s.ansi[1];
    if (!inverted) {
        // Higher = worse
        if (v >= critical) return red;
        if (v >= warning) return yellow;
        return green;
    } else {
        // Lower = worse (e.g. battery percentage)
        if (v <= critical) return red;
        if (v <= warning) return yellow;
        return green;
    }
}

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

    // Color-ramp thresholds for every numeric widget. Caller overrides
    // these from config; defaults match xmobar conventions.
    thresholds: Thresholds = .{},

    // Push widgets registered via MCP (teruwm only). The renderer iterates
    // on every `.push_widget` token and does a linear name lookup — fine
    // for the ≤32-slot budget. Slots with `.used = false` are skipped.
    push_widgets: []const PushWidget = &.{},
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
                x = renderMemWidget(cpu, x, y, cw, s, &data.thresholds);
            },
            .cpu => {
                x = renderCpuWidget(cpu, x, y, cw, s, max_x, &data.thresholds);
            },
            .cputemp => {
                x = renderCpuTempWidget(cpu, x, y, cw, s, max_x, &data.thresholds);
            },
            .battery => {
                x = renderBatteryWidget(cpu, x, y, cw, s, max_x, &data.thresholds);
            },
            .watts => {
                x = renderWattsWidget(cpu, x, y, cw, s, max_x, &data.thresholds);
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
                const color = rampColor(
                    @intCast(data.frame_avg_us),
                    data.thresholds.perf_us_warning,
                    data.thresholds.perf_us_critical,
                    false,
                    s,
                );
                for (text) |ch| {
                    Ui.blitCharAt(cpu, ch, x, y, color);
                    x += cw;
                    if (x >= max_x) break;
                }
            },
            .exec => {
                // Refresh the cache if enough time has elapsed.
                const now_ns = compat.monotonicNow();
                const age_s: u32 = if (w.last_eval == 0) std.math.maxInt(u32) else blk: {
                    const age = @divTrunc(now_ns -| w.last_eval, std.time.ns_per_s);
                    break :blk if (age > std.math.maxInt(u32)) std.math.maxInt(u32) else @as(u32, @intCast(age));
                };
                if (age_s >= w.interval) evalExec(w, now_ns);

                for (w.cache[0..w.cache_len]) |ch| {
                    if (ch < 32 or ch > 126) continue;
                    Ui.blitCharAt(cpu, ch, x, y, s.fg);
                    x += cw;
                    if (x >= max_x) break;
                }
            },
            .push_widget => {
                // Linear scan over the ≤32-slot array. Missing widget
                // renders empty (no placeholder) so users can conditionally
                // hide a widget by unregistering it.
                const found: ?*const PushWidget = blk: {
                    for (data.push_widgets) |*pw| {
                        if (pw.used and std.mem.eql(u8, pw.name(), w.arg)) break :blk pw;
                    }
                    break :blk null;
                };
                if (found) |pw| {
                    const color = classColor(pw.class, s);
                    for (pw.text()) |ch| {
                        if (ch < 32 or ch > 126) continue;
                        Ui.blitCharAt(cpu, ch, x, y, color);
                        x += cw;
                        if (x >= max_x) break;
                    }
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
            .watts => 7 * cw,     // "12.3W"
            .keymap => @max(data.keymap.len, 2) * cw,
            .perf => 12 * cw,
            .exec => @as(usize, w.cache_len) * cw,
            .push_widget => blk: {
                // Same linear scan as in render; worst case 32 comparisons.
                for (data.push_widgets) |*pw| {
                    if (pw.used and std.mem.eql(u8, pw.name(), w.arg))
                        break :blk pw.text_len * cw;
                }
                break :blk 0;
            },
            .text => w.arg.len * cw,
        };
    }
    return total;
}

/// Map a push-widget Class to a ColorScheme palette entry. Keeps theming
/// centralized: switch themes → widget colors follow automatically.
fn classColor(c: WidgetClass, s: anytype) u32 {
    return switch (c) {
        .none => s.fg,
        .muted => s.ansi[8],
        .info => s.ansi[4],
        .success => s.ansi[2],
        .warning => s.ansi[3],
        .critical => s.ansi[1],
        .accent => s.ansi[6],
    };
}

/// Read /proc/meminfo and render used-memory percentage. Just "N%" — the
/// caller's format string is responsible for any label ("RAM {mem}" etc).
fn renderMemWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, th: *const Thresholds) usize {
    var x = start_x;
    var mem_buf: [512]u8 = undefined;
    var pct_buf: [16]u8 = undefined;
    var used_pct: u32 = 0;
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
        used_pct = @intCast(100 - (available * 100 / total));
        break :blk std.fmt.bufPrint(&pct_buf, "{d}%", .{used_pct}) catch "?%";
    };
    const color = rampColor(@intCast(used_pct), th.mem_warning, th.mem_critical, false, s);
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

fn renderCpuWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, max_x: usize, th: *const Thresholds) usize {
    var x = start_x;
    var buf: [16]u8 = undefined;
    const pct = readCpuPct() orelse {
        for ("?%") |ch| {
            Ui.blitCharAt(cpu, ch, x, y, s.ansi[8]);
            x += cw;
        }
        return x;
    };
    const color = rampColor(@intCast(pct), th.cpu_warning, th.cpu_critical, false, s);
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

fn renderCpuTempWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, max_x: usize, th: *const Thresholds) usize {
    var x = start_x;
    var buf: [16]u8 = undefined;
    const temp = readCpuTempC();
    const text = if (temp) |t| std.fmt.bufPrint(&buf, "{d}C", .{t}) catch "?C" else "?C";
    const color: u32 = if (temp) |t|
        rampColor(@intCast(t), th.cputemp_warning, th.cputemp_critical, false, s)
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

fn renderBatteryWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, max_x: usize, th: *const Thresholds) usize {
    var x = start_x;
    const b = readBattery();
    var buf: [16]u8 = undefined;
    const text = if (b) |bat|
        std.fmt.bufPrint(&buf, "{c}{d}%", .{ if (bat.charging) @as(u8, '+') else @as(u8, ' '), bat.percent }) catch "?"
    else
        "";
    // inverted=true: low % is bad (red), high % is good (green)
    const color: u32 = if (b) |bat|
        rampColor(bat.percent, th.battery_warning, th.battery_critical, true, s)
    else
        s.ansi[8];
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

// ── Exec widget evaluator ───────────────────────────────────────
// Runs the widget's shell command via popen, captures stdout into the
// widget's fixed cache buffer. Called at most once per interval.
// Blocking: acceptable because exec widgets are opt-in, have high
// intervals (default 5s), and short commands. If a command blocks too
// long (>2s) it'll stall the bar render — user's fault.

fn evalExec(w: *BarWidget.Widget, now_ns: i128) void {
    w.last_eval = now_ns;
    w.cache_len = 0;

    // Null-terminate the command (popen wants c-string)
    var cmd_z: [max_exec_cmd]u8 = undefined;
    if (w.arg.len == 0 or w.arg.len >= cmd_z.len) return;
    @memcpy(cmd_z[0..w.arg.len], w.arg);
    cmd_z[w.arg.len] = 0;

    const fp = libc.popen(@ptrCast(cmd_z[0..w.arg.len :0]), "r") orelse return;
    defer _ = libc.pclose(fp);

    // Read into widget cache. Stop at first newline — bar is single line.
    var buf: [BarWidget.max_exec_output]u8 = undefined;
    const got = libc.fread(&buf, 1, buf.len, fp);
    if (got == 0) return;

    // Trim trailing whitespace / newlines
    var end: usize = got;
    while (end > 0) : (end -= 1) {
        const c = buf[end - 1];
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') break;
    }
    // Only keep first line
    if (std.mem.indexOfScalar(u8, buf[0..end], '\n')) |nl| end = nl;

    const copy_n = @min(end, w.cache.len);
    @memcpy(w.cache[0..copy_n], buf[0..copy_n]);
    w.cache_len = @intCast(copy_n);
}

const max_exec_cmd = 512;

// ── Watts widget ────────────────────────────────────────────────
// Battery power draw in watts. Source of truth: /sys/class/power_supply/
// BAT*/power_now (microwatts). Some platforms only expose current_now /
// voltage_now — compute W from those as fallback. Shows a '+' prefix
// when charging.

fn renderWattsWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, max_x: usize, th: *const Thresholds) usize {
    var x = start_x;
    var buf: [16]u8 = undefined;
    const w_opt = readWatts();
    const text = if (w_opt) |pw|
        std.fmt.bufPrint(&buf, "{c}{d:.1}W", .{ if (pw.charging) @as(u8, '+') else @as(u8, ' '), pw.watts }) catch "?W"
    else
        "";
    // Charging always green; otherwise ramp against discharge thresholds.
    const color: u32 = if (w_opt) |pw|
        (if (pw.charging) s.ansi[2] else rampColor(@intFromFloat(pw.watts), th.watts_warning, th.watts_critical, false, s))
    else
        s.ansi[8];
    for (text) |ch| {
        Ui.blitCharAt(cpu, ch, x, y, color);
        x += cw;
        if (x >= max_x) break;
    }
    return x;
}

const Power = struct { watts: f32, charging: bool };

fn readWatts() ?Power {
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        // Try power_now first (most direct)
        var pn_buf: [64]u8 = undefined;
        const pn_path = std.fmt.bufPrintZ(&pn_buf, "/sys/class/power_supply/BAT{d}/power_now", .{i}) catch continue;
        if (readSysfsInt(pn_path)) |uw| {
            const charging = isCharging(i);
            return .{ .watts = @as(f32, @floatFromInt(uw)) / 1_000_000.0, .charging = charging };
        }
        // Fallback: current_now * voltage_now (both µ)
        var cn_buf: [64]u8 = undefined;
        var vn_buf: [64]u8 = undefined;
        const cn_path = std.fmt.bufPrintZ(&cn_buf, "/sys/class/power_supply/BAT{d}/current_now", .{i}) catch continue;
        const vn_path = std.fmt.bufPrintZ(&vn_buf, "/sys/class/power_supply/BAT{d}/voltage_now", .{i}) catch continue;
        const current = readSysfsInt(cn_path) orelse continue;
        const voltage = readSysfsInt(vn_path) orelse continue;
        // current µA × voltage µV = 10^-12 W, divide by 1e12 for W
        const watts = (@as(f32, @floatFromInt(current)) * @as(f32, @floatFromInt(voltage))) / 1.0e12;
        return .{ .watts = watts, .charging = isCharging(i) };
    }
    return null;
}

fn isCharging(bat_idx: u8) bool {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "/sys/class/power_supply/BAT{d}/status", .{bat_idx}) catch return false;
    const fd = libc.open(path.ptr, 0, 0);
    if (fd < 0) return false;
    defer _ = libc.close(fd);
    var sbuf: [16]u8 = undefined;
    const n = libc.read(fd, &sbuf, sbuf.len);
    if (n <= 0) return false;
    const data = sbuf[0..@as(usize, @intCast(n))];
    return std.mem.startsWith(u8, data, "Charging") or std.mem.startsWith(u8, data, "Full");
}

fn readSysfsInt(path: [:0]const u8) ?u64 {
    const fd = libc.open(path.ptr, 0, 0);
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    var buf: [24]u8 = undefined;
    const n = libc.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const s = std.mem.trimEnd(u8, buf[0..@as(usize, @intCast(n))], " \n\t");
    return std.fmt.parseInt(u64, s, 10) catch null;
}

const libc = struct {
    extern "c" fn time(timer: ?*i64) callconv(.c) i64;
    extern "c" fn localtime(timer: *const i64) callconv(.c) ?*tm;
    extern "c" fn strftime(s: [*]u8, max: usize, fmt: [*:0]const u8, t: *const tm) callconv(.c) usize;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) callconv(.c) c_int;
    extern "c" fn close(fd: c_int) callconv(.c) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) callconv(.c) isize;
    extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn pclose(fp: *anyopaque) callconv(.c) c_int;
    extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, fp: *anyopaque) callconv(.c) usize;

    // Opaque — we only pass the pointer to strftime.
    pub const tm = extern struct {
        _fields: [9]c_int,
        _gmtoff: c_long,
        _zone: ?[*:0]const u8,
    };
};

// ── Tests ─────────────────────────────────────────────────────

test "rampColor normal direction (higher = worse)" {
    const Scheme = struct { ansi: [9]u32 = .{ 0, 0xFFFF0000, 0xFF00FF00, 0xFFFFFF00, 0, 0, 0, 0, 0 } };
    const s = Scheme{};
    // warning=30, critical=70: red ≥70, yellow ≥30, else green
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), rampColor(10, 30, 70, false, s));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), rampColor(30, 30, 70, false, s));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), rampColor(50, 30, 70, false, s));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), rampColor(70, 30, 70, false, s));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), rampColor(90, 30, 70, false, s));
}

test "rampColor inverted direction (lower = worse, e.g. battery)" {
    const Scheme = struct { ansi: [9]u32 = .{ 0, 0xFFFF0000, 0xFF00FF00, 0xFFFFFF00, 0, 0, 0, 0, 0 } };
    const s = Scheme{};
    // warning=50, critical=20: red ≤20, yellow ≤50, else green
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), rampColor(80, 50, 20, true, s));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), rampColor(50, 50, 20, true, s));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF00), rampColor(30, 50, 20, true, s));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), rampColor(20, 50, 20, true, s));
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), rampColor(5, 50, 20, true, s));
}
