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

// ── Window layout ────────────────────────────────────────────────

/// Gap in pixels between tiled windows (half applied on each side).
gap: u16 = 4,

/// Border width in pixels around focused/unfocused windows.
border_width: u16 = 2,

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

// ── String storage (static buffers, no allocator needed) ────────

bar_top_left_buf: [max_bar_str]u8 = undefined,
bar_top_center_buf: [max_bar_str]u8 = undefined,
bar_top_right_buf: [max_bar_str]u8 = undefined,
bar_bottom_left_buf: [max_bar_str]u8 = undefined,
bar_bottom_center_buf: [max_bar_str]u8 = undefined,
bar_bottom_right_buf: [max_bar_str]u8 = undefined,

// ── Loading ─────────────────────────────────────────────────────

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
            .rules => self.applyRule(key, value),
        }
    }
}

const Section = enum {
    global,
    bar_top,
    bar_bottom,
    rules,
};

fn parseSection(name: []const u8) Section {
    if (std.mem.eql(u8, name, "bar.top")) return .bar_top;
    if (std.mem.eql(u8, name, "bar.bottom")) return .bar_bottom;
    if (std.mem.eql(u8, name, "rules")) return .rules;
    return .global;
}

fn applyGlobal(self: *WmConfig, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "gap")) {
        self.gap = std.fmt.parseInt(u16, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "border_width")) {
        self.border_width = std.fmt.parseInt(u16, value, 10) catch return;
    }
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
