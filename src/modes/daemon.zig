//! Daemon-related entrypoints: headless daemon start (--daemon),
//! session attach/restore flows, and the -n NAME named-session
//! dispatcher. Each function is a thin orchestrator that picks
//! between tui.zig and windowed.zig based on the terminal tier.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");
const common = @import("common.zig");
const windowed = @import("windowed.zig");
const tui = @import("tui.zig");
const Multiplexer = @import("../core/Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Daemon = @import("../server/daemon.zig");
const daemon_proto = @import("../server/protocol.zig");
const McpServer = @import("../agent/McpServer.zig");
const Config = @import("../config/Config.zig");
const Hooks = @import("../config/Hooks.zig");
const Session = @import("../persist/Session.zig");
const render = @import("../render/render.zig");

/// --attach: restore a saved session into windowed mode. Falls back
/// to fresh-start if no saved session exists.
pub fn runAttach(allocator: std.mem.Allocator, io: std.Io, wm_class: ?[]const u8) !void {
    var sess = Session.loadFromFile(common.session_path, allocator, io) catch {
        common.out("[teru] No saved session found, starting fresh\n");
        return windowed.run(allocator, io, null, wm_class);
    };
    defer sess.deinit();

    // Count shell nodes (kind == 0) to determine how many panes to restore.
    var shell_count: u16 = 0;
    for (sess.graph_snapshot) |node| {
        if (node.kind == 0) shell_count += 1;
    }
    if (shell_count == 0) shell_count = 1;

    var msg_buf: [128]u8 = undefined;
    common.outFmt(&msg_buf, "[teru] Restoring session ({d} panes)\n", .{shell_count});

    return windowed.run(allocator, io, .{ .pane_count = shell_count }, wm_class);
}

/// -n NAME: connect to (or start) a named daemon session with full
/// windowed UI. Falls back to TUI in tty environments (SSH).
pub fn runNamed(allocator: std.mem.Allocator, io: std.Io, name: []const u8, template: ?[]const u8, wm_class: ?[]const u8) !void {
    const tier = render.detectTier();
    const use_tui = (tier == .tty);

    // 1. Existing daemon?
    if (Daemon.connectToSession(name)) |sock| {
        var buf: [128]u8 = undefined;
        if (use_tui) {
            common.outFmt(&buf, "[teru] TUI session '{s}'\n", .{name});
            return tui.run(allocator, io, sock);
        } else {
            common.outFmt(&buf, "[teru] Connecting to session '{s}'\n", .{name});
            return windowed.runDaemon(allocator, io, sock, wm_class);
        }
    } else |_| {}

    // 2. Auto-start daemon with optional template (POSIX only).
    if (builtin.os.tag != .windows) {
        if (common.autoStartNamedDaemon(name, template)) {
            var attempts: u32 = 0;
            while (attempts < common.DAEMON_RETRY_ATTEMPTS) : (attempts += 1) {
                if (Daemon.connectToSession(name)) |sock| {
                    var buf: [128]u8 = undefined;
                    if (use_tui) {
                        common.outFmt(&buf, "[teru] TUI session '{s}'\n", .{name});
                        return tui.run(allocator, io, sock);
                    } else {
                        common.outFmt(&buf, "[teru] Connected to session '{s}'\n", .{name});
                        return windowed.runDaemon(allocator, io, sock, wm_class);
                    }
                } else |_| {}
                io.sleep(.fromMilliseconds(common.DAEMON_RETRY_DELAY_MS), .awake) catch {};
            }
        }
    }

    // 3. Fallback.
    if (use_tui) {
        var buf: [128]u8 = undefined;
        common.outFmt(&buf, "[teru] Session '{s}' not available\n", .{name});
        return;
    }
    return windowed.run(allocator, io, null, wm_class);
}

/// persist_session = true: full daemon persistence. Auto-starts
/// daemon, connects windowed UI. Processes survive window close.
pub fn runPersistent(allocator: std.mem.Allocator, io: std.Io, wm_class: ?[]const u8) !void {
    if (Daemon.connectToSession("default")) |sock| {
        common.out("[teru] Connecting to existing daemon\n");
        return windowed.runDaemon(allocator, io, sock, wm_class);
    } else |_| {}

    if (builtin.os.tag != .windows) {
        if (common.autoStartDaemon()) {
            var attempts: u32 = 0;
            while (attempts < common.DAEMON_RETRY_ATTEMPTS) : (attempts += 1) {
                if (Daemon.connectToSession("default")) |sock| {
                    common.out("[teru] Connected to daemon\n");
                    return windowed.runDaemon(allocator, io, sock, wm_class);
                } else |_| {}
                io.sleep(.fromMilliseconds(common.DAEMON_RETRY_DELAY_MS), .awake) catch {};
            }
            common.out("[teru] Daemon failed, falling back to layout restore\n");
        }
    }

    return runRestore(allocator, io, wm_class);
}

/// restore_layout = true: save layout on exit, restore on launch.
/// No daemon, no background process. Lightweight.
pub fn runRestore(allocator: std.mem.Allocator, io: std.Io, wm_class: ?[]const u8) !void {
    const sess_dir = Session.getSessionDir(allocator) catch
        return windowed.run(allocator, io, null, wm_class);
    defer allocator.free(sess_dir);

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/default.bin", .{sess_dir}) catch
        return windowed.run(allocator, io, null, wm_class);

    var sess = Session.loadFromFile(path, allocator, io) catch {
        common.out("[teru] No saved layout, starting fresh\n");
        return windowed.run(allocator, io, null, wm_class);
    };
    defer sess.deinit();

    var restore = common.RestoreInfo{ .pane_count = 0 };
    restore.active_workspace = sess.active_workspace;
    for (sess.workspace_states, 0..) |ws, i| {
        restore.workspace_panes[i] = ws.pane_count;
        restore.workspace_layouts[i] = ws.layout;
        restore.workspace_ratios[i] = ws.master_ratio;
        restore.pane_count += ws.pane_count;
    }
    if (restore.pane_count == 0) restore.pane_count = 1;

    var msg_buf: [128]u8 = undefined;
    common.outFmt(&msg_buf, "[teru] Restoring layout ({d} panes)\n", .{restore.pane_count});

    return windowed.run(allocator, io, restore, wm_class);
}

/// --daemon NAME: start a headless daemon session. PTYs persist
/// after this process forks. Blocks until every pane closes.
pub fn runHeadless(allocator: std.mem.Allocator, io: std.Io, session_name: []const u8, template: ?[]const u8) !void {
    var config = try Config.load(allocator, io);
    defer config.deinit();
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();

    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var mux = Multiplexer.init(allocator);
    mux.graph = &graph;
    mux.spawn_config = .{
        .shell = config.shell,
        .scrollback_lines = config.scrollback_lines,
        .term = config.term,
        .tab_width = config.tab_width,
        .cursor_shape = config.cursor_shape,
    };
    defer mux.deinit();

    // Apply template if provided, otherwise spawn a single default pane.
    if (template) |tmpl| {
        common.applyTemplate(allocator, &mux, &graph, tmpl, io);
    } else {
        const pid = try mux.spawnPane(common.DEFAULT_ROWS, common.DEFAULT_COLS);
        _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = if (mux.getPaneById(pid)) |p| p.childPid() else null }) catch {};
    }
    if (mux.panes.items.len == 0) {
        const pid = try mux.spawnPane(common.DEFAULT_ROWS, common.DEFAULT_COLS);
        _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = if (mux.getPaneById(pid)) |p| p.childPid() else null }) catch {};
    }

    var mcp = McpServer.init(allocator, &mux, &graph) catch null;
    defer if (mcp) |*m| m.deinit();

    var daemon = try Daemon.init(allocator, session_name, &mux, &graph, if (mcp) |*m| m else null, &hooks);
    defer daemon.deinit();
    daemon.persist_session = config.persist_session;
    daemon.io = io;
    mux.persist_session_name = session_name;

    var buf: [128]u8 = undefined;
    common.outFmt(&buf, "[teru] Daemon started: {s}\n", .{daemon.getSocketPath()});

    daemon.run();

    common.outFmt(&buf, "[teru] Daemon {s} exited\n", .{session_name});
}

/// Attach to a running daemon session in TTY raw mode (POSIX only).
/// Distinct from tui.zig — this is a pure byte-relay for shells.
pub fn runSessionAttach(session_name: []const u8) !void {
    if (builtin.os.tag == .windows) return error.Unsupported;
    const sock = Daemon.connectToSession(session_name) catch {
        var buf: [128]u8 = undefined;
        common.outFmt(&buf, "[teru] Session '{s}' not found\n", .{session_name});
        return;
    };
    defer _ = posix.system.close(sock);

    common.out("[teru] Attached to session\n");

    // Raw termios
    var orig_termios: posix.termios = undefined;
    _ = std.c.tcgetattr(0, &orig_termios);
    var raw = orig_termios;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    _ = std.c.tcsetattr(0, .FLUSH, &raw);
    defer _ = std.c.tcsetattr(0, .FLUSH, &orig_termios);

    const flags = std.c.fcntl(sock, posix.F.GETFL);
    if (flags >= 0) _ = std.c.fcntl(sock, posix.F.SETFL, flags | compat.O_NONBLOCK);

    const stdin_flags = std.c.fcntl(0, posix.F.GETFL);
    if (stdin_flags >= 0) _ = std.c.fcntl(0, posix.F.SETFL, stdin_flags | compat.O_NONBLOCK);
    defer _ = std.c.fcntl(0, posix.F.SETFL, stdin_flags);

    var in_buf: [4096]u8 = undefined;
    var out_buf: [4096]u8 = undefined;
    const POLLIN: i16 = 0x001;
    const POLLHUP: i16 = 0x010;

    while (true) {
        var fds = [2]posix.pollfd{
            .{ .fd = 0, .events = POLLIN, .revents = 0 },
            .{ .fd = sock, .events = POLLIN, .revents = 0 },
        };
        _ = posix.poll(&fds, 100) catch continue;

        if (fds[0].revents & POLLIN != 0) {
            const n = posix.read(0, &in_buf) catch break;
            if (n == 0) break;
            // Detach sequence: Ctrl+\ (0x1C)
            for (in_buf[0..n]) |b| {
                if (b == 0x1C) {
                    _ = daemon_proto.sendMessage(sock, .detach, &.{});
                    common.out("\r\n[teru] Detached\r\n");
                    return;
                }
            }
            _ = daemon_proto.sendMessage(sock, .active_input, in_buf[0..n]);
        }

        if (fds[1].revents & POLLIN != 0) {
            var hdr: daemon_proto.Header = undefined;
            while (daemon_proto.recvMessage(sock, &hdr, &out_buf)) |payload| {
                if (hdr.tag == .output) {
                    _ = std.c.write(1, payload.ptr, payload.len);
                }
            }
        }

        if (fds[1].revents & POLLHUP != 0) {
            common.out("\r\n[teru] Session ended\r\n");
            return;
        }
    }
}
