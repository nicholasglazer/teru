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

/// Max bytes per [keyboard] field (xkb_layout, xkb_variant, xkb_options,
/// xkb_model, xkb_rules). Headroom for comma-separated multi-layout lists.
const kb_field_max = 128;

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

pub const max_spawn_chords = 32; // matches Action.spawn_0..spawn_31

/// User-defined spawn keybind. Chord is the unparsed token on the LHS
/// of a `[keybind]` entry (e.g. "Mod+Return"); cmd is the shell command
/// to exec. Server resolves `chord` into (mods, key) and wires it into
/// the active Keybinds table on init.
pub const SpawnChord = struct {
    chord: [64]u8 = undefined,
    chord_len: u8 = 0,
    cmd: [256]u8 = undefined,
    cmd_len: u16 = 0,

    pub fn getChord(self: *const SpawnChord) []const u8 {
        return self.chord[0..self.chord_len];
    }
    pub fn getCmd(self: *const SpawnChord) []const u8 {
        return self.cmd[0..self.cmd_len];
    }
};

pub const max_name_rules = 32;

/// Compile-time default that Server.init references before WmConfig is
/// loaded. Keep in lockstep with the cursor_size field default below.
pub const default_cursor_size: u32 = 24;

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

/// Border width in pixels around focused/unfocused windows. 0 hides
/// borders completely. Applied uniformly to terminals, xdg clients,
/// and XWayland clients.
border_width: u16 = 2,

/// Border colour for the currently-focused window. ARGB u32 — high
/// byte is alpha so users can make borders translucent (e.g.
/// 0x80FF7733 = 50 %-alpha orange). Accepts 0xAARRGGBB or #AARRGGBB.
border_color_focused: u32 = 0xFFFF7733,

/// Border colour for unfocused windows. Dimmer by default so the
/// focused window is easy to spot in a dense tiling layout.
border_color_unfocused: u32 = 0xFF3a3d44,

/// Compositor background color (ARGB u32). Visible through gaps between
/// panes/bars. Config accepts `bg = 0x1a1d24` or `bg = #1a1d24`.
/// Default: miozu dark gray (0xFF1a1d24).
bg_color: u32 = 0xFF1a1d24,

/// Opacity applied to unfocused terminal panes on focus change
/// (since v0.4.16). Range [0.0, 1.0]; 1.0 = no fade. wlroots blends
/// on composite — CPU renderer cost is unchanged.
unfocused_opacity: f32 = 1.0,

// ── Cursor / input ──────────────────────────────────────────────

/// Logical cursor size in px (xcursor loads a bitmap at this size).
/// Not yet reloadable at runtime — xcursor_manager is created during
/// Server init before config applies; changing this requires restart.
cursor_size: u32 = default_cursor_size,

/// Pixel width of the border-drag hit zone inside each pane. Clicks
/// within this distance of a pane's edge start a border-resize drag
/// instead of focusing the pane. 2 is the outer insensitive ring,
/// 8 is the wider draggable zone past the insensitive ring.
border_drag_insensitive_px: i32 = 2,
border_drag_zone_px: i32 = 8,

// ── Floating / scratchpad defaults ──────────────────────────────

/// Default size of a newly-floated window (pre-xdg-toplevel-configure
/// dimensions). Clients override via set_size; this is the fallback.
float_default_w: u32 = 640,
float_default_h: u32 = 480,

/// Minimum pane dimension allowed during interactive resize drag.
resize_min_px: i32 = 100,

/// Named-scratchpad geometry (% of output). Rect is centered.
scratchpad_width_pct: u8 = 35,
scratchpad_height_pct: u8 = 40,

// ── Synthetic-mouse trajectory ─────────────────────────────────

/// Humanize synthetic cursor movement. Default off — warps are
/// instant, matching naive bot behaviour. When on, test_drag and
/// the dedicated `teruwm_mouse_path` MCP tool sample a Bezier curve
/// between from/to with per-waypoint jitter and real wall-clock
/// delays. Useful for automation that needs to look like a person
/// (browsing-data collection, UI smoke tests against anti-bot
/// heuristics). Explicit `humanize: true` on `teruwm_mouse_path`
/// overrides this per-call.
mouse_humanize: bool = false,

/// Default wall-clock duration for a humanized path, in ms. Fitts-
/// law-ish — longer for longer distances too, but this is the floor.
mouse_path_default_ms: u32 = 250,

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

// ── User-defined spawn chords ──────────────────────────────────

/// Keybinds from the `[keybind]` section with `spawn:<cmd>` actions.
/// Applied by the compositor on init/reload — each entry gets a
/// spawn_table slot in Server and a binding in Keybinds.
spawn_chords: [max_spawn_chords]SpawnChord = undefined,
spawn_chord_count: u8 = 0,

// ── DynamicProjects — per-workspace CWD + startup (v0.4.17) ────

/// Startup command for workspace N (1-indexed in config, 0-indexed
/// internally). Fired when the workspace is visited and empty
/// (xmonad DynamicProjects `projectStartHook` semantics). Null = no
/// startup action.
workspace_startup: [10]?[]const u8 = [_]?[]const u8{null} ** 10,
workspace_startup_buf: [10][256]u8 = undefined,
workspace_startup_len: [10]u16 = [_]u16{0} ** 10,

/// Working directory for panes spawned on workspace N via
/// spawn_terminal (xmonad `projectDirectory`). Tilde-expanded at
/// startup. Null = inherit the compositor's CWD.
workspace_cwd: [10]?[]const u8 = [_]?[]const u8{null} ** 10,
workspace_cwd_buf: [10][256]u8 = undefined,
workspace_cwd_len: [10]u16 = [_]u16{0} ** 10,

/// Which workspaces have already had their startup hook fired. Flips
/// true on first switch-to-empty; reset when workspace becomes
/// empty again (so revisit re-runs the hook).
workspace_startup_fired: [10]bool = [_]bool{false} ** 10,

// ── Keyboard (xkb_rule_names — libxkbcommon) ───────────────────
//
// Compositor config is the source of truth for xkb settings, mirroring
// Sway's `input ... xkb_layout` pattern. Each field is either set in
// the config file or left empty — an empty field passes NULL to
// xkb_keymap_new_from_names, which then consults `XKB_DEFAULT_*` env
// vars and libxkbcommon's built-in defaults. This gives three layers:
//
//   1. teruwm [keyboard] section     (this)
//   2. XKB_DEFAULT_* env vars        (environment.d, shell)
//   3. libxkbcommon compiled-in default (us QWERTY)
//
// Config syntax (Sway-compatible naming):
//   [keyboard]
//   xkb_layout = us,ua
//   xkb_variant = dvorak,
//   xkb_options = grp:alt_shift_toggle,caps:escape
//   xkb_model = pc105
//   xkb_rules = evdev
//
// Storage is fixed-size nul-terminated buffers so getters can hand a
// `[*:0]const u8` straight to the C struct with no allocator or copy.

xkb_layout_buf: [kb_field_max:0]u8 = undefined,
xkb_layout_len: u8 = 0,
xkb_variant_buf: [kb_field_max:0]u8 = undefined,
xkb_variant_len: u8 = 0,
xkb_options_buf: [kb_field_max:0]u8 = undefined,
xkb_options_len: u8 = 0,
xkb_model_buf: [kb_field_max:0]u8 = undefined,
xkb_model_len: u8 = 0,
xkb_rules_buf: [kb_field_max:0]u8 = undefined,
xkb_rules_len: u8 = 0,

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
    var current_ws_idx: ?u8 = null;
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
                // Parse `[workspace.N]` with embedded index.
                if (std.mem.startsWith(u8, sec_name, "workspace.")) {
                    const idx_str = sec_name["workspace.".len..];
                    const idx_1 = std.fmt.parseInt(u8, idx_str, 10) catch {
                        current_section = .global;
                        current_ws_idx = null;
                        continue;
                    };
                    if (idx_1 >= 1 and idx_1 <= 10) {
                        current_section = .workspace;
                        current_ws_idx = idx_1 - 1;
                    } else {
                        current_section = .global;
                        current_ws_idx = null;
                    }
                    continue;
                }
                current_section = parseSection(sec_name);
                current_ws_idx = null;
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
            .keybind => self.applyKeybind(key, value),
            .keyboard => self.applyKeyboard(key, value),
            .workspace => if (current_ws_idx) |idx| self.applyWorkspace(idx, key, value),
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
    keybind,
    keyboard,
    workspace,
};

fn parseSection(name: []const u8) Section {
    if (std.mem.eql(u8, name, "names")) return .names;
    if (std.mem.eql(u8, name, "bar.top")) return .bar_top;
    if (std.mem.eql(u8, name, "bar.bottom")) return .bar_bottom;
    if (std.mem.eql(u8, name, "bar.thresholds")) return .bar_thresholds;
    if (std.mem.eql(u8, name, "rules")) return .rules;
    if (std.mem.eql(u8, name, "autostart")) return .autostart;
    if (std.mem.eql(u8, name, "keybind")) return .keybind;
    if (std.mem.eql(u8, name, "keyboard")) return .keyboard;
    return .global;
}

fn applyGlobal(self: *WmConfig, key: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, key, "gap")) {
        self.gap = std.fmt.parseInt(u16, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "border_width")) {
        self.border_width = std.fmt.parseInt(u16, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "unfocused_opacity")) {
        const f = std.fmt.parseFloat(f32, value) catch return;
        self.unfocused_opacity = @max(0.0, @min(1.0, f));
    } else if (std.mem.eql(u8, key, "bg_color") or std.mem.eql(u8, key, "bg")) {
        // Accept "#rrggbb", "0xrrggbb", "rrggbb", or full ARGB "0xaarrggbb"
        var v = value;
        if (v.len > 0 and v[0] == '#') v = v[1..];
        if (v.len > 2 and v[0] == '0' and (v[1] == 'x' or v[1] == 'X')) v = v[2..];
        if (v.len == 0) return;
        const parsed = std.fmt.parseInt(u32, v, 16) catch return;
        // If user gave 6 hex chars (RRGGBB), add full alpha
        self.bg_color = if (v.len <= 6) 0xFF000000 | parsed else parsed;
    } else if (std.mem.eql(u8, key, "border_color_focused")) {
        if (parseArgb(value)) |c| self.border_color_focused = c;
    } else if (std.mem.eql(u8, key, "border_color_unfocused")) {
        if (parseArgb(value)) |c| self.border_color_unfocused = c;
    } else if (std.mem.eql(u8, key, "cursor_size")) {
        self.cursor_size = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "float_default_w")) {
        self.float_default_w = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "float_default_h")) {
        self.float_default_h = std.fmt.parseInt(u32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "resize_min_px")) {
        self.resize_min_px = std.fmt.parseInt(i32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "border_drag_insensitive_px")) {
        self.border_drag_insensitive_px = std.fmt.parseInt(i32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "border_drag_zone_px")) {
        self.border_drag_zone_px = std.fmt.parseInt(i32, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "scratchpad_width_pct")) {
        self.scratchpad_width_pct = std.fmt.parseInt(u8, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "scratchpad_height_pct")) {
        self.scratchpad_height_pct = std.fmt.parseInt(u8, value, 10) catch return;
    } else if (std.mem.eql(u8, key, "mouse_humanize")) {
        self.mouse_humanize = std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes");
    } else if (std.mem.eql(u8, key, "mouse_path_default_ms")) {
        self.mouse_path_default_ms = std.fmt.parseInt(u32, value, 10) catch return;
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

/// Parse `[keybind]` entries. Current v1 scope: only `spawn:<cmd>`
/// actions. Other action types should use the shared `[keybinds.*]`
/// syntax in teru.conf — this section is for commands that don't
/// fit the pure Action enum (user-typed shell commands).
fn applyKeybind(self: *WmConfig, key: []const u8, value: []const u8) void {
    if (self.spawn_chord_count >= max_spawn_chords) return;
    const prefix = "spawn:";
    if (!std.mem.startsWith(u8, value, prefix)) return;
    const cmd = std.mem.trim(u8, value[prefix.len..], &std.ascii.whitespace);
    if (cmd.len == 0 or key.len == 0) return;

    var chord = SpawnChord{};
    const chord_len = @min(key.len, chord.chord.len);
    @memcpy(chord.chord[0..chord_len], key[0..chord_len]);
    chord.chord_len = @intCast(chord_len);
    const cmd_len = @min(cmd.len, chord.cmd.len);
    @memcpy(chord.cmd[0..cmd_len], cmd[0..cmd_len]);
    chord.cmd_len = @intCast(cmd_len);

    self.spawn_chords[self.spawn_chord_count] = chord;
    self.spawn_chord_count += 1;
}

/// Parse `[keyboard]` entries — xkb_rule_names fields. Empty or unset
/// fields leave the buffer at length 0, which getXkbLayout() etc. below
/// translate to null, which xkb_keymap_new_from_names treats as "consult
/// XKB_DEFAULT_* env vars / defaults". Sway-compatible naming.
fn applyKeyboard(self: *WmConfig, key: []const u8, value: []const u8) void {
    const targets: [5]struct {
        names: []const []const u8,
        buf: *[kb_field_max:0]u8,
        len: *u8,
    } = .{
        .{ .names = &.{ "xkb_layout", "layout", "kb_layout" }, .buf = &self.xkb_layout_buf, .len = &self.xkb_layout_len },
        .{ .names = &.{ "xkb_variant", "variant", "kb_variant" }, .buf = &self.xkb_variant_buf, .len = &self.xkb_variant_len },
        .{ .names = &.{ "xkb_options", "options", "kb_options" }, .buf = &self.xkb_options_buf, .len = &self.xkb_options_len },
        .{ .names = &.{ "xkb_model", "model", "kb_model" }, .buf = &self.xkb_model_buf, .len = &self.xkb_model_len },
        .{ .names = &.{ "xkb_rules", "rules", "kb_rules" }, .buf = &self.xkb_rules_buf, .len = &self.xkb_rules_len },
    };

    for (targets) |t| {
        for (t.names) |name| {
            if (std.mem.eql(u8, key, name)) {
                const n = @min(value.len, t.buf.len);
                @memcpy(t.buf[0..n], value[0..n]);
                t.buf[n] = 0;
                t.len.* = @intCast(n);
                return;
            }
        }
    }
}

/// Return the xkb_layout value as a nul-terminated C string, or null
/// if unset. Null signals "fall back to XKB_DEFAULT_* env vars / defaults"
/// when passed through to xkb_keymap_new_from_names.
pub fn getXkbLayout(self: *const WmConfig) ?[*:0]const u8 {
    return if (self.xkb_layout_len == 0) null else self.xkb_layout_buf[0..self.xkb_layout_len :0];
}

pub fn getXkbVariant(self: *const WmConfig) ?[*:0]const u8 {
    return if (self.xkb_variant_len == 0) null else self.xkb_variant_buf[0..self.xkb_variant_len :0];
}

pub fn getXkbOptions(self: *const WmConfig) ?[*:0]const u8 {
    return if (self.xkb_options_len == 0) null else self.xkb_options_buf[0..self.xkb_options_len :0];
}

pub fn getXkbModel(self: *const WmConfig) ?[*:0]const u8 {
    return if (self.xkb_model_len == 0) null else self.xkb_model_buf[0..self.xkb_model_len :0];
}

pub fn getXkbRules(self: *const WmConfig) ?[*:0]const u8 {
    return if (self.xkb_rules_len == 0) null else self.xkb_rules_buf[0..self.xkb_rules_len :0];
}

/// True if any `[keyboard]` field is set. If false, the compositor passes
/// NULL to xkb_keymap_new_from_names (full env-var / default fallback).
pub fn hasXkbOverrides(self: *const WmConfig) bool {
    return self.xkb_layout_len != 0 or self.xkb_variant_len != 0 or
        self.xkb_options_len != 0 or self.xkb_model_len != 0 or
        self.xkb_rules_len != 0;
}

/// Parse an ARGB / RGB hex string. Accepts "#rrggbb", "0xrrggbb",
/// "rrggbb", "#aarrggbb", "0xaarrggbb", "aarrggbb". Returns null on
/// parse failure so callers can leave the current value untouched.
fn parseArgb(value: []const u8) ?u32 {
    var v = value;
    if (v.len > 0 and v[0] == '#') v = v[1..];
    if (v.len > 2 and v[0] == '0' and (v[1] == 'x' or v[1] == 'X')) v = v[2..];
    if (v.len == 0) return null;
    const parsed = std.fmt.parseInt(u32, v, 16) catch return null;
    return if (v.len <= 6) 0xFF000000 | parsed else parsed;
}

/// Populate `[workspace.N]` fields (cwd, startup). Ignores `name`,
/// `layout`, `master_ratio` etc. — those are handled by the shared
/// teru Config and applied to the layout engine separately.
fn applyWorkspace(self: *WmConfig, idx: u8, key: []const u8, value: []const u8) void {
    if (idx >= 10) return;
    if (std.mem.eql(u8, key, "startup")) {
        const n = @min(value.len, self.workspace_startup_buf[idx].len);
        @memcpy(self.workspace_startup_buf[idx][0..n], value[0..n]);
        self.workspace_startup_len[idx] = @intCast(n);
        self.workspace_startup[idx] = self.workspace_startup_buf[idx][0..n];
    } else if (std.mem.eql(u8, key, "cwd")) {
        const n = @min(value.len, self.workspace_cwd_buf[idx].len);
        @memcpy(self.workspace_cwd_buf[idx][0..n], value[0..n]);
        self.workspace_cwd_len[idx] = @intCast(n);
        self.workspace_cwd[idx] = self.workspace_cwd_buf[idx][0..n];
    }
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

test "keyboard section parses sway-compatible xkb_ fields" {
    var cfg = WmConfig{};
    cfg.parse(
        \\[keyboard]
        \\xkb_layout = us,ua
        \\xkb_variant = dvorak,
        \\xkb_options = grp:alt_shift_toggle,caps:escape
        \\
    );
    try std.testing.expect(cfg.hasXkbOverrides());
    const layout = cfg.getXkbLayout() orelse return error.NullLayout;
    const variant = cfg.getXkbVariant() orelse return error.NullVariant;
    const options = cfg.getXkbOptions() orelse return error.NullOptions;
    try std.testing.expectEqualStrings("us,ua", std.mem.span(layout));
    try std.testing.expectEqualStrings("dvorak,", std.mem.span(variant));
    try std.testing.expectEqualStrings("grp:alt_shift_toggle,caps:escape", std.mem.span(options));
    try std.testing.expect(cfg.getXkbModel() == null);
    try std.testing.expect(cfg.getXkbRules() == null);
}

test "keyboard section accepts hyprland-style kb_ and bare names" {
    var cfg = WmConfig{};
    cfg.parse(
        \\[keyboard]
        \\kb_layout = us
        \\variant = colemak
        \\
    );
    try std.testing.expectEqualStrings("us", std.mem.span(cfg.getXkbLayout().?));
    try std.testing.expectEqualStrings("colemak", std.mem.span(cfg.getXkbVariant().?));
}

test "empty keyboard section leaves all xkb fields null" {
    var cfg = WmConfig{};
    cfg.parse("gap = 8\n");
    try std.testing.expect(!cfg.hasXkbOverrides());
    try std.testing.expect(cfg.getXkbLayout() == null);
    try std.testing.expect(cfg.getXkbVariant() == null);
    try std.testing.expect(cfg.getXkbOptions() == null);
}
