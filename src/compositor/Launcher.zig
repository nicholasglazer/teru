//! Built-in application launcher for teruwm.
//!
//! Scans $PATH for executables on init. When activated (Super+D), the
//! top bar transforms into an input field with prefix-filtered results.
//! Type to filter, Enter to launch, Escape to cancel, Tab to cycle.
//!
//! Zero external dependencies. Renders with the same FontAtlas as the bar.
//! No popup, no floating window — the bar IS the launcher.

const std = @import("std");
const teru = @import("teru");
const Ui = teru.Ui;
const SoftwareRenderer = teru.render.SoftwareRenderer;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");

const Launcher = @This();
const Action = teru.Keybinds.Action;
const Entry = teru.LeaderKey.Entry;

const max_entries = 4096;
const max_commands = 256;
const max_query = 128;
const max_visible = 8; // max results shown in bar

/// A leader command in the palette: a label + the action to dispatch. `label`
/// points into stable storage (comptime tree or config buffers, both
/// Server-lived).
const Command = struct { label: []const u8, action: Action };

// Sorted executable names from $PATH
entries: [max_entries][]const u8 = undefined,
count: u32 = 0,

// Leader commands (flattened from the leader tree) — ranked BEFORE apps so the
// palette is "do something" first, "launch something" second.
commands: [max_commands]Command = undefined,
command_count: u32 = 0,

// Filter state
query: [max_query]u8 = undefined,
query_len: u8 = 0,
selected: u16 = 0, // index into filtered results
active: bool = false,
// Set when Enter selects a COMMAND — the caller (ServerInput) dispatches it
// through executeAction. Apps are launched here directly (spawnProcess).
pending_action: ?Action = null,

// Filtered results, in a UNIFIED index space: 0..command_count are commands,
// command_count.. are apps (offset by command_count into entries[]).
filtered: [max_entries]u32 = undefined,
filtered_count: u32 = 0,

// Backing memory for entry strings
arena: [256 * 1024]u8 = undefined, // 256KB for all executable names
arena_used: usize = 0,

pub fn init(self: *Launcher) void {
    self.count = 0;
    self.query_len = 0;
    self.selected = 0;
    self.active = false;
    self.filtered_count = 0;
    self.arena_used = 0;
    self.scanPath();
}

/// Scan $PATH directories for executables.
fn scanPath(self: *Launcher) void {
    const path_env = teru.compat.getenv("PATH") orelse return;
    var path_iter = std.mem.splitScalar(u8, path_env, ':');

    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;
        self.scanDir(dir);
    }

    // Sort entries for consistent display
    self.sortEntries();

    std.log.scoped(.compositor).info("launcher loaded {d} executables from $PATH", .{self.count});
}

fn scanDir(self: *Launcher, path: []const u8) void {
    // Use C opendir/readdir for Zig 0.16 compat
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len - 1) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const dir = libc.opendir(@ptrCast(path_buf[0..path.len :0]));
    if (dir == null) return;
    defer _ = libc.closedir(dir.?);

    while (libc.readdir(dir.?)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.*.d_name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (name.len == 0 or name[0] == '.') continue;

        // Skip duplicates
        var dupe = false;
        for (self.entries[0..self.count]) |existing| {
            if (std.mem.eql(u8, existing, name)) { dupe = true; break; }
        }
        if (dupe) continue;

        // Store in arena
        if (self.arena_used + name.len > self.arena.len) return;
        if (self.count >= max_entries) return;

        @memcpy(self.arena[self.arena_used .. self.arena_used + name.len], name);
        self.entries[self.count] = self.arena[self.arena_used .. self.arena_used + name.len];
        self.arena_used += name.len;
        self.count += 1;
    }
}

fn sortEntries(self: *Launcher) void {
    const items = self.entries[0..self.count];
    std.mem.sort([]const u8, items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
}

// ── Activation ─────────────────────────────────────────────────

pub fn activate(self: *Launcher) void {
    self.active = true;
    self.query_len = 0;
    self.selected = 0;
    self.pending_action = null;
    self.updateFilter();
}

pub fn deactivate(self: *Launcher) void {
    self.active = false;
    self.query_len = 0;
}

/// Flatten a leader tree into the command list (depth-first) so the palette can
/// fuzzy-search every action by its label. Call right before activate() so the
/// commands reflect the live (possibly config-driven) tree.
pub fn seedCommands(self: *Launcher, root: []const Entry) void {
    self.command_count = 0;
    self.addGroup(root, 0);
}

fn addGroup(self: *Launcher, node: []const Entry, depth: u8) void {
    if (depth > 8) return; // guard against a self-referential config tree
    for (node) |e| {
        switch (e.target) {
            .action => |a| {
                if (self.command_count >= max_commands) return;
                self.commands[self.command_count] = .{ .label = e.label, .action = a };
                self.command_count += 1;
            },
            .group => |g| self.addGroup(g, depth + 1),
        }
    }
}

// ── Input handling ─────────────────────────────────────────────

/// Handle a key press while launcher is active. Returns true if consumed.
pub fn handleKey(self: *Launcher, keysym: u32, server: *Server) bool {
    switch (keysym) {
        0xFF1B => { // Escape
            self.deactivate();
            // deactivate() only flips the active flag — the bar still
            // holds the last-painted launcher pixels. bar.render() has a
            // signature-based skip, and deactivating doesn't change any
            // of the fields that feed the signature (same workspace,
            // same windows, same mode text). Force a repaint by flipping
            // the dirty flag so render() bypasses the signature check.
            if (server.bar) |b| {
                b.dirty = true;
                _ = b.render(server);
            }
            return true;
        },
        0xFF0D => { // Return — run selected (command → action; app → spawn)
            if (self.filtered_count > 0 and self.selected < self.filtered_count) {
                const uidx = self.filtered[self.selected];
                if (uidx < self.command_count) {
                    // Command: defer dispatch to the caller (it owns executeAction).
                    self.pending_action = self.commands[uidx].action;
                } else {
                    self.launchProgram(self.entries[uidx - self.command_count], server);
                }
            }
            self.deactivate();
            if (server.bar) |b| {
                b.dirty = true;
                _ = b.render(server);
            }
            return true;
        },
        0xFF09 => { // Tab — cycle selection
            if (self.filtered_count > 0) {
                self.selected = @intCast((@as(u32, self.selected) + 1) % self.filtered_count);
            }
            return true;
        },
        0xFF08 => { // BackSpace
            if (self.query_len > 0) {
                self.query_len -= 1;
                self.updateFilter();
            }
            return true;
        },
        else => {
            // Printable ASCII → append to query
            if (keysym >= 0x20 and keysym <= 0x7E and self.query_len < max_query) {
                self.query[self.query_len] = @intCast(keysym);
                self.query_len += 1;
                self.selected = 0;
                self.updateFilter();
                return true;
            }
            return false;
        },
    }
}

fn updateFilter(self: *Launcher) void {
    self.filtered_count = 0;
    const q = self.query[0..self.query_len];

    // Commands FIRST (case-insensitive substring on the short labels).
    for (0..self.command_count) |i| {
        if (q.len == 0 or icontains(self.commands[i].label, q)) {
            self.filtered[self.filtered_count] = @intCast(i);
            self.filtered_count += 1;
            if (self.filtered_count >= max_entries) return;
        }
    }

    // Apps after — prefix matches, then substring matches (offset into the
    // unified index space by command_count).
    for (0..self.count) |i| {
        if (q.len == 0 or std.mem.startsWith(u8, self.entries[i], q)) {
            self.filtered[self.filtered_count] = @intCast(self.command_count + i);
            self.filtered_count += 1;
            if (self.filtered_count >= max_entries) return;
        }
    }
    if (q.len > 0) {
        for (0..self.count) |i| {
            if (!std.mem.startsWith(u8, self.entries[i], q) and std.mem.find(u8, self.entries[i], q) != null) {
                self.filtered[self.filtered_count] = @intCast(self.command_count + i);
                self.filtered_count += 1;
                if (self.filtered_count >= max_entries) return;
            }
        }
    }
}

/// Case-insensitive substring test (labels are short; this is off the hot path).
fn icontains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn launchProgram(self: *Launcher, name: []const u8, server: *Server) void {
    _ = self;
    var cmd_buf: [256]u8 = undefined;
    if (name.len >= cmd_buf.len - 1) return;
    @memcpy(cmd_buf[0..name.len], name);
    cmd_buf[name.len] = 0;
    server.spawnProcess(@ptrCast(cmd_buf[0..name.len :0]));
}

// ── Rendering ──────────────────────────────────────────────────

/// Render the launcher UI into the bar's scene buffer.
pub fn render(self: *Launcher, cpu: *SoftwareRenderer) void {
    const s = &cpu.scheme;
    const cw: usize = cpu.cell_width;
    const fb_w: usize = cpu.width;
    const bar_h: usize = cpu.height;

    // Clear bar with slightly different bg to indicate launcher mode
    const launcher_bg = s.ansi[0]; // black
    const total = @min(fb_w * bar_h, cpu.framebuffer.len);
    teru.compat.memsetU32(cpu.framebuffer[0..total], launcher_bg);

    // Separator
    if (fb_w > 0 and total >= fb_w) {
        teru.compat.memsetU32(cpu.framebuffer[0..fb_w], s.cursor); // orange separator = launcher active
    }

    const text_y: usize = 2;
    var x: usize = 4;

    // Prompt
    Ui.blitCharAt(cpu, '>', x, text_y, s.cursor); // orange >
    x += cw;
    Ui.blitCharAt(cpu, ' ', x, text_y, launcher_bg);
    x += cw;

    // Query text
    for (self.query[0..self.query_len]) |ch| {
        Ui.blitCharAt(cpu, ch, x, text_y, s.fg);
        x += cw;
    }

    // Cursor
    Ui.blitCharAt(cpu, '_', x, text_y, s.cursor);
    x += cw * 3;

    // Filtered results (right side of bar)
    const results_start = fb_w / 3; // start results at 1/3 of bar width
    x = @max(x, results_start);

    const show = @min(self.filtered_count, max_visible);
    for (0..show) |ri| {
        const uidx = self.filtered[ri];
        const is_cmd = uidx < self.command_count;
        const name = if (is_cmd) self.commands[uidx].label else self.entries[uidx - self.command_count];
        const is_selected = ri == self.selected;
        // orange selected · cyan commands · gray apps
        const color = if (is_selected) s.cursor else if (is_cmd) s.ansi[6] else s.ansi[8];

        for (name) |ch| {
            if (ch < 32 or ch > 126) continue;
            Ui.blitCharAt(cpu, ch, x, text_y, color);
            x += cw;
            if (x + cw * 3 >= fb_w) break;
        }

        // Separator between results
        if (ri < show - 1) {
            Ui.blitCharAt(cpu, ' ', x, text_y, launcher_bg);
            x += cw;
            Ui.blitCharAt(cpu, '|', x, text_y, s.ansi[8]);
            x += cw;
            Ui.blitCharAt(cpu, ' ', x, text_y, launcher_bg);
            x += cw;
        }

        if (x + cw >= fb_w) break;
    }
}

// ── C libc for directory scanning ──────────────────────────────

const DirEntry = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};

const libc = struct {
    extern "c" fn opendir(name: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "c" fn closedir(dir: *anyopaque) callconv(.c) c_int;
    extern "c" fn readdir(dir: *anyopaque) callconv(.c) ?*DirEntry;
};
