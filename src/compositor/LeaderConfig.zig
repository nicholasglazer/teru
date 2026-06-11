//! Materializes WmConfig's index-based `[leader]` definitions into the
//! pointer-linked `[]const Entry` tree that LeaderKey walks, and installs the
//! optional activation chord.
//!
//! Why a separate stage: WmConfig is a copied value type (fixed buffers, no
//! allocator), so it can't hold the self-referential `[]const Entry` slices a
//! group tree needs. This struct is a Server FIELD (Server is heap-allocated
//! and never moved), so the inter-group slices and the label pointers (which
//! point back into the equally-stable `server.wm_config`) stay valid for the
//! process lifetime. Rebuilt wholesale on every config (re)load.

const std = @import("std");
const teru = @import("teru");
const Server = @import("Server.zig");
const WmConfig = @import("WmConfig.zig");
const LeaderKey = @import("LeaderKey.zig");
const Keybinds = teru.Keybinds;
const Entry = LeaderKey.Entry;

const LeaderConfig = @This();

/// Stable backing store for the runtime Entry tree.
groups: [WmConfig.max_leader_groups][WmConfig.max_leader_entries]Entry = undefined,
group_lens: [WmConfig.max_leader_groups]u8 = @splat(0),
group_count: u8 = 0,

/// Rebuild `server.leader.{root,node,crumb}` from `server.wm_config`. Falls
/// back to LeaderKey's comptime default tree when the user hasn't configured
/// `[leader]` (or configured an empty root).
pub fn build(server: *Server) void {
    const wc = &server.wm_config;
    if (!wc.leader_configured or wc.leader_group_count == 0) {
        useDefault(server);
        return;
    }

    var t = &server.leader_tree;
    t.group_count = wc.leader_group_count;

    // Pass 1: copy entries. Group targets get a placeholder until pass 2 (all
    // group lengths must be known before the child slices can be taken).
    var gi: u8 = 0;
    while (gi < wc.leader_group_count) : (gi += 1) {
        const gdef = &wc.leader_groups[gi];
        var n: u8 = 0;
        var ei: u8 = 0;
        while (ei < gdef.entry_count and n < WmConfig.max_leader_entries) : (ei += 1) {
            const edef = &gdef.entries[ei];
            if (edef.is_group and edef.group_idx >= wc.leader_group_count) continue; // bad ref
            t.groups[gi][n] = .{
                .key = edef.key,
                .label = edef.label(),
                .target = if (edef.is_group) .{ .action = .none } else .{ .action = edef.action },
            };
            n += 1;
        }
        t.group_lens[gi] = n;
    }

    // Pass 2: wire group links (mirror pass 1's skip logic so slot indices align).
    gi = 0;
    while (gi < wc.leader_group_count) : (gi += 1) {
        const gdef = &wc.leader_groups[gi];
        var n: u8 = 0;
        var ei: u8 = 0;
        while (ei < gdef.entry_count and n < t.group_lens[gi]) : (ei += 1) {
            const edef = &gdef.entries[ei];
            if (edef.is_group and edef.group_idx >= wc.leader_group_count) continue;
            if (edef.is_group) {
                const tg = edef.group_idx;
                t.groups[gi][n].target = .{ .group = t.groups[tg][0..t.group_lens[tg]] };
            }
            n += 1;
        }
    }

    // An empty root means the config is unusable — keep the curated default.
    if (t.group_lens[0] == 0) {
        useDefault(server);
        return;
    }

    server.leader.root = t.groups[0][0..t.group_lens[0]];
    server.leader.node = server.leader.root;
    server.leader.crumb = "LEADER";
    std.log.scoped(.config).info("loaded leader menu ({d} groups)", .{wc.leader_group_count});
}

fn useDefault(server: *Server) void {
    server.leader.root = &LeaderKey.root_group;
    server.leader.node = server.leader.root;
    server.leader.crumb = "LEADER";
}

/// Install the configured `[leader] activate = <chord>` over the hardcoded
/// Super+Space default. No-op when unset. Call AFTER loadMediaDefaults so it
/// overrides, not the other way round.
pub fn applyActivate(server: *Server) void {
    const chord = server.wm_config.leaderActivate();
    if (chord.len == 0) return;
    const trig = Keybinds.parseTriggerWithMod(chord, server.keybinds.mod_key) orelse {
        std.log.scoped(.config).warn("bad [leader] activate chord '{s}'", .{chord});
        return;
    };
    if (trig.is_keycode) {
        _ = server.keybinds.addKeycode(.normal, trig.key, .leader_activate);
    } else {
        _ = server.keybinds.add(.normal, trig.mods, trig.key, .leader_activate);
    }
    std.log.scoped(.config).info("leader activation rebound to '{s}'", .{chord});
}
