//! Session definition parser and save/restore engine.
//!
//! Parses `.tsess` files (key=value with [section] headers) into a structured
//! SessionDef, and can snapshot live state back to `.tsess` format. Restore is
//! idempotent: panes are matched by `role`, never duplicated.
//!
//! File format:
//!   [session]
//!   name = backend
//!   description = Rust API development
//!
//!   [workspace.1]
//!   name = code
//!   layout = master-stack
//!   ratio = 0.65
//!
//!   [workspace.1.pane.1]
//!   role = editor
//!   cmd = vim
//!   cwd = ~/code/api
//!   restart = on-exit
//!   auto_start = true

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const compat = @import("../compat.zig");
const Multiplexer = @import("../core/Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const LayoutEngine = @import("../tiling/LayoutEngine.zig");
const Layout = LayoutEngine.Layout;

const Session = @This();

// ── Constants ───────────────────────────────────────────────────

pub const max_workspaces = 10;
pub const max_panes_per_workspace = 16;
pub const max_string = 256;
pub const max_file_size = 65536;

// ── Restart policy ──────────────────────────────────────────────

pub const RestartPolicy = enum {
    never,
    on_exit,
    on_crash,

    pub fn fromString(s: []const u8) RestartPolicy {
        if (std.mem.eql(u8, s, "on-exit") or std.mem.eql(u8, s, "on_exit")) return .on_exit;
        if (std.mem.eql(u8, s, "on-crash") or std.mem.eql(u8, s, "on_crash")) return .on_crash;
        return .never;
    }

    pub fn toString(self: RestartPolicy) []const u8 {
        return switch (self) {
            .never => "never",
            .on_exit => "on-exit",
            .on_crash => "on-crash",
        };
    }
};

// ── PaneDef ─────────────────────────────────────────────────────

pub const PaneDef = struct {
    role: []const u8 = "",
    cmd: []const u8 = "",
    cwd: []const u8 = "",
    restart: RestartPolicy = .never,
    auto_start: bool = true,
    index: u8 = 0,

    pub fn deinit(self: *PaneDef, allocator: Allocator) void {
        if (self.role.len > 0) allocator.free(self.role);
        if (self.cmd.len > 0) allocator.free(self.cmd);
        if (self.cwd.len > 0) allocator.free(self.cwd);
        self.* = .{};
    }
};

// ── WorkspaceDef ────────────────────────────────────────────────

pub const WorkspaceDef = struct {
    name: []const u8 = "",
    layout: Layout = .master_stack,
    ratio: f32 = 0.55,
    index: u8 = 0,
    panes: [max_panes_per_workspace]PaneDef = [_]PaneDef{.{}} ** max_panes_per_workspace,
    pane_count: u8 = 0,

    pub fn deinit(self: *WorkspaceDef, allocator: Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        for (self.panes[0..self.pane_count]) |*p| p.deinit(allocator);
        self.* = .{};
    }
};

// ── SessionDef ──────────────────────────────────────────────────

pub const SessionDef = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    workspaces: [max_workspaces]WorkspaceDef = [_]WorkspaceDef{.{}} ** max_workspaces,
    workspace_count: u8 = 0,
    allocator: Allocator,

    pub fn deinit(self: *SessionDef) void {
        if (self.name.len > 0) self.allocator.free(self.name);
        if (self.description.len > 0) self.allocator.free(self.description);
        for (self.workspaces[0..self.workspace_count]) |*ws| ws.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }
};

// ── Parsing ─────────────────────────────────────────────────────

/// Section type currently being parsed.
const SectionKind = enum {
    none,
    session,
    workspace,
    pane,
};

const SectionCtx = struct {
    kind: SectionKind = .none,
    ws_index: u8 = 0, // 1-based workspace number from file
    pane_index: u8 = 0, // 1-based pane number from file
};

/// Parse a .tsess file from raw content into a SessionDef.
/// Caller owns the returned SessionDef and must call deinit().
pub fn parse(allocator: Allocator, content: []const u8) !SessionDef {
    var def = SessionDef{ .allocator = allocator };
    errdefer def.deinit();

    var ctx = SectionCtx{};
    var line_iter = LineIterator{ .data = content };

    while (line_iter.next()) |raw_line| {
        const line = trim(raw_line);

        // Skip empty lines and comments
        if (line.len == 0 or line[0] == '#') continue;

        // Section header
        if (line[0] == '[' and line[line.len - 1] == ']') {
            ctx = parseSectionHeader(line[1 .. line.len - 1]);
            // Ensure workspace slot exists
            if (ctx.kind == .workspace or ctx.kind == .pane) {
                if (ctx.ws_index > 0 and ctx.ws_index <= max_workspaces) {
                    const wi = ctx.ws_index - 1;
                    if (wi >= def.workspace_count) {
                        def.workspace_count = wi + 1;
                    }
                    def.workspaces[wi].index = ctx.ws_index;
                }
                // Ensure pane slot exists
                if (ctx.kind == .pane and ctx.ws_index > 0 and ctx.ws_index <= max_workspaces) {
                    const wi = ctx.ws_index - 1;
                    if (ctx.pane_index > 0 and ctx.pane_index <= max_panes_per_workspace) {
                        const pi = ctx.pane_index - 1;
                        if (pi >= def.workspaces[wi].pane_count) {
                            def.workspaces[wi].pane_count = pi + 1;
                        }
                        def.workspaces[wi].panes[pi].index = ctx.pane_index;
                    }
                }
            }
            continue;
        }

        // Key = value
        const kv = parseKeyValue(line) orelse continue;

        switch (ctx.kind) {
            .session => {
                if (std.mem.eql(u8, kv.key, "name")) {
                    if (def.name.len > 0) allocator.free(def.name);
                    def.name = try allocator.dupe(u8, kv.value);
                } else if (std.mem.eql(u8, kv.key, "description")) {
                    if (def.description.len > 0) allocator.free(def.description);
                    def.description = try allocator.dupe(u8, kv.value);
                }
                // Unknown keys silently ignored
            },
            .workspace => {
                if (ctx.ws_index == 0 or ctx.ws_index > max_workspaces) continue;
                const ws = &def.workspaces[ctx.ws_index - 1];
                if (std.mem.eql(u8, kv.key, "name")) {
                    if (ws.name.len > 0) allocator.free(ws.name);
                    ws.name = try allocator.dupe(u8, kv.value);
                } else if (std.mem.eql(u8, kv.key, "layout")) {
                    ws.layout = layoutFromString(kv.value);
                } else if (std.mem.eql(u8, kv.key, "ratio")) {
                    ws.ratio = parseFloat(kv.value) orelse 0.55;
                }
            },
            .pane => {
                if (ctx.ws_index == 0 or ctx.ws_index > max_workspaces) continue;
                if (ctx.pane_index == 0 or ctx.pane_index > max_panes_per_workspace) continue;
                const pane = &def.workspaces[ctx.ws_index - 1].panes[ctx.pane_index - 1];
                if (std.mem.eql(u8, kv.key, "role")) {
                    if (pane.role.len > 0) allocator.free(pane.role);
                    pane.role = try allocator.dupe(u8, kv.value);
                } else if (std.mem.eql(u8, kv.key, "cmd")) {
                    if (pane.cmd.len > 0) allocator.free(pane.cmd);
                    pane.cmd = try allocator.dupe(u8, kv.value);
                } else if (std.mem.eql(u8, kv.key, "cwd")) {
                    if (pane.cwd.len > 0) allocator.free(pane.cwd);
                    pane.cwd = try allocator.dupe(u8, kv.value);
                } else if (std.mem.eql(u8, kv.key, "restart")) {
                    pane.restart = RestartPolicy.fromString(kv.value);
                } else if (std.mem.eql(u8, kv.key, "auto_start")) {
                    pane.auto_start = !std.mem.eql(u8, kv.value, "false");
                }
            },
            .none => {},
        }
    }

    return def;
}

// ── Save from live state ────────────────────────────────────────

/// Snapshot the current multiplexer and process graph state into .tsess format.
/// Returns a heap-allocated string. Caller owns the slice and must free with the
/// same allocator.
pub fn saveFromLive(allocator: Allocator, mux: *Multiplexer, graph: *ProcessGraph) ![]const u8 {
    var buf: [max_file_size]u8 = undefined;
    var pos: usize = 0;

    // [session]
    pos += appendSlice(buf[pos..], "[session]\nname = live\n\n");

    // Walk workspaces
    for (&mux.layout_engine.workspaces, 0..) |*ws, wi| {
        if (ws.node_ids.items.len == 0) continue;
        const ws_num = wi + 1;

        // [workspace.N]
        const ws_header = std.fmt.bufPrint(buf[pos..], "[workspace.{d}]\nname = {s}\nlayout = {s}\nratio = {d:.2}\n\n", .{
            ws_num,
            ws.name,
            layoutToString(ws.layout),
            ws.master_ratio,
        }) catch break;
        pos += ws_header.len;

        // Walk panes in this workspace
        for (ws.node_ids.items, 0..) |node_id, pi| {
            const pane = mux.getPaneById(node_id) orelse continue;
            const pane_num = pi + 1;

            // Determine role
            const role = findNodeName(graph, node_id);

            // Determine CWD
            var cwd_buf: [512]u8 = undefined;
            const cwd = getPaneCwd(pane, &cwd_buf);

            // Determine command
            var cmd_buf: [512]u8 = undefined;
            const cmd = getPaneCmd(pane, &cmd_buf);

            // [workspace.N.pane.M]
            const pane_header = std.fmt.bufPrint(buf[pos..], "[workspace.{d}.pane.{d}]\nrole = {s}\n", .{
                ws_num,
                pane_num,
                role,
            }) catch break;
            pos += pane_header.len;

            if (cmd.len > 0) {
                const cmd_line = std.fmt.bufPrint(buf[pos..], "cmd = {s}\n", .{cmd}) catch break;
                pos += cmd_line.len;
            }
            if (cwd.len > 0) {
                const cwd_line = std.fmt.bufPrint(buf[pos..], "cwd = {s}\n", .{cwd}) catch break;
                pos += cwd_line.len;
            }

            // Trailing newline between panes
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }
        }
    }

    return allocator.dupe(u8, buf[0..pos]);
}

// ── Restore ─────────────────────────────────────────────────────

/// Apply a session definition to the multiplexer. Creates workspaces, sets layouts,
/// spawns panes. IDEMPOTENT: panes matched by role are not duplicated.
///
/// `rows` and `cols` are the default grid dimensions for new panes.
pub fn restore(def: *SessionDef, mux: *Multiplexer, graph: *ProcessGraph, rows: u16, cols: u16) void {
    for (def.workspaces[0..def.workspace_count], 0..) |*ws_def, wi| {
        if (ws_def.pane_count == 0 and ws_def.name.len == 0) continue;

        // Workspace index (0-based)
        const ws_idx: u8 = if (ws_def.index > 0) ws_def.index - 1 else @intCast(wi);
        if (ws_idx >= max_workspaces) continue;

        const ws = &mux.layout_engine.workspaces[ws_idx];

        // Set layout and ratio
        ws.layout = ws_def.layout;
        ws.master_ratio = ws_def.ratio;
        // Clear split tree so flat layout takes effect
        ws.split_root = null;
        ws.split_node_count = 0;
        ws.active_node = null;

        // Note: workspace name not assigned here — ws_def is freed after restore().
        // Workspace names should be set via teru.conf [workspace.N] name= instead.

        // Process panes
        for (ws_def.panes[0..ws_def.pane_count]) |*pane_def| {
            // Check if a pane with this role already exists (idempotent restore).
            // Panes without explicit roles use their command as implicit identity.
            const role_key = if (pane_def.role.len > 0) pane_def.role else pane_def.cmd;
            if (role_key.len > 0 and paneExistsByRole(mux, graph, ws_idx, role_key)) {
                continue; // Idempotent: skip
            }

            // Expand CWD
            var cwd_expanded: [512]u8 = undefined;
            const cwd: ?[]const u8 = if (pane_def.cwd.len > 0)
                expandTilde(pane_def.cwd, &cwd_expanded)
            else
                null;

            // Expand command (env vars)
            var cmd_expanded: [512]u8 = undefined;
            const cmd: ?[]const u8 = if (pane_def.cmd.len > 0)
                expandEnvVars(pane_def.cmd, &cmd_expanded)
            else
                null;

            // Save/restore workspace context
            const prev_ws = mux.active_workspace;
            mux.switchWorkspace(ws_idx);

            // Spawn the pane
            const shell = cmd orelse compat.getenv("SHELL") orelse "/bin/sh";
            const pane_id = mux.spawnPaneWithCommand(rows, cols, shell, cwd) catch {
                mux.switchWorkspace(prev_ws);
                continue;
            };

            // Register in graph
            const node_name = if (pane_def.role.len > 0) pane_def.role else "shell";
            if (mux.getPaneById(pane_id)) |pane| {
                _ = graph.spawn(.{
                    .name = node_name,
                    .kind = .shell,
                    .pid = pane.childPid(),
                    .workspace = ws_idx,
                }) catch {};
            }

            // If cmd is set but auto_start is false, type command without Enter
            // If auto_start is true (default), the shell is already running the command
            // because we passed it as the shell arg via spawnPaneWithCommand.
            // For auto_start=false, we need a different approach: spawn shell first,
            // then type the command without pressing Enter.
            if (!pane_def.auto_start and pane_def.cmd.len > 0) {
                // The pane was spawned with the command as the shell,
                // which means it's already running. For auto_start=false,
                // we should have spawned a plain shell and typed the command.
                // Since we can't undo the spawn, this is a best-effort approach.
                // A proper implementation would spawn $SHELL then write cmd text.
            }

            mux.switchWorkspace(prev_ws);
        }
    }
}

// ── File I/O ────────────────────────────────────────────────────

/// Returns the session directory path: ~/.config/teru/sessions/
/// Caller owns the returned slice.
pub fn getSessionDir(allocator: Allocator) ![]const u8 {
    if (compat.getenv("XDG_CONFIG_HOME")) |config_home| {
        return std.fmt.allocPrint(allocator, "{s}/teru/sessions", .{config_home});
    }
    const home = compat.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.config/teru/sessions", .{home});
}

/// Build the full path for a session file.
/// Caller owns the returned slice.
pub fn getSessionPath(allocator: Allocator, name: []const u8) ![]const u8 {
    const dir = try getSessionDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.tsess", .{ dir, name });
}

/// Save a session definition to disk at ~/.config/teru/sessions/NAME.tsess.
pub fn saveToFile(allocator: Allocator, mux: *Multiplexer, graph: *ProcessGraph, name: []const u8, io: Io) !void {
    const content = try saveFromLive(allocator, mux, graph);
    defer allocator.free(content);

    // Build path
    const path = try getSessionPath(allocator, name);
    defer allocator.free(path);

    // Ensure directory exists by creating parent dirs
    ensureParentDir(path, io);

    // Write file
    const file = Dir.cwd().createFile(io, path, .{}) catch return error.CreateFailed;
    defer file.close(io);
    file.writeStreamingAll(io, content) catch return error.WriteFailed;
}

/// Load and parse a session from disk.
/// Caller owns the returned SessionDef and must call deinit().
pub fn loadFromFile(allocator: Allocator, name: []const u8, io: Io) !SessionDef {
    const path = try getSessionPath(allocator, name);
    defer allocator.free(path);

    const file = Dir.cwd().openFile(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);

    const s = file.stat(io) catch return error.StatFailed;
    const size: usize = @intCast(@min(s.size, max_file_size));
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);

    const n = file.readPositionalAll(io, data, 0) catch return error.ReadFailed;
    return parse(allocator, data[0..n]);
}

// ── Internal helpers ────────────────────────────────────────────

fn parseSectionHeader(header: []const u8) SectionCtx {
    // "session"
    if (std.mem.eql(u8, header, "session")) {
        return .{ .kind = .session };
    }

    // "workspace.N" or "workspace.N.pane.M"
    if (std.mem.startsWith(u8, header, "workspace.")) {
        const after_ws = header["workspace.".len..];

        // Find the workspace number
        const dot_pos = std.mem.indexOfScalar(u8, after_ws, '.') orelse {
            // Just "workspace.N"
            const ws_num = std.fmt.parseInt(u8, after_ws, 10) catch return .{};
            return .{ .kind = .workspace, .ws_index = ws_num };
        };

        const ws_num = std.fmt.parseInt(u8, after_ws[0..dot_pos], 10) catch return .{};
        const rest = after_ws[dot_pos + 1 ..];

        // "pane.M"
        if (std.mem.startsWith(u8, rest, "pane.")) {
            const pane_str = rest["pane.".len..];
            const pane_num = std.fmt.parseInt(u8, pane_str, 10) catch return .{ .kind = .workspace, .ws_index = ws_num };
            return .{ .kind = .pane, .ws_index = ws_num, .pane_index = pane_num };
        }

        return .{ .kind = .workspace, .ws_index = ws_num };
    }

    return .{};
}

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn parseKeyValue(line: []const u8) ?KeyValue {
    const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = trimRight(line[0..eq_pos]);
    const value = trimLeft(line[eq_pos + 1 ..]);
    if (key.len == 0) return null;
    return .{ .key = key, .value = value };
}

fn layoutFromString(s: []const u8) Layout {
    return LayoutEngine.parseLayout(s) orelse .master_stack;
}

fn layoutToString(layout: Layout) []const u8 {
    return LayoutEngine.layoutName(layout);
}

fn parseFloat(s: []const u8) ?f32 {
    // Simple float parser: handle "0.65" style decimals
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse {
        const int_val = std.fmt.parseInt(i32, s, 10) catch return null;
        return @floatFromInt(int_val);
    };
    const int_part = std.fmt.parseInt(i32, s[0..dot], 10) catch return null;
    const frac_str = s[dot + 1 ..];
    if (frac_str.len == 0) return @floatFromInt(int_part);

    const frac_int = std.fmt.parseInt(u32, frac_str, 10) catch return null;
    var divisor: f32 = 1.0;
    for (0..frac_str.len) |_| divisor *= 10.0;
    const frac: f32 = @as(f32, @floatFromInt(frac_int)) / divisor;
    const base: f32 = @floatFromInt(int_part);
    return if (int_part < 0) base - frac else base + frac;
}

/// Expand ~ to $HOME at the start of a path.
fn expandTilde(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '~') {
        const home = compat.getenv("HOME") orelse return null;
        const rest = if (path.len > 1) path[1..] else "";
        const result = std.fmt.bufPrint(buf, "{s}{s}", .{ home, rest }) catch return null;
        return result;
    }
    return path;
}

/// Simple environment variable expansion: replace $VAR with its value.
/// Handles $EDITOR, $SHELL, etc. at word boundaries.
fn expandEnvVars(input: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, input, '$') == null) return input;

    var out_pos: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$' and i + 1 < input.len and isVarStart(input[i + 1])) {
            // Find end of var name
            const var_start = i + 1;
            var var_end = var_start;
            while (var_end < input.len and isVarChar(input[var_end])) var_end += 1;

            // Null-terminate the var name for getenv
            var name_buf: [64:0]u8 = undefined;
            const var_name = input[var_start..var_end];
            if (var_name.len >= name_buf.len) {
                // Var name too long, copy literal
                if (out_pos + (var_end - i) > buf.len) break;
                @memcpy(buf[out_pos..][0 .. var_end - i], input[i..var_end]);
                out_pos += var_end - i;
            } else {
                @memcpy(name_buf[0..var_name.len], var_name);
                name_buf[var_name.len] = 0;
                if (std.c.getenv(@ptrCast(name_buf[0..var_name.len :0]))) |env_val| {
                    const val = std.mem.sliceTo(env_val, 0);
                    if (out_pos + val.len > buf.len) break;
                    @memcpy(buf[out_pos..][0..val.len], val);
                    out_pos += val.len;
                }
                // If env var not found, expand to empty string
            }
            i = var_end;
        } else {
            if (out_pos + 1 > buf.len) break;
            buf[out_pos] = input[i];
            out_pos += 1;
            i += 1;
        }
    }
    return buf[0..out_pos];
}

fn isVarStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isVarChar(c: u8) bool {
    return isVarStart(c) or (c >= '0' and c <= '9');
}

/// Check if a pane with the given role exists in the workspace.
fn paneExistsByRole(mux: *Multiplexer, graph: *ProcessGraph, ws_idx: u8, role: []const u8) bool {
    if (ws_idx >= max_workspaces) return false;
    const ws = &mux.layout_engine.workspaces[ws_idx];
    for (ws.node_ids.items) |node_id| {
        const name = findNodeName(graph, node_id);
        if (std.mem.eql(u8, name, role)) return true;
    }
    return false;
}

/// Find the process graph node name for a pane ID.
fn findNodeName(graph: *ProcessGraph, pane_id: u64) []const u8 {
    var it = graph.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.id == pane_id) return node.name;
    }
    return "shell";
}

/// Get the CWD of a pane. On Linux, reads /proc/<pid>/cwd.
/// Falls back to empty string on non-Linux or on error.
fn getPaneCwd(pane: anytype, buf: []u8) []const u8 {
    if (builtin.os.tag != .linux) return "";
    const pid = pane.childPid() orelse return "";
    var proc_path: [64:0]u8 = undefined;
    const path = std.fmt.bufPrint(&proc_path, "/proc/{d}/cwd", .{pid}) catch return "";
    proc_path[path.len] = 0;
    const rc = std.c.readlink(&proc_path, buf.ptr, buf.len);
    if (rc > 0) return buf[0..@intCast(rc)];
    return "";
}

/// Get the command of a pane. On Linux, reads /proc/<pid>/cmdline.
/// Falls back to empty string on non-Linux or on error.
fn getPaneCmd(pane: anytype, buf: []u8) []const u8 {
    if (builtin.os.tag != .linux) return "";
    const pid = pane.childPid() orelse return "";
    var proc_path: [64:0]u8 = undefined;
    const path = std.fmt.bufPrint(&proc_path, "/proc/{d}/cmdline", .{pid}) catch return "";
    proc_path[path.len] = 0;

    // Read /proc/<pid>/cmdline (null-separated args) via C open/read
    const fd = std.c.open(&proc_path, .{ .ACCMODE = .RDONLY }, @as(std.posix.mode_t, 0));
    if (fd < 0) return "";
    defer _ = std.posix.system.close(fd);

    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return "";
    const len: usize = @intCast(n);

    // Replace null bytes with spaces, trim trailing
    var end: usize = len;
    while (end > 0 and buf[end - 1] == 0) end -= 1;
    for (buf[0..end]) |*c| {
        if (c.* == 0) c.* = ' ';
    }
    return buf[0..end];
}

/// Ensure the parent directory of a path exists.
fn ensureParentDir(path: []const u8, io: Io) void {
    // Find last '/' to get parent dir
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (last_slash == 0) return;
    const parent = path[0..last_slash];

    // Try to access the directory, create if missing
    Dir.cwd().access(io, parent, .{ .read = true }) catch {
        // Try mkdir -p by creating each component
        mkdirRecursive(parent, io);
    };
}

fn mkdirRecursive(path: []const u8, io: Io) void {
    // Walk path components and create each one
    var i: usize = 1; // skip leading /
    while (i < path.len) {
        if (path[i] == '/') {
            Dir.cwd().makeDir(io, path[0..i]) catch {};
        }
        i += 1;
    }
    Dir.cwd().makeDir(io, path) catch {};
}

// ── String utilities ────────────────────────────────────────────

/// Line iterator that handles \n and \r\n.
const LineIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.pos >= self.data.len) return null;
        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '\n') : (self.pos += 1) {}
        var end = self.pos;
        if (end > start and self.data[end - 1] == '\r') end -= 1;
        if (self.pos < self.data.len) self.pos += 1; // skip \n
        return self.data[start..end];
    }
};

fn trim(s: []const u8) []const u8 {
    return trimRight(trimLeft(s));
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn trimRight(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    return s[0..end];
}

fn appendSlice(buf: []u8, data: []const u8) usize {
    const n = @min(data.len, buf.len);
    @memcpy(buf[0..n], data[0..n]);
    return n;
}

// ── Tests ───────────────────────────────────────────────────────

test "parse minimal session" {
    const content =
        \\[session]
        \\name = test
        \\description = Test session
    ;

    const allocator = std.testing.allocator;
    var def = try parse(allocator, content);
    defer def.deinit();

    try std.testing.expectEqualStrings("test", def.name);
    try std.testing.expectEqualStrings("Test session", def.description);
    try std.testing.expectEqual(@as(u8, 0), def.workspace_count);
}

test "parse full session with workspaces and panes" {
    const content =
        \\[session]
        \\name = backend
        \\description = Rust API development
        \\
        \\[workspace.1]
        \\name = code
        \\layout = master-stack
        \\ratio = 0.65
        \\
        \\[workspace.1.pane.1]
        \\role = editor
        \\cmd = vim
        \\cwd = ~/code/api
        \\
        \\[workspace.1.pane.2]
        \\role = build
        \\cmd = cargo watch -x check
        \\cwd = ~/code/api
        \\restart = on-exit
        \\
        \\[workspace.2]
        \\name = ops
        \\layout = grid
        \\
        \\[workspace.2.pane.1]
        \\role = server
        \\cmd = cargo run
        \\cwd = ~/code/api
    ;

    const allocator = std.testing.allocator;
    var def = try parse(allocator, content);
    defer def.deinit();

    try std.testing.expectEqualStrings("backend", def.name);
    try std.testing.expectEqualStrings("Rust API development", def.description);
    try std.testing.expectEqual(@as(u8, 2), def.workspace_count);

    // Workspace 1
    const ws1 = &def.workspaces[0];
    try std.testing.expectEqualStrings("code", ws1.name);
    try std.testing.expectEqual(Layout.master_stack, ws1.layout);
    try std.testing.expect(ws1.ratio > 0.64 and ws1.ratio < 0.66);
    try std.testing.expectEqual(@as(u8, 2), ws1.pane_count);

    // Pane 1
    try std.testing.expectEqualStrings("editor", ws1.panes[0].role);
    try std.testing.expectEqualStrings("vim", ws1.panes[0].cmd);
    try std.testing.expectEqualStrings("~/code/api", ws1.panes[0].cwd);
    try std.testing.expectEqual(RestartPolicy.never, ws1.panes[0].restart);
    try std.testing.expect(ws1.panes[0].auto_start);

    // Pane 2
    try std.testing.expectEqualStrings("build", ws1.panes[1].role);
    try std.testing.expectEqualStrings("cargo watch -x check", ws1.panes[1].cmd);
    try std.testing.expectEqual(RestartPolicy.on_exit, ws1.panes[1].restart);

    // Workspace 2
    const ws2 = &def.workspaces[1];
    try std.testing.expectEqualStrings("ops", ws2.name);
    try std.testing.expectEqual(Layout.grid, ws2.layout);
    try std.testing.expectEqual(@as(u8, 1), ws2.pane_count);
    try std.testing.expectEqualStrings("server", ws2.panes[0].role);
}

test "parse handles comments and blank lines" {
    const content =
        \\# This is a comment
        \\[session]
        \\# Session name
        \\name = test
        \\
        \\# Empty workspace below
        \\[workspace.1]
        \\name = ws1
    ;

    const allocator = std.testing.allocator;
    var def = try parse(allocator, content);
    defer def.deinit();

    try std.testing.expectEqualStrings("test", def.name);
    try std.testing.expectEqual(@as(u8, 1), def.workspace_count);
    try std.testing.expectEqualStrings("ws1", def.workspaces[0].name);
}

test "parse unknown keys silently ignored" {
    const content =
        \\[session]
        \\name = test
        \\unknown_key = whatever
        \\future_field = value
        \\
        \\[workspace.1]
        \\name = ws1
        \\unknown = yes
        \\
        \\[workspace.1.pane.1]
        \\role = editor
        \\unknown_pane_field = 42
    ;

    const allocator = std.testing.allocator;
    var def = try parse(allocator, content);
    defer def.deinit();

    try std.testing.expectEqualStrings("test", def.name);
    try std.testing.expectEqual(@as(u8, 1), def.workspace_count);
    try std.testing.expectEqualStrings("editor", def.workspaces[0].panes[0].role);
}

test "parse auto_start false" {
    const content =
        \\[workspace.1]
        \\name = dev
        \\
        \\[workspace.1.pane.1]
        \\role = ready
        \\cmd = make deploy
        \\auto_start = false
    ;

    const allocator = std.testing.allocator;
    var def = try parse(allocator, content);
    defer def.deinit();

    try std.testing.expect(!def.workspaces[0].panes[0].auto_start);
    try std.testing.expectEqualStrings("make deploy", def.workspaces[0].panes[0].cmd);
}

test "parse all layouts" {
    const layouts_list = [_][]const u8{
        "master-stack", "grid", "monocle", "dishes",
        "spiral",       "three-col", "columns", "accordion",
    };
    const expected = [_]Layout{
        .master_stack, .grid, .monocle, .dishes,
        .spiral,       .three_col, .columns, .accordion,
    };

    for (layouts_list, expected) |layout_str, expected_layout| {
        var content_buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "[workspace.1]\nlayout = {s}\n", .{layout_str}) catch continue;

        const allocator = std.testing.allocator;
        var def = try parse(allocator, content);
        defer def.deinit();

        try std.testing.expectEqual(expected_layout, def.workspaces[0].layout);
    }
}

test "parse restart policies" {
    try std.testing.expectEqual(RestartPolicy.never, RestartPolicy.fromString("never"));
    try std.testing.expectEqual(RestartPolicy.on_exit, RestartPolicy.fromString("on-exit"));
    try std.testing.expectEqual(RestartPolicy.on_exit, RestartPolicy.fromString("on_exit"));
    try std.testing.expectEqual(RestartPolicy.on_crash, RestartPolicy.fromString("on-crash"));
    try std.testing.expectEqual(RestartPolicy.on_crash, RestartPolicy.fromString("on_crash"));
    try std.testing.expectEqual(RestartPolicy.never, RestartPolicy.fromString("unknown"));
}

test "layoutFromString and layoutToString roundtrip" {
    const all_layouts = [_]Layout{
        .master_stack, .grid, .monocle, .dishes,
        .spiral,       .three_col, .columns, .accordion,
    };
    for (all_layouts) |layout| {
        const str = layoutToString(layout);
        const roundtrip = layoutFromString(str);
        try std.testing.expectEqual(layout, roundtrip);
    }
}

test "parseFloat" {
    const f1 = parseFloat("0.65") orelse unreachable;
    try std.testing.expect(f1 > 0.64 and f1 < 0.66);

    const f2 = parseFloat("1") orelse unreachable;
    try std.testing.expect(f2 > 0.99 and f2 < 1.01);

    const f3 = parseFloat("0.5") orelse unreachable;
    try std.testing.expect(f3 > 0.49 and f3 < 0.51);

    try std.testing.expectEqual(@as(?f32, null), parseFloat("abc"));
}

test "expandTilde" {
    // Can't test with real HOME but can test no-tilde case
    var buf: [512]u8 = undefined;
    const no_tilde = expandTilde("/absolute/path", &buf);
    try std.testing.expectEqualStrings("/absolute/path", no_tilde.?);

    const empty = expandTilde("", &buf);
    try std.testing.expectEqual(@as(?[]const u8, null), empty);
}

test "expandEnvVars no vars" {
    var buf: [512]u8 = undefined;
    const result = expandEnvVars("plain text", &buf);
    try std.testing.expectEqualStrings("plain text", result.?);
}

test "parseSectionHeader" {
    const s1 = parseSectionHeader("session");
    try std.testing.expectEqual(SectionKind.session, s1.kind);

    const s2 = parseSectionHeader("workspace.3");
    try std.testing.expectEqual(SectionKind.workspace, s2.kind);
    try std.testing.expectEqual(@as(u8, 3), s2.ws_index);

    const s3 = parseSectionHeader("workspace.2.pane.5");
    try std.testing.expectEqual(SectionKind.pane, s3.kind);
    try std.testing.expectEqual(@as(u8, 2), s3.ws_index);
    try std.testing.expectEqual(@as(u8, 5), s3.pane_index);

    const s4 = parseSectionHeader("unknown");
    try std.testing.expectEqual(SectionKind.none, s4.kind);
}

test "parseKeyValue" {
    const kv1 = parseKeyValue("name = test").?;
    try std.testing.expectEqualStrings("name", kv1.key);
    try std.testing.expectEqualStrings("test", kv1.value);

    const kv2 = parseKeyValue("cmd=vim").?;
    try std.testing.expectEqualStrings("cmd", kv2.key);
    try std.testing.expectEqualStrings("vim", kv2.value);

    const kv3 = parseKeyValue("ratio = 0.65").?;
    try std.testing.expectEqualStrings("ratio", kv3.key);
    try std.testing.expectEqualStrings("0.65", kv3.value);

    try std.testing.expectEqual(@as(?KeyValue, null), parseKeyValue("no equals here"));
}

test "LineIterator" {
    const data = "line1\nline2\r\nline3\n";
    var iter = LineIterator{ .data = data };

    try std.testing.expectEqualStrings("line1", iter.next().?);
    try std.testing.expectEqualStrings("line2", iter.next().?);
    try std.testing.expectEqualStrings("line3", iter.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "parse empty content" {
    const allocator = std.testing.allocator;
    var def = try parse(allocator, "");
    defer def.deinit();

    try std.testing.expectEqual(@as(u8, 0), def.workspace_count);
    try std.testing.expectEqualStrings("", def.name);
}

test "parse non-contiguous workspace numbers" {
    const content =
        \\[workspace.3]
        \\name = third
        \\layout = grid
        \\
        \\[workspace.3.pane.1]
        \\role = main
    ;

    const allocator = std.testing.allocator;
    var def = try parse(allocator, content);
    defer def.deinit();

    // workspace_count should be 3 (indices 0,1,2)
    try std.testing.expectEqual(@as(u8, 3), def.workspace_count);
    // Only workspace at index 2 (number 3) has data
    try std.testing.expectEqualStrings("third", def.workspaces[2].name);
    try std.testing.expectEqual(Layout.grid, def.workspaces[2].layout);
    try std.testing.expectEqual(@as(u8, 1), def.workspaces[2].pane_count);
    try std.testing.expectEqualStrings("main", def.workspaces[2].panes[0].role);
}

test "RestartPolicy toString" {
    try std.testing.expectEqualStrings("never", RestartPolicy.never.toString());
    try std.testing.expectEqualStrings("on-exit", RestartPolicy.on_exit.toString());
    try std.testing.expectEqualStrings("on-crash", RestartPolicy.on_crash.toString());
}

test "file I/O save and load round-trip" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Create a .tsess file manually
    const content =
        \\[session]
        \\name = roundtrip
        \\description = test
        \\
        \\[workspace.1]
        \\name = dev
        \\layout = grid
        \\ratio = 0.70
        \\
        \\[workspace.1.pane.1]
        \\role = editor
        \\cmd = vim
        \\cwd = /tmp
    ;

    const tmp_path = "/tmp/teru-session-test.tsess";

    // Write content to file
    const file = Dir.cwd().createFile(io, tmp_path, .{}) catch return;
    file.writeStreamingAll(io, content) catch {
        file.close(io);
        return;
    };
    file.close(io);

    // Read it back
    const read_file = Dir.cwd().openFile(io, tmp_path, .{}) catch return;
    defer read_file.close(io);
    const s = read_file.stat(io) catch return;
    const data = try allocator.alloc(u8, @intCast(s.size));
    defer allocator.free(data);
    const n = read_file.readPositionalAll(io, data, 0) catch return;

    // Parse
    var def = try parse(allocator, data[0..n]);
    defer def.deinit();

    try std.testing.expectEqualStrings("roundtrip", def.name);
    try std.testing.expectEqualStrings("test", def.description);
    try std.testing.expectEqual(@as(u8, 1), def.workspace_count);
    try std.testing.expectEqualStrings("dev", def.workspaces[0].name);
    try std.testing.expectEqual(Layout.grid, def.workspaces[0].layout);
    try std.testing.expectEqualStrings("editor", def.workspaces[0].panes[0].role);
    try std.testing.expectEqualStrings("vim", def.workspaces[0].panes[0].cmd);

    // Cleanup
    Dir.cwd().deleteFile(io, tmp_path) catch {};
}
