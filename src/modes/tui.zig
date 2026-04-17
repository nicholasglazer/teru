//! TUI mode — a multiplexer UI rendered as ANSI to a remote or
//! local terminal. Connects to a running teru daemon over a Unix
//! socket; works over SSH; the daemon's session persists after the
//! TUI detaches.
//!
//! Entry: `run(allocator, io, sock)`. Takes ownership of `sock` and
//! closes it on exit.
//!
//! SIGWINCH plumbing: the signal fires on a self-pipe; the main
//! poll loop drains it and resends a resize message to the daemon.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");
const common = @import("common.zig");
const Multiplexer = @import("../core/Multiplexer.zig");
const TuiScreen = @import("../render/TuiScreen.zig");
const TuiRenderer = @import("../render/TuiRenderer.zig");
const TuiInput = @import("../input/TuiInput.zig");
const daemon_proto = @import("../server/protocol.zig");

// SIGWINCH self-pipe — set by run() before installing the handler.
var g_sigwinch_pipe: posix.fd_t = -1;

fn sigwinchHandler(_: posix.SIG) callconv(.c) void {
    if (g_sigwinch_pipe != -1) {
        _ = std.c.write(g_sigwinch_pipe, "W", 1);
    }
}

/// TUI multiplexer mode: full pane/workspace/layout rendered as ANSI
/// to a terminal. Connects to a daemon over Unix socket. POSIX-only.
pub fn run(allocator: std.mem.Allocator, io: std.Io, sock: posix.fd_t) !void {
    // TUI daemon mode talks to a daemon over a Unix socket and
    // toggles termios for raw keystroke input. Windows never reaches
    // this path (Daemon.connectToSession only exists on POSIX), but
    // the function must still type-check because posix.fd_t is
    // *anyopaque on Windows and stdin fd `0` is comptime_int.
    if (builtin.os.tag == .windows) return error.Unsupported;

    defer _ = posix.system.close(sock);

    common.out("[teru] TUI mode \xe2\x80\x94 attached to session\r\n");

    // Enter raw terminal mode
    var orig_termios: posix.termios = undefined;
    const stdin_fd: posix.fd_t = if (builtin.os.tag == .windows) undefined else 0;
    _ = std.c.tcgetattr(stdin_fd, &orig_termios);
    var raw = orig_termios;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    _ = std.c.tcsetattr(0, .FLUSH, &raw);
    defer _ = std.c.tcsetattr(0, .FLUSH, &orig_termios);

    // Terminal size
    var ws: posix.winsize = undefined;
    const ws_rc = std.c.ioctl(1, posix.T.IOCGWINSZ, &ws);
    const term_rows: u16 = if (ws_rc == 0) ws.row else 24;
    const term_cols: u16 = if (ws_rc == 0) ws.col else 80;

    // Non-blocking socket + stdin
    const sock_flags = std.c.fcntl(sock, posix.F.GETFL);
    if (sock_flags >= 0) _ = std.c.fcntl(sock, posix.F.SETFL, sock_flags | compat.O_NONBLOCK);
    const stdin_flags = std.c.fcntl(0, posix.F.GETFL);
    if (stdin_flags >= 0) _ = std.c.fcntl(0, posix.F.SETFL, stdin_flags | compat.O_NONBLOCK);
    defer _ = std.c.fcntl(0, posix.F.SETFL, stdin_flags);

    // Multiplexer for remote panes
    _ = io;
    var mux = Multiplexer.init(allocator);
    defer mux.deinit();

    // Send resize to daemon (subtract 1 for status bar)
    const content_rows = if (term_rows > 1) term_rows - 1 else term_rows;
    const resize_payload = daemon_proto.encodeResize(content_rows, term_cols);
    _ = daemon_proto.sendMessage(sock, .resize, &resize_payload);

    // Wait for state_sync from daemon
    {
        var sync_attempts: u32 = 0;
        while (sync_attempts < 100) : (sync_attempts += 1) {
            var hdr: daemon_proto.Header = undefined;
            var recv_buf: [daemon_proto.max_payload]u8 = undefined;
            var poll_fds = [1]posix.pollfd{
                .{ .fd = sock, .events = 0x001, .revents = 0 },
            };
            _ = posix.poll(&poll_fds, 10) catch continue;
            if (poll_fds[0].revents & 0x001 != 0) {
                while (daemon_proto.recvMessage(sock, &hdr, &recv_buf)) |payload| {
                    switch (hdr.tag) {
                        .state_sync => {
                            common.parseDaemonStateSync(sock, &mux, payload);
                            sync_attempts = 100;
                        },
                        .output => {
                            if (daemon_proto.decodePanePayload(payload)) |pp| {
                                if (mux.getPaneById(pp.pane_id)) |pane| {
                                    if (pp.data.len > 0) {
                                        pane.vt.feed(pp.data);
                                        pane.grid.dirty = true;
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }
    }

    // Resize + clear all panes to match content area
    {
        const cr = if (term_rows > 1) term_rows - 1 else term_rows;
        for (mux.panes.items) |*pane| {
            var rbuf: [12]u8 = undefined;
            std.mem.writeInt(u64, rbuf[0..8], pane.id, .little);
            const rd = daemon_proto.encodeResize(cr, term_cols);
            @memcpy(rbuf[8..12], &rd);
            _ = daemon_proto.sendMessage(sock, .resize, &rbuf);
            pane.grid.resize(allocator, cr, term_cols) catch {};
            pane.grid.clearScreen(2);
            pane.grid.cursor_row = 0;
            pane.grid.cursor_col = 0;
        }
    }

    // TUI screen + renderer
    var screen = TuiScreen.init(allocator, term_rows, term_cols) catch {
        common.out("[teru] Failed to init TUI screen\r\n");
        return;
    };
    defer screen.deinit(allocator);

    var renderer = TuiRenderer.init(&screen, allocator, sock);
    var tui_input = TuiInput.initAutoDetect();

    // Enter alt screen, hide cursor, enable SGR mouse
    const enter_tui = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H\x1b[?1000h\x1b[?1006h";
    _ = std.c.write(1, enter_tui.ptr, enter_tui.len);
    const leave_tui = "\x1b[?1000l\x1b[?1006l\x1b[?25h\x1b[?1049l";
    defer _ = std.c.write(1, leave_tui.ptr, leave_tui.len);

    // SIGWINCH wiring
    var sigwinch_fds: [2]posix.fd_t = .{ -1, -1 };
    {
        var pipe_fds: [2]c_int = undefined;
        if (std.c.pipe(&pipe_fds) == 0) {
            sigwinch_fds[0] = pipe_fds[0];
            sigwinch_fds[1] = pipe_fds[1];
            const pf = std.c.fcntl(sigwinch_fds[1], posix.F.GETFL);
            if (pf >= 0) _ = std.c.fcntl(sigwinch_fds[1], posix.F.SETFL, pf | compat.O_NONBLOCK);
            g_sigwinch_pipe = sigwinch_fds[1];
            const SA_RESTART = 0x10000000;
            const sa = posix.Sigaction{
                .handler = .{ .handler = sigwinchHandler },
                .mask = posix.sigemptyset(),
                .flags = SA_RESTART,
            };
            posix.sigaction(posix.SIG.WINCH, &sa, null);
        }
    }
    defer {
        if (sigwinch_fds[0] != -1) _ = posix.system.close(sigwinch_fds[0]);
        if (sigwinch_fds[1] != -1) _ = posix.system.close(sigwinch_fds[1]);
    }

    // Initial render
    renderer.renderWithOpts(&mux, 1, .{ .nested = tui_input.isNested(), .prefix_active = tui_input.isPrefixActive() });

    // Main poll loop
    var in_buf: [4096]u8 = undefined;
    const POLLIN: i16 = 0x001;
    const POLLHUP: i16 = 0x010;
    const POLLERR: i16 = 0x008;

    while (true) {
        var fds = [3]posix.pollfd{
            .{ .fd = 0, .events = POLLIN, .revents = 0 },
            .{ .fd = sock, .events = POLLIN, .revents = 0 },
            .{ .fd = sigwinch_fds[0], .events = POLLIN, .revents = 0 },
        };
        const nfds: usize = if (sigwinch_fds[0] != -1) 3 else 2;
        const poll_result = posix.poll(fds[0..nfds], 50) catch continue;

        var needs_render = false;

        if (poll_result == 0) {
            tui_input.checkTimeout(sock);
            continue;
        }

        // stdin → TuiInput
        if (fds[0].revents & POLLIN != 0) {
            const n = posix.read(0, &in_buf) catch break;
            if (n == 0) break;
            if (tui_input.feed(in_buf[0..n], sock)) {
                common.out("[teru] Detached\r\n");
                return;
            }
            // Mouse events from TuiInput
            if (tui_input.last_mouse) |mouse| {
                var dbg: [128]u8 = undefined;
                const dbg_msg = std.fmt.bufPrint(&dbg, "MOUSE: col={d} row={d} btn={d} rel={}\n", .{ mouse.col, mouse.row, mouse.button, mouse.release }) catch "";
                _ = std.c.write(2, dbg_msg.ptr, dbg_msg.len);
                tui_input.last_mouse = null;
                if (!mouse.release and mouse.button == 0) {
                    // Left click → focus pane under cursor
                    const active_ws = &mux.layout_engine.workspaces[mux.active_workspace];
                    const pane_ids = active_ws.node_ids.items;
                    const LE_Rect = @import("../tiling/LayoutEngine.zig").Rect;
                    const sr = LE_Rect{ .x = 0, .y = 0, .width = screen.width, .height = if (screen.height > 1) screen.height - 1 else screen.height };
                    var dbg2: [256]u8 = undefined;
                    const dbg2_msg = std.fmt.bufPrint(&dbg2, "HIT: panes={d} screen={d}x{d} active_idx={d}\n", .{ pane_ids.len, screen.width, screen.height, active_ws.active_index }) catch "";
                    _ = std.c.write(2, dbg2_msg.ptr, dbg2_msg.len);
                    const rects = mux.layout_engine.calculate(mux.active_workspace, sr) catch null;
                    if (rects) |rs| {
                        defer allocator.free(rs);
                        for (rs, 0..) |rect, idx| {
                            var dbg3: [256]u8 = undefined;
                            const dbg3_msg = std.fmt.bufPrint(&dbg3, "  rect[{d}]: x={d} y={d} w={d} h={d}\n", .{ idx, rect.x, rect.y, rect.width, rect.height }) catch "";
                            _ = std.c.write(2, dbg3_msg.ptr, dbg3_msg.len);
                            if (mouse.col >= rect.x and mouse.col < rect.x + rect.width and
                                mouse.row >= rect.y and mouse.row < rect.y + rect.height)
                            {
                                if (idx < pane_ids.len and active_ws.active_index != idx) {
                                    // Send focus_next/prev to reach target pane.
                                    const current = active_ws.active_index;
                                    const count = pane_ids.len;
                                    if (count > 1) {
                                        const fwd = if (idx > current) idx - current else count - current + idx;
                                        const bwd = if (current > idx) current - idx else count - idx + current;
                                        const cmd = if (fwd <= bwd) daemon_proto.Command.focus_next else daemon_proto.Command.focus_prev;
                                        const steps = if (fwd <= bwd) fwd else bwd;
                                        const cmd_byte = [1]u8{@intFromEnum(cmd)};
                                        for (0..steps) |_| {
                                            _ = daemon_proto.sendMessage(sock, .command, &cmd_byte);
                                        }
                                    }
                                    // Update locally; daemon will confirm via state_sync.
                                    active_ws.active_index = idx;
                                    active_ws.active_node = pane_ids[idx];
                                    needs_render = true;
                                }
                                break;
                            }
                        }
                    }
                }
            }
        }

        // daemon → render
        if (fds[1].revents & POLLIN != 0) {
            var hdr: daemon_proto.Header = undefined;
            var recv_buf: [daemon_proto.max_payload]u8 = undefined;
            while (daemon_proto.recvMessage(sock, &hdr, &recv_buf)) |payload| {
                switch (hdr.tag) {
                    .output => {
                        if (daemon_proto.decodePanePayload(payload)) |pp| {
                            if (mux.getPaneById(pp.pane_id)) |pane| {
                                if (pp.data.len > 0) {
                                    pane.vt.feed(pp.data);
                                    pane.grid.dirty = true;
                                    needs_render = true;
                                }
                            }
                        }
                    },
                    .state_sync => {
                        common.parseDaemonStateSync(sock, &mux, payload);
                        // Resolve active_node to active_index
                        for (&mux.layout_engine.workspaces) |*wsp| {
                            if (wsp.active_node) |node_id| {
                                for (wsp.node_ids.items, 0..) |nid, idx| {
                                    if (nid == node_id) {
                                        wsp.active_index = idx;
                                        break;
                                    }
                                }
                            }
                        }
                        needs_render = true;
                    },
                    .pane_event => {
                        if (payload.len >= 9) {
                            const pane_id = std.mem.readInt(u64, payload[0..8], .little);
                            const event = payload[8];
                            if (event == 1) {
                                mux.closePane(pane_id);
                                needs_render = true;
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        // SIGWINCH → resize
        if (nfds >= 3 and fds[2].revents & POLLIN != 0) {
            var sig_drain: [16]u8 = undefined;
            _ = posix.read(sigwinch_fds[0], &sig_drain) catch {};
            var new_ws: posix.winsize = undefined;
            if (std.c.ioctl(1, posix.T.IOCGWINSZ, &new_ws) == 0) {
                const new_rows: u16 = new_ws.row;
                const new_cols: u16 = new_ws.col;
                if (new_rows != screen.height or new_cols != screen.width) {
                    screen.resize(allocator, new_rows, new_cols) catch {};
                    renderer.invalidate();
                    const new_resize = daemon_proto.encodeResize(new_rows, new_cols);
                    _ = daemon_proto.sendMessage(sock, .resize, &new_resize);
                    needs_render = true;
                }
            }
        }

        // Daemon disconnected
        if (fds[1].revents & (POLLHUP | POLLERR) != 0) {
            common.out("[teru] Session ended\r\n");
            return;
        }

        if (needs_render) {
            renderer.renderWithOpts(&mux, 1, .{ .nested = tui_input.isNested(), .prefix_active = tui_input.isPrefixActive() });
        }
    }
}
