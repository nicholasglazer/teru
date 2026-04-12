//! teruwm-specific configuration loader.
//!
//! Reads ~/.config/teruwm/config — a separate config file for compositor
//! settings that don't belong in the shared teru.conf (which covers font,
//! colors, terminal keybinds, etc.).
//!
//! Config file format:
//!   # ~/.config/teruwm/config
//!   gap = 8
//!   border_width = 2
//!
//!   [bar.top]
//!   left = {workspaces}
//!   center = {title}
//!   right = {clock}
//!
//!   [bar.bottom]
//!   left = {mem}
//!   right = {exec:2:sensors | grep CPU}
//!
//!   [rules]
//!   Chromium = 2
//!   Firefox = 1
//!   Steam = 7

const std = @import("std");
const teru = @import("teru");
const Io = std.Io;
const Dir = Io.Dir;
const Thresholds = teru.render.BarRenderer.Thresholds;

const WmConfig = @This();

// ── Constants and types (must precede fields) ────────────────────

pub const max_rules = 32;

/// Fixed buffers for bar format strings so we don't need an allocator.
const max_bar_str = 256;

pub const Rule = struct {
    class: [64]u8 = undefined,
    class_len: u8 = 0,
    workspace: u8 = 0,

    pub fn getClass(self: *const Rule) []const u8 {
        return self.class[0..self.class_len];
    }
};

pub const max_autostart = 16;

pub const AutostartEntry = struct {
    cmd: [256]u8 = undefined,
    cmd_len: u16 = 0,

    pub fn getCmd(self: *const AutostartEntry) []const u8 {
        return self.cmd[0..self.cmd_len];
    }
};

pub const max_name_rules = 32;

pub const NameRule = struct {
    class: [64]u8 = undefined,
    class_len: u8 = 0,
    name: [32]u8 = undefined,
    name_len: u8 = 0,

    pub fn getClass(self: *const NameRule) []const u8 {
        return self.class[0..self.class_len];
    }
    pub fn getName(self: *const NameRule) []const u8 {
        return self.name[0..self.name_len];
    }
};

// ── Window layout ────────────────────────────────────────────────

/// Uniform gap in pixels — same between panes and between panes and screen edges/bars.
gap: u16 = 4,

/// Border width in pixels around focused/unfocused windows.
border_width: u16 = 2,

/// Compositor background color (ARGB u32). Visible through gaps between
/// panes/bars. Config accepts `bg = 0x1a1d24` or `bg = #1a1d24`.
/// Default: miozu dark gray (0xFF1a1d24).
bg_color: u32 = 0xFF1a1d24,

// ── Bar widget color thresholds ────────────────────────────────
// Low/high boundaries for each numeric widget. Values below `_low` are
// green, below `_high` yellow, else red (battery is inverted).
// Configure via `[bar.thresholds]` section — e.g. `cpu_low = 40`.
bar_thresholds: Thresholds = .{},

// ── Bar format strings ──────────────────────────────────────────

bar_top_left: ?[]const u8 = null,
bar_top_center: ?[]const u8 = null,
bar_top_right: ?[]const u8 = null,
bar_bottom_left: ?[]const u8 = null,
bar_bottom_center: ?[]const u8 = null,
bar_bottom_right: ?[]const u8 = null,

// ── Window rules (class/app_id → workspace) ─────────────────────

/// Simple window rules: match an X11 class or Wayland app_id to a
/// workspace index (0-based internally, 1-based in config file).
rules: [max_rules]Rule = undefined,
rule_count: u8 = 0,

// ── Name rules (class/app_id → human-readable name) ────────────

name_rules: [max_name_rules]NameRule = undefined,
name_rule_count: u8 = 0,

// ── Autostart (commands to run when the compositor comes up) ───

/// Commands spawned once, after the first output is ready. Skipped on
/// hot-restart (existing clients are still connected). Window placement
/// is handled by `[rules]` on WM_CLASS match, so an autostart entry just
/// runs the program — the rule puts it on the right workspace.
autostart: [max_autostart]AutostartEntry = undefined,
autostart_count: u8 = 0,

// ── String storage (static buffers, no allocator needed) ────────

bar_top_left_buf: [max_bar_str]u8 = undefined,
bar_top_center_buf: [max_bar_str]u8 = undefined,
bar_top_right_buf: [max_bar_str]u8 = undefined,
bar_bottom_left_buf: [max_bar_str]u8 = undefined,
bar_bottom_center_buf: [max_bar_str]u8 = undefined,
bar_bottom_right_buf: [max_bar_str]u8 = undefined,

// ── Loading ─────────────────────────────────────────────────────

/// Load config using libc (for hot-reload, no Io needed).
pub fn loadWithLibc() WmConfig {
    var config = WmConfig{};
    const home = teru.compat.getenv("HOME") orelse return config;

    var path_buf: [512:0]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/teruwm/config", .{home}) catch return config;
    path_buf[path.len] = 0;

    const file = std.c.fopen(@ptrCast(path_buf[0..path.len :0]), "rb") orelse return config;
    defer _ = std.c.fclose(file);

    var content: [64 * 1024]u8 = undefined;
    const n = std.c.fread(&content, 1, content.len, file);
    if (n == 0) return config;

    config.parse(content[0..n]);
    return config;
}

/// Load teruwm config from ~/.config/teruwm/config.
/// Returns defaults if the file does not exist or cannot be parsed.
pub fn load(io: Io) WmConfig {
    var config = WmConfig{};

    const home = teru.compat.getenv("HOME") orelse return config;

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/teruwm/config", .{home}) catch return config;

    const file = Dir.cwd().openFile(io, path, .{}) catch return config;
    defer file.close(io);

    const s = file.stat(io) catch return config;
    const size: usize = @intCast(s.size);
    if (size == 0 or size > 64 * 1024) return config;

    // Read into stack buffer (config files are small)
    var content: [64 * 1024]u8 = undefined;
    const n = file.readPositionalAll(io, content[0..size], 0) catch return config;

    config.parse(content[0..n]);
    return config;
}

/// Parse config file content (key=value with [section] headers).
fn parse(self: *WmConfig, content: []const u8) void {
    var current_section: Section = .global;
    var line_iter = std.mem.splitScalar(u8, content, '\n');

    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);

        // Skip empty lines and comments
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Section header: [section_name]
        if (line[0] == '[') {
            if (std.mem.indexOfScalar(u8, line, ']')) |end| {
                const sec_name = line[1..end];
                current_section = parseSection(sec_name);
            }
            continue;
        }

        // Split on first '='
        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_pos], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[eq_pos + 1 ..], &std.ascii.whitespace);

        if (key.len == 0 or value.len == 0) continue;

        switch (current_section) {
            .global => self.applyGlobal(key, value),
            .bar_top => self.applyBarTop(key, value),
            .bar_bottom => self.applyBarBottom(key, value),
            .bar_thresholds => self.applyThreshold(key, value),
            .rules => self.applyRule(key, value),
            .names => self.applyNameRule(key, value),
            .autostart => self.applyAutostart(key, value),
        }
    }
}

const Section = enum {
    global,
    bar_top,
    bar_bottom,
    bar_thresholds,
    rules,
    names,
    autostart,
};

fn parseSection(name: []const u8) Section {
    if (std.mem.eql(u8, name, "names")) return .names;
    if (std.mem.eql(u8, name, "bar.top")) return .bar_top;
    if (std.mem.eql(u8, name, "bar.bottom")) return .bar_bottom;
    if (std.mem.eql(u8, name, "bar.thresholds")) return .bar_thresholds;
    if (std.mem.eql(u8, name, "rules")) return .rules;
    if (std.mem.eql(u8, name, "autostart")) return .autostart;
    return .global;
}

fn applyGlobal(self: *WmConfig, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "gap")) {
        self.gap = std.fmt.parseInt(u16, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "border_width")) {
        self.border_width = std.fmt.parseInt(u16, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "bg_color") or std.mem.eql(u8, key, "bg")) {
        // Accept "#rrggbb", "0xrrggbb", "rrggbb", or full ARGB "0xaarrggbb"
        var v = value;
        if (v.len > 0 and v[0] == '#') v = v[1..];
        if (v.len > 2 and v[0] == '0' and (v[1] == 'x' or v[1] == 'X')) v = v[2..];
        if (v.len == 0) return;
        const parsed = std.fmt.parseInt(u32, v, 16) catch return;
        // If user gave 6 hex chars (RRGGBB), add full alpha
        self.bg_color = if (v.len <= 6) 0xFF000000 | parsed else parsed;
    }
}

/// Parse `[bar.thresholds]` entries. Primary names are `_warning` and
/// `_critical` (waybar/polybar/i3status convention). The old `_low` /
/// `_high` names are kept as aliases — `_low` → `_warning`, `_high` →
/// `_critical` — so configs written against the first revision keep
/// working. Unknown keys are silently ignored.
fn applyThreshold(self: *WmConfig, key: []const u8, value: []const u8) void {
    const t = &self.bar_thresholds;
    const val_u16 = std.fmt.parseInt(u16, value, 10) catch return;
    const val_u32 = std.fmt.parseInt(u32, value, 10) catch return;

    const eqi = std.mem.eql;
    // CPU
    if (eqi(u8, key, "cpu_warning") or eqi(u8, key, "cpu_low")) t.cpu_warning = val_u16
    else if (eqi(u8, key, "cpu_critical") or eqi(u8, key, "cpu_high")) t.cpu_critical = val_u16
    // CPU temperature
    else if (eqi(u8, key, "cputemp_warning") or eqi(u8, key, "cputemp_low")) t.cputemp_warning = val_u16
    else if (eqi(u8, key, "cputemp_critical") or eqi(u8, key, "cputemp_high")) t.cputemp_critical = val_u16
    // Memory
    else if (eqi(u8, key, "mem_warning") or eqi(u8, key, "mem_low")) t.mem_warning = val_u16
    else if (eqi(u8, key, "mem_critical") or eqi(u8, key, "mem_high")) t.mem_critical = val_u16
    // Battery (inverted: low % is bad)
    else if (eqi(u8, key, "battery_warning") or eqi(u8, key, "battery_low")) t.battery_warning = val_u16
    else if (eqi(u8, key, "battery_critical") or eqi(u8, key, "battery_high")) t.battery_critical = val_u16
    // Power draw
    else if (eqi(u8, key, "watts_warning") or eqi(u8, key, "watts_low")) t.watts_warning = val_u16
    else if (eqi(u8, key, "watts_critical") or eqi(u8, key, "watts_high")) t.watts_critical = val_u16
    // Render perf (µs)
    else if (eqi(u8, key, "perf_us_warning") or eqi(u8, key, "perf_us_low")) t.perf_us_warning = val_u32
    else if (eqi(u8, key, "perf_us_critical") or eqi(u8, key, "perf_us_high")) t.perf_us_critical = val_u32;
}

fn applyBarTop(self: *WmConfig, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "left")) {
        self.bar_top_left = self.storeBarStr(&self.bar_top_left_buf, value);
    } else if (std.mem.eql(u8, key, "center")) {
        self.bar_top_center = self.storeBarStr(&self.bar_top_center_buf, value);
    } else if (std.mem.eql(u8, key, "right")) {
        self.bar_top_right = self.storeBarStr(&self.bar_top_right_buf, value);
    }
}

fn applyBarBottom(self: *WmConfig, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "left")) {
        self.bar_bottom_left = self.storeBarStr(&self.bar_bottom_left_buf, value);
    } else if (std.mem.eql(u8, key, "center")) {
        self.bar_bottom_center = self.storeBarStr(&self.bar_bottom_center_buf, value);
    } else if (std.mem.eql(u8, key, "right")) {
        self.bar_bottom_right = self.storeBarStr(&self.bar_bottom_right_buf, value);
    }
}

fn storeBarStr(_: *WmConfig, buf: *[max_bar_str]u8, value: []const u8) []const u8 {
    const len = @min(value.len, max_bar_str);
    @memcpy(buf[0..len], value[0..len]);
    return buf[0..len];
}

fn applyRule(self: *WmConfig, key: []const u8, value: []const u8) void {
    if (self.rule_count >= max_rules) return;

    // value is a 1-based workspace number in the config file
    const ws_1 = std.fmt.parseInt(u8, value, 10) catch return;
    if (ws_1 < 1 or ws_1 > 10) return;

    var rule = Rule{};
    const len = @min(key.len, rule.class.len);
    @memcpy(rule.class[0..len], key[0..len]);
    rule.class_len = @intCast(len);
    rule.workspace = ws_1 - 1; // store 0-based internally

    self.rules[self.rule_count] = rule;
    self.rule_count += 1;
}

fn applyNameRule(self: *WmConfig, key: []const u8, value: []const u8) void {
    if (self.name_rule_count >= max_name_rules) return;

    var rule = NameRule{};
    const class_len = @min(key.len, rule.class.len);
    @memcpy(rule.class[0..class_len], key[0..class_len]);
    rule.class_len = @intCast(class_len);

    const name_len = @min(value.len, rule.name.len - 1);
    @memcpy(rule.name[0..name_len], value[0..name_len]);
    rule.name_len = @intCast(name_len);

    self.name_rules[self.name_rule_count] = rule;
    self.name_rule_count += 1;
}

fn applyAutostart(self: *WmConfig, key: []const u8, value: []const u8) void {
    _ = key; // keys are ignored — they just disambiguate lines in the INI parser
    if (self.autostart_count >= max_autostart) return;
    if (value.len == 0) return;

    var entry = AutostartEntry{};
    const len = @min(value.len, entry.cmd.len);
    @memcpy(entry.cmd[0..len], value[0..len]);
    entry.cmd_len = @intCast(len);

    self.autostart[self.autostart_count] = entry;
    self.autostart_count += 1;
}

// ── Rule lookup ─────────────────────────────────────────────────

/// Look up a window class/app_id in the rules table.
/// Returns the 0-based workspace index if a rule matches, null otherwise.
pub fn matchRule(self: *const WmConfig, class_or_app_id: []const u8) ?u8 {
    for (self.rules[0..self.rule_count]) |*rule| {
        if (std.mem.eql(u8, rule.getClass(), class_or_app_id)) {
            return rule.workspace;
        }
    }
    return null;
}

/// Look up a window class/app_id in the name rules table.
/// Returns the human-readable name if a rule matches, null otherwise.
pub fn matchName(self: *const WmConfig, class_or_app_id: []const u8) ?[]const u8 {
    for (self.name_rules[0..self.name_rule_count]) |*rule| {
        if (std.mem.eql(u8, rule.getClass(), class_or_app_id)) {
            return rule.getName();
        }
    }
    return null;
}
