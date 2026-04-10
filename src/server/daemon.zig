//! Session daemon for teru terminal persistence.
//!
//! The daemon owns PTYs and a Multiplexer, surviving client disconnects.
//! A single client connects via Unix domain socket, receives PTY output,
//! and sends keyboard input. When the client detaches, PTYs keep running.
//! When all panes close, the daemon exits.
//!
//! Socket path: /run/user/{uid}/teru-session-{name}.sock

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");
const ipc = @import("ipc.zig");
const Allocator = std.mem.Allocator;
const Multiplexer = @import("../core/Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const McpServer = @import("../agent/McpServer.zig");
const Hooks = @import("../config/Hooks.zig");
const Session = @import("../persist/Session.zig");
const proto = @import("protocol.zig");

const Daemon = @This();

const socket_path_max: usize = 108;
const POLLIN: i16 = 0x001;
const POLLHUP: i16 = 0x010;
const POLLERR: i16 = 0x008;
const O_NONBLOCK = compat.O_NONBLOCK;

allocator: Allocator,
mux: *Multiplexer,
graph: *ProcessGraph,
mcp: ?*McpServer,
hooks: *const Hooks,
socket_fd: posix.fd_t,
client_fd: ?posix.fd_t,
socket_path: [socket_path_max]u8,
socket_path_len: usize,
session_name: []const u8,
running: bool,
persist_session: bool = false,
io: ?std.Io = null,

// ── Lifecycle ─────────────────────────────────────────────────────

pub fn init(
    allocator: Allocator,
    session_name: []const u8,
    mux: *Multiplexer,
    graph: *ProcessGraph,
    mcp: ?*McpServer,
    hooks: *const Hooks,
) !Daemon {
    var ipc_path_buf: [256]u8 = undefined;
    const path = ipc.buildPath(&ipc_path_buf, "session", session_name) orelse
        return error.PathTooLong;
    const path_len = path.len;

    const ipc_server = ipc.listen(path) catch return error.SocketFailed;
    const sock = ipc_server.rawFd();

    var daemon = Daemon{
        .allocator = allocator,
        .mux = mux,
        .graph = graph,
        .mcp = mcp,
        .hooks = hooks,
        .socket_fd = sock,
        .client_fd = null,
        .socket_path = undefined,
        .socket_path_len = path_len,
        .session_name = session_name,
        .running = true,
    };
    @memcpy(daemon.socket_path[0..path_len], path);

    return daemon;
}

/// Main daemon event loop. Blocks until all panes close.
pub fn run(self: *Daemon) void {
    var pty_buf: [8192]u8 = undefined;
    var recv_buf: [proto.max_payload]u8 = undefined;

    while (self.running) {
        // Exit when all panes are gone
        if (self.mux.panes.items.len == 0) {
            self.running = false;
            break;
        }

        // Build poll fd set (POSIX only — Windows daemon returns Unsupported in init)
        if (builtin.os.tag == .windows) return;
        var fds: [34]posix.pollfd = undefined; // listen + client + up to 32 PTYs
        var nfds: usize = 0;

        // [0] = listen socket
        fds[0] = .{ .fd = self.socket_fd, .events = POLLIN, .revents = 0 };
        nfds = 1;

        // [1] = client socket (if connected)
        if (self.client_fd) |cfd| {
            fds[1] = .{ .fd = cfd, .events = POLLIN, .revents = 0 };
            nfds = 2;
        }

        // [nfds..] = PTY master fds
        const pty_start = nfds;
        for (self.mux.panes.items) |*pane| {
            if (nfds >= fds.len) break;
            fds[nfds] = .{ .fd = pane.ptyMasterFd(), .events = POLLIN, .revents = 0 };
            nfds += 1;
        }

        // Poll with 10ms timeout
        const ready = posix.poll(fds[0..nfds], 10) catch 0;
        if (ready == 0) {
            // Idle — poll MCP and check pane health
            if (self.mcp) |m| m.poll();
            self.checkPaneAlive();
            continue;
        }

        // Accept new client
        if (fds[0].revents & POLLIN != 0) {
            self.tryAcceptClient();
        }

        // Read client input
        if (self.client_fd != null and nfds > 1) {
            if (fds[1].revents & (POLLIN | POLLHUP | POLLERR) != 0) {
                self.handleClientData(&recv_buf);
            }
        }

        // Read PTY output and relay to client (tagged with pane_id)
        var pane_idx: usize = 0;
        for (pty_start..nfds) |fi| {
            if (pane_idx >= self.mux.panes.items.len) break;
            if (fds[fi].revents & POLLIN != 0) {
                const pane = &self.mux.panes.items[pane_idx];
                const pane_id = pane.id;
                const n = pane.readAndProcess(&pty_buf) catch 0;
                if (n > 0) {
                    if (self.client_fd) |cfd| {
                        // Tag output with pane_id: [8-byte LE pane_id][data]
                        var tagged_buf: [8 + 8192]u8 = undefined;
                        if (proto.encodePanePayload(pane_id, pty_buf[0..n], &tagged_buf)) |tagged| {
                            _ = proto.sendMessage(cfd, .output, tagged);
                        }
                    }
                }
            }
            if (fds[fi].revents & (POLLHUP | POLLERR) != 0) {
                // PTY died — will be cleaned up in checkPaneAlive
            }
            pane_idx += 1;
        }

        // Poll MCP server
        if (self.mcp) |m| m.poll();

        // Check for dead panes
        self.checkPaneAlive();

        // Persist session: debounced save (100ms after last mutation)
        if (self.persist_session and self.mux.persist_dirty) {
            const elapsed = compat.monotonicNow() - self.mux.persist_dirty_since;
            if (elapsed >= 100_000_000) { // 100ms
                self.mux.persist_dirty = false;
                self.persistSave();
            }
        }
    }

    // Final save on daemon exit
    if (self.persist_session) {
        self.persistSave();
    }
}

pub fn deinit(self: *Daemon) void {
    if (self.client_fd) |cfd| {
        _ = posix.system.close(cfd);
        self.client_fd = null;
    }
    _ = posix.system.close(self.socket_fd);

    // Unlink socket file
    var unlink_buf: [socket_path_max + 1]u8 = undefined;
    @memcpy(unlink_buf[0..self.socket_path_len], self.socket_path[0..self.socket_path_len]);
    unlink_buf[self.socket_path_len] = 0;
    _ = std.c.unlink(@ptrCast(&unlink_buf));
}

pub fn getSocketPath(self: *const Daemon) []const u8 {
    return self.socket_path[0..self.socket_path_len];
}

// ── Client management ─────────────────────────────────────────────

fn tryAcceptClient(self: *Daemon) void {
    const client = ipc.accept(ipc.IpcHandle.fromRaw(self.socket_fd)) orelse return;

    // Only one client at a time — disconnect previous
    if (self.client_fd) |old| {
        _ = posix.system.close(old);
    }

    self.client_fd = client.rawFd();

    // Send current state to newly connected client
    self.sendStateSync();

    // Send recent grid content for all panes so client can render immediately
    self.sendGridSync();
}

/// Send visible grid content for all panes to the client.
/// This enables the client to render immediately on reconnect.
fn sendGridSync(self: *Daemon) void {
    const cfd = self.client_fd orelse return;
    var line_buf: [16384]u8 = undefined;

    for (self.mux.panes.items) |*pane| {
        // Build grid content: rows of text for VtParser to replay
        var grid_buf: [65536]u8 = undefined;
        var gpos: usize = 0;

        // Encode pane_id prefix
        std.mem.writeInt(u64, grid_buf[0..8], pane.id, .little);
        gpos = 8;

        // Encode visible grid as VT sequences: cursor home + each row's text
        // ESC[H = cursor home
        if (gpos + 3 <= grid_buf.len) {
            grid_buf[gpos] = 0x1b;
            grid_buf[gpos + 1] = '[';
            grid_buf[gpos + 2] = 'H';
            gpos += 3;
        }

        var row: u16 = 0;
        while (row < pane.grid.rows) : (row += 1) {
            const row_start = @as(usize, row) * @as(usize, pane.grid.cols);
            var col: u16 = 0;
            var line_len: usize = 0;
            while (col < pane.grid.cols) : (col += 1) {
                const cell = pane.grid.cells[row_start + col];
                if (cell.char >= 32 and cell.char < 127) {
                    if (line_len < line_buf.len) {
                        line_buf[line_len] = @intCast(cell.char);
                        line_len += 1;
                    }
                } else {
                    if (line_len < line_buf.len) {
                        line_buf[line_len] = ' ';
                        line_len += 1;
                    }
                }
            }
            // Trim trailing spaces
            while (line_len > 0 and line_buf[line_len - 1] == ' ') line_len -= 1;

            if (gpos + line_len + 2 > grid_buf.len) break;
            @memcpy(grid_buf[gpos..][0..line_len], line_buf[0..line_len]);
            gpos += line_len;
            // Newline (CR+LF) between rows
            if (row + 1 < pane.grid.rows) {
                grid_buf[gpos] = '\r';
                grid_buf[gpos + 1] = '\n';
                gpos += 2;
            }
        }

        _ = proto.sendMessage(cfd, .output, grid_buf[0..gpos]);
    }
}

fn handleClientData(self: *Daemon, recv_buf: []u8) void {
    var hdr: proto.Header = undefined;
    const payload = proto.recvMessage(self.client_fd.?, &hdr, recv_buf) orelse {
        // EOF or error — client disconnected
        self.disconnectClient();
        return;
    };

    switch (hdr.tag) {
        .active_input => {
            // Forward keyboard input to active pane PTY
            if (self.mux.getActivePaneMut()) |pane| {
                _ = pane.ptyWrite(payload) catch {};
            }
        },
        .input => {
            // Forward input to specific pane (pane_id-tagged)
            if (proto.decodePanePayload(payload)) |pp| {
                if (self.mux.getPaneById(pp.pane_id)) |pane| {
                    _ = pane.ptyWrite(pp.data) catch {};
                }
            }
        },
        .resize => {
            if (proto.decodeResize(payload)) |sz| {
                self.resizeAllPanes(sz.rows, sz.cols);
            }
        },
        .detach => {
            self.disconnectClient();
        },
        .command => {
            self.handleCommand(payload);
        },
        .request_sync => {
            self.sendStateSync();
        },
        else => {},
    }
}

fn handleCommand(self: *Daemon, payload: []const u8) void {
    if (payload.len == 0) return;
    const cmd = proto.Command.fromByte(payload[0]) orelse return;
    switch (cmd) {
        .switch_workspace => {
            if (payload.len >= 2) self.mux.switchWorkspace(payload[1]);
        },
        .focus_next => self.mux.focusNext(),
        .focus_prev => self.mux.focusPrev(),
        .split_vertical => {
            _ = self.mux.spawnPane(24, 80) catch {};
        },
        .split_horizontal => {
            _ = self.mux.spawnPane(24, 80) catch {};
        },
        .close_pane => {
            if (self.mux.getActivePane()) |pane| {
                self.mux.closePane(pane.id);
            }
        },
        .cycle_layout => self.mux.cycleLayout(),
        .zoom_toggle => self.mux.toggleZoom(),
        .swap_next => self.mux.swapPaneNext(),
        .swap_prev => self.mux.swapPanePrev(),
        .focus_master => self.mux.focusMaster(),
        .set_master => self.mux.setMaster(),
    }
    // Notify client of state change
    self.sendStateSync();
}

/// Send full multiplexer state to connected client for synchronization.
fn sendStateSync(self: *Daemon) void {
    const cfd = self.client_fd orelse return;

    // State sync format:
    // [active_workspace: 1]
    // [ws_count: 1]
    // per-workspace (× ws_count):
    //   [layout: 1] [pane_count: 1] [active_node_idx: 1] [master_ratio_x100: 1] [zoomed: 1]
    // per-pane (ordered by workspace node_ids to preserve position):
    //   [pane_id: 8] [rows: 2] [cols: 2] [ws_idx: 1]
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    buf[pos] = self.mux.active_workspace;
    pos += 1;
    const ws_count: u8 = 10;
    buf[pos] = ws_count;
    pos += 1;

    // Per-workspace info (12 bytes each):
    //   [layout:1][pane_count:1][ratio_x100:1][reserved:1][active_pane_id:8]
    for (&self.mux.layout_engine.workspaces) |*ws| {
        if (pos + 12 > buf.len) break;
        buf[pos] = @intFromEnum(ws.layout);
        pos += 1;
        buf[pos] = @intCast(@min(ws.node_ids.items.len, 255));
        pos += 1;
        buf[pos] = @intCast(@min(@as(u32, @intFromFloat(ws.master_ratio * 100)), 100));
        pos += 1;
        buf[pos] = 0; // reserved
        pos += 1;
        // Active pane ID (8 bytes, 0 = none)
        const active_id: u64 = ws.active_node orelse 0;
        std.mem.writeInt(u64, buf[pos..][0..8], active_id, .little);
        pos += 8;
    }

    // Per-pane info: iterate workspaces in order, then node_ids in order.
    // This preserves the position of each pane within its workspace.
    for (&self.mux.layout_engine.workspaces, 0..) |*ws, wi| {
        for (ws.node_ids.items) |nid| {
            if (pos + 13 > buf.len) break;
            const pane = self.mux.getPaneById(nid) orelse continue;
            std.mem.writeInt(u64, buf[pos..][0..8], pane.id, .little);
            pos += 8;
            std.mem.writeInt(u16, buf[pos..][0..2], pane.grid.rows, .little);
            pos += 2;
            std.mem.writeInt(u16, buf[pos..][0..2], pane.grid.cols, .little);
            pos += 2;
            buf[pos] = @intCast(wi);
            pos += 1;
        }
    }

    _ = proto.sendMessage(cfd, .state_sync, buf[0..pos]);
}

fn disconnectClient(self: *Daemon) void {
    if (self.client_fd) |cfd| {
        _ = posix.system.close(cfd);
        self.client_fd = null;
    }
}

fn resizeAllPanes(self: *Daemon, rows: u16, cols: u16) void {
    for (self.mux.panes.items) |*pane| {
        if (cols != pane.grid.cols or rows != pane.grid.rows) {
            pane.resize(self.allocator, rows, cols) catch continue;
        }
    }
}

// ── Pane health check ─────────────────────────────────────────────

fn checkPaneAlive(self: *Daemon) void {
    var i: usize = 0;
    while (i < self.mux.panes.items.len) {
        const pane = &self.mux.panes.items[i];
        if (pane.childPid()) |pid| {
            var status: c_int = 0;
            const rc = std.c.waitpid(pid, &status, 1); // WNOHANG = 1
            if (rc > 0) {
                // Child exited
                self.hooks.fire(.close);
                pane.deinit(self.allocator);
                _ = self.mux.panes.orderedRemove(i);
                // Re-link remaining panes after removal
                for (self.mux.panes.items) |*p| p.linkVt(self.allocator);
                self.mux.markDirty();
                continue; // don't increment i
            }
        }
        i += 1;
    }
}

fn persistSave(self: *Daemon) void {
    const io = self.io orelse return;
    const sess_dir = Session.getSessionDir(self.allocator) catch return;
    defer self.allocator.free(sess_dir);
    compat.ensureDirC(sess_dir);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.bin", .{ sess_dir, self.session_name }) catch return;
    self.mux.saveSession(self.graph, path, io) catch {};
}

// ── Session socket utilities ──────────────────────────────────────

/// Build the socket path for a given session name.
pub fn sessionSocketPath(name: []const u8, buf: *[socket_path_max]u8) ?[]const u8 {
    var ipc_buf: [256]u8 = undefined;
    const path = ipc.buildPath(&ipc_buf, "session", name) orelse return null;
    if (path.len > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    return buf[0..path.len];
}

/// Connect to an existing daemon session. Returns the connected socket fd.
pub fn connectToSession(name: []const u8) !posix.fd_t {
    var path_buf: [socket_path_max]u8 = undefined;
    const path = sessionSocketPath(name, &path_buf) orelse return error.PathTooLong;

    const conn = ipc.connect(path) catch return error.ConnectFailed;
    return conn.rawFd();
}

/// List active session names by scanning socket/pipe directory.
/// POSIX: scans /run/user/{uid}/ or /tmp/ for teru-session-*.sock
/// Windows: scans \\.\pipe\ for teru-session-* named pipes
pub fn listSessions(buf: *[1024]u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return listSessionsWin32(buf);
    return listSessionsPosix(buf);
}

fn listSessionsPosix(buf: *[1024]u8) ?[]const u8 {
    const uid = compat.getUid();
    var dir_path_buf: [64]u8 = undefined;
    const dir_path = if (builtin.os.tag == .macos)
        std.fmt.bufPrint(&dir_path_buf, "/tmp", .{}) catch return null
    else
        std.fmt.bufPrint(&dir_path_buf, "/run/user/{d}", .{uid}) catch return null;

    // Build prefix to match: "teru-{uid}-session-" (macOS) or "teru-session-" (Linux)
    var prefix_buf: [64]u8 = undefined;
    const prefix = if (builtin.os.tag == .macos)
        std.fmt.bufPrint(&prefix_buf, "teru-{d}-session-", .{uid}) catch return null
    else
        std.fmt.bufPrint(&prefix_buf, "teru-session-", .{}) catch return null;
    const suffix = ".sock";

    // Null-terminate for C opendir
    var dir_path_z: [65]u8 = undefined;
    @memcpy(dir_path_z[0..dir_path.len], dir_path);
    dir_path_z[dir_path.len] = 0;

    const dir = std.c.opendir(@ptrCast(&dir_path_z));
    if (dir == null) return null;
    defer _ = std.c.closedir(dir.?);

    var len: usize = 0;

    while (std.c.readdir(dir.?)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.sliceTo(name_ptr, 0);

        if (name.len > prefix.len + suffix.len and
            std.mem.startsWith(u8, name, prefix) and
            std.mem.endsWith(u8, name, suffix))
        {
            const session_name = name[prefix.len .. name.len - suffix.len];

            // Try connecting to verify it's alive
            const sock = connectToSession(session_name) catch continue;
            _ = posix.system.close(sock);

            if (len + session_name.len + 1 < buf.len) {
                @memcpy(buf[len .. len + session_name.len], session_name);
                buf[len + session_name.len] = '\n';
                len += session_name.len + 1;
            }
        }
    }

    if (len == 0) return null;
    return buf[0..len];
}

fn listSessionsWin32(_: *[1024]u8) ?[]const u8 {
    // Windows pipe enumeration requires NtQueryDirectoryFile on \Device\NamedPipe
    // or FindFirstFileW on "\\.\pipe\teru-session-*".
    // For now, Windows users must specify session names explicitly.
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────

test "sessionSocketPath: generates expected format" {
    var buf: [socket_path_max]u8 = undefined;
    const path = sessionSocketPath("test", &buf);
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.endsWith(u8, path.?, "teru-session-test.sock") or
        std.mem.endsWith(u8, path.?, "session-test.sock"));
}

test "sessionSocketPath: long name returns null" {
    var buf: [socket_path_max]u8 = undefined;
    // 100 char name should overflow the 108-byte sun_path
    const long_name = "a" ** 100;
    const path = sessionSocketPath(long_name, &buf);
    try std.testing.expect(path == null);
}

test "connectToSession: non-existent session returns error" {
    const result = connectToSession("nonexistent-session-12345");
    try std.testing.expectError(error.ConnectFailed, result);
}
