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
    workspace_has_nodes: [10]bool = @splat(false),
    /// Urgency flag per workspace — set iff any node on that workspace
    /// has its `urgent` bit set (via xdg_activation_v1). Rendered as a
    /// visible marker on the bar pill.
    workspace_urgent: [10]bool = @splat(false),
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

    // Desktop notification (teruwm only). The compositor copies its live
    // Server.Notification into these plain fields so the shared renderer
    // stays free of compositor types. `notify_active = false` (the default)
    // means no notification is showing and the `{notify}` widget renders
    // nothing. The renderer composes "app: summary — body" and marquee-
    // scrolls it by `notify_scroll` cells when it overflows the center span.
    notify_active: bool = false,
    /// 0=low, 1=normal, 2=critical — drives the marquee color ramp.
    notify_urgency: u8 = 1,
    /// Cells to advance the marquee. Wraps internally; safe at any value.
    notify_scroll: u32 = 0,
    notify_app: []const u8 = "",
    notify_summary: []const u8 = "",
    notify_body: []const u8 = "",
};

// ── Sysfs/proc cache ──────────────────────────────────────────────
// Module-level so TTLs survive across frames. refreshCachedData()
// reads /proc and /sys with per-source TTL gating; widget renderers
// read from the cached values below when `cache_valid` is set, so no
// synchronous I/O lands on the wlroots event loop during rendering.

var cache_mem_pct: u32 = 0;
var cache_cpu_pct: u32 = 0;
var cache_cpu_temp_c: ?u32 = null;
var cache_battery_percent: u8 = 0;
var cache_battery_charging: bool = false;
var cache_battery_present: bool = false;
var cache_watts: f32 = 0.0;
var cache_watts_charging: bool = false;
var cache_watts_present: bool = false;

var cache_last_mem_ns: i128 = 0;
var cache_last_cpu_ns: i128 = 0;
var cache_last_temp_ns: i128 = 0;
var cache_last_battery_ns: i128 = 0;
var cache_last_watts_ns: i128 = 0;

/// Whether the module-level cache has been populated at least once.
var cache_valid: bool = false;

/// When true, exec widgets are managed by the compositor via non-blocking
/// fork+pipe+wl_event_loop_add_fd. The render path just reads from the
/// widget cache. Set by Bar.create(); standalone teru leaves this false
/// so evalExec() runs synchronously in the render path.
pub var exec_nonblocking: bool = false;

/// Refresh stale sysfs/proc cache entries. Called from the frame
/// callback before bar rendering. Each data source has its own TTL —
/// only reads when stale. Returns true if any cached value changed
/// (caller should mark the bar dirty).
pub fn refreshCachedData(now_ns: i128) bool {
    const ns_per_s = std.time.ns_per_s;
    var changed = false;

    // Memory: refresh every 2s
    if (now_ns - cache_last_mem_ns > 2 * ns_per_s) {
        cache_last_mem_ns = now_ns;
        if (readMemPct()) |pct| {
            if (pct != cache_mem_pct) changed = true;
            cache_mem_pct = pct;
        }
    }

    // CPU: refresh every 1s
    if (now_ns - cache_last_cpu_ns > 1 * ns_per_s) {
        cache_last_cpu_ns = now_ns;
        if (readCpuPct()) |pct| {
            if (pct != cache_cpu_pct) changed = true;
            cache_cpu_pct = pct;
        }
    }

    // CPU temp: refresh every 5s
    if (now_ns - cache_last_temp_ns > 5 * ns_per_s) {
        cache_last_temp_ns = now_ns;
        const new_temp = readCpuTempC();
        if (new_temp != cache_cpu_temp_c) changed = true;
        cache_cpu_temp_c = new_temp;
    }

    // Battery: refresh every 10s
    if (now_ns - cache_last_battery_ns > 10 * ns_per_s) {
        cache_last_battery_ns = now_ns;
        const bat = readBattery();
        const present = bat != null;
        const pct: u8 = if (bat) |b| b.percent else 0;
        const chg = if (bat) |b| b.charging else false;
        if (present != cache_battery_present or pct != cache_battery_percent or chg != cache_battery_charging) changed = true;
        cache_battery_present = present;
        cache_battery_percent = pct;
        cache_battery_charging = chg;
    }

    // Watts: refresh every 10s
    if (now_ns - cache_last_watts_ns > 10 * ns_per_s) {
        cache_last_watts_ns = now_ns;
        const pw = readWatts();
        const present = pw != null;
        const w: f32 = if (pw) |p| p.watts else 0.0;
        const chg = if (pw) |p| p.charging else false;
        if (present != cache_watts_present or !approxEq(w, cache_watts) or chg != cache_watts_charging) changed = true;
        cache_watts_present = present;
        cache_watts = w;
        cache_watts_charging = chg;
    }

    cache_valid = true;
    return changed;
}

fn approxEq(a: f32, b: f32) bool {
    const diff = if (a > b) a - b else b - a;
    return diff < 0.05;
}

/// Linear scan over the ≤32-slot push widget array. Short-circuits on
/// empty slice. Hot-path-shared between renderWidgets and measureWidgets
/// so the two stay in lockstep.
inline fn findPushWidget(data: *const BarData, name: []const u8) ?*const PushWidget {
    if (data.push_widgets.len == 0) return null;
    for (data.push_widgets) |*pw| {
        if (pw.used and std.mem.eql(u8, pw.name(), name)) return pw;
    }
    return null;
}

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
                    // Urgent > active > has-nodes for color precedence.
                    const color = if (data.workspace_urgent[wi])
                        s.ansi[1] // red (attention)
                    else if (wi == data.workspace_active)
                        s.cursor
                    else
                        s.ansi[8];
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
                // If the compositor manages exec via non-blocking fork+pipe,
                // the cache is filled asynchronously — just render from it.
                // Standalone teru (exec_nonblocking=false) evaluates inline.
                if (!exec_nonblocking) {
                    const now_ns = compat.monotonicNow();
                    const age_s: u32 = if (w.last_eval == 0) std.math.maxInt(u32) else blk: {
                        const age = @divTrunc(now_ns -| w.last_eval, std.time.ns_per_s);
                        break :blk if (age > std.math.maxInt(u32)) std.math.maxInt(u32) else @as(u32, @intCast(age));
                    };
                    if (age_s >= w.interval) evalExec(w, now_ns);
                }

                for (w.cache[0..w.cache_len]) |ch| {
                    if (ch < 32 or ch > 126) continue;
                    Ui.blitCharAt(cpu, ch, x, y, s.fg);
                    x += cw;
                    if (x >= max_x) break;
                }
            },
            .push_widget => {
                // Missing widget renders empty (no placeholder) so users
                // can conditionally hide a widget by unregistering it.
                if (findPushWidget(data, w.arg)) |pw| {
                    const color = classColor(pw.class, s);
                    for (pw.text()) |ch| {
                        if (ch < 32 or ch > 126) continue;
                        Ui.blitCharAt(cpu, ch, x, y, color);
                        x += cw;
                        if (x >= max_x) break;
                    }
                }
            },
            .notify => {
                x = renderNotify(cpu, x, y, cw, s, max_x, data);
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
            .push_widget => if (findPushWidget(data, w.arg)) |pw| pw.text_len * cw else 0,
            .notify => if (data.notify_active) notifyVisibleCells(data) * cw else 0,
            .text => w.arg.len * cw,
        };
    }
    return total;
}

// ── Notification marquee widget ─────────────────────────────────
//
// Renders the active desktop notification (Server.Notification, copied
// into BarData by Bar.buildBarData) as a single line: "app: summary — body".
// When the composed line fits inside `notify_span_cells` it renders
// statically; when it overflows it marquee-scrolls left by `notify_scroll`
// cells (advanced once per fast bar-tick — see Server.barTick), wrapping
// with a " · " gap so the head reappears after the tail. Color ramps by
// urgency. Renders nothing when no notification is active.

/// Visible width of the notification widget, in cells. The marquee window
/// is bounded so it can sit in the bottom-bar center without overrunning
/// the side sections.
pub const notify_span_cells: usize = 56;
/// Separator inserted between the tail and the wrapped head of a scrolling
/// marquee so the message reads as a loop, not a hard cut.
const notify_gap = " · ";

/// Length (in printable bytes) of the composed notification line, capped
/// at the visible span. Used by measureWidgets for centering.
fn notifyVisibleCells(data: *const BarData) usize {
    const total = composedNotifyLen(data);
    return @min(total, notify_span_cells);
}

/// Total length of "app: summary — body" honoring which fields are present.
fn composedNotifyLen(data: *const BarData) usize {
    var n: usize = 0;
    if (data.notify_app.len > 0) n += data.notify_app.len + 2; // "app: "
    n += data.notify_summary.len;
    if (data.notify_body.len > 0) n += 3 + data.notify_body.len; // " — body"
    return n;
}

/// Emit the i-th printable byte of the composed "app: summary — body"
/// line, or null when i is past the end. Lets the marquee index a virtual
/// string without materializing it into a buffer (zero-alloc hot path).
fn composedNotifyByte(data: *const BarData, i: usize) ?u8 {
    var off: usize = 0;
    if (data.notify_app.len > 0) {
        if (i < off + data.notify_app.len) return data.notify_app[i - off];
        off += data.notify_app.len;
        if (i == off) return ':';
        if (i == off + 1) return ' ';
        off += 2;
    }
    if (i < off + data.notify_summary.len) return data.notify_summary[i - off];
    off += data.notify_summary.len;
    if (data.notify_body.len > 0) {
        if (i == off) return ' ';
        if (i == off + 1) return '-';
        if (i == off + 2) return ' ';
        off += 3;
        if (i < off + data.notify_body.len) return data.notify_body[i - off];
    }
    return null;
}

fn notifyColor(urgency: u8, s: anytype) u32 {
    return switch (urgency) {
        0 => s.ansi[8], // low → dim
        2 => s.ansi[1], // critical → red
        else => s.fg, // normal → fg
    };
}

fn renderNotify(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, max_x: usize, data: *const BarData) usize {
    if (!data.notify_active) return start_x;
    var x = start_x;
    const color = notifyColor(data.notify_urgency, s);
    const total = composedNotifyLen(data);
    if (total == 0) return x;

    if (total <= notify_span_cells) {
        // Fits — render statically, no scroll.
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const ch = composedNotifyByte(data, i) orelse break;
            if (ch >= 32 and ch <= 126) {
                Ui.blitCharAt(cpu, ch, x, y, color);
                x += cw;
                if (x >= max_x) break;
            }
        }
        return x;
    }

    // Overflow — marquee. Virtual string is the composed line + gap; the
    // window starts at `notify_scroll % period` and wraps.
    const period = total + notify_gap.len;
    const scroll = @as(usize, data.notify_scroll) % period;
    var col: usize = 0;
    while (col < notify_span_cells) : (col += 1) {
        const vi = (scroll + col) % period;
        const ch: u8 = if (vi < total)
            (composedNotifyByte(data, vi) orelse ' ')
        else
            notify_gap[vi - total];
        if (ch >= 32 and ch <= 126) {
            Ui.blitCharAt(cpu, ch, x, y, color);
        }
        x += cw;
        if (x >= max_x) break;
    }
    return x;
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

/// Read /proc/meminfo and return used-memory percentage (0-100). Returns
/// null if the file can't be read or parsed. Extracted from renderMemWidget
/// so refreshCachedData can call it outside the render path.
fn readMemPct() ?u32 {
    var buf: [512]u8 = undefined;
    const fd = libc.open("/proc/meminfo", 0, 0);
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    const n = libc.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    const data = buf[0..@as(usize, @intCast(n))];
    const total = parseMemLine(data, "MemTotal:") orelse return null;
    const available = parseMemLine(data, "MemAvailable:") orelse return null;
    if (total == 0) return 0;
    return @intCast(100 - (available * 100 / total));
}

fn renderMemWidget(cpu: *SoftwareRenderer, start_x: usize, y: usize, cw: usize, s: anytype, th: *const Thresholds) usize {
    var x = start_x;
    var pct_buf: [16]u8 = undefined;
    var used_pct: u32 = 0;
    const mem_str = blk: {
        if (cache_valid) {
            used_pct = cache_mem_pct;
            break :blk std.fmt.bufPrint(&pct_buf, "{d}%", .{used_pct}) catch "?%";
        }
        // Legacy path (standalone teru): do synchronous I/O.
        if (readMemPct()) |pct| {
            used_pct = pct;
            break :blk std.fmt.bufPrint(&pct_buf, "{d}%", .{used_pct}) catch "?%";
        }
        break :blk "?%";
    };
    const color = rampColor(@intCast(used_pct), th.mem_warning, th.mem_critical, false, s);
    for (mem_str) |ch| {
        Ui.blitCharAt(cpu, ch, x, y, color);
        x += cw;
    }
    return x;
}

fn parseMemLine(data: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.find(u8, data, key) orelse return null;
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
    var fields: [8]u64 = @splat(0);
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
    const pct: u32 = if (cache_valid) cache_cpu_pct else readCpuPct() orelse {
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
    const temp: ?u32 = if (cache_valid) cache_cpu_temp_c else readCpuTempC();
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
        const name_path = std.fmt.bufPrintSentinel(&name_path_buf, "/sys/class/hwmon/hwmon{d}/name", .{i}, 0) catch continue;
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
        const temp_path = std.fmt.bufPrintSentinel(&temp_path_buf, "/sys/class/hwmon/hwmon{d}/temp1_input", .{i}, 0) catch continue;
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
    const present, const pct, const charging = if (cache_valid)
        .{ cache_battery_present, cache_battery_percent, cache_battery_charging }
    else blk: {
        const b = readBattery();
        break :blk .{ b != null, if (b) |bat| bat.percent else @as(u8, 0), if (b) |bat| bat.charging else false };
    };
    var buf: [16]u8 = undefined;
    const text = if (present)
        std.fmt.bufPrint(&buf, "{c}{d}%", .{ if (charging) @as(u8, '+') else @as(u8, ' '), pct }) catch "?"
    else
        "";
    const color: u32 = if (present)
        rampColor(pct, th.battery_warning, th.battery_critical, true, s)
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
        const cap_path = std.fmt.bufPrintSentinel(&cap_path_buf, "/sys/class/power_supply/BAT{d}/capacity", .{i}, 0) catch continue;
        const fd = libc.open(cap_path.ptr, 0, 0);
        if (fd < 0) continue;
        defer _ = libc.close(fd);
        var buf: [16]u8 = undefined;
        const n = libc.read(fd, &buf, buf.len);
        if (n <= 0) continue;
        const pct = std.fmt.parseInt(u8, std.mem.trimEnd(u8, buf[0..@as(usize, @intCast(n))], " \n\t"), 10) catch continue;

        var st_path_buf: [96]u8 = undefined;
        const st_path = std.fmt.bufPrintSentinel(&st_path_buf, "/sys/class/power_supply/BAT{d}/status", .{i}, 0) catch return .{ .percent = pct, .charging = false };
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
    if (std.mem.findScalar(u8, buf[0..end], '\n')) |nl| end = nl;

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
    const present, const w, const charging = if (cache_valid)
        .{ cache_watts_present, cache_watts, cache_watts_charging }
    else blk: {
        const pw = readWatts();
        break :blk .{ pw != null, if (pw) |p| p.watts else @as(f32, 0.0), if (pw) |p| p.charging else false };
    };
    var buf: [16]u8 = undefined;
    const text = if (present)
        std.fmt.bufPrint(&buf, "{c}{d:.1}W", .{ if (charging) @as(u8, '+') else @as(u8, ' '), w }) catch "?W"
    else
        "";
    const color: u32 = if (present)
        (if (charging) s.ansi[2] else rampColor(@intFromFloat(w), th.watts_warning, th.watts_critical, false, s))
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
        const pn_path = std.fmt.bufPrintSentinel(&pn_buf, "/sys/class/power_supply/BAT{d}/power_now", .{i}, 0) catch continue;
        if (readSysfsInt(pn_path)) |uw| {
            const charging = isCharging(i);
            return .{ .watts = @as(f32, @floatFromInt(uw)) / 1_000_000.0, .charging = charging };
        }
        // Fallback: current_now * voltage_now (both µ)
        var cn_buf: [64]u8 = undefined;
        var vn_buf: [64]u8 = undefined;
        const cn_path = std.fmt.bufPrintSentinel(&cn_buf, "/sys/class/power_supply/BAT{d}/current_now", .{i}, 0) catch continue;
        const vn_path = std.fmt.bufPrintSentinel(&vn_buf, "/sys/class/power_supply/BAT{d}/voltage_now", .{i}, 0) catch continue;
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
    const path = std.fmt.bufPrintSentinel(&buf, "/sys/class/power_supply/BAT{d}/status", .{bat_idx}, 0) catch return false;
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
