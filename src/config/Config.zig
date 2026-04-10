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
const Grid = @import("../core/Grid.zig");
const LayoutEngine = @import("../tiling/LayoutEngine.zig");
const themes = @import("themes.zig");
pub const Keybinds = @import("Keybinds.zig");
const Config = @This();

pub const Bell = enum { visual, none };

// ── ColorScheme ──────────────────────────────────────────────────

/// Full base16 color scheme: 16 ANSI colors + semantic colors.
/// Built from Config fields. Passed to the renderer and multiplexer
/// so every color reference in the codebase comes from one place.
pub const ColorScheme = struct {
    /// ANSI colors 0-15 (indexed palette entries)
    ansi: [16]u32 = default_ansi,

    // Semantic colors (used for UI elements, not palette lookups)
    bg: u32 = 0xFF232733, // default background
    fg: u32 = 0xFFD0D2DB, // default foreground
    cursor: u32 = 0xFFFF9837, // cursor block color
    selection_bg: u32 = 0xFF3E4359, // selection highlight
    border_active: u32 = 0xFFFF9837, // active pane border
    border_inactive: u32 = 0xFF3E4359, // inactive pane border
    attention: u32 = 0xFFEB3137, // workspace attention indicator
    bold_is_bright: bool = false, // shift ANSI 0-7 to bright 8-15 when bold

    /// Miozu theme defaults for ANSI 0-15.
    pub const default_ansi = [16]u32{
        0xFF232733, // 0  black       (miozu00)
        0xFFEB3137, // 1  red
        0xFF6DD672, // 2  green
        0xFFE8D176, // 3  yellow
        0xFF83D2FC, // 4  blue
        0xFFC974E6, // 5  magenta
        0xFF40FFE2, // 6  cyan
        0xFFD0D2DB, // 7  white       (miozu05)
        0xFF565E78, // 8  bright black (miozu03 - comments)
        0xFFEB3137, // 9  bright red
        0xFF6DD672, // 10 bright green
        0xFFE8D176, // 11 bright yellow
        0xFF83D2FC, // 12 bright blue
        0xFFC974E6, // 13 bright magenta
        0xFF40FFE2, // 14 bright cyan
        0xFFF3F4F7, // 15 bright white (miozu06)
    };

    /// Resolve a Grid.Color to a packed ARGB u32, using this scheme's
    /// palette for indexed colors and default fg/bg.
    pub fn resolve(self: *const ColorScheme, color: @import("../core/Grid.zig").Color, is_fg: bool) u32 {
        return switch (color) {
            .default => if (is_fg) self.fg else self.bg,
            .indexed => |idx| self.indexed256(idx),
            .rgb => |c| packArgb(c.r, c.g, c.b),
        };
    }

    /// Look up a 256-color index. 0-15 come from the scheme's ansi table,
    /// 16-231 are the 6x6x6 color cube, 232-255 are the grayscale ramp.
    pub fn indexed256(self: *const ColorScheme, idx: u8) u32 {
        if (idx < 16) return self.ansi[idx];
        if (idx >= 232) {
            const v: u32 = @as(u32, idx - 232) * 10 + 8;
            return 0xFF000000 | (v << 16) | (v << 8) | v;
        }
        // 16-231: 6x6x6 color cube
        const i = @as(u32, idx) - 16;
        const b_val = i % 6;
        const g_val = (i / 6) % 6;
        const r_val = i / 36;
        const r: u32 = if (r_val == 0) 0 else r_val * 40 + 55;
        const g: u32 = if (g_val == 0) 0 else g_val * 40 + 55;
        const b: u32 = if (b_val == 0) 0 else b_val * 40 + 55;
        return 0xFF000000 | (r << 16) | (g << 8) | b;
    }

    /// Dim a color to 75% brightness (preserve alpha).
    pub fn dimColor(_: *const ColorScheme, argb: u32) u32 {
        const r = ((argb >> 16) & 0xFF) * 3 / 4;
        const g = ((argb >> 8) & 0xFF) * 3 / 4;
        const b = (argb & 0xFF) * 3 / 4;
        return (0xFF << 24) | (r << 16) | (g << 8) | b;
    }
};

/// Pack R, G, B bytes into an ARGB u32 with full alpha.
pub fn packArgb(r: u8, g: u8, b: u8) u32 {
    return (0xFF << 24) |
        (@as(u32, r) << 16) |
        (@as(u32, g) << 8) |
        @as(u32, b);
}

// ── Fields ────────────────────────────────────────────────────────

// Appearance
font_path: ?[]const u8 = null, // path to .ttf font
font_bold: ?[]const u8 = null, // path to bold .ttf
font_italic: ?[]const u8 = null, // path to italic .ttf
font_bold_italic: ?[]const u8 = null, // path to bold+italic .ttf
font_size: u16 = 16,

// Colors (miozu theme defaults — matches alacritty/ghostty miozu config)
bg: u32 = 0xFF232733, // miozu00 - darkest background
fg: u32 = 0xFFD0D2DB, // miozu05 - default foreground
cursor_color: u32 = 0xFFFF9837, // orange accent
selection_bg: u32 = 0xFF3E4359, // miozu02 - selection
border_active: u32 = 0xFFFF9837, // active pane border
border_inactive: u32 = 0xFF3E4359, // inactive pane border
attention_color: u32 = 0xFFEB3137, // workspace attention indicator

// ANSI palette overrides (color0-color15). null = use default from ColorScheme.
ansi_colors: [16]?u32 = .{null} ** 16,

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

// Appearance
padding: u32 = 8,
opacity: f32 = 1.0,
cursor_shape: Grid.CursorShape = .block,
cursor_blink: bool = false,
bold_is_bright: bool = false,

// Terminal
term: ?[]const u8 = null,
scroll_speed: u32 = 3,
copy_on_select: bool = true,
bell: Bell = .visual,
tab_width: u8 = 8,
dynamic_title: bool = true,

// Behavior
alt_workspace_switch: bool = true, // Alt+key shortcuts (workspace, focus, zoom, split)
mouse_hide_when_typing: bool = true,
restore_layout: bool = false, // save layout on exit, restore on launch (fresh shells)
persist_session: bool = false, // keep processes alive between window closes (daemon mode)
word_delimiters: ?[]const u8 = null,

// Timing
prefix_timeout_ms: u32 = 500,
notification_duration_ms: u32 = 5000,

// Theme
theme: ?[]const u8 = null,

// Status bar
show_status_bar: bool = true,
bar_left: ?[]const u8 = null, // format string (null = workspace tabs)
bar_center: ?[]const u8 = null, // format string (null = layout + title)
bar_right: ?[]const u8 = null, // format string (null = dimensions)

// Per-workspace config (10 workspaces, 1-indexed in config, 0-indexed in array)
workspace_layouts: [10]?LayoutEngine.Layout = .{null} ** 10,
workspace_ratios: [10]?f32 = .{null} ** 10,
workspace_names: [10]?[]const u8 = .{null} ** 10,
// Per-workspace layout lists (layouts = master-stack, grid, monocle)
workspace_layout_lists: [10][LayoutEngine.max_layouts]LayoutEngine.Layout = undefined,
workspace_layout_counts: [10]u8 = .{0} ** 10,

// Keybindings (loaded from [keybinds.*] sections or keybinds.conf)
keybinds: Keybinds.Keybinds = .{},
keybinds_loaded: bool = false, // true once any [keybinds.*] section is parsed

allocator: Allocator,

// ── Public API ────────────────────────────────────────────────────

/// Load configuration from ~/.config/teru/teru.conf.
/// Returns defaults if the file does not exist.
pub fn load(allocator: Allocator, io: Io) !Config {
    var config = Config{ .allocator = allocator };
    config.keybinds.loadDefaults();

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

    config.parseWithDepth(allocator, content[0..n], io, 0);

    // Load external theme file if theme was set and not a built-in
    if (config.theme) |name| {
        if (themes.getBuiltin(name) == null) {
            config.loadThemeFile(allocator, io, name);
        }
    }

    return config;
}

/// Reload config from disk. Returns a fresh Config.
/// Caller must deinit the OLD config after applying values.
pub fn reload(allocator: Allocator, io: Io) ?Config {
    var new_config = Config.load(allocator, io) catch return null;
    _ = &new_config;
    return new_config;
}

/// Free any allocator-owned string fields.
pub fn deinit(self: *Config) void {
    if (self.font_path) |p| self.allocator.free(p);
    if (self.font_bold) |p| self.allocator.free(p);
    if (self.font_italic) |p| self.allocator.free(p);
    if (self.font_bold_italic) |p| self.allocator.free(p);
    if (self.shell) |s| self.allocator.free(s);
    if (self.hook_on_spawn) |s| self.allocator.free(s);
    if (self.hook_on_close) |s| self.allocator.free(s);
    if (self.hook_on_agent_start) |s| self.allocator.free(s);
    if (self.hook_on_session_save) |s| self.allocator.free(s);
    if (self.term) |s| self.allocator.free(s);
    if (self.word_delimiters) |s| self.allocator.free(s);
    if (self.theme) |s| self.allocator.free(s);
    for (&self.workspace_names) |*name| {
        if (name.*) |s| self.allocator.free(s);
        name.* = null;
    }
    self.font_path = null;
    self.font_bold = null;
    self.font_italic = null;
    self.font_bold_italic = null;
    self.shell = null;
    self.hook_on_spawn = null;
    self.hook_on_close = null;
    self.hook_on_agent_start = null;
    self.hook_on_session_save = null;
    self.term = null;
    self.word_delimiters = null;
    self.theme = null;
    if (self.bar_left) |p| self.allocator.free(p);
    if (self.bar_center) |p| self.allocator.free(p);
    if (self.bar_right) |p| self.allocator.free(p);
    self.bar_left = null;
    self.bar_center = null;
    self.bar_right = null;
}

/// Load a theme from ~/.config/teru/themes/<name>.conf.
/// The file uses key=value format supporting base16 keys (base00-base0F),
/// direct ANSI colors (color0-color15), and semantic colors (bg, fg, etc.).
fn loadThemeFile(self: *Config, allocator: Allocator, io: Io, name: []const u8) void {
    const home = compat.getenv("HOME") orelse return;

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/teru/themes/{s}.conf", .{ home, name }) catch return;

    const file = Dir.cwd().openFile(io, path, .{}) catch return;
    defer file.close(io);

    const s = file.stat(io) catch return;
    const size: usize = @intCast(s.size);
    if (size > 64 * 1024) return;
    const content = allocator.alloc(u8, size) catch return;
    defer allocator.free(content);
    const n = file.readPositionalAll(io, content, 0) catch return;

    var line_iter = std.mem.splitScalar(u8, content[0..n], '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;

        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_pos], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[eq_pos + 1 ..], &std.ascii.whitespace);
        if (key.len == 0 or value.len == 0) continue;

        const color = parseHexColor(value) orelse continue;

        // Try base16 key first
        var scheme = self.colorScheme();
        if (themes.applyBase16Key(&scheme, key, color)) {
            // Write scheme back to config fields
            self.bg = scheme.bg;
            self.fg = scheme.fg;
            self.cursor_color = scheme.cursor;
            self.selection_bg = scheme.selection_bg;
            self.border_active = scheme.border_active;
            self.border_inactive = scheme.border_inactive;
            for (scheme.ansi, 0..) |c, i| self.ansi_colors[i] = c;
            continue;
        }

        // Direct color keys
        if (std.mem.eql(u8, key, "bg")) {
            self.bg = color;
        } else if (std.mem.eql(u8, key, "fg")) {
            self.fg = color;
        } else if (std.mem.eql(u8, key, "cursor_color")) {
            self.cursor_color = color;
        } else if (std.mem.eql(u8, key, "selection_bg")) {
            self.selection_bg = color;
        } else if (std.mem.eql(u8, key, "border_active")) {
            self.border_active = color;
        } else if (std.mem.eql(u8, key, "border_inactive")) {
            self.border_inactive = color;
        } else if (key.len >= 6 and key.len <= 7 and std.mem.startsWith(u8, key, "color")) {
            const idx = std.fmt.parseInt(u8, key[5..], 10) catch continue;
            if (idx > 15) continue;
            self.ansi_colors[idx] = color;
        }
    }
}

/// Build a ColorScheme from the current config fields.
/// ANSI colors 0-15 are overridden by color0-color15 if set.
/// Default word delimiters for double-click word selection.
pub const default_word_delimiters = " \t{}[]()\"'`,;:@";

/// Return the effective word delimiters (user-configured or default).
pub fn getWordDelimiters(self: *const Config) []const u8 {
    return self.word_delimiters orelse default_word_delimiters;
}

pub fn colorScheme(self: *const Config) ColorScheme {
    var scheme = ColorScheme{
        .bg = self.bg,
        .fg = self.fg,
        .cursor = self.cursor_color,
        .selection_bg = self.selection_bg,
        .border_active = self.border_active,
        .border_inactive = self.border_inactive,
        .attention = self.attention_color,
        .bold_is_bright = self.bold_is_bright,
    };
    for (self.ansi_colors, 0..) |maybe_color, i| {
        if (maybe_color) |color| {
            scheme.ansi[i] = color;
        }
    }
    return scheme;
}

// ── Parsing ───────────────────────────────────────────────────────

fn parse(self: *Config, allocator: Allocator, content: []const u8) void {
    self.parseWithDepth(allocator, content, null, 0);
}

fn parseWithDepth(self: *Config, allocator: Allocator, content: []const u8, io: ?Io, depth: u8) void {
    if (depth > 4) return; // prevent infinite include cycles

    var current_section: ?[]const u8 = null;
    var keybind_mode: ?Keybinds.Mode = null; // non-null when inside [keybinds.*]
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);

        // Skip empty lines and comments
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        // Include directive: include <path>
        if (std.mem.startsWith(u8, line, "include ")) {
            if (io) |real_io| {
                const inc_path = std.mem.trim(u8, line["include ".len..], &std.ascii.whitespace);
                if (inc_path.len > 0) self.loadInclude(allocator, real_io, inc_path, depth + 1);
            }
            continue;
        }

        // Section header: [section_name]
        if (line[0] == '[') {
            if (std.mem.indexOfScalar(u8, line, ']')) |end| {
                current_section = line[1..end];
                // Check for [keybinds.MODE]
                if (std.mem.startsWith(u8, current_section.?, "keybinds.")) {
                    const mode_str = current_section.?["keybinds.".len..];
                    keybind_mode = Keybinds.Mode.fromString(mode_str);
                    if (keybind_mode != null and !self.keybinds_loaded) {
                        // First keybinds section: start fresh (user overrides all)
                        self.keybinds.count = 0;
                        self.keybinds.loadDefaults();
                        self.keybinds_loaded = true;
                    }
                } else {
                    keybind_mode = null;
                }
            }
            continue;
        }

        // If inside a [keybinds.*] section, route to keybind parser
        if (keybind_mode) |mode| {
            self.keybinds.parseLine(mode, line);
            continue;
        }

        // Split on first '='
        const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq_pos], &std.ascii.whitespace);
        const value = std.mem.trim(u8, line[eq_pos + 1 ..], &std.ascii.whitespace);

        if (key.len == 0 or value.len == 0) continue;

        self.applyField(allocator, current_section, key, value);
    }
}

/// Load an included config file. Relative paths resolve from ~/.config/teru/.
fn loadInclude(self: *Config, allocator: Allocator, io: Io, path: []const u8, depth: u8) void {
    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const full_path = if (path.len > 0 and path[0] == '/')
        path
    else blk: {
        const home = compat.getenv("HOME") orelse return;
        break :blk std.fmt.bufPrint(&path_buf, "{s}/.config/teru/{s}", .{ home, path }) catch return;
    };

    const file = Dir.cwd().openFile(io, full_path, .{}) catch return;
    defer file.close(io);

    const s = file.stat(io) catch return;
    const size: usize = @intCast(s.size);
    if (size > 64 * 1024) return;
    const content = allocator.alloc(u8, size) catch return;
    defer allocator.free(content);
    const n = file.readPositionalAll(io, content, 0) catch return;

    self.parseWithDepth(allocator, content[0..n], io, depth);
}

fn applyField(self: *Config, allocator: Allocator, section: ?[]const u8, key: []const u8, value: []const u8) void {
    // Delegate workspace section keys
    if (section) |sec| {
        if (std.mem.startsWith(u8, sec, "workspace.")) {
            const idx_str = sec["workspace.".len..];
            const ws_idx_1 = std.fmt.parseInt(usize, idx_str, 10) catch return;
            if (ws_idx_1 < 1 or ws_idx_1 > 9) return;
            self.applyWorkspaceField(allocator, ws_idx_1 - 1, key, value);
            return;
        }
    }

    if (std.mem.eql(u8, key, "font_size")) {
        self.font_size = std.fmt.parseInt(u16, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "font_path")) {
        self.setString(allocator, &self.font_path, value);
    } else if (std.mem.eql(u8, key, "font_bold")) {
        self.setString(allocator, &self.font_bold, value);
    } else if (std.mem.eql(u8, key, "font_italic")) {
        self.setString(allocator, &self.font_italic, value);
    } else if (std.mem.eql(u8, key, "font_bold_italic")) {
        self.setString(allocator, &self.font_bold_italic, value);
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
    } else if (std.mem.eql(u8, key, "attention_color")) {
        self.attention_color = parseHexColor(value) orelse return;
    } else if (std.mem.eql(u8, key, "scrollback_lines")) {
        self.scrollback_lines = @min(std.fmt.parseInt(u32, value, 10) catch return, 1_000_000);
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
    } else if (std.mem.eql(u8, key, "padding")) {
        self.padding = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "opacity")) {
        self.opacity = parseFloat(value) orelse return;
    } else if (std.mem.eql(u8, key, "cursor_shape")) {
        self.cursor_shape = parseCursorShape(value) orelse return;
    } else if (std.mem.eql(u8, key, "cursor_blink")) {
        self.cursor_blink = parseBool(value) orelse return;
    } else if (std.mem.eql(u8, key, "bold_is_bright")) {
        self.bold_is_bright = parseBool(value) orelse return;
    } else if (std.mem.eql(u8, key, "term")) {
        self.setString(allocator, &self.term, value);
    } else if (std.mem.eql(u8, key, "scroll_speed")) {
        self.scroll_speed = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "copy_on_select")) {
        self.copy_on_select = parseBool(value) orelse return;
    } else if (std.mem.eql(u8, key, "bell")) {
        self.bell = parseBell(value) orelse return;
    } else if (std.mem.eql(u8, key, "alt_workspace_switch")) {
        self.alt_workspace_switch = parseBool(value) orelse return;
    } else if (std.mem.eql(u8, key, "mouse_hide_when_typing")) {
        self.mouse_hide_when_typing = parseBool(value) orelse return;
    } else if (std.mem.eql(u8, key, "restore_layout")) {
        self.restore_layout = parseBool(value) orelse return;
    } else if (std.mem.eql(u8, key, "persist_session")) {
        self.persist_session = parseBool(value) orelse return;
    } else if (std.mem.eql(u8, key, "word_delimiters")) {
        self.setString(allocator, &self.word_delimiters, value);
    } else if (std.mem.eql(u8, key, "show_status_bar")) {
        self.show_status_bar = parseBool(value) orelse return;
    } else if (std.mem.eql(u8, key, "bar_left")) {
        self.setString(allocator, &self.bar_left, value);
    } else if (std.mem.eql(u8, key, "bar_center")) {
        self.setString(allocator, &self.bar_center, value);
    } else if (std.mem.eql(u8, key, "bar_right")) {
        self.setString(allocator, &self.bar_right, value);
    } else if (std.mem.eql(u8, key, "prefix_timeout_ms")) {
        self.prefix_timeout_ms = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "notification_duration_ms")) {
        self.notification_duration_ms = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "theme")) {
        self.setString(allocator, &self.theme, value);
        // Apply theme colors immediately — subsequent color keys override
        if (themes.getBuiltin(value)) |scheme| {
            self.bg = scheme.bg;
            self.fg = scheme.fg;
            self.cursor_color = scheme.cursor;
            self.selection_bg = scheme.selection_bg;
            self.border_active = scheme.border_active;
            self.border_inactive = scheme.border_inactive;
            self.ansi_colors = [_]?u32{null} ** 16;
            for (scheme.ansi, 0..) |c, i| self.ansi_colors[i] = c;
        }
    } else if (key.len >= 6 and key.len <= 7 and std.mem.startsWith(u8, key, "color")) {
        // color0 through color15
        const idx = std.fmt.parseInt(u8, key[5..], 10) catch return;
        if (idx > 15) return;
        self.ansi_colors[idx] = parseHexColor(value) orelse return;
    }
    // Unknown keys are silently ignored (forward-compatibility)
}

fn applyWorkspaceField(self: *Config, allocator: Allocator, ws_idx: usize, key: []const u8, value: []const u8) void {
    if (ws_idx >= 10) return;
    if (std.mem.eql(u8, key, "layout")) {
        self.workspace_layouts[ws_idx] = parseLayout(value);
    } else if (std.mem.eql(u8, key, "layouts")) {
        self.workspace_layout_counts[ws_idx] = parseLayoutList(value, &self.workspace_layout_lists[ws_idx]);
    } else if (std.mem.eql(u8, key, "master_ratio")) {
        self.workspace_ratios[ws_idx] = parseFloat(value);
    } else if (std.mem.eql(u8, key, "name")) {
        // Free any previous name
        if (self.workspace_names[ws_idx]) |prev| allocator.free(prev);
        self.workspace_names[ws_idx] = allocator.dupe(u8, value) catch null;
    }
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

// ── Value parsers ────────────────────────────────────────────────

fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "1")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "no") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

fn parseFloat(value: []const u8) ?f32 {
    return std.fmt.parseFloat(f32, value) catch return null;
}

fn parseLayout(value: []const u8) ?LayoutEngine.Layout {
    if (std.mem.eql(u8, value, "master-stack") or std.mem.eql(u8, value, "master_stack")) return .master_stack;
    if (std.mem.eql(u8, value, "grid")) return .grid;
    if (std.mem.eql(u8, value, "monocle")) return .monocle;
    if (std.mem.eql(u8, value, "dishes")) return .dishes;
    if (std.mem.eql(u8, value, "accordion")) return .accordion;
    if (std.mem.eql(u8, value, "spiral")) return .spiral;
    if (std.mem.eql(u8, value, "three-col") or std.mem.eql(u8, value, "three_col")) return .three_col;
    if (std.mem.eql(u8, value, "columns")) return .columns;
    return null;
}

/// Parse a comma-separated list of layout names.
/// Returns the count of successfully parsed layouts written into `out`.
fn parseLayoutList(value: []const u8, out: *[LayoutEngine.max_layouts]LayoutEngine.Layout) u8 {
    var count: u8 = 0;
    var iter = std.mem.splitScalar(u8, value, ',');
    while (iter.next()) |raw| {
        if (count >= LayoutEngine.max_layouts) break;
        const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (parseLayout(trimmed)) |layout| {
            out[count] = layout;
            count += 1;
        }
    }
    return count;
}

fn parseCursorShape(value: []const u8) ?Grid.CursorShape {
    if (std.mem.eql(u8, value, "block")) return .block;
    if (std.mem.eql(u8, value, "underline")) return .underline;
    if (std.mem.eql(u8, value, "bar")) return .bar;
    return null;
}

fn parseBell(value: []const u8) ?Bell {
    if (std.mem.eql(u8, value, "visual")) return .visual;
    if (std.mem.eql(u8, value, "none")) return .none;
    return null;
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
    try std.testing.expectEqual(@as(u32, 0xFF232733), config.bg);
}

test "missing config file returns defaults" {
    const allocator = std.testing.allocator;

    // load() tries ~/.config/teru/teru.conf — almost certainly missing in test env
    var config = try Config.load(allocator, std.testing.io);
    defer config.deinit();

    try std.testing.expectEqual(@as(u16, 16), config.font_size);
    try std.testing.expectEqual(@as(u32, 0xFF232733), config.bg);
    try std.testing.expectEqual(@as(u32, 0xFFD0D2DB), config.fg);
    try std.testing.expectEqual(@as(u32, 0xFFFF9837), config.cursor_color);
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

test "colorScheme returns defaults" {
    const allocator = std.testing.allocator;
    const config = Config{ .allocator = allocator };
    const scheme = config.colorScheme();

    try std.testing.expectEqual(@as(u32, 0xFF232733), scheme.bg);
    try std.testing.expectEqual(@as(u32, 0xFFD0D2DB), scheme.fg);
    try std.testing.expectEqual(@as(u32, 0xFFFF9837), scheme.cursor);
    try std.testing.expectEqual(@as(u32, 0xFF3E4359), scheme.selection_bg);
    try std.testing.expectEqual(@as(u32, 0xFF232733), scheme.ansi[0]); // black
    try std.testing.expectEqual(@as(u32, 0xFFEB3137), scheme.ansi[1]); // red
    try std.testing.expectEqual(@as(u32, 0xFFF3F4F7), scheme.ansi[15]); // bright white
}

test "colorScheme with color overrides" {
    const allocator = std.testing.allocator;

    const content =
        \\color0 = #000000
        \\color1 = #FF0000
        \\color15 = #FFFFFF
        \\bg = #111111
        \\fg = #EEEEEE
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);
    const scheme = config.colorScheme();

    try std.testing.expectEqual(@as(u32, 0xFF000000), scheme.ansi[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), scheme.ansi[1]);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), scheme.ansi[15]);
    try std.testing.expectEqual(@as(u32, 0xFF111111), scheme.bg);
    try std.testing.expectEqual(@as(u32, 0xFFEEEEEE), scheme.fg);
    // Non-overridden colors stay at default
    try std.testing.expectEqual(@as(u32, 0xFF6DD672), scheme.ansi[2]); // green
}

test "colorScheme resolve" {
    const allocator = std.testing.allocator;
    const config = Config{ .allocator = allocator };
    const scheme = config.colorScheme();

    // Default colors
    try std.testing.expectEqual(scheme.fg, scheme.resolve(.default, true));
    try std.testing.expectEqual(scheme.bg, scheme.resolve(.default, false));

    // Indexed color
    try std.testing.expectEqual(scheme.ansi[1], scheme.resolve(.{ .indexed = 1 }, true));

    // RGB passthrough
    try std.testing.expectEqual(packArgb(128, 64, 255), scheme.resolve(.{ .rgb = .{ .r = 128, .g = 64, .b = 255 } }, true));

    // 256-color cube
    const idx232 = scheme.indexed256(232);
    try std.testing.expectEqual(packArgb(8, 8, 8), idx232);

    // Dim
    const bright = packArgb(200, 100, 50);
    try std.testing.expectEqual(packArgb(150, 75, 37), scheme.dimColor(bright));
}

test "parse color0-color15 keys" {
    const allocator = std.testing.allocator;

    const content =
        \\color0 = #000000
        \\color7 = #BBBBBB
        \\color15 = #FFFFFF
        \\color16 = #ABCDEF
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);

    try std.testing.expectEqual(@as(?u32, 0xFF000000), config.ansi_colors[0]);
    try std.testing.expectEqual(@as(?u32, 0xFFBBBBBB), config.ansi_colors[7]);
    try std.testing.expectEqual(@as(?u32, 0xFFFFFFFF), config.ansi_colors[15]);
    // color16 should be ignored (out of range)
    // Check that no other ansi_colors were set
    try std.testing.expectEqual(@as(?u32, null), config.ansi_colors[1]);
}

test "parse new flat fields" {
    const allocator = std.testing.allocator;

    const content =
        \\padding = 12
        \\opacity = 0.85
        \\cursor_shape = bar
        \\cursor_blink = true
        \\bold_is_bright = yes
        \\term = xterm-256color
        \\scroll_speed = 5
        \\copy_on_select = 1
        \\bell = none
        \\prefix_timeout_ms = 1000
        \\notification_duration_ms = 3000
        \\theme = miozu
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 12), config.padding);
    try std.testing.expect(@abs(config.opacity - 0.85) < 0.001);
    try std.testing.expectEqual(Grid.CursorShape.bar, config.cursor_shape);
    try std.testing.expect(config.cursor_blink);
    try std.testing.expect(config.bold_is_bright);
    try std.testing.expectEqualStrings("xterm-256color", config.term.?);
    try std.testing.expectEqual(@as(u32, 5), config.scroll_speed);
    try std.testing.expect(config.copy_on_select);
    try std.testing.expectEqual(Bell.none, config.bell);
    try std.testing.expectEqual(@as(u32, 1000), config.prefix_timeout_ms);
    try std.testing.expectEqual(@as(u32, 3000), config.notification_duration_ms);
    try std.testing.expectEqualStrings("miozu", config.theme.?);
}

test "parse workspace sections" {
    const allocator = std.testing.allocator;

    const content =
        \\font_size = 14
        \\
        \\[workspace.1]
        \\layout = master-stack
        \\master_ratio = 0.6
        \\name = code
        \\
        \\[workspace.3]
        \\layout = grid
        \\name = monitoring
        \\
        \\[workspace.9]
        \\layout = monocle
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);
    defer config.deinit();

    // Global field still works
    try std.testing.expectEqual(@as(u16, 14), config.font_size);

    // Workspace 1 (index 0)
    try std.testing.expectEqual(LayoutEngine.Layout.master_stack, config.workspace_layouts[0].?);
    try std.testing.expect(@abs(config.workspace_ratios[0].? - 0.6) < 0.001);
    try std.testing.expectEqualStrings("code", config.workspace_names[0].?);

    // Workspace 2 (index 1) — not set
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, null), config.workspace_layouts[1]);
    try std.testing.expectEqual(@as(?f32, null), config.workspace_ratios[1]);
    try std.testing.expectEqual(@as(?[]const u8, null), config.workspace_names[1]);

    // Workspace 3 (index 2)
    try std.testing.expectEqual(LayoutEngine.Layout.grid, config.workspace_layouts[2].?);
    try std.testing.expectEqualStrings("monitoring", config.workspace_names[2].?);

    // Workspace 9 (index 8)
    try std.testing.expectEqual(LayoutEngine.Layout.monocle, config.workspace_layouts[8].?);
}

test "parseBool" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("true"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("yes"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("1"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("false"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("no"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("0"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("maybe"));
    try std.testing.expectEqual(@as(?bool, null), parseBool(""));
}

test "parseFloat" {
    const v1 = parseFloat("0.5");
    try std.testing.expect(v1 != null);
    try std.testing.expect(@abs(v1.? - 0.5) < 0.001);

    const v2 = parseFloat("1.0");
    try std.testing.expect(v2 != null);
    try std.testing.expect(@abs(v2.? - 1.0) < 0.001);

    try std.testing.expectEqual(@as(?f32, null), parseFloat("abc"));
    try std.testing.expectEqual(@as(?f32, null), parseFloat(""));
}

test "parseLayout" {
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .master_stack), parseLayout("master-stack"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .master_stack), parseLayout("master_stack"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .grid), parseLayout("grid"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .monocle), parseLayout("monocle"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .dishes), parseLayout("dishes"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .accordion), parseLayout("accordion"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, null), parseLayout("floating"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .spiral), parseLayout("spiral"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .three_col), parseLayout("three-col"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .three_col), parseLayout("three_col"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, .columns), parseLayout("columns"));
    try std.testing.expectEqual(@as(?LayoutEngine.Layout, null), parseLayout("unknown"));
}

test "parseLayoutList" {
    var buf: [LayoutEngine.max_layouts]LayoutEngine.Layout = undefined;

    // Basic comma-separated list
    const n1 = parseLayoutList("master-stack, grid, monocle", &buf);
    try std.testing.expectEqual(@as(u8, 3), n1);
    try std.testing.expectEqual(LayoutEngine.Layout.master_stack, buf[0]);
    try std.testing.expectEqual(LayoutEngine.Layout.grid, buf[1]);
    try std.testing.expectEqual(LayoutEngine.Layout.monocle, buf[2]);

    // With new layout types
    const n2 = parseLayoutList("spiral, three-col, columns", &buf);
    try std.testing.expectEqual(@as(u8, 3), n2);
    try std.testing.expectEqual(LayoutEngine.Layout.spiral, buf[0]);
    try std.testing.expectEqual(LayoutEngine.Layout.three_col, buf[1]);
    try std.testing.expectEqual(LayoutEngine.Layout.columns, buf[2]);

    // Invalid entries are skipped
    const n3 = parseLayoutList("grid, bogus, monocle", &buf);
    try std.testing.expectEqual(@as(u8, 2), n3);
    try std.testing.expectEqual(LayoutEngine.Layout.grid, buf[0]);
    try std.testing.expectEqual(LayoutEngine.Layout.monocle, buf[1]);

    // Empty string
    const n4 = parseLayoutList("", &buf);
    try std.testing.expectEqual(@as(u8, 0), n4);

    // Single layout
    const n5 = parseLayoutList("spiral", &buf);
    try std.testing.expectEqual(@as(u8, 1), n5);
    try std.testing.expectEqual(LayoutEngine.Layout.spiral, buf[0]);
}

test "parse workspace layouts list" {
    const allocator = std.testing.allocator;

    const content =
        \\[workspace.1]
        \\layouts = master-stack, grid, monocle
        \\name = code
        \\
        \\[workspace.2]
        \\layouts = spiral, three-col
        \\master_ratio = 0.5
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);
    defer config.deinit();

    // Workspace 1 layout list
    try std.testing.expectEqual(@as(u8, 3), config.workspace_layout_counts[0]);
    try std.testing.expectEqual(LayoutEngine.Layout.master_stack, config.workspace_layout_lists[0][0]);
    try std.testing.expectEqual(LayoutEngine.Layout.grid, config.workspace_layout_lists[0][1]);
    try std.testing.expectEqual(LayoutEngine.Layout.monocle, config.workspace_layout_lists[0][2]);

    // Workspace 2 layout list
    try std.testing.expectEqual(@as(u8, 2), config.workspace_layout_counts[1]);
    try std.testing.expectEqual(LayoutEngine.Layout.spiral, config.workspace_layout_lists[1][0]);
    try std.testing.expectEqual(LayoutEngine.Layout.three_col, config.workspace_layout_lists[1][1]);

    // Workspace 3 — not set
    try std.testing.expectEqual(@as(u8, 0), config.workspace_layout_counts[2]);
}

test "parseCursorShape" {
    try std.testing.expectEqual(@as(?Grid.CursorShape, .block), parseCursorShape("block"));
    try std.testing.expectEqual(@as(?Grid.CursorShape, .underline), parseCursorShape("underline"));
    try std.testing.expectEqual(@as(?Grid.CursorShape, .bar), parseCursorShape("bar"));
    try std.testing.expectEqual(@as(?Grid.CursorShape, null), parseCursorShape("invalid"));
}

test "parseBell" {
    try std.testing.expectEqual(@as(?Bell, .visual), parseBell("visual"));
    try std.testing.expectEqual(@as(?Bell, .none), parseBell("none"));
    try std.testing.expectEqual(@as(?Bell, null), parseBell("audible"));
}

test "theme = miozu applies miozu colors" {
    const allocator = std.testing.allocator;

    const content =
        \\theme = miozu
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 0xFF232733), config.bg);
    try std.testing.expectEqual(@as(u32, 0xFFD0D2DB), config.fg);
    try std.testing.expectEqual(@as(u32, 0xFFFF9837), config.cursor_color);
    try std.testing.expectEqual(@as(u32, 0xFF3E4359), config.selection_bg);
    try std.testing.expectEqual(@as(?u32, 0xFFEB3137), config.ansi_colors[1]); // red
    try std.testing.expectEqual(@as(?u32, 0xFF6DD672), config.ansi_colors[2]); // green

    const scheme = config.colorScheme();
    try std.testing.expectEqual(@as(u32, 0xFF232733), scheme.bg);
    try std.testing.expectEqual(@as(u32, 0xFFEB3137), scheme.ansi[1]);
}

test "theme colors can be overridden by subsequent keys" {
    const allocator = std.testing.allocator;

    const content =
        \\theme = miozu
        \\bg = #000000
        \\color1 = #FF0000
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);
    defer config.deinit();

    // bg overridden after theme
    try std.testing.expectEqual(@as(u32, 0xFF000000), config.bg);
    // color1 overridden after theme
    try std.testing.expectEqual(@as(?u32, 0xFFFF0000), config.ansi_colors[1]);
    // fg still from miozu
    try std.testing.expectEqual(@as(u32, 0xFFD0D2DB), config.fg);
}

test "unknown theme name leaves defaults" {
    const allocator = std.testing.allocator;

    const content =
        \\theme = nonexistent
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);
    defer config.deinit();

    // Should remain at defaults since theme name is unknown
    try std.testing.expectEqual(@as(u32, 0xFF232733), config.bg);
    try std.testing.expectEqual(@as(u32, 0xFFD0D2DB), config.fg);
    try std.testing.expectEqualStrings("nonexistent", config.theme.?);
}

test "deinit frees workspace names" {
    const allocator = std.testing.allocator;

    const content =
        \\[workspace.1]
        \\name = dev
        \\[workspace.5]
        \\name = chat
    ;

    var config = Config{ .allocator = allocator };
    config.parse(allocator, content);

    try std.testing.expectEqualStrings("dev", config.workspace_names[0].?);
    try std.testing.expectEqualStrings("chat", config.workspace_names[4].?);

    config.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), config.workspace_names[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), config.workspace_names[4]);
}
