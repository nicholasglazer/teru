//! Configuration file parser for teru.
//!
//! Reads a simple key=value config file from ~/.config/teru/teru.conf.
//! No Lua dependency — pure Zig. Falls back to sensible defaults when
//! the config file is missing or individual keys are absent.
//!
//! Config file format:
//!   # comment
//!   font_size = 14
//!   bg = #1D1D23
//!   cursor_color = #FF9922

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const compat = @import("../compat.zig");
const Config = @This();

// ── Fields ────────────────────────────────────────────────────────

// Appearance
font_path: ?[]const u8 = null, // path to .ttf font
font_size: u16 = 16,

// Colors (miozu theme defaults)
bg: u32 = 0xFF1D1D23, // dark background
fg: u32 = 0xFFFAF8FB, // light foreground
cursor_color: u32 = 0xFFFF9922, // orange accent
selection_bg: u32 = 0xFF38384C, // selection highlight
border_active: u32 = 0xFFFF9922, // active pane border
border_inactive: u32 = 0xFF38384C, // inactive pane border

// Terminal
scrollback_lines: u32 = 10000,
shell: ?[]const u8 = null, // override $SHELL

// Keybindings
prefix_key: u8 = 0, // 0 = Ctrl+Space (NUL)

// Window
initial_width: u32 = 960,
initial_height: u32 = 640,

// Hooks — raw command strings (transferred to Hooks struct at init)
hook_on_spawn: ?[]const u8 = null,
hook_on_close: ?[]const u8 = null,
hook_on_agent_start: ?[]const u8 = null,
hook_on_session_save: ?[]const u8 = null,

allocator: Allocator,

// ── Public API ────────────────────────────────────────────────────

/// Load configuration from ~/.config/teru/teru.conf.
/// Returns defaults if the file does not exist.
pub fn load(allocator: Allocator, io: Io) !Config {
    var config = Config{ .allocator = allocator };

    const home = compat.getenv("HOME") orelse return config;

    // Build path: $HOME/.config/teru/teru.conf
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/teru/teru.conf", .{home}) catch return config;

    const file = Dir.cwd().openFile(io, path, .{}) catch return config;
    defer file.close(io);

    // Read the entire file (cap at 64KB — config files should be tiny)
    const s = file.stat(io) catch return config;
    const size: usize = @intCast(s.size);
    if (size > 64 * 1024) return config;
    const content = allocator.alloc(u8, size) catch return config;
    defer allocator.free(content);
    const n = file.readPositionalAll(io, content, 0) catch return config;

    config.parse(allocator, content[0..n]);
    return config;
}

/// Free any allocator-owned string fields.
pub fn deinit(self: *Config) void {
    if (self.font_path) |p| self.allocator.free(p);
    if (self.shell) |s| self.allocator.free(s);
    if (self.hook_on_spawn) |s| self.allocator.free(s);
    if (self.hook_on_close) |s| self.allocator.free(s);
    if (self.hook_on_agent_start) |s| self.allocator.free(s);
    if (self.hook_on_session_save) |s| self.allocator.free(s);
    self.font_path = null;
    self.shell = null;
    self.hook_on_spawn = null;
    self.hook_on_close = null;
    self.hook_on_agent_start = null;
    self.hook_on_session_save = null;
}

// ── Parsing ───────────────────────────────────────────────────────

fn parse(self: *Config, allocator: Allocator, content: []const u8) void {
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);

        // Skip empty lines and comments
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Split on first '='
        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_pos], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[eq_pos + 1 ..], &std.ascii.whitespace);

        if (key.len == 0 or value.len == 0) continue;

        self.applyField(allocator, key, value);
    }
}

fn applyField(self: *Config, allocator: Allocator, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "font_size")) {
        self.font_size = std.fmt.parseInt(u16, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "font_path")) {
        self.setString(allocator, &self.font_path, value);
    } else if (std.mem.eql(u8, key, "shell")) {
        self.setString(allocator, &self.shell, value);
    } else if (std.mem.eql(u8, key, "bg")) {
        self.bg = parseHexColor(value) orelse return;
    } else if (std.mem.eql(u8, key, "fg")) {
        self.fg = parseHexColor(value) orelse return;
    } else if (std.mem.eql(u8, key, "cursor_color")) {
        self.cursor_color = parseHexColor(value) orelse return;
    } else if (std.mem.eql(u8, key, "selection_bg")) {
        self.selection_bg = parseHexColor(value) orelse return;
    } else if (std.mem.eql(u8, key, "border_active")) {
        self.border_active = parseHexColor(value) orelse return;
    } else if (std.mem.eql(u8, key, "border_inactive")) {
        self.border_inactive = parseHexColor(value) orelse return;
    } else if (std.mem.eql(u8, key, "scrollback_lines")) {
        self.scrollback_lines = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "prefix_key")) {
        self.prefix_key = parsePrefixKey(value) orelse return;
    } else if (std.mem.eql(u8, key, "initial_width")) {
        self.initial_width = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "initial_height")) {
        self.initial_height = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "hook_on_spawn")) {
        self.setString(allocator, &self.hook_on_spawn, value);
    } else if (std.mem.eql(u8, key, "hook_on_close")) {
        self.setString(allocator, &self.hook_on_close, value);
    } else if (std.mem.eql(u8, key, "hook_on_agent_start")) {
        self.setString(allocator, &self.hook_on_agent_start, value);
    } else if (std.mem.eql(u8, key, "hook_on_session_save")) {
        self.setString(allocator, &self.hook_on_session_save, value);
    }
    // Unknown keys are silently ignored (forward-compatibility)
}

fn setString(self: *Config, allocator: Allocator, field: *?[]const u8, value: []const u8) void {
    _ = self;
    // Free any previous value
    if (field.*) |prev| allocator.free(prev);
    field.* = allocator.dupe(u8, value) catch null;
}

// ── Hex color parsing ─────────────────────────────────────────────

/// Parse "#RRGGBB" into 0xFFRRGGBB. Returns null on invalid input.
pub fn parseHexColor(value: []const u8) ?u32 {
    // Strip leading '#' if present
    const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
    if (hex.len != 6) return null;

    const rgb = std.fmt.parseInt(u24, hex, 16) catch return null;
    return 0xFF000000 | @as(u32, rgb);
}

/// Parse a prefix key string like "ctrl+space", "ctrl+a", "ctrl+b".
/// Returns the byte value the key produces (Ctrl+A = 1, Ctrl+B = 2, etc.).
/// Ctrl+Space = 0 (NUL byte).
pub fn parsePrefixKey(value: []const u8) ?u8 {
    // Normalize: skip whitespace, lowercase compare
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;

    // Check for "ctrl+" prefix (case-insensitive)
    if (trimmed.len > 5) {
        const has_ctrl = (trimmed[0] == 'c' or trimmed[0] == 'C') and
            (trimmed[1] == 't' or trimmed[1] == 'T') and
            (trimmed[2] == 'r' or trimmed[2] == 'R') and
            (trimmed[3] == 'l' or trimmed[3] == 'L') and
            trimmed[4] == '+';

        if (has_ctrl) {
            const rest = trimmed[5..];
            // ctrl+space
            if (rest.len == 5 and
                (rest[0] == 's' or rest[0] == 'S') and
                (rest[1] == 'p' or rest[1] == 'P') and
                (rest[2] == 'a' or rest[2] == 'A') and
                (rest[3] == 'c' or rest[3] == 'C') and
                (rest[4] == 'e' or rest[4] == 'E'))
            {
                return 0; // NUL
            }
            // ctrl+a through ctrl+z
            if (rest.len == 1) {
                const ch = rest[0];
                if (ch >= 'a' and ch <= 'z') return ch - 'a' + 1;
                if (ch >= 'A' and ch <= 'Z') return ch - 'A' + 1;
            }
        }
    }

    // Raw integer fallback (0-31)
    return std.fmt.parseInt(u8, trimmed, 10) catch null;
}

// ── Tests ─────────────────────────────────────────────────────────

test "parsePrefixKey" {
    try std.testing.expectEqual(@as(?u8, 0), parsePrefixKey("ctrl+space"));
    try std.testing.expectEqual(@as(?u8, 0), parsePrefixKey("Ctrl+Space"));
    try std.testing.expectEqual(@as(?u8, 1), parsePrefixKey("ctrl+a"));
    try std.testing.expectEqual(@as(?u8, 2), parsePrefixKey("ctrl+b"));
    try std.testing.expectEqual(@as(?u8, 2), parsePrefixKey("Ctrl+B"));
    try std.testing.expectEqual(@as(?u8, 26), parsePrefixKey("ctrl+z"));
    try std.testing.expectEqual(@as(?u8, 0), parsePrefixKey("0")); // raw integer
    try std.testing.expectEqual(@as(?u8, 2), parsePrefixKey("2")); // raw integer
    try std.testing.expectEqual(@as(?u8, null), parsePrefixKey(""));
    try std.testing.expectEqual(@as(?u8, null), parsePrefixKey("invalid"));
}

test "parseHexColor valid" {
    try std.testing.expectEqual(@as(?u32, 0xFF1D1D23), parseHexColor("#1D1D23"));
    try std.testing.expectEqual(@as(?u32, 0xFFFF9922), parseHexColor("#FF9922"));
    try std.testing.expectEqual(@as(?u32, 0xFF000000), parseHexColor("#000000"));
    try std.testing.expectEqual(@as(?u32, 0xFFFFFFFF), parseHexColor("#FFFFFF"));
}

test "parseHexColor without hash" {
    try std.testing.expectEqual(@as(?u32, 0xFFFF9922), parseHexColor("FF9922"));
}

test "parseHexColor lowercase" {
    try std.testing.expectEqual(@as(?u32, 0xFFff9922), parseHexColor("#ff9922"));
}

test "parseHexColor invalid" {
    try std.testing.expectEqual(@as(?u32, null), parseHexColor(""));
    try std.testing.expectEqual(@as(?u32, null), parseHexColor("#"));
    try std.testing.expectEqual(@as(?u32, null), parseHexColor("#FFF")); // too short
    try std.testing.expectEqual(@as(?u32, null), parseHexColor("#GGGGGG")); // invalid hex
    try std.testing.expectEqual(@as(?u32, null), parseHexColor("#FF99220")); // too long
}

test "parse key=value pairs" {
    const allocator = std.testing.allocator;

    const content =
        \\# teru configuration
        \\font_size = 14
        \\font_path = /usr/share/fonts/TTF/Hack-Regular.ttf
        \\bg = #1D1D23
        \\cursor_color = #FF9922
        \\scrollback_lines = 50000
        \\initial_width = 1200
        \\initial_height = 800
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 14), config.font_size);
    try std.testing.expect(config.font_path != null);
    try std.testing.expectEqualStrings("/usr/share/fonts/TTF/Hack-Regular.ttf", config.font_path.?);
    try std.testing.expectEqual(@as(u32, 0xFF1D1D23), config.bg);
    try std.testing.expectEqual(@as(u32, 0xFFFF9922), config.cursor_color);
    try std.testing.expectEqual(@as(u32, 50000), config.scrollback_lines);
    try std.testing.expectEqual(@as(u32, 1200), config.initial_width);
    try std.testing.expectEqual(@as(u32, 800), config.initial_height);
}

test "parse handles comments and blank lines" {
    const allocator = std.testing.allocator;

    const content =
        \\# Full line comment
        \\
        \\  # Indented comment
        \\font_size = 20
        \\
        \\
        \\initial_width = 1024
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);

    try std.testing.expectEqual(@as(u16, 20), config.font_size);
    try std.testing.expectEqual(@as(u32, 1024), config.initial_width);
    // Everything else should be defaults
    try std.testing.expectEqual(@as(?[]const u8, null), config.font_path);
    try std.testing.expectEqual(@as(u32, 640), config.initial_height);
}

test "parse ignores unknown keys" {
    const allocator = std.testing.allocator;

    const content =
        \\future_feature = yes
        \\font_size = 12
        \\unknown_color = #AABBCC
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);

    try std.testing.expectEqual(@as(u16, 12), config.font_size);
}

test "parse ignores malformed lines" {
    const allocator = std.testing.allocator;

    const content =
        \\no_equals_sign
        \\= no_key
        \\font_size=
        \\font_size = not_a_number
        \\bg = #GGHHII
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);

    // All should remain at defaults since values are invalid
    try std.testing.expectEqual(@as(u16, 16), config.font_size);
    try std.testing.expectEqual(@as(u32, 0xFF1D1D23), config.bg);
}

test "missing config file returns defaults" {
    const allocator = std.testing.allocator;

    // load() tries ~/.config/teru/teru.conf — almost certainly missing in test env
    var config = try Config.load(allocator, std.testing.io);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 16), config.font_size);
    try std.testing.expectEqual(@as(u32, 0xFF1D1D23), config.bg);
    try std.testing.expectEqual(@as(u32, 0xFFFAF8FB), config.fg);
    try std.testing.expectEqual(@as(u32, 0xFFFF9922), config.cursor_color);
    try std.testing.expectEqual(@as(u32, 10000), config.scrollback_lines);
    try std.testing.expectEqual(@as(u32, 960), config.initial_width);
    try std.testing.expectEqual(@as(u32, 640), config.initial_height);
}

test "deinit frees allocated strings" {
    const allocator = std.testing.allocator;

    const content =
        \\font_path = /some/path/font.ttf
        \\shell = /bin/zsh
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);

    try std.testing.expect(config.font_path != null);
    try std.testing.expect(config.shell != null);

    config.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), config.font_path);
    try std.testing.expectEqual(@as(?[]const u8, null), config.shell);
}

test "string fields can be overwritten" {
    const allocator = std.testing.allocator;

    const content =
        \\font_path = /first/path.ttf
        \\font_path = /second/path.ttf
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);
    defer config.deinit();

    try std.testing.expectEqualStrings("/second/path.ttf", config.font_path.?);
}
