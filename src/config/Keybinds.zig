//! Configurable keybinding system.
//!
//! Parses [keybinds.MODE] sections from teru.conf / keybinds.conf.
//! Supports modes (normal, prefix, scroll, search), shared bindings,
//! modifier flags (alt, ralt, ctrl, shift, super), and namespaced actions.
//!
//! Format:
//!   [keybinds.normal]
//!   alt+j = pane:focus_next
//!   ralt+h = resize:shrink_w
//!   alt+1 = workspace:1
//!   ctrl+space = mode:prefix
//!
//!   [keybinds.shared]
//!   ctrl+shift+c = copy:selection

const std = @import("std");

// ── Modifier flags ──────────────────────────────────────────

pub const Mods = packed struct(u8) {
    alt: bool = false,
    ralt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    super_: bool = false,
    _pad: u3 = 0,

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }

    pub const ALT = Mods{ .alt = true };
    pub const RALT = Mods{ .alt = true, .ralt = true };
    pub const CTRL = Mods{ .ctrl = true };
    pub const SHIFT = Mods{ .shift = true };
    pub const CTRL_SHIFT = Mods{ .ctrl = true, .shift = true };
    pub const SUPER = Mods{ .super_ = true };
    pub const NONE = Mods{};

    /// Return a copy with shift added.
    pub fn withShift(self: Mods) Mods {
        var m = self;
        m.shift = true;
        return m;
    }

    /// Return a copy with ralt added (for secondary mod bindings).
    pub fn withRalt(self: Mods) Mods {
        var m = self;
        m.ralt = true;
        return m;
    }
};

// ── Modes ───────────────────────────────────────────────────

pub const Mode = enum(u8) {
    normal = 0,
    prefix = 1,
    scroll = 2,
    search = 3,
    locked = 4,
    shared = 252, // applies to all modes
    shared_except_normal = 253, // all except normal
    shared_except_locked = 254, // all except locked
    _,

    pub fn fromString(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "prefix")) return .prefix;
        if (std.mem.eql(u8, s, "scroll")) return .scroll;
        if (std.mem.eql(u8, s, "search")) return .search;
        if (std.mem.eql(u8, s, "locked")) return .locked;
        if (std.mem.eql(u8, s, "shared")) return .shared;
        // shared_except.normal, shared_except.locked, etc
        if (std.mem.startsWith(u8, s, "shared_except.")) {
            const rest = s["shared_except.".len..];
            if (std.mem.eql(u8, rest, "normal")) return .shared_except_normal;
            if (std.mem.eql(u8, rest, "locked")) return .shared_except_locked;
        }
        return null;
    }

    /// Check if a shared mode applies to the given active mode.
    pub fn appliesTo(binding_mode: Mode, active_mode: Mode) bool {
        return switch (binding_mode) {
            .shared => true,
            .shared_except_normal => active_mode != .normal,
            .shared_except_locked => active_mode != .locked,
            else => binding_mode == active_mode,
        };
    }
};

// ── Actions ─────────────────────────────────────────────────

pub const Action = enum(u8) {
    none = 0,

    // Pane
    pane_focus_next,
    pane_focus_prev,
    pane_focus_master,
    pane_set_master,
    pane_swap_next,
    pane_swap_prev,
    pane_swap_master,
    pane_rotate_slaves_up,
    pane_rotate_slaves_down,
    pane_sink,
    pane_sink_all,
    master_count_inc,
    master_count_dec,
    pane_close,
    pane_move_to_1,
    pane_move_to_2,
    pane_move_to_3,
    pane_move_to_4,
    pane_move_to_5,
    pane_move_to_6,
    pane_move_to_7,
    pane_move_to_8,
    pane_move_to_9,
    pane_move_to_0,

    // Split
    split_vertical,
    split_horizontal,

    // Workspace
    workspace_1,
    workspace_2,
    workspace_3,
    workspace_4,
    workspace_5,
    workspace_6,
    workspace_7,
    workspace_8,
    workspace_9,
    workspace_0,

    // Layout
    layout_cycle,
    layout_reset,

    // Workspace navigation helpers
    workspace_toggle_last,
    workspace_next_nonempty,

    // Multi-output (v0.4.20)
    focus_output_next,
    move_to_output_next,

    // Zoom
    zoom_in,
    zoom_out,
    zoom_reset,
    zoom_toggle,

    // Resize
    resize_shrink_w,
    resize_grow_w,
    resize_shrink_h,
    resize_grow_h,

    // Mode transitions
    mode_normal,
    mode_prefix,
    mode_scroll,
    mode_search,
    mode_locked,

    // Session
    session_detach,
    session_save,
    session_restore,

    // UI
    toggle_status_bar,

    // Clipboard
    copy_selection,
    paste_clipboard,

    // Scroll (for scroll mode)
    scroll_up_1,
    scroll_down_1,
    scroll_up_half,
    scroll_down_half,
    scroll_top,
    scroll_bottom,

    // Search (for search mode)
    search_next,
    search_prev,

    // Select (for scroll/copy mode)
    select_begin,

    // Send raw key through to PTY
    send_through,

    // Compositor actions (no-ops in standalone teru, handled by teruwm Server)
    spawn_terminal,
    window_close,
    compositor_quit,
    compositor_restart,
    config_reload,
    launcher_toggle,
    float_toggle,
    fullscreen_toggle,
    screenshot,
    screenshot_pane,
    screenshot_area,
    bar_toggle_top,
    bar_toggle_bottom,
    // Media actions (compositor spawns the appropriate command)
    volume_up,
    volume_down,
    volume_mute,
    brightness_up,
    brightness_down,
    media_play,
    media_next,
    media_prev,

    // User-defined spawn chords (B3). Each slot maps to a command
    // string stored in Server.spawn_table[slot]. Config file assigns
    // via [keybind] section: `Mod+Return = spawn:teru`. 32 slots is
    // more than anyone needs; Action stays u8-sized.
    spawn_0, spawn_1, spawn_2, spawn_3, spawn_4, spawn_5, spawn_6, spawn_7,
    spawn_8, spawn_9, spawn_10, spawn_11, spawn_12, spawn_13, spawn_14, spawn_15,
    spawn_16, spawn_17, spawn_18, spawn_19, spawn_20, spawn_21, spawn_22, spawn_23,
    spawn_24, spawn_25, spawn_26, spawn_27, spawn_28, spawn_29, spawn_30, spawn_31,

    pub fn fromString(s: []const u8) ?Action {
        // Exact match table
        const map = .{
            .{ "pane:focus_next", Action.pane_focus_next },
            .{ "pane:focus_prev", Action.pane_focus_prev },
            .{ "pane:focus_master", Action.pane_focus_master },
            .{ "pane:set_master", Action.pane_set_master },
            .{ "pane:swap_next", Action.pane_swap_next },
            .{ "pane:swap_prev", Action.pane_swap_prev },
            .{ "pane:swap_master", Action.pane_swap_master },
            .{ "pane:rotate_slaves_up", Action.pane_rotate_slaves_up },
            .{ "pane:rotate_slaves_down", Action.pane_rotate_slaves_down },
            .{ "pane:sink", Action.pane_sink },
            .{ "pane:sink_all", Action.pane_sink_all },
            .{ "master:count_inc", Action.master_count_inc },
            .{ "master:count_dec", Action.master_count_dec },
            .{ "layout:reset", Action.layout_reset },
            .{ "workspace:toggle_last", Action.workspace_toggle_last },
            .{ "workspace:next_nonempty", Action.workspace_next_nonempty },
            .{ "output:focus_next", Action.focus_output_next },
            .{ "output:move_to_next", Action.move_to_output_next },
            .{ "pane:close", Action.pane_close },
            .{ "split:vertical", Action.split_vertical },
            .{ "split:horizontal", Action.split_horizontal },
            .{ "layout:cycle", Action.layout_cycle },
            .{ "zoom:in", Action.zoom_in },
            .{ "zoom:out", Action.zoom_out },
            .{ "zoom:reset", Action.zoom_reset },
            .{ "zoom:toggle", Action.zoom_toggle },
            .{ "resize:shrink_w", Action.resize_shrink_w },
            .{ "resize:grow_w", Action.resize_grow_w },
            .{ "resize:shrink_h", Action.resize_shrink_h },
            .{ "resize:grow_h", Action.resize_grow_h },
            .{ "resize:-2:0", Action.resize_shrink_w },
            .{ "resize:+2:0", Action.resize_grow_w },
            .{ "resize:0:-2", Action.resize_shrink_h },
            .{ "resize:0:+2", Action.resize_grow_h },
            .{ "mode:normal", Action.mode_normal },
            .{ "mode:prefix", Action.mode_prefix },
            .{ "mode:scroll", Action.mode_scroll },
            .{ "mode:search", Action.mode_search },
            .{ "mode:locked", Action.mode_locked },
            .{ "session:detach", Action.session_detach },
            .{ "session:save", Action.session_save },
            .{ "session:restore", Action.session_restore },
            .{ "ui:toggle_status_bar", Action.toggle_status_bar },
            .{ "copy:selection", Action.copy_selection },
            .{ "paste:clipboard", Action.paste_clipboard },
            .{ "scroll:up:1", Action.scroll_up_1 },
            .{ "scroll:down:1", Action.scroll_down_1 },
            .{ "scroll:up:half", Action.scroll_up_half },
            .{ "scroll:down:half", Action.scroll_down_half },
            .{ "scroll:top", Action.scroll_top },
            .{ "scroll:bottom", Action.scroll_bottom },
            .{ "search:next", Action.search_next },
            .{ "search:prev", Action.search_prev },
            .{ "select:begin", Action.select_begin },
            .{ "send:through", Action.send_through },
            .{ "spawn:terminal", Action.spawn_terminal },
            .{ "window:close", Action.window_close },
            .{ "compositor:quit", Action.compositor_quit },
            .{ "compositor:restart", Action.compositor_restart },
            .{ "config:reload", Action.config_reload },
            .{ "launcher:toggle", Action.launcher_toggle },
            .{ "float:toggle", Action.float_toggle },
            .{ "fullscreen:toggle", Action.fullscreen_toggle },
            .{ "screenshot", Action.screenshot },
            .{ "screenshot:pane", Action.screenshot_pane },
            .{ "screenshot:area", Action.screenshot_area },
            .{ "bar:toggle_top", Action.bar_toggle_top },
            .{ "bar:toggle_bottom", Action.bar_toggle_bottom },
            .{ "volume:up", Action.volume_up },
            .{ "volume:down", Action.volume_down },
            .{ "volume:mute", Action.volume_mute },
            .{ "brightness:up", Action.brightness_up },
            .{ "brightness:down", Action.brightness_down },
            .{ "media:play", Action.media_play },
            .{ "media:next", Action.media_next },
            .{ "media:prev", Action.media_prev },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, s, entry[0])) return entry[1];
        }
        // Parameterized: workspace:N, pane:move_to:N
        if (std.mem.startsWith(u8, s, "workspace:")) {
            const n = std.fmt.parseInt(u8, s["workspace:".len..], 10) catch return null;
            return switch (n) {
                1 => .workspace_1,
                2 => .workspace_2,
                3 => .workspace_3,
                4 => .workspace_4,
                5 => .workspace_5,
                6 => .workspace_6,
                7 => .workspace_7,
                8 => .workspace_8,
                9 => .workspace_9,
                0 => .workspace_0,
                else => null,
            };
        }
        if (std.mem.startsWith(u8, s, "pane:move_to:")) {
            const n = std.fmt.parseInt(u8, s["pane:move_to:".len..], 10) catch return null;
            return switch (n) {
                1 => .pane_move_to_1,
                2 => .pane_move_to_2,
                3 => .pane_move_to_3,
                4 => .pane_move_to_4,
                5 => .pane_move_to_5,
                6 => .pane_move_to_6,
                7 => .pane_move_to_7,
                8 => .pane_move_to_8,
                9 => .pane_move_to_9,
                0 => .pane_move_to_0,
                else => null,
            };
        }
        return null;
    }

    /// Get the workspace number (0-indexed) for workspace actions.
    pub fn workspaceIndex(self: Action) ?u8 {
        return switch (self) {
            .workspace_1 => 0,
            .workspace_2 => 1,
            .workspace_3 => 2,
            .workspace_4 => 3,
            .workspace_5 => 4,
            .workspace_6 => 5,
            .workspace_7 => 6,
            .workspace_8 => 7,
            .workspace_9 => 8,
            .workspace_0 => 9,
            else => null,
        };
    }

    /// Get workspace index for move-to actions.
    pub fn moveToIndex(self: Action) ?u8 {
        return switch (self) {
            .pane_move_to_1 => 0,
            .pane_move_to_2 => 1,
            .pane_move_to_3 => 2,
            .pane_move_to_4 => 3,
            .pane_move_to_5 => 4,
            .pane_move_to_6 => 5,
            .pane_move_to_7 => 6,
            .pane_move_to_8 => 7,
            .pane_move_to_9 => 8,
            .pane_move_to_0 => 9,
            else => null,
        };
    }
};

// ── Binding ─────────────────────────────────────────────────

pub const Binding = struct {
    mode: Mode,
    mods: Mods,
    key: u32, // XKB keysym (0x20-0x7E for ASCII, 0x1008FFxx for XF86, etc.)
    action: Action,
    is_keycode: bool = false, // if true, key is a raw evdev keycode, not keysym
};

// ── Named key map ───────────────────────────────────────────

fn namedKey(name: []const u8) ?u32 {
    // Single ASCII character
    if (name.len == 1 and name[0] >= 0x20 and name[0] <= 0x7E) return name[0];

    const map = .{
        // Standard keys
        .{ "space", @as(u32, 0x0020) }, // XKB_KEY_space
        .{ "enter", @as(u32, 0xFF0D) }, // XKB_KEY_Return
        .{ "return", @as(u32, 0xFF0D) },
        .{ "esc", @as(u32, 0xFF1B) }, // XKB_KEY_Escape
        .{ "escape", @as(u32, 0xFF1B) },
        .{ "tab", @as(u32, 0xFF09) }, // XKB_KEY_Tab
        .{ "backspace", @as(u32, 0xFF08) }, // XKB_KEY_BackSpace
        .{ "delete", @as(u32, 0xFFFF) }, // XKB_KEY_Delete
        .{ "minus", @as(u32, '-') },
        .{ "equal", @as(u32, '=') },
        .{ "slash", @as(u32, '/') },
        .{ "backslash", @as(u32, '\\') },
        // Arrow keys
        .{ "up", @as(u32, 0xFF52) },
        .{ "down", @as(u32, 0xFF54) },
        .{ "left", @as(u32, 0xFF51) },
        .{ "right", @as(u32, 0xFF53) },
        // Function keys
        .{ "f1", @as(u32, 0xFFBE) },
        .{ "f2", @as(u32, 0xFFBF) },
        .{ "f3", @as(u32, 0xFFC0) },
        .{ "f4", @as(u32, 0xFFC1) },
        .{ "f5", @as(u32, 0xFFC2) },
        .{ "f6", @as(u32, 0xFFC3) },
        .{ "f7", @as(u32, 0xFFC4) },
        .{ "f8", @as(u32, 0xFFC5) },
        .{ "f9", @as(u32, 0xFFC6) },
        .{ "f10", @as(u32, 0xFFC7) },
        .{ "f11", @as(u32, 0xFFC8) },
        .{ "f12", @as(u32, 0xFFC9) },
        // XF86 media keys
        .{ "XF86AudioRaiseVolume", @as(u32, 0x1008FF13) },
        .{ "XF86AudioLowerVolume", @as(u32, 0x1008FF11) },
        .{ "XF86AudioMute", @as(u32, 0x1008FF12) },
        .{ "XF86AudioPlay", @as(u32, 0x1008FF14) },
        .{ "XF86AudioStop", @as(u32, 0x1008FF15) },
        .{ "XF86AudioNext", @as(u32, 0x1008FF17) },
        .{ "XF86AudioPrev", @as(u32, 0x1008FF16) },
        .{ "XF86MonBrightnessUp", @as(u32, 0x1008FF02) },
        .{ "XF86MonBrightnessDown", @as(u32, 0x1008FF03) },
        .{ "Print", @as(u32, 0xFF61) }, // XKB_KEY_Print (PrintScreen)
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

// ── Trigger parser ──────────────────────────────────────────

pub const ParsedTrigger = struct { mods: Mods, key: u32, is_keycode: bool = false };

/// Parse a trigger string like "mod+j", "alt+j", "ctrl+shift+c", "super+XF86AudioMute"
/// The "mod" token resolves to whatever mod_key is set to.
/// Also supports "keycode:44" for physical key binding.
fn parseTrigger(trigger: []const u8) ?ParsedTrigger {
    return parseTriggerWithMod(trigger, Mods.ALT);
}

pub fn parseTriggerWithMod(trigger: []const u8, mod_key: Mods) ?ParsedTrigger {
    var mods = Mods{};
    var remaining = trigger;

    // Strip inline comment
    if (std.mem.indexOf(u8, remaining, "#")) |idx| {
        remaining = std.mem.trim(u8, remaining[0..idx], " \t");
    }

    // Check for keycode: prefix (physical key binding)
    if (std.mem.startsWith(u8, remaining, "keycode:")) {
        const code_str = remaining["keycode:".len..];
        const code = std.fmt.parseInt(u32, code_str, 10) catch return null;
        return .{ .mods = .{}, .key = code, .is_keycode = true };
    }

    // Split by + and process modifiers, last token is the key
    var last_plus: usize = 0;
    var i: usize = 0;
    while (i < remaining.len) : (i += 1) {
        if (remaining[i] == '+') {
            const token = remaining[last_plus..i];
            if (std.mem.eql(u8, token, "mod")) {
                // Resolve $mod to the configured modifier
                if (mod_key.alt) mods.alt = true;
                if (mod_key.ralt) mods.ralt = true;
                if (mod_key.ctrl) mods.ctrl = true;
                if (mod_key.super_) mods.super_ = true;
            } else if (std.mem.eql(u8, token, "alt")) {
                mods.alt = true;
            } else if (std.mem.eql(u8, token, "ralt")) {
                mods.alt = true;
                mods.ralt = true;
            } else if (std.mem.eql(u8, token, "ctrl")) {
                mods.ctrl = true;
            } else if (std.mem.eql(u8, token, "shift")) {
                mods.shift = true;
            } else if (std.mem.eql(u8, token, "super")) {
                mods.super_ = true;
            } else return null; // unknown modifier
            last_plus = i + 1;
        }
    }

    // Everything after the last + is the key name
    const key_name = remaining[last_plus..];
    if (key_name.len == 0) return null;
    const key = namedKey(key_name) orelse return null;

    return .{ .mods = mods, .key = key };
}

// ── Keybinds config ─────────────────────────────────────────

pub const MAX_BINDINGS = 256;

pub const Keybinds = struct {
    bindings: [MAX_BINDINGS]Binding = undefined,
    count: u16 = 0,
    /// The primary modifier key. Defaults to Alt (standalone) or Super (compositor).
    /// Set via `mod = super` in config. All `mod+key` bindings resolve to this.
    mod_key: Mods = Mods.ALT,

    /// Look up an action for the given mode, modifiers, and keysym.
    /// Checks mode-specific bindings first, then shared bindings.
    /// For keycode bindings, pass the raw evdev keycode as keysym_or_keycode
    /// and set check_keycode=true.
    pub fn lookup(self: *const Keybinds, active_mode: Mode, mods: Mods, keysym: u32) ?Action {
        // 1. Exact mode match (keysym bindings)
        for (self.bindings[0..self.count]) |b| {
            if (!b.is_keycode and b.mode == active_mode and mods.eql(b.mods) and b.key == keysym) {
                return if (b.action == .none) null else b.action;
            }
        }
        // 2. Shared/shared_except matches
        for (self.bindings[0..self.count]) |b| {
            if (!b.is_keycode and b.mode != active_mode and b.mode.appliesTo(active_mode) and
                mods.eql(b.mods) and b.key == keysym)
            {
                return if (b.action == .none) null else b.action;
            }
        }
        return null;
    }

    /// Look up by raw keycode (physical key, layout-independent).
    pub fn lookupKeycode(self: *const Keybinds, active_mode: Mode, keycode: u32) ?Action {
        for (self.bindings[0..self.count]) |b| {
            if (b.is_keycode and b.key == keycode and b.mode.appliesTo(active_mode)) {
                return if (b.action == .none) null else b.action;
            }
        }
        return null;
    }

    /// Add a keysym binding. Returns false if full.
    pub fn add(self: *Keybinds, mode: Mode, mods: Mods, key: u32, action: Action) bool {
        return self.addBinding(mode, mods, key, action, false);
    }

    /// Add a keycode binding (layout-independent physical key).
    pub fn addKeycode(self: *Keybinds, mode: Mode, keycode: u32, action: Action) bool {
        return self.addBinding(mode, .{}, keycode, action, true);
    }

    fn addBinding(self: *Keybinds, mode: Mode, mods: Mods, key: u32, action: Action, is_keycode: bool) bool {
        if (self.count >= MAX_BINDINGS) return false;
        for (self.bindings[0..self.count]) |*b| {
            if (b.mode == mode and mods.eql(b.mods) and b.key == key and b.is_keycode == is_keycode) {
                b.action = action;
                return true;
            }
        }
        self.bindings[self.count] = .{ .mode = mode, .mods = mods, .key = key, .action = action, .is_keycode = is_keycode };
        self.count += 1;
        return true;
    }

    /// Parse a single keybind line: "alt+j = pane:focus_next"
    /// Also supports: "XF86AudioMute = exec:wpctl ..." and "keycode:44 = ..."
    pub fn parseLine(self: *Keybinds, mode: Mode, line: []const u8) void {
        const eq_idx = std.mem.indexOf(u8, line, "=") orelse return;
        const lhs = std.mem.trim(u8, line[0..eq_idx], " \t");
        const rhs_raw = if (eq_idx + 1 < line.len) line[eq_idx + 1 ..] else "";
        var rhs = std.mem.trim(u8, rhs_raw, " \t");
        if (std.mem.indexOf(u8, rhs, "#")) |hash| {
            rhs = std.mem.trim(u8, rhs[0..hash], " \t");
        }

        const trigger = parseTriggerWithMod(lhs, self.mod_key) orelse return;

        if (rhs.len == 0) {
            _ = self.addBinding(mode, trigger.mods, trigger.key, .none, trigger.is_keycode);
            return;
        }

        const action = Action.fromString(rhs) orelse return;
        _ = self.addBinding(mode, trigger.mods, trigger.key, action, trigger.is_keycode);
    }

    /// Load defaults using the configured mod key.
    pub fn loadDefaults(self: *Keybinds) void {
        self.count = 0;

        // ── Normal mode ($mod shortcuts) ────────────────
        const n = Mode.normal;
        const M = self.mod_key; // $mod — Alt (standalone) or Super (compositor)
        const MS = self.mod_key.withShift(); // $mod+Shift

        // Navigation
        _ = self.add(n, M, 'j', .pane_focus_next);
        _ = self.add(n, M, 'k', .pane_focus_prev);
        _ = self.add(n, M, 'm', .pane_focus_master);
        _ = self.add(n, MS, 'm', .pane_swap_master); // Swap focused ↔ master (xmonad semantics)
        _ = self.add(n, MS, 'j', .pane_swap_next); // Swap focused with next
        _ = self.add(n, MS, 'k', .pane_swap_prev); // Swap focused with previous
        _ = self.add(n, M, 'h', .resize_shrink_w);
        _ = self.add(n, M, 'l', .resize_grow_w);

        // Master-workflow (v0.4.15 — xmonad rotSlaves + IncMasterN)
        const MC = Mods{ .ctrl = true, .super_ = true };
        _ = self.add(n, MC, 'j', .pane_rotate_slaves_down);
        _ = self.add(n, MC, 'k', .pane_rotate_slaves_up);
        _ = self.add(n, MC, 's', .pane_sink_all);
        _ = self.add(n, M, ',', .master_count_inc);
        _ = self.add(n, M, '.', .master_count_dec);

        // Workspace navigation (v0.4.15)
        _ = self.add(n, M, 0xFF1B, .workspace_toggle_last); // Mod+Escape
        _ = self.add(n, MC, '`', .workspace_next_nonempty); // Mod+Ctrl+grave

        // Multi-output (v0.4.20)
        _ = self.add(n, M, 'o', .focus_output_next); // Mod+O — cycle focused output
        _ = self.add(n, MS, 'o', .move_to_output_next); // Mod+Shift+O — move focused window across outputs

        // Layout (v0.4.15)
        _ = self.add(n, MS, ' ', .layout_reset);

        // Focus also via Tab (XMonad style)
        _ = self.add(n, M, 0xFF09, .pane_focus_next); // Mod+Tab
        _ = self.add(n, MS, 0xFF09, .pane_focus_prev); // Mod+Shift+Tab

        // Pane management
        _ = self.add(n, M, 'c', .split_vertical);
        _ = self.add(n, MS, 'c', .window_close);
        _ = self.add(n, M, 'x', .pane_close);
        _ = self.add(n, M, '\r', .spawn_terminal);

        // Layout + window
        _ = self.add(n, M, ' ', .layout_cycle);
        _ = self.add(n, M, 'z', .zoom_toggle);
        _ = self.add(n, M, 'f', .fullscreen_toggle);
        _ = self.add(n, M, 's', .float_toggle);
        _ = self.add(n, M, 'd', .launcher_toggle);

        // Modes + UI
        _ = self.add(n, M, '/', .mode_search);
        _ = self.add(n, M, 'v', .mode_scroll);
        _ = self.add(n, M, 'b', .bar_toggle_top);
        _ = self.add(n, MS, 'b', .bar_toggle_bottom);
        _ = self.add(n, M, '=', .zoom_in);
        _ = self.add(n, M, '-', .zoom_out);
        _ = self.add(n, M, '\\', .zoom_reset);
        _ = self.add(n, MS, 'q', .compositor_quit);
        _ = self.add(n, MS, 'r', .config_reload);
        // Mod+Ctrl+Shift+R: hot-restart compositor (preserves terminal sessions)
        const MCS = Mods{ .ctrl = true, .shift = true, .super_ = true };
        _ = self.add(n, MCS, 'r', .compositor_restart);
        _ = self.add(n, M, 'w', .screenshot);
        _ = self.add(n, MS, 'w', .screenshot_pane);
        const MCW = Mods{ .ctrl = true, .super_ = true };
        _ = self.add(n, MCW, 'w', .screenshot_area); // slurp + grim

        // Workspaces: $mod+1-9, $mod+shift+1-9 move pane
        for (0..9) |i| {
            const digit: u8 = @intCast('1' + i);
            const ws: Action = @enumFromInt(@intFromEnum(Action.workspace_1) + @as(u8, @intCast(i)));
            const mv: Action = @enumFromInt(@intFromEnum(Action.pane_move_to_1) + @as(u8, @intCast(i)));
            _ = self.add(n, M, digit, ws);
            _ = self.add(n, MS, digit, mv);
        }
        _ = self.add(n, M, '0', .workspace_0);
        _ = self.add(n, MS, '0', .pane_move_to_0);

        // Ctrl+Space enters prefix mode
        _ = self.add(n, Mods.CTRL, ' ', .mode_prefix);

        // ── Prefix mode ─────────────────────────────────
        const p = Mode.prefix;
        const N = Mods.NONE;

        _ = self.add(p, N, 'c', .split_vertical);
        _ = self.add(p, N, '\\', .split_vertical);
        _ = self.add(p, N, '-', .split_horizontal);
        _ = self.add(p, N, 'x', .pane_close);
        _ = self.add(p, N, 'n', .pane_focus_next);
        _ = self.add(p, N, 'p', .pane_focus_prev);
        _ = self.add(p, N, ' ', .layout_cycle);
        _ = self.add(p, N, 'z', .zoom_toggle);
        _ = self.add(p, N, '/', .mode_search);
        _ = self.add(p, N, 'v', .mode_scroll);
        _ = self.add(p, N, 'd', .session_detach);
        _ = self.add(p, N, 's', .session_save); // tmux-resurrect: prefix + s
        _ = self.add(p, N, 'r', .session_restore); // tmux-resurrect: prefix + r
        _ = self.add(p, N, 0x1b, .mode_normal); // Esc

        for (0..9) |i| {
            const digit: u8 = @intCast('1' + i);
            const ws: Action = @enumFromInt(@intFromEnum(Action.workspace_1) + @as(u8, @intCast(i)));
            _ = self.add(p, N, digit, ws);
        }
        _ = self.add(p, N, '0', .workspace_0);

        // Resize in prefix mode (shifted H/J/K/L)
        _ = self.add(p, Mods.SHIFT, 'h', .resize_shrink_w);
        _ = self.add(p, Mods.SHIFT, 'l', .resize_grow_w);
        _ = self.add(p, Mods.SHIFT, 'k', .resize_shrink_h);
        _ = self.add(p, Mods.SHIFT, 'j', .resize_grow_h);

        // ── Scroll mode ─────────────────────────────────
        const sc = Mode.scroll;

        _ = self.add(sc, N, 'j', .scroll_down_1);
        _ = self.add(sc, N, 'k', .scroll_up_1);
        _ = self.add(sc, Mods.CTRL, 'd', .scroll_down_half);
        _ = self.add(sc, Mods.CTRL, 'u', .scroll_up_half);
        _ = self.add(sc, N, 'g', .scroll_top);
        _ = self.add(sc, Mods.SHIFT, 'g', .scroll_bottom);
        _ = self.add(sc, N, '/', .mode_search);
        _ = self.add(sc, N, 'v', .select_begin);
        _ = self.add(sc, N, 'y', .copy_selection);
        _ = self.add(sc, N, 'q', .mode_normal);
        _ = self.add(sc, N, 0x1b, .mode_normal); // Esc

        // ── Search mode ─────────────────────────────────
        const sr = Mode.search;

        _ = self.add(sr, N, '\r', .search_next); // Enter
        _ = self.add(sr, Mods.SHIFT, 'n', .search_prev);
        _ = self.add(sr, N, 0x1b, .mode_normal); // Esc

        // ── Shared ──────────────────────────────────────
        _ = self.add(.shared, Mods.CTRL_SHIFT, 'c', .copy_selection);
        _ = self.add(.shared, Mods.CTRL_SHIFT, 'v', .paste_clipboard);
    }

    /// Load media key defaults (no modifier — XF86 keysyms).
    /// Called after loadDefaults(). These are compositor-only because
    /// standalone teru doesn't handle hardware media keys.
    pub fn loadMediaDefaults(self: *Keybinds) void {
        const n = Mode.normal;
        const NONE = Mods{};
        _ = self.add(n, NONE, 0x1008FF13, .volume_up);
        _ = self.add(n, NONE, 0x1008FF11, .volume_down);
        _ = self.add(n, NONE, 0x1008FF12, .volume_mute);
        _ = self.add(n, NONE, 0x1008FF14, .media_play);
        _ = self.add(n, NONE, 0x1008FF17, .media_next);
        _ = self.add(n, NONE, 0x1008FF16, .media_prev);
        _ = self.add(n, NONE, 0x1008FF02, .brightness_up);
        _ = self.add(n, NONE, 0x1008FF03, .brightness_down);
        _ = self.add(n, NONE, 0xFF61, .screenshot);
    }
};

// ── Tests ───────────────────────────────────────────────────

test "parseTrigger basic" {
    const t1 = parseTrigger("alt+j").?;
    try std.testing.expect(t1.mods.alt);
    try std.testing.expect(!t1.mods.ctrl);
    try std.testing.expectEqual(@as(u32, 'j'), t1.key);

    const t2 = parseTrigger("ctrl+shift+c").?;
    try std.testing.expect(t2.mods.ctrl);
    try std.testing.expect(t2.mods.shift);
    try std.testing.expectEqual(@as(u32, 'c'), t2.key);

    const t3 = parseTrigger("ralt+h").?;
    try std.testing.expect(t3.mods.alt);
    try std.testing.expect(t3.mods.ralt);
    try std.testing.expectEqual(@as(u32, 'h'), t3.key);
}

test "parseTrigger named keys" {
    const t1 = parseTrigger("alt+space").?;
    try std.testing.expectEqual(@as(u32, 0x0020), t1.key); // XKB_KEY_space

    const t2 = parseTrigger("ctrl+space").?;
    try std.testing.expectEqual(@as(u32, 0x0020), t2.key);
    try std.testing.expect(t2.mods.ctrl);

    const t3 = parseTrigger("esc").?;
    try std.testing.expectEqual(@as(u32, 0xFF1B), t3.key); // XKB_KEY_Escape
}

test "parseTrigger XF86 keys" {
    const t1 = parseTrigger("XF86AudioMute").?;
    try std.testing.expectEqual(@as(u32, 0x1008FF12), t1.key);
    try std.testing.expect(!t1.is_keycode);

    const t2 = parseTrigger("super+Print").?;
    try std.testing.expectEqual(@as(u32, 0xFF61), t2.key);
    try std.testing.expect(t2.mods.super_);
}

test "parseTrigger keycode binding" {
    const t1 = parseTrigger("keycode:44").?;
    try std.testing.expectEqual(@as(u32, 44), t1.key);
    try std.testing.expect(t1.is_keycode);
}

test "Action.fromString" {
    try std.testing.expect(Action.fromString("pane:focus_next").? == .pane_focus_next);
    try std.testing.expect(Action.fromString("workspace:3").? == .workspace_3);
    try std.testing.expect(Action.fromString("workspace:0").? == .workspace_0);
    try std.testing.expect(Action.fromString("pane:move_to:5").? == .pane_move_to_5);
    try std.testing.expect(Action.fromString("pane:move_to:0").? == .pane_move_to_0);
    try std.testing.expect(Action.fromString("zoom:in").? == .zoom_in);
    try std.testing.expect(Action.fromString("mode:prefix").? == .mode_prefix);
    try std.testing.expect(Action.fromString("resize:-2:0").? == .resize_shrink_w);
    try std.testing.expect(Action.fromString("bogus") == null);
}

test "Keybinds defaults and lookup" {
    var kb = Keybinds{};
    kb.loadDefaults();

    // Normal mode: Alt+j = focus next
    try std.testing.expect(kb.lookup(.normal, Mods.ALT, 'j').? == .pane_focus_next);
    // Normal mode: Alt+1 = workspace 1
    try std.testing.expect(kb.lookup(.normal, Mods.ALT, '1').? == .workspace_1);
    // Prefix mode: c = split vertical
    try std.testing.expect(kb.lookup(.prefix, Mods.NONE, 'c').? == .split_vertical);
    // Shared: Ctrl+Shift+C = copy
    try std.testing.expect(kb.lookup(.normal, Mods.CTRL_SHIFT, 'c').? == .copy_selection);
    try std.testing.expect(kb.lookup(.scroll, Mods.CTRL_SHIFT, 'c').? == .copy_selection);
    // Unknown key returns null
    try std.testing.expect(kb.lookup(.normal, Mods.NONE, 'q') == null);
}

test "Keybinds parseLine" {
    var kb = Keybinds{};
    kb.parseLine(.normal, "alt+j = pane:focus_next");
    kb.parseLine(.normal, "ctrl+space = mode:prefix");
    kb.parseLine(.prefix, "x = pane:close");

    try std.testing.expect(kb.lookup(.normal, Mods.ALT, 'j').? == .pane_focus_next);
    try std.testing.expect(kb.lookup(.normal, Mods.CTRL, ' ').? == .mode_prefix);
    try std.testing.expect(kb.lookup(.prefix, Mods.NONE, 'x').? == .pane_close);
}

test "Keybinds unbind" {
    var kb = Keybinds{};
    kb.loadDefaults();
    // Alt+j is bound
    try std.testing.expect(kb.lookup(.normal, Mods.ALT, 'j') != null);
    // Unbind it
    kb.parseLine(.normal, "alt+j =");
    // Now returns null
    try std.testing.expect(kb.lookup(.normal, Mods.ALT, 'j') == null);
}

test "Mode.appliesTo" {
    try std.testing.expect(Mode.shared.appliesTo(.normal));
    try std.testing.expect(Mode.shared.appliesTo(.prefix));
    try std.testing.expect(Mode.shared.appliesTo(.scroll));
    try std.testing.expect(!Mode.shared_except_normal.appliesTo(.normal));
    try std.testing.expect(Mode.shared_except_normal.appliesTo(.prefix));
    try std.testing.expect(Mode.shared_except_locked.appliesTo(.normal));
    try std.testing.expect(!Mode.shared_except_locked.appliesTo(.locked));
}
