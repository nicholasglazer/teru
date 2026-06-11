//! Shared leader/which-key CONFIG: parses `[leader]` / `[leader.NAME]` config
//! sections into index-based defs (copy-safe — no pointers), and materializes
//! them into the pointer-linked `[]const Entry` tree the LeaderKey engine
//! walks. One code path for both binaries: teruwm (`~/.config/teruwm/config`
//! via WmConfig) and teru (`teru.conf` via Config). The owning config struct
//! is kept alive for the session, so the materialized tree's label slices
//! (which point back into `Defs`) stay valid.

const std = @import("std");
const LeaderKey = @import("LeaderKey.zig");
const Keybinds = @import("Keybinds.zig");
const Entry = LeaderKey.Entry;

pub const max_groups = 12; // root + 11 sub-groups
pub const max_entries = 16; // rows per group
const label_max = 24;
const name_max = 24;

/// One configured row: a key, a label, and either an Action or a child group.
pub const EntryDef = struct {
    key: u8 = 0,
    label_buf: [label_max]u8 = undefined,
    label_len: u8 = 0,
    is_group: bool = false,
    action: Keybinds.Action = .none,
    group_idx: u8 = 0,

    pub fn label(self: *const EntryDef) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

/// One configured group. Index 0 is always the root (crumb "LEADER"); named
/// groups (`[leader.NAME]`) get crumb "+NAME".
pub const GroupDef = struct {
    name_buf: [name_max]u8 = undefined,
    name_len: u8 = 0,
    crumb_buf: [label_max]u8 = undefined,
    crumb_len: u8 = 0,
    entries: [max_entries]EntryDef = undefined,
    entry_count: u8 = 0,

    pub fn name(self: *const GroupDef) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn crumb(self: *const GroupDef) []const u8 {
        return self.crumb_buf[0..self.crumb_len];
    }
};

/// Index-based, copy-safe leader definition. Embedded in WmConfig / Config.
pub const Defs = struct {
    groups: [max_groups]GroupDef = undefined,
    group_count: u8 = 0,
    configured: bool = false,
    /// Optional activation chord (`[leader] activate = <chord>`). Empty = keep
    /// the binary's hardcoded default.
    activate_buf: [64]u8 = undefined,
    activate_len: u8 = 0,

    pub fn activateChord(self: *const Defs) []const u8 {
        return self.activate_buf[0..self.activate_len];
    }

    fn setCrumb(self: *Defs, idx: u8, s: []const u8) void {
        const n = @min(s.len, label_max);
        @memcpy(self.groups[idx].crumb_buf[0..n], s[0..n]);
        self.groups[idx].crumb_len = @intCast(n);
    }

    /// Find or append a group by name. Index 0 is reserved for the root (name
    /// "", crumb "LEADER"); named groups get crumb "+NAME". Forward refs are
    /// fine (a `+foo` entry before `[leader.foo]` just creates the empty group).
    pub fn resolveGroup(self: *Defs, gname: []const u8) ?u8 {
        self.configured = true;
        if (self.group_count == 0) {
            self.groups[0] = .{};
            self.setCrumb(0, "LEADER");
            self.group_count = 1;
        }
        if (gname.len == 0) return 0; // root
        if (gname.len >= name_max) return null;
        var i: u8 = 1;
        while (i < self.group_count) : (i += 1) {
            if (std.mem.eql(u8, self.groups[i].name(), gname)) return i;
        }
        if (self.group_count >= max_groups) return null;
        const idx = self.group_count;
        self.groups[idx] = .{};
        @memcpy(self.groups[idx].name_buf[0..gname.len], gname);
        self.groups[idx].name_len = @intCast(gname.len);
        var cbuf: [label_max]u8 = undefined;
        cbuf[0] = '+';
        const clen = @min(gname.len, label_max - 1);
        @memcpy(cbuf[1 .. 1 + clen], gname[0..clen]);
        self.setCrumb(idx, cbuf[0 .. 1 + clen]);
        self.group_count += 1;
        return idx;
    }

    /// Map a key token to a byte: "SPC"/"Space" → space; else a single printable
    /// non-space char (letters may be uppercase to mean Shift+letter).
    fn parseKey(tok: []const u8) ?u8 {
        if (std.mem.eql(u8, tok, "SPC") or std.mem.eql(u8, tok, "Space") or std.mem.eql(u8, tok, "space")) return ' ';
        if (tok.len == 1 and tok[0] >= 0x21 and tok[0] <= 0x7e) return tok[0];
        return null;
    }

    /// Parse one `key = value` under a `[leader]` / `[leader.NAME]` section.
    ///   activate = <chord>           (root only)
    ///   <key> = +group               (descend)
    ///   <key> = label : action       (run an Action; Action.fromString name)
    pub fn applyLine(self: *Defs, gidx: u8, key: []const u8, value: []const u8) void {
        if (gidx >= self.group_count) return;

        if (gidx == 0 and std.mem.eql(u8, key, "activate")) {
            const n = @min(value.len, self.activate_buf.len);
            @memcpy(self.activate_buf[0..n], value[0..n]);
            self.activate_len = @intCast(n);
            return;
        }

        const k = parseKey(key) orelse return;
        if (self.groups[gidx].entry_count >= max_entries) return;

        // Group reference: "<key> = +groupname"
        if (value.len > 1 and value[0] == '+') {
            const gname = std.mem.trim(u8, value[1..], &std.ascii.whitespace);
            if (gname.len == 0) return;
            const tidx = self.resolveGroup(gname) orelse return;
            const g = &self.groups[gidx];
            var e = EntryDef{ .key = k, .is_group = true, .group_idx = tidx };
            const llen = @min(value.len, label_max);
            @memcpy(e.label_buf[0..llen], value[0..llen]);
            e.label_len = @intCast(llen);
            g.entries[g.entry_count] = e;
            g.entry_count += 1;
            return;
        }

        // Action entry: "<key> = label : action"
        const colon = std.mem.findScalar(u8, value, ':') orelse return;
        const lbl = std.mem.trim(u8, value[0..colon], &std.ascii.whitespace);
        const act_str = std.mem.trim(u8, value[colon + 1 ..], &std.ascii.whitespace);
        if (lbl.len == 0) return;
        const action = Keybinds.Action.fromString(act_str) orelse return;
        const g = &self.groups[gidx];
        var e = EntryDef{ .key = k, .is_group = false, .action = action };
        const llen = @min(lbl.len, label_max);
        @memcpy(e.label_buf[0..llen], lbl[0..llen]);
        e.label_len = @intCast(llen);
        g.entries[g.entry_count] = e;
        g.entry_count += 1;
    }
};

/// Stable materialized tree. Owned by the consumer (a Server field / a tui.zig
/// local), since its inter-group slices and the label pointers (into `Defs`)
/// must outlive build().
pub const Tree = struct {
    groups: [max_groups][max_entries]Entry = undefined,
    group_lens: [max_groups]u8 = @splat(0),
    group_count: u8 = 0,

    /// Materialize `defs` into a pointer-linked tree. Returns the root slice, or
    /// null when defs are unusable (unconfigured / empty root) — the caller then
    /// falls back to its comptime default tree.
    pub fn build(self: *Tree, defs: *const Defs) ?[]const Entry {
        if (!defs.configured or defs.group_count == 0) return null;
        self.group_count = defs.group_count;

        // Pass 1: copy entries (group targets get a placeholder until pass 2,
        // since all group lengths must be known before child slices are taken).
        var gi: u8 = 0;
        while (gi < defs.group_count) : (gi += 1) {
            const gdef = &defs.groups[gi];
            var n: u8 = 0;
            var ei: u8 = 0;
            while (ei < gdef.entry_count and n < max_entries) : (ei += 1) {
                const edef = &gdef.entries[ei];
                if (edef.is_group and edef.group_idx >= defs.group_count) continue; // bad ref
                self.groups[gi][n] = .{
                    .key = edef.key,
                    .label = edef.label(),
                    .target = if (edef.is_group) .{ .action = .none } else .{ .action = edef.action },
                };
                n += 1;
            }
            self.group_lens[gi] = n;
        }

        // Pass 2: wire group links (mirror pass 1's skip logic so slots align).
        gi = 0;
        while (gi < defs.group_count) : (gi += 1) {
            const gdef = &defs.groups[gi];
            var n: u8 = 0;
            var ei: u8 = 0;
            while (ei < gdef.entry_count and n < self.group_lens[gi]) : (ei += 1) {
                const edef = &gdef.entries[ei];
                if (edef.is_group and edef.group_idx >= defs.group_count) continue;
                if (edef.is_group) {
                    const tg = edef.group_idx;
                    self.groups[gi][n].target = .{ .group = self.groups[tg][0..self.group_lens[tg]] };
                }
                n += 1;
            }
        }

        if (self.group_lens[0] == 0) return null; // empty root → unusable
        return self.groups[0][0..self.group_lens[0]];
    }
};

test "LeaderDefs: parse + materialize a small tree" {
    var d = Defs{};
    // root
    _ = d.resolveGroup("");
    d.applyLine(0, "activate", "ctrl+space");
    d.applyLine(0, "d", "detach : session:detach");
    d.applyLine(0, "p", "+pane");
    // +pane (forward-referenced above)
    const pi = d.resolveGroup("pane").?;
    d.applyLine(pi, "x", "close : pane:close");
    d.applyLine(pi, "J", "swap-next : pane:swap_next");

    try std.testing.expect(d.configured);
    try std.testing.expectEqual(@as(u8, 2), d.group_count);
    try std.testing.expectEqualStrings("ctrl+space", d.activateChord());

    var tree = Tree{};
    const root = tree.build(&d) orelse return error.BuildFailed;
    var lk = LeaderKey{};
    lk.root = root;
    lk.activate();
    var r = lk.feedKey('d', false);
    try std.testing.expect(r == .run and r.run == .session_detach);
    lk.activate();
    try std.testing.expect(lk.feedKey('p', false) == .redraw);
    r = lk.feedKey('j', true); // Shift+j → swap-next
    try std.testing.expect(r == .run and r.run == .pane_swap_next);
}
