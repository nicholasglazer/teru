//! Compositor-level session snapshot + restore.
//!
//! Walks LayoutEngine workspaces and terminal_panes to dump the current
//! state to a `.tsess` file (same format as the teru multiplexer uses).
//! Restore reads the file and re-spawns panes via
//! TerminalPane.createWithSpawn so each resumes in its saved cwd
//! running its saved cmd. Layouts and master_ratio are restored.
//!
//! Scope is intentionally small:
//!   - only tiled terminal panes are captured (no XDG clients, no floats)
//!   - no scrollback, no env, no scratchpads
//!   - restore is idempotent by role: a pane with a matching role is not
//!     duplicated on repeat calls
//!
//! File location: `~/.config/teru/sessions/<name>.tsess`.
//!
//! Uses libc for file I/O to match the compositor's hot-restart
//! conventions (no std.Io plumbing required at the Server layer).

const std = @import("std");
const builtin = @import("builtin");
const teru = @import("teru");
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");
const Pane = teru.Pane;
const CoreSession = teru.SessionDef;

const max_file_size = 65536;

// ── Save ────────────────────────────────────────────────────────

/// Serialize the compositor's live state to `~/.config/teru/sessions/<name>.tsess`.
pub fn save(server: *Server, name: []const u8) !void {
    var buf: [max_file_size]u8 = undefined;
    var pos: usize = 0;

    pos += writeStr(buf[pos..], "# teruwm session snapshot — regenerate with session:save\n");
    pos += try writeFmt(buf[pos..], "[session]\nname = {s}\n\n", .{name});

    for (&server.layout_engine.workspaces, 0..) |*ws, wi| {
        if (ws.node_ids.items.len == 0) continue;
        const ws_num: u8 = @intCast(wi + 1);

        pos += try writeFmt(buf[pos..], "[workspace.{d}]\nlayout = {s}\nratio = {d:.2}\n\n", .{
            ws_num,
            ws.layout.name(),
            ws.master_ratio,
        });

        var pane_num: u8 = 0;
        for (ws.node_ids.items) |node_id| {
            const tp = findTerminal(server, node_id) orelse continue;
            pane_num += 1;

            const role = nodeName(server, node_id);

            var cwd_buf: [512]u8 = undefined;
            const cwd = getChildCwd(&tp.pane, &cwd_buf);

            var cmd_buf: [512]u8 = undefined;
            const cmd = getChildCmd(&tp.pane, &cmd_buf);

            pos += try writeFmt(buf[pos..], "[workspace.{d}.pane.{d}]\nrole = {s}\n", .{ ws_num, pane_num, role });
            if (cmd.len > 0) pos += try writeFmt(buf[pos..], "cmd = {s}\n", .{cmd});
            if (cwd.len > 0) pos += try writeFmt(buf[pos..], "cwd = {s}\n", .{cwd});
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }
        }
    }

    const allocator = server.zig_allocator;
    const path = try CoreSession.getSessionPath(allocator, name);
    defer allocator.free(path);

    ensureParentDirLibc(path);

    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const file = std.c.fopen(@ptrCast(path_z[0..path.len :0]), "wb") orelse return error.CreateFailed;
    defer _ = std.c.fclose(file);
    const written = std.c.fwrite(buf[0..pos].ptr, 1, pos, file);
    if (written != pos) return error.WriteFailed;

    std.debug.print("teruwm: session saved to {s} ({d} bytes)\n", .{ path, pos });
}

// ── Restore ─────────────────────────────────────────────────────

/// Load `~/.config/teru/sessions/<name>.tsess` and respawn panes. Idempotent
/// by pane role — running panes with matching roles are left untouched.
pub fn restore(server: *Server, name: []const u8) !void {
    const allocator = server.zig_allocator;

    const path = try CoreSession.getSessionPath(allocator, name);
    defer allocator.free(path);

    var path_z: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    const file = std.c.fopen(@ptrCast(path_z[0..path.len :0]), "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    var content_buf: [max_file_size]u8 = undefined;
    const n = std.c.fread(&content_buf, 1, content_buf.len, file);
    if (n == 0) return error.EmptyFile;

    var def = try CoreSession.parse(allocator, content_buf[0..n]);
    defer def.deinit();

    for (def.workspaces[0..def.workspace_count], 0..) |*ws_def, wi| {
        if (ws_def.pane_count == 0) continue;

        const ws_idx: u8 = if (ws_def.index > 0) ws_def.index - 1 else @intCast(wi);
        if (ws_idx >= 10) continue;

        const ws = &server.layout_engine.workspaces[ws_idx];
        ws.layout = ws_def.layout;
        ws.master_ratio = ws_def.ratio;

        for (ws_def.panes[0..ws_def.pane_count]) |*pd| {
            const role_key = if (pd.role.len > 0) pd.role else pd.cmd;
            if (role_key.len > 0 and workspaceHasRole(server, ws_idx, role_key)) continue;

            var cwd_buf: [512]u8 = undefined;
            const cwd_expanded: ?[]const u8 = if (pd.cwd.len > 0) expandTilde(pd.cwd, &cwd_buf) else null;

            const spawn_config = Pane.SpawnConfig{
                .shell = if (pd.cmd.len > 0) pd.cmd else null,
                .cwd = cwd_expanded,
            };

            const tp = TerminalPane.createWithSpawn(server, ws_idx, 24, 80, spawn_config) orelse {
                std.debug.print("teruwm: session restore: failed to spawn pane on ws={d}\n", .{ws_idx});
                continue;
            };

            for (&server.terminal_panes) |*slot| {
                if (slot.* == null) {
                    slot.* = tp;
                    server.terminal_count += 1;
                    break;
                }
            }

            if (pd.role.len > 0) {
                if (server.nodes.findById(tp.node_id)) |s| server.nodes.setName(s, pd.role);
            }
        }

        server.arrangeworkspace(ws_idx);
    }

    for (server.terminal_panes) |maybe_tp| {
        if (maybe_tp) |t| t.render();
    }
    if (server.bar) |b| b.render(server);

    std.debug.print("teruwm: session {s} restored\n", .{name});
}

// ── Helpers ─────────────────────────────────────────────────────

fn findTerminal(server: *Server, node_id: u64) ?*TerminalPane {
    for (server.terminal_panes) |maybe| {
        if (maybe) |tp| {
            if (tp.node_id == node_id) return tp;
        }
    }
    return null;
}

fn nodeName(server: *Server, node_id: u64) []const u8 {
    if (server.nodes.findById(node_id)) |s| return server.nodes.getName(s);
    return "term";
}

fn workspaceHasRole(server: *Server, ws_idx: u8, role: []const u8) bool {
    const ws = &server.layout_engine.workspaces[ws_idx];
    for (ws.node_ids.items) |id| {
        if (std.mem.eql(u8, nodeName(server, id), role)) return true;
    }
    return false;
}

fn getChildCwd(pane: *const Pane, buf: []u8) []const u8 {
    if (builtin.os.tag != .linux) return "";
    const pid = pane.childPid() orelse return "";
    var proc_path: [64:0]u8 = undefined;
    const path = std.fmt.bufPrint(&proc_path, "/proc/{d}/cwd", .{pid}) catch return "";
    proc_path[path.len] = 0;
    const rc = std.c.readlink(&proc_path, buf.ptr, buf.len);
    if (rc > 0) return buf[0..@intCast(rc)];
    return "";
}

fn getChildCmd(pane: *const Pane, buf: []u8) []const u8 {
    if (builtin.os.tag != .linux) return "";
    const pid = pane.childPid() orelse return "";
    var proc_path: [64:0]u8 = undefined;
    const path = std.fmt.bufPrint(&proc_path, "/proc/{d}/cmdline", .{pid}) catch return "";
    proc_path[path.len] = 0;

    const fd = std.c.open(&proc_path, .{ .ACCMODE = .RDONLY }, @as(std.posix.mode_t, 0));
    if (fd < 0) return "";
    defer _ = std.posix.system.close(fd);

    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return "";
    const len: usize = @intCast(n);

    var end: usize = len;
    while (end > 0 and buf[end - 1] == 0) end -= 1;
    for (buf[0..end]) |*c| {
        if (c.* == 0) c.* = ' ';
    }
    return buf[0..end];
}

fn expandTilde(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '~') {
        const home = teru.compat.getenv("HOME") orelse return null;
        const rest = if (path.len > 1) path[1..] else "";
        return std.fmt.bufPrint(buf, "{s}{s}", .{ home, rest }) catch return null;
    }
    return path;
}

fn writeStr(dst: []u8, s: []const u8) usize {
    const n = @min(dst.len, s.len);
    @memcpy(dst[0..n], s[0..n]);
    return n;
}

fn writeFmt(dst: []u8, comptime fmt: []const u8, args: anytype) !usize {
    const out = try std.fmt.bufPrint(dst, fmt, args);
    return out.len;
}

fn ensureParentDirLibc(path: []const u8) void {
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (last_slash == 0) return;
    const parent = path[0..last_slash];

    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (parent.len >= buf.len) return;

    var i: usize = 1;
    while (i < parent.len) : (i += 1) {
        if (parent[i] == '/') {
            @memcpy(buf[0..i], parent[0..i]);
            buf[i] = 0;
            _ = std.c.mkdir(@ptrCast(buf[0..i :0]), 0o755);
        }
    }
    @memcpy(buf[0..parent.len], parent);
    buf[parent.len] = 0;
    _ = std.c.mkdir(@ptrCast(buf[0..parent.len :0]), 0o755);
}
