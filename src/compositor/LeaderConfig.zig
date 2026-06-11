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
const LeaderKey = teru.LeaderKey; // shared engine
const CompositorLeader = @import("CompositorLeader.zig"); // teruwm's default tree
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
    // Materialize the user's [leader] config via the shared builder; on null
    // (unconfigured / empty root) fall back to teruwm's curated comptime tree.
    const root = server.leader_tree.build(&server.wm_config.leader) orelse &CompositorLeader.root_group;
    server.leader.root = root;
    server.leader.node = root;
    server.leader.crumb = "LEADER";
    if (server.wm_config.leader.configured)
        std.log.scoped(.config).info("loaded leader menu ({d} groups)", .{server.wm_config.leader.group_count});
}

/// Install the configured `[leader] activate = <chord>` over the hardcoded
/// Super+Space default. No-op when unset. Call AFTER loadMediaDefaults so it
/// overrides, not the other way round.
pub fn applyActivate(server: *Server) void {
    const chord = server.wm_config.leader.activateChord();
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
