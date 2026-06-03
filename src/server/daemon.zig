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
const Pane = @import("../core/Pane.zig");
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
/// Monotonic ns of last checkPaneAlive() call; used to throttle the
/// pane-health sweep to ~5 s in the absence of POLLHUP/POLLERR.
last_pane_check_ns: i128 = 0,
/// Reusable poll() fd set, grown to fit (listen + client + every PTY + 2 MCP
/// fds). Heap-backed rather than a fixed array so a large session — e.g. the
/// 34-pane claude-power layout — never silently drops panes from the poll set
/// (an un-polled PTY's output is never drained; its buffer fills and the agent
/// blocks). Grows on demand, never shrinks; freed in deinit.
poll_fds: []posix.pollfd = &.{},

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

    // Seed the poll fd set (grown on demand in run()). 16 covers the common
    // small-session case with no in-loop allocation.
    const pollbuf = try allocator.alloc(posix.pollfd, 16);
    errdefer allocator.free(pollbuf);

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
        .poll_fds = pollbuf,
    };
    @memcpy(daemon.socket_path[0..path_len], path);

    return daemon;
}

/// Grow the reusable poll fd buffer to at least `n` entries (never shrinks).
/// On allocation failure returns the existing buffer — callers must tolerate a
/// slightly-short slice (the run loop's `fds.len < 4` guard does).
fn ensurePollCapacity(self: *Daemon, n: usize) []posix.pollfd {
    if (self.poll_fds.len >= n) return self.poll_fds;
    if (self.allocator.realloc(self.poll_fds, n)) |grown| {
        self.poll_fds = grown;
    } else |_| {}
    return self.poll_fds;
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
        // Size to fit listen + client + every PTY + 2 MCP fds. Grows with the
        // pane count so no pane is ever dropped from the poll set.
        const fds = self.ensurePollCapacity(self.mux.panes.items.len + 4);
        // fds is seeded to 16 in init and only ever grows, so it is always
        // ≥ 4. The guard is defence-in-depth against a pathological OOM that
        // left it empty; skip the iteration rather than index a short slice.
        if (fds.len < 4) continue;
        var nfds: usize = 0;

        // [0] = listen socket
        fds[0] = .{ .fd = self.socket_fd, .events = POLLIN, .revents = 0 };
        nfds = 1;

        // [1] = client socket (if connected)
        if (self.client_fd) |cfd| {
            fds[1] = .{ .fd = cfd, .events = POLLIN, .revents = 0 };
            nfds = 2;
        }

        // [nfds..pty_end] = PTY master fds
        const pty_start = nfds;
        for (self.mux.panes.items) |*pane| {
            if (nfds >= fds.len -| 2) break; // leave room for MCP fds
            fds[nfds] = .{ .fd = pane.ptyMasterFd(), .events = POLLIN, .revents = 0 };
            nfds += 1;
        }
        const pty_end = nfds;

        // [pty_end..nfds] = MCP request + event listen sockets (if any).
        // Adding them to the poll set means MCP wakes us on demand instead
        // of forcing an idle 100 Hz poll loop just to call mcp.poll().
        var mcp_req_idx: ?usize = null;
        var mcp_evt_idx: ?usize = null;
        if (self.mcp) |m| {
            if (m.socket_fd >= 0 and nfds < fds.len) {
                fds[nfds] = .{ .fd = m.socket_fd, .events = POLLIN, .revents = 0 };
                mcp_req_idx = nfds;
                nfds += 1;
            }
            if (m.event_socket_fd >= 0 and nfds < fds.len) {
                fds[nfds] = .{ .fd = m.event_socket_fd, .events = POLLIN, .revents = 0 };
                mcp_evt_idx = nfds;
                nfds += 1;
            }
        }

        // Deadline-driven timeout: wait forever unless we have a debounce
        // window pending (persist save fires 100 ms after last mutation).
        // Cap at 5000 ms as a safety net for any periodic work that isn't
        // currently event-driven (none today, but cheap insurance).
        var timeout_ms: i32 = 5000;
        if (self.persist_session and self.mux.persist_dirty) {
            const elapsed_ns: i128 = compat.monotonicNow() - self.mux.persist_dirty_since;
            const remaining_ns: i128 = 100_000_000 - elapsed_ns;
            if (remaining_ns <= 0) {
                timeout_ms = 0;
            } else {
                const cand_ms: i32 = @intCast(@divFloor(remaining_ns, 1_000_000));
                if (cand_ms < timeout_ms) timeout_ms = cand_ms;
            }
        }

        const ready = posix.poll(fds[0..nfds], timeout_ms) catch 0;
        _ = ready;

        // Accept new client
        if (fds[0].revents & POLLIN != 0) {
            self.tryAcceptClient();
        }

        // Read client input. A client command here (handleClientData) can
        // spawn or close a pane, mutating mux.panes — which leaves the fds[]
        // snapshot (built before poll) stale relative to the live pane list.
        const panes_before = self.mux.panes.items.len;
        if (self.client_fd != null and pty_start >= 2) {
            if (fds[1].revents & (POLLIN | POLLHUP | POLLERR) != 0) {
                self.handleClientData(&recv_buf);
            }
        }

        // Read PTY output and relay to client (tagged with pane_id).
        // Skip the relay if the pane set changed under us this iteration:
        // fds[pty_start..] no longer lines up with mux.panes by index. fds[]
        // is rebuilt at the top of the next iteration, so output is relayed
        // one iteration later — imperceptible, and avoids reading a pane's fd
        // against the wrong pane (mis-tagged output / off-by-one).
        var pane_idx: usize = 0;
        var any_pty_died = false;
        const pane_set_stable = self.mux.panes.items.len == panes_before;
        if (pane_set_stable) for (pty_start..pty_end) |fi| {
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
                any_pty_died = true;
            }
            pane_idx += 1;
        };

        // MCP poll only when one of its listen sockets has readiness.
        // mcp.poll() drains both event_socket_fd and socket_fd internally,
        // so calling it once per loop iteration is sufficient.
        const mcp_ready =
            (if (mcp_req_idx) |i| (fds[i].revents & POLLIN != 0) else false) or
            (if (mcp_evt_idx) |i| (fds[i].revents & POLLIN != 0) else false);
        if (mcp_ready) {
            if (self.mcp) |m| m.poll();
        }

        // Check for dead panes only when a PTY signaled HUP/ERR or when
        // ≥ 5 s has elapsed since the last sweep (safety net for SIGCHLD
        // races). Without this throttle, every wake-up (keystroke, MCP
        // request) would re-scan all panes — wasted syscalls.
        const now_ns = compat.monotonicNow();
        if (any_pty_died or (now_ns - self.last_pane_check_ns) >= 5_000_000_000) {
            self.checkPaneAlive();
            self.last_pane_check_ns = now_ns;
        }

        // Persist session: debounced save (100 ms after last mutation)
        if (self.persist_session and self.mux.persist_dirty) {
            const elapsed = compat.monotonicNow() - self.mux.persist_dirty_since;
            if (elapsed >= 100_000_000) { // 100 ms
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
    if (self.poll_fds.len > 0) self.allocator.free(self.poll_fds);
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

/// Replay ONE pane's visible grid to the client as a self-contained snapshot:
///   clear screen → home → repaint every row from the top → restore the cursor.
/// Sent on attach AND re-sent after every resize (see handleClientData), so the
/// client's copy always exactly mirrors the daemon's grid at the current size.
///
/// Why clear + cursor-restore: the previous version homed and repainted but never
/// cleared and never restored the cursor — and it ran once, BEFORE the client's
/// resize. So the stale (pre-resize) snapshot stayed on screen while the live
/// shell redrew its prompt at the post-resize position, leaving a DUPLICATE: a
/// frozen copy at the top plus the live prompt lower down. Clearing first
/// replaces any stale content; restoring the cursor makes the live shell's next
/// output land exactly on the replayed copy instead of beside it.
/// (Plaintext/ASCII only — SGR/wide-glyph fidelity is a separately-scoped TODO.)
fn sendPaneGridSync(self: *Daemon, pane: *Pane) void {
    const cfd = self.client_fd orelse return;
    var line_buf: [16384]u8 = undefined;
    var grid_buf: [65536]u8 = undefined;
    var gpos: usize = 0;

    // pane_id prefix
    std.mem.writeInt(u64, grid_buf[0..8], pane.id, .little);
    gpos = 8;

    // Clear the pane then home, so this repaint REPLACES any stale snapshot
    // rather than layering on top of it (the duplication bug).
    const clear_home = "\x1b[2J\x1b[H";
    @memcpy(grid_buf[gpos..][0..clear_home.len], clear_home);
    gpos += clear_home.len;

    var row: u16 = 0;
    while (row < pane.grid.rows) : (row += 1) {
        const row_start = @as(usize, row) * @as(usize, pane.grid.cols);
        var col: u16 = 0;
        var line_len: usize = 0;
        while (col < pane.grid.cols) : (col += 1) {
            if (row_start + col >= pane.grid.cells.len) break;
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

    // Restore the cursor to the daemon's real position (1-based CUP) so the live
    // shell's next byte continues where the replay left off — not at the bottom
    // where the trailing-blank-row CRLFs would otherwise have parked it.
    var cur_buf: [24]u8 = undefined;
    const cur = std.fmt.bufPrint(&cur_buf, "\x1b[{d};{d}H", .{
        pane.grid.cursor_row + 1,
        pane.grid.cursor_col + 1,
    }) catch "";
    if (gpos + cur.len <= grid_buf.len) {
        @memcpy(grid_buf[gpos..][0..cur.len], cur);
        gpos += cur.len;
    }

    _ = proto.sendMessage(cfd, .output, grid_buf[0..gpos]);
}

/// Replay every pane's grid to the client (on attach / full re-sync).
fn sendGridSync(self: *Daemon) void {
    if (self.client_fd == null) return;
    for (self.mux.panes.items) |*pane| self.sendPaneGridSync(pane);
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
            if (payload.len >= 12) {
                if (proto.decodePanePayload(payload)) |pp| {
                    if (pp.data.len >= 4) {
                        if (self.mux.getPaneById(pp.pane_id)) |pane| {
                            if (proto.decodeResize(pp.data)) |sz| {
                                // Drop a 0-dimension resize (never a valid terminal).
                                // Reflow the Grid too (resize() = grid.resize + ptyResize),
                                // not just the PTY — otherwise the daemon's authoritative
                                // grid for a non-active workspace's pane stays at its
                                // 24×80 spawn default and replays at the wrong geometry
                                // on the next attach. &pane.grid is stable, so no relink.
                                if (sz.rows != 0 and sz.cols != 0) {
                                    pane.resize(self.allocator, sz.rows, sz.cols) catch |e|
                                        std.log.scoped(.daemon).warn("pane resize failed: {s}", .{@errorName(e)});
                                    // Re-send this pane's grid at the new size so the
                                    // client replaces its pre-resize snapshot (which was
                                    // at the wrong geometry) — kills the duplicate prompt.
                                    self.sendPaneGridSync(pane);
                                }
                            }
                        }
                    }
                }
            } else if (proto.decodeResize(payload)) |sz| {
                self.resizeAllPanes(sz.rows, sz.cols);
                // Full re-sync after a whole-screen resize, same rationale.
                self.sendGridSync();
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
            if (payload.len >= 2 and payload[1] < 10) self.mux.switchWorkspace(payload[1]);
        },
        .focus_next => self.mux.focusNext(),
        .focus_prev => self.mux.focusPrev(),
        .split_vertical => {
            _ = self.mux.spawnPane(24, 80) catch |err| {
                std.log.scoped(.daemon).err("split_vertical spawn failed: {s}", .{@errorName(err)});
            };
        },
        .split_horizontal => {
            _ = self.mux.spawnPane(24, 80) catch |err| {
                std.log.scoped(.daemon).err("split_horizontal spawn failed: {s}", .{@errorName(err)});
            };
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
        .focus_pane => {
            if (payload.len >= 9) {
                const pane_id = std.mem.readInt(u64, payload[1..9], .little);
                self.mux.focusPaneId(pane_id);
            }
        },
        .resize_shrink => self.mux.resizeActive(-2, -2),
        .resize_grow => self.mux.resizeActive(2, 2),
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
        // Active pane ID (8 bytes, 0 = none). Use getActiveNodeId() — NOT the
        // raw active_node, which is null for every flat layout (master-stack/
        // grid/monocle, where focus lives in active_index). Shipping
        // active_node here meant the daemon's real focus never reached the
        // client: the highlight + click-stepping base went stale and input
        // routed to a different pane than the one shown focused (S1/S2).
        const active_id: u64 = ws.getActiveNodeId() orelse 0;
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
    // Ignore a degenerate 0-dimension resize. A 0x0 terminal is never valid,
    // and resizing a pane grid to 0 cols/rows makes the VtParser index an empty
    // cell slice → panic → the daemon dies and takes every agent with it. The
    // daemon must be uncrashable by client input; keep the current size.
    if (rows == 0 or cols == 0) return;
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
                const dead_id = pane.id;
                // Mirror Multiplexer.closePane: clear the dead id from every
                // workspace's flat list AND split tree first. Workspace.removeNode
                // is what resets active_node/master_id when they point at this
                // pane — skipping it (as this path did) leaves a freed pane id
                // live in the layout, so getActivePane()/node lists rot for any
                // long-lived daemon whose shells exit.
                for (&self.mux.layout_engine.workspaces) |*ws| {
                    ws.removeNode(dead_id);
                    ws.removeNodeFromTree(dead_id);
                }
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
    self.mux.saveSession(self.graph, path, io) catch |e| {
        // Session persist failure is exactly what users need to see — a
        // silent catch {} swallowed "disk full" / "permission denied"
        // long enough to lose a session on daemon exit.
        std.log.scoped(.daemon).err("saveSession failed: {} (path={s})", .{ e, path });
    };
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
    const long_name: [100]u8 = @splat('a');
    const path = sessionSocketPath(&long_name, &buf);
    try std.testing.expect(path == null);
}

test "connectToSession: non-existent session returns error" {
    const result = connectToSession("nonexistent-session-12345");
    try std.testing.expectError(error.ConnectFailed, result);
}
