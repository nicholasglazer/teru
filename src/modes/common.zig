//! Shared state + helpers for teru's top-level modes.
//!
//! Constants, CLI-parse globals, stdout helpers (`out`, `outFmt`),
//! daemon auto-start, template resolution, hook-event processing,
//! and the RestoreInfo struct used by --attach / restore flows.
//! Anything that was previously a free helper in main.zig but is
//! referenced from more than one mode module lives here.
//!
//! Mode modules (daemon.zig, tui.zig, windowed.zig, raw.zig) import
//! this as `common` and reach the shared state through `common.xxx`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");
const Multiplexer = @import("../core/Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Session = @import("../persist/Session.zig");
const SessionDef = @import("../config/SessionDef.zig");
const Config = @import("../config/Config.zig");
const Hooks = @import("../config/Hooks.zig");
const HookHandler = @import("../agent/HookHandler.zig");
const HookListener = @import("../agent/HookListener.zig");
const daemon_proto = @import("../server/protocol.zig");
const build_options = @import("build_options");

pub const version = build_options.version;

// ── Tunables ──────────────────────────────────────────────────

pub const DEFAULT_ROWS: u16 = 24;
pub const DEFAULT_COLS: u16 = 80;

pub const MASTER_RATIO_MIN: f32 = 0.15;
pub const MASTER_RATIO_MAX: f32 = 0.85;

pub const DOUBLE_CLICK_NS: i128 = 300_000_000; // 300 ms
pub const CURSOR_BLINK_NS: i128 = 530_000_000; // 530 ms on/off
pub const PERSIST_DEBOUNCE_NS: i128 = 100_000_000; // 100 ms

pub const DAEMON_RETRY_ATTEMPTS: u32 = 20;
pub const DAEMON_RETRY_DELAY_MS: u32 = 100;

pub const session_path = "/tmp/teru-session.bin";

pub const setenv = if (builtin.os.tag == .windows) struct {
    fn f(_: [*:0]const u8, _: [*:0]const u8, _: c_int) c_int {
        return 0;
    }
}.f else struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
}.setenv;

// ── CLI-parse shared state ────────────────────────────────────
//
// main.zig's arg loop writes these from argv; runWindowedModeImpl
// reads them when setting up the config / spawn_config. Pass-by-
// parameter would require threading through 4 modes — the pub-var
// approach mirrors the original single-file design at the cost of
// one module-level mutable.

pub var cli_no_bar: bool = false;
pub var cli_exec_argv_buf: [64]?[*:0]const u8 = .{null} ** 64;
pub var cli_exec_argv: ?[*:null]const ?[*:0]const u8 = null;

// ── stdout helpers ────────────────────────────────────────────

pub fn out(msg: []const u8) void {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetStdHandle(n: u32) callconv(.c) *anyopaque;
        };
        _ = std.c.write(k.GetStdHandle(@bitCast(@as(i32, -11))), msg.ptr, msg.len);
    } else {
        _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
    }
}

pub fn outFmt(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(buf, fmt, args) catch return;
    out(msg);
}

// ── Session restore info ──────────────────────────────────────

pub const RestoreInfo = struct {
    pane_count: u16,
    workspace_panes: [10]u16 = .{0} ** 10,
    workspace_layouts: [10]u8 = .{0} ** 10,
    workspace_ratios: [10]f32 = .{0.55} ** 10,
    active_workspace: u8 = 0,
};

// ── Daemon auto-start ─────────────────────────────────────────

/// Fork a teru daemon named `name` in the background, optionally
/// with a template. Returns true iff the fork succeeded.
pub fn autoStartNamedDaemon(name: []const u8, template: ?[]const u8) bool {
    const exe_path = "/proc/self/exe";
    var name_buf: [128:0]u8 = undefined;
    if (name.len >= name_buf.len) return false;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;

    // Build argv: teru --daemon NAME [--template TMPL]
    var tmpl_buf: [256:0]u8 = undefined;
    const has_tmpl = if (template) |t| blk: {
        if (t.len >= tmpl_buf.len) break :blk false;
        @memcpy(tmpl_buf[0..t.len], t);
        tmpl_buf[t.len] = 0;
        break :blk true;
    } else false;

    var argv: [6:null]?[*:0]const u8 = .{ null, null, null, null, null, null };
    argv[0] = @ptrCast(exe_path);
    argv[1] = @ptrCast("--daemon");
    argv[2] = @ptrCast(name_buf[0..name.len :0]);
    if (has_tmpl) {
        argv[3] = @ptrCast("--template");
        argv[4] = @ptrCast(tmpl_buf[0..template.?.len :0]);
    }

    const fork_pid = compat.posixFork();
    if (fork_pid < 0) return false;
    if (fork_pid == 0) {
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = std.c.execve(exe_path, @ptrCast(&argv), envp);
        compat.posixExit(1);
    }
    return true;
}

/// Default-daemon variant of autoStartNamedDaemon (no template).
pub fn autoStartDaemon() bool {
    return autoStartNamedDaemon("default", null);
}

// ── Template resolution ───────────────────────────────────────

/// Resolve a template NAME to a file path. Search order:
///   1. exact path (contains "/" or ends with ".tsess")
///   2. ~/.config/teru/templates/NAME.tsess
///   3. ./examples/NAME.tsess
/// Returns null if not found.
pub fn resolveTemplatePath(name: []const u8, buf: *[512]u8) ?[]const u8 {
    if (std.mem.indexOf(u8, name, "/") != null or std.mem.endsWith(u8, name, ".tsess")) {
        if (name.len < buf.len) {
            @memcpy(buf[0..name.len], name);
            return buf[0..name.len];
        }
        return null;
    }

    const home = compat.getenv("HOME") orelse "/tmp";
    if (std.fmt.bufPrint(buf, "{s}/.config/teru/templates/{s}.tsess", .{ home, name })) |path| {
        var path_z: [513]u8 = undefined;
        if (path.len < path_z.len) {
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            const f = std.c.fopen(@ptrCast(path_z[0..path.len :0]), "r");
            if (f != null) {
                _ = std.c.fclose(f.?);
                return path;
            }
        }
    } else |_| {}

    if (std.fmt.bufPrint(buf, "examples/{s}.tsess", .{name})) |path| {
        var path_z: [513]u8 = undefined;
        if (path.len < path_z.len) {
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            const f = std.c.fopen(@ptrCast(path_z[0..path.len :0]), "r");
            if (f != null) {
                _ = std.c.fclose(f.?);
                return path;
            }
        }
    } else |_| {}

    return null;
}

/// Apply a .tsess template: parse it, create workspaces and panes
/// as defined.
pub fn applyTemplate(allocator: std.mem.Allocator, mux: *Multiplexer, graph: *ProcessGraph, template: []const u8, io: std.Io) void {
    var path_buf: [512]u8 = undefined;
    const path = resolveTemplatePath(template, &path_buf) orelse {
        var msg: [128]u8 = undefined;
        outFmt(&msg, "[teru] Template '{s}' not found\n", .{template});
        return;
    };

    // Was: std.c.fopen + std.c.fread + std.c.fclose. Zig 0.16
    // prefers Io.Dir / Io.File — same reader, with proper slice
    // returns and error propagation instead of a stateful FILE*.
    const Dir = std.Io.Dir;
    const file = Dir.cwd().openFile(io, path, .{}) catch {
        var msg: [128]u8 = undefined;
        outFmt(&msg, "[teru] Cannot read template: {s}\n", .{path});
        return;
    };
    defer file.close(io);

    var file_buf: [SessionDef.max_file_size]u8 = undefined;
    const file_len = file.readPositionalAll(io, &file_buf, 0) catch |err| {
        var msg: [128]u8 = undefined;
        outFmt(&msg, "[teru] Template read failed: {s} ({s})\n", .{ path, @errorName(err) });
        return;
    };
    if (file_len == 0) return;

    var def = SessionDef.parse(allocator, file_buf[0..file_len]) catch {
        var msg: [128]u8 = undefined;
        outFmt(&msg, "[teru] Failed to parse template: {s}\n", .{path});
        return;
    };
    defer def.deinit();

    SessionDef.restore(&def, mux, graph, DEFAULT_ROWS, DEFAULT_COLS);

    var msg: [128]u8 = undefined;
    outFmt(&msg, "[teru] Applied template '{s}' ({d} workspaces)\n", .{ template, def.workspace_count });
}

// ── Session persistence ───────────────────────────────────────

pub fn persistSave(mux: *Multiplexer, graph: *const ProcessGraph, allocator: std.mem.Allocator, io: std.Io) void {
    const sess_dir = Session.getSessionDir(allocator) catch return;
    defer allocator.free(sess_dir);
    compat.ensureDirC(sess_dir);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.bin", .{ sess_dir, mux.persist_session_name }) catch return;
    mux.saveSession(graph, path, io) catch |err| {
        var ebuf: [128]u8 = undefined;
        outFmt(&ebuf, "[teru] session save failed: {s}\n", .{@errorName(err)});
    };
}

// ── Hook wiring ───────────────────────────────────────────────

/// Transfer hook commands from Config into the Hooks struct.
pub fn loadHooks(config: *const Config, hooks: *Hooks) void {
    if (config.hook_on_spawn) |cmd| hooks.setHook(.spawn, cmd);
    if (config.hook_on_close) |cmd| hooks.setHook(.close, cmd);
    if (config.hook_on_agent_start) |cmd| hooks.setHook(.agent_start, cmd);
    if (config.hook_on_session_save) |cmd| hooks.setHook(.session_save, cmd);
}

// ── Agent lifecycle helpers ───────────────────────────────────

/// Assign an agent node to a workspace matching its group name.
/// Uses a simple hash of the group name to pick workspace 1-8.
pub fn autoAssignAgentWorkspace(mux: *Multiplexer, node_id: u64, group: []const u8) void {
    var hash: u32 = 0;
    for (group) |c| hash = hash *% 31 +% c;
    const ws: u8 = @truncate((hash % 8) + 1);

    const ws_engine = &mux.layout_engine.workspaces[ws];
    ws_engine.addNode(mux.allocator, node_id) catch return;

    if (mux.graph) |g| g.moveToWorkspace(node_id, ws);
}

/// Mark an agent finished by looking it up by name.
pub fn markAgentFinished(graph: *ProcessGraph, name: []const u8, exit_status: ?[]const u8) void {
    const node_id = graph.findAgentByName(name) orelse return;
    const exit_code: u8 = if (exit_status) |status| blk: {
        if (std.mem.eql(u8, status, "success") or std.mem.eql(u8, status, "0")) break :blk 0;
        break :blk 1;
    } else 1;
    graph.markFinished(node_id, exit_code);
}

/// Update an agent's task description + progress by name.
pub fn updateAgentStatusByName(graph: *ProcessGraph, name: []const u8, task: ?[]const u8, progress: ?f32) void {
    const node_id = graph.findAgentByName(name) orelse return;
    graph.updateAgentStatus(node_id, task, progress);
}

/// Update the most recently spawned running agent's task description.
pub fn updateLatestAgentTask(graph: *ProcessGraph, task: []const u8) void {
    var latest_id: ?ProcessGraph.NodeId = null;
    var latest_time: i128 = 0;
    var it = graph.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.kind == .agent and node.state == .running and node.started_at > latest_time) {
            latest_time = node.started_at;
            latest_id = node.id;
        }
    }
    if (latest_id) |id| graph.updateAgentStatus(id, task, null);
}

// ── Daemon wire helpers ───────────────────────────────────────
//
// Both runTuiDaemonMode and runWindowedDaemonMode talk to a daemon
// over a Unix socket using the daemon_proto format. These live here
// because both modes need them.

/// Poll daemon IPC socket for tagged PTY output and feed to each
/// pane's VtParser. Returns true if anything was processed.
pub fn pollDaemonOutput(fd: posix.fd_t, mux: *Multiplexer, buf: []u8) bool {
    var any = false;
    var hdr: daemon_proto.Header = undefined;
    var recv_buf: [daemon_proto.max_payload]u8 = undefined;
    _ = buf;

    while (daemon_proto.recvMessage(fd, &hdr, &recv_buf)) |payload| {
        switch (hdr.tag) {
            .output => {
                if (daemon_proto.decodePanePayload(payload)) |pp| {
                    if (mux.getPaneById(pp.pane_id)) |pane| {
                        if (pp.data.len > 0) {
                            pane.vt.feed(pp.data);
                            pane.grid.dirty = true;
                            any = true;
                        }
                    }
                }
            },
            .state_sync => {
                parseDaemonStateSync(fd, mux, payload);
                any = true;
            },
            .pane_event => {
                if (payload.len >= 9) {
                    const pane_id = std.mem.readInt(u64, payload[0..8], .little);
                    const event = payload[8];
                    if (event == 1) mux.closePane(pane_id);
                    // event == 0 (created) handled via state_sync
                }
                any = true;
            },
            else => {},
        }
    }
    return any;
}

/// Parse state_sync from daemon and create/update remote panes.
/// Restores exact workspace position, active pane, layout, ratio.
/// Format: [active_ws:1][ws_count:1]
///   per-ws × N: [layout:1][pane_count:1][ratio_x100:1][reserved:1][active_pane_id:8]
///   per-pane (ordered by workspace position): [pane_id:8][rows:2][cols:2][ws_idx:1]
pub fn parseDaemonStateSync(daemon_fd: posix.fd_t, mux: *Multiplexer, payload: []const u8) void {
    if (payload.len < 2) return;
    const active_ws = payload[0];
    const ws_count = @min(payload[1], 10);
    var pos: usize = 2;

    const LE = @import("../tiling/LayoutEngine.zig");

    for (0..ws_count) |wi| {
        if (pos + 12 > payload.len) break;
        const layout_byte = payload[pos];
        pos += 1;
        _ = payload[pos]; // pane_count
        pos += 1;
        const ratio_x100 = payload[pos];
        pos += 1;
        pos += 1; // reserved
        const active_pane_id = std.mem.readInt(u64, payload[pos..][0..8], .little);
        pos += 8;

        if (wi < 10) {
            var ws = &mux.layout_engine.workspaces[wi];
            ws.layout = @enumFromInt(@min(layout_byte, @intFromEnum(LE.Layout.accordion)));
            ws.active_node = if (active_pane_id != 0) active_pane_id else null;
            ws.master_ratio = @as(f32, @floatFromInt(ratio_x100)) / 100.0;
        }
    }

    const Pane = @import("../core/Pane.zig");
    while (pos + 13 <= payload.len) {
        const pane_id = std.mem.readInt(u64, payload[pos..][0..8], .little);
        pos += 8;
        const rows = std.mem.readInt(u16, payload[pos..][0..2], .little);
        pos += 2;
        const cols = std.mem.readInt(u16, payload[pos..][0..2], .little);
        pos += 2;
        const ws_idx = payload[pos];
        pos += 1;

        if (mux.getPaneById(pane_id) != null) continue;

        const pane = Pane.initRemote(mux.allocator, rows, cols, pane_id, daemon_fd, mux.spawn_config) catch continue;
        if (pane_id >= mux.next_pane_id) mux.next_pane_id = pane_id + 1;

        mux.panes.append(mux.allocator, pane) catch continue;
        const idx = mux.panes.items.len - 1;
        mux.panes.items[idx].linkVt(mux.allocator);

        if (ws_idx < 10) {
            mux.layout_engine.workspaces[ws_idx].addNode(mux.allocator, pane_id) catch |err| {
                var ebuf: [128]u8 = undefined;
                outFmt(&ebuf, "[teru] layout addNode failed: {s}\n", .{@errorName(err)});
            };
        }
    }

    mux.switchWorkspace(active_ws);
    for (mux.panes.items) |*p| p.grid.dirty = true;
}

/// Send a command to the daemon (for windowed-daemon mode).
pub fn sendDaemonCommand(fd: posix.fd_t, cmd: daemon_proto.Command, arg: ?u8) void {
    var buf: [2]u8 = undefined;
    buf[0] = @intFromEnum(cmd);
    const len: usize = if (arg) |a| blk: {
        buf[1] = a;
        break :blk 2;
    } else 1;
    _ = daemon_proto.sendMessage(fd, .command, buf[0..len]);
}

/// Send keyboard input to the daemon's active pane.
pub fn sendDaemonInput(fd: posix.fd_t, data: []const u8) void {
    _ = daemon_proto.sendMessage(fd, .active_input, data);
}

/// Process a Claude Code hook event: update ProcessGraph and fire
/// hooks. Frees event + queued strings via the `defer` block.
pub fn processHookEvent(
    graph: *ProcessGraph,
    hooks: *Hooks,
    ev: HookListener.QueuedEvent,
    allocator: std.mem.Allocator,
) void {
    defer {
        var event = ev.event;
        HookHandler.freeHookEvent(&event, allocator);
        if (ev.session_id) |s| allocator.free(s);
        if (ev.tool_name) |s| allocator.free(s);
        if (ev.tool_input) |s| allocator.free(s);
    }

    switch (ev.event) {
        .subagent_start => |e| {
            _ = graph.spawn(.{
                .name = e.agent_type,
                .kind = .agent,
                .pid = null,
                .agent = .{
                    .group = "claude-code",
                    .role = e.agent_type,
                },
            }) catch return;
            hooks.fire(.agent_start);
        },
        .subagent_stop => |e| markAgentFinished(graph, e.agent_id, null),
        .teammate_idle => |e| {
            if (graph.findAgentByName(e.agent_id)) |node_id| {
                if (graph.nodes.getPtr(node_id)) |node| node.state = .paused;
            }
        },
        .task_created => |e| updateLatestAgentTask(graph, e.description),
        .task_completed => {},
        .pre_tool_use => |e| updateLatestAgentTask(graph, e.tool_name),
        .post_tool_use => {},
        .post_tool_use_failure => {},
        .session_start => {},
        .session_end => {},
        .stop => {},
        .stop_failure => {},
        .notification => {},
        .pre_compact, .post_compact => {},
        .unknown => {},
    }
}
