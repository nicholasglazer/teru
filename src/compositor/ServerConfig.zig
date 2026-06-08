//! Config application for teruwm — translates a parsed teru.Config and
//! the teruwm-specific WmConfig into live Server state: font atlas,
//! keybind tables, per-workspace layouts, spawn/scratchpad chords, bar
//! widgets, and the live `reloadWmConfig` hot-reload path. Server.zig
//! keeps thin delegators; the private chord/rule seeders moved here
//! whole since applyConfig is their only caller.

const std = @import("std");
const wlr = @import("wlr.zig");
const WmConfig = @import("WmConfig.zig");
const Server = @import("Server.zig");
const teru = @import("teru");
const Keybinds = teru.Keybinds;
const Mods = Keybinds.Mods;

/// Apply loaded config to server state: font, colors, keybinds, workspace layouts, bars.
pub fn applyConfig(self: *Server, config: *const teru.Config, allocator: std.mem.Allocator, io: std.Io) void {
    // ── Font atlas from config (+ optional bold/italic variants) ──
    if (teru.render.FontAtlas.init(allocator, config.font_path, config.font_size, io)) |atlas| {
        const fa = allocator.create(teru.render.FontAtlas) catch return;
        fa.* = atlas;
        self.font_atlas = fa;
        self.font_size = config.font_size;
        self.font_size_base = config.font_size;
        // Bold/italic/bold-italic variants — same as windowed mode; silently
        // fall back to the regular atlas when unset or unloadable.
        if (config.font_bold) |p| self.font_variant_bold = fa.loadVariant(allocator, p, io) catch null;
        if (config.font_italic) |p| self.font_variant_italic = fa.loadVariant(allocator, p, io) catch null;
        if (config.font_bold_italic) |p| self.font_variant_bold_italic = fa.loadVariant(allocator, p, io) catch null;
        std.log.scoped(.config).info("font loaded ({d}x{d} cells)", .{ fa.cell_width, fa.cell_height });
    } else |err| {
        std.log.scoped(.config).err("font init failed: {}, using fallback", .{err});
    }

    // ── Keybinds: set mod to Super (compositor), load unified defaults + media ──
    self.keybinds.mod_key = Mods.SUPER;
    self.keybinds.loadDefaults(); // uses mod_key = Super for all $mod bindings
    self.keybinds.loadMediaDefaults(); // XF86 media keys (no modifier)
    self.keybinds.loadScratchpadDefaults(); // Super+T, Super+Shift+T → scratchpad_0, scratchpad_1
    applyDefaultScratchpadNames(self); // seed scratchpad_table[0..1]
    // applyDefaultScratchpadRules runs later, *after* wm_config.load
    // — otherwise load() would overwrite the rule table with its own
    // default-init values. Deferred to the post-load hook below.
    // Apply user overrides from teru.conf on top
    // (config.keybinds were parsed with the old mod — we re-load with Super)

    // ── Launcher ($PATH scan) ─────────────────────────────────
    self.launcher.init();

    // ── Per-workspace layouts from config ────────────────────
    for (0..10) |i| {
        if (config.workspace_layout_counts[i] > 0) {
            self.layout_engine.workspaces[i].setLayouts(
                config.workspace_layout_lists[i][0..config.workspace_layout_counts[i]],
            );
        } else if (config.workspace_layouts[i]) |layout| {
            self.layout_engine.workspaces[i].layout = layout;
        }
        if (config.workspace_ratios[i]) |ratio| {
            self.layout_engine.workspaces[i].master_ratio = ratio;
        }
        if (config.workspace_names[i]) |name| {
            self.layout_engine.workspaces[i].name = name;
        }
    }

    // ── Terminal-rendering settings from teru.conf ───────────
    // Fed to every native TerminalPane so panes honour the user's teru.conf
    // instead of libteru defaults: colors/palette/cursor-color/selection via
    // the scheme, cursor shape / scrollback / shell / $TERM / tab width via the
    // SpawnConfig, and the content margin via padding. (bold_is_bright rides the
    // scheme.) Consumed in TerminalPane init/restore — the same teru.conf the
    // standalone windowed terminal reads, so panes look identical in both.
    self.color_scheme = config.colorScheme();
    self.terminal_padding = config.padding;
    self.spawn_config = .{
        .shell = config.shell,
        .scrollback_lines = config.scrollback_lines,
        .term = config.term,
        .tab_width = config.tab_width,
        .cursor_shape = config.cursor_shape,
    };

    // ── teruwm-specific config (~/.config/teruwm/config) ────
    self.wm_config = WmConfig.load(io);
    if (self.wm_config.rule_count > 0) {
        std.log.scoped(.config).info("loaded {d} window rules", .{self.wm_config.rule_count});
    }

    // ── User-defined spawn chords from [keybind] section ────
    applyWmSpawnChords(self);

    // ── User-defined scratchpad chords from [keybind] section ──
    applyWmScratchpadChords(self);

    // ── Default scratchpad geometry rules (xmonad parity) ──
    // Runs AFTER wm_config.load so user's `[scratchpad.NAME]` rules
    // are already in wm_config.scratchpad_rules — the default seeder
    // only fills in names the user hasn't customised.
    applyDefaultScratchpadRules(self);
}

/// Resolve each `[keybind] chord = spawn:cmd` entry into a spawn_table
/// slot and install the binding in the keybinds table.
fn applyWmSpawnChords(self: *Server) void {
    var slot: u8 = 0;
    for (self.wm_config.spawn_chords[0..self.wm_config.spawn_chord_count]) |*entry| {
        if (slot >= self.spawn_table.len) break;

        // Parse the chord ("Mod+Return") via the shared trigger parser
        const trig = Keybinds.parseTriggerWithMod(entry.getChord(), self.keybinds.mod_key) orelse {
            std.log.scoped(.config).warn("skipping bad keybind chord '{s}'", .{entry.getChord()});
            continue;
        };

        // Store cmd in spawn_table[slot]
        const cmd = entry.getCmd();
        const n = @min(cmd.len, self.spawn_table[slot].len);
        @memcpy(self.spawn_table[slot][0..n], cmd[0..n]);
        self.spawn_table_len[slot] = @intCast(n);

        // Map to spawn_N action
        const first_tag: u8 = @intFromEnum(Keybinds.Action.spawn_0);
        const action: Keybinds.Action = @enumFromInt(first_tag + slot);

        // Install in normal mode (shared works too but normal is the daily path)
        _ = self.keybinds.add(.normal, trig.mods, trig.key, action);
        slot += 1;
    }
    if (slot > 0) {
        std.log.scoped(.config).info("loaded {d} spawn chords", .{slot});
    }
}

/// Resolve each `[keybind] chord = scratchpad:name` entry. User config
/// entries take precedence over defaults: if a chord matches a default
/// binding's chord we reuse the same slot (`addBinding` already
/// overwrites same-chord mappings), but we first store the name in
/// the next free table slot and bind `scratchpad_<slot>` to the chord.
fn applyWmScratchpadChords(self: *Server) void {
    var slot: u8 = 0;
    for (self.wm_config.scratchpad_chords[0..self.wm_config.scratchpad_chord_count]) |*entry| {
        if (slot >= self.scratchpad_table.len) break;

        const trig = Keybinds.parseTriggerWithMod(entry.getChord(), self.keybinds.mod_key) orelse {
            std.log.scoped(.config).warn("skipping bad scratchpad chord '{s}'", .{entry.getChord()});
            continue;
        };

        const name = entry.getName();
        const n = @min(name.len, self.scratchpad_table[slot].len);
        @memcpy(self.scratchpad_table[slot][0..n], name[0..n]);
        self.scratchpad_table_len[slot] = @intCast(n);

        const first_tag: u8 = @intFromEnum(Keybinds.Action.scratchpad_0);
        const action: Keybinds.Action = @enumFromInt(first_tag + slot);
        _ = self.keybinds.add(.normal, trig.mods, trig.key, action);
        slot += 1;
    }
    if (slot > 0) {
        std.log.scoped(.config).info("loaded {d} scratchpad chords", .{slot});
    }
}

/// Pre-seed scratchpad_table[0..3] with the names the default
/// loadScratchpadDefaults() chords point at. Called once during init,
/// before the user's [keybind] entries are applied — users who
/// override a default chord get their own name in the next free
/// slot, but these defaults stay live for any chord they didn't
/// rebind.
fn applyDefaultScratchpadNames(self: *Server) void {
    // Only 2 default-bound chords: Super+T → terminalBR, Super+Shift+T
    // → terminalSR. Matches user's xmonad Mod+T / Mod+Shift+T bindings.
    // terminalBL/SL are registered as rules (reachable via MCP or
    // user-added config chord) but don't consume a default keybind.
    const defaults = [_][]const u8{ "terminalBR", "terminalSR" };
    for (defaults, 0..) |name, slot| {
        const n = @min(name.len, self.scratchpad_table[slot].len);
        @memcpy(self.scratchpad_table[slot][0..n], name[0..n]);
        self.scratchpad_table_len[slot] = @intCast(n);
    }
}

/// Pre-register 4 named scratchpad rules matching the user's xmonad
/// layout (Scratchpads.hs). User's `[scratchpad.NAME]` config sections
/// look these up by name — existing rules are mutated in place, new
/// names are appended. So adding `[scratchpad.terminalBR] w = 70%` in
/// the user's config replaces only the width field; x/y/h stay at
/// xmonad defaults.
fn applyDefaultScratchpadRules(self: *Server) void {
    const defaults = [_]struct {
        name: []const u8,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
    }{
        // terminalBR — big right: h=78%, w=57%, l=42%, t=3%
        .{ .name = "terminalBR", .x = 0.42, .y = 0.03, .w = 0.57, .h = 0.78 },
        // terminalSR — small right: h=15%, w=57%, l=42%, t=83%
        .{ .name = "terminalSR", .x = 0.42, .y = 0.83, .w = 0.57, .h = 0.15 },
        // terminalBL — big left: h=62%, w=40%, l=1%, t=3%
        .{ .name = "terminalBL", .x = 0.01, .y = 0.03, .w = 0.40, .h = 0.62 },
        // terminalSL — small left: h=31%, w=40%, l=1%, t=67%
        .{ .name = "terminalSL", .x = 0.01, .y = 0.67, .w = 0.40, .h = 0.31 },
    };
    for (defaults) |d| {
        // resolveScratchpadRule either finds or appends.
        const idx = self.wm_config.resolveScratchpadRule(d.name) orelse continue;
        const rule = &self.wm_config.scratchpad_rules[idx];
        if (!rule.has_rect) {
            rule.x = d.x;
            rule.y = d.y;
            rule.w = d.w;
            rule.h = d.h;
            rule.has_rect = true;
        }
    }
}

/// Look up per-name scratchpad rule by scratchpad name. Returns null
/// if no explicit rule — caller should fall back to global centered
/// rect.
pub fn scratchpadRuleFor(self: *const Server, name: []const u8) ?*const WmConfig.ScratchpadRule {
    var i: u8 = 0;
    while (i < self.wm_config.scratchpad_rule_count) : (i += 1) {
        const r = &self.wm_config.scratchpad_rules[i];
        if (std.mem.eql(u8, r.getName(), name)) return r;
    }
    return null;
}

/// Return the scratchpad name for action `a` (which must be one of
/// scratchpad_0..7). Empty string if unbound.
pub fn scratchpadNameFor(self: *const Server, a: Keybinds.Action) []const u8 {
    const first: u8 = @intFromEnum(Keybinds.Action.scratchpad_0);
    const tag: u8 = @intFromEnum(a);
    if (tag < first or tag >= first + self.scratchpad_table.len) return "";
    const slot = tag - first;
    return self.scratchpad_table[slot][0..self.scratchpad_table_len[slot]];
}

/// Apply teruwm bar config to the bar instance (called after bar creation).
pub fn applyWmBar(self: *Server) void {
    if (self.bar) |b| {
        const wc = &self.wm_config;
        b.configure(
            wc.bar_top_left,
            wc.bar_top_center,
            wc.bar_top_right,
            wc.bar_bottom_left,
            wc.bar_bottom_center,
            wc.bar_bottom_right,
        );
    }
}

/// Reload compositor config from disk and re-apply live.
/// Called by Mod+Shift+R keybind or teruwm_reload_config MCP tool.
pub fn reloadWmConfig(self: *Server) void {
    // Re-read config file (requires io — use a dummy Io for file access)
    // Use libc fopen/fread to reload config (no Io needed)
    self.wm_config = WmConfig.loadWithLibc();

    // Re-seed the xmonad-parity scratchpad rects. loadWithLibc() returns a
    // fresh WmConfig with scratchpad_rule_count = 0, so any user
    // `[scratchpad.NAME]` sections are re-parsed but the DEFAULT geometry
    // for names the user hasn't customised (terminalBR/SR/BL/SL) is gone
    // until we re-seed — exactly as applyConfig does after the initial
    // WmConfig.load. Without this, reload (Mod+Shift+R / teruwm_reload_config
    // / config-watch) leaves every default scratchpad falling back to the
    // centered defaultRect, so mod+t and mod+shift+t both open the same
    // centered window instead of their distinct xmonad rects.
    applyDefaultScratchpadRules(self);

    // Re-bind user [keybind] spawn + scratchpad chords. loadWithLibc()
    // refreshed the chord DATA (wm_config.spawn_chords / scratchpad_chords),
    // but the keybinds trigger→Action table and the Action→command payload
    // tables (spawn_table / scratchpad_table) are only populated by these
    // two appliers — they run at init from applyConfig. Without re-running
    // them on reload, a newly added chord is dead until restart and an
    // edited chord keeps firing the STALE command (the appliers re-@memcpy
    // the fresh command into its deterministic slot). Re-applier-only is
    // deliberate: a full keybinds reset would wipe init-time teru.conf
    // [keybinds.*] overrides.
    applyWmSpawnChords(self);
    applyWmScratchpadChords(self);

    // Re-apply bar configuration — widget layout or thresholds may
    // have changed in ways the signature hash doesn't detect
    // (widgets.count alone can't express a widget's internal fmt).
    // Force a repaint.
    if (self.bar) |b| {
        b.configure(
            self.wm_config.bar_top_left,
            self.wm_config.bar_top_center,
            self.wm_config.bar_top_right,
            self.wm_config.bar_bottom_left,
            self.wm_config.bar_bottom_center,
            self.wm_config.bar_bottom_right,
        );
        b.dirty = true;
        _ = b.render(self);
    }

    // Apply new background color to the scene rect
    if (self.bg_rect) |rect| {
        const col = self.wm_config.bg_color;
        const rgba: [4]f32 = .{
            @as(f32, @floatFromInt((col >> 16) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((col >> 8) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt(col & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((col >> 24) & 0xFF)) / 255.0,
        };
        wlr.wlr_scene_rect_set_color(rect, &rgba);
    }

    // Re-arrange all workspaces with new gap
    for (0..10) |wi| {
        const ws = &self.layout_engine.workspaces[wi];
        if (ws.node_ids.items.len > 0) {
            self.arrangeworkspace(@intCast(wi));
        }
    }

    // Re-apply keymap to *every* attached keyboard so [keyboard] edits
    // take effect without reconnecting devices. Laptops typically have
    // a built-in keyboard plus one external dock keyboard — refreshing
    // only the seat's active one (which is whichever key was last hit)
    // leaves the other stuck on the old layout.
    //
    // Build the keymap once and hand the same ref to each device. wlroots
    // retains its own ref in wlr_keyboard_set_keymap, so we unref once
    // at the end.
    const new_keymap = blk: {
        if (self.wm_config.hasXkbOverrides()) {
            const names = wlr.XkbRuleNames{
                .rules = self.wm_config.getXkbRules(),
                .model = self.wm_config.getXkbModel(),
                .layout = self.wm_config.getXkbLayout(),
                .variant = self.wm_config.getXkbVariant(),
                .options = self.wm_config.getXkbOptions(),
            };
            if (wlr.xkb_keymap_new_from_names(self.xkb_ctx, &names, 0)) |km| break :blk km;
            std.log.scoped(.config).warn("[keyboard] config invalid on reload, keeping previous keymap", .{});
            break :blk null;
        }
        break :blk wlr.xkb_keymap_new_from_names(self.xkb_ctx, null, 0);
    };
    if (new_keymap) |km| {
        defer wlr.xkb_keymap_unref(km);
        for (self.keyboards.items) |kb| {
            _ = wlr.wlr_keyboard_set_keymap(kb.wlr_keyboard, km);
        }
        // Refresh the bar widget from the seat's active keyboard (or any
        // keyboard if the seat has none yet — the name is identical after
        // a bulk reapply).
        const refresh_kb = wlr.miozu_seat_get_keyboard(self.seat) orelse
            (if (self.keyboards.items.len > 0) self.keyboards.items[0].wlr_keyboard else null);
        if (refresh_kb) |rkb| self.refreshActiveKeymap(rkb);
    }

    std.log.scoped(.config).info("config reloaded (gap={d}, border={d}, bg=0x{x:0>8})", .{ self.wm_config.gap, self.wm_config.border_width, self.wm_config.bg_color });
}
