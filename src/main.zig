const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("compat.zig");
const Pty = @import("pty/pty.zig").Pty;
const Multiplexer = @import("core/Multiplexer.zig");
const ProcessGraph = @import("graph/ProcessGraph.zig");
const Terminal = @import("core/Terminal.zig");
const platform = @import("platform/platform.zig");
const render = @import("render/render.zig");
const Ui = @import("render/Ui.zig");
const protocol = @import("agent/protocol.zig");
const McpServer = @import("agent/McpServer.zig");
const McpBridge = @import("agent/McpBridge.zig");
const PaneBackend = @import("agent/PaneBackend.zig");
const build_options = @import("build_options");
const Config = @import("config/Config.zig");
const ConfigWatcher = @import("config/ConfigWatcher.zig");
const Hooks = @import("config/Hooks.zig");
const Selection = @import("core/Selection.zig");
const ViMode = @import("core/ViMode.zig");
const Clipboard = @import("core/Clipboard.zig");
const KeyHandler = @import("core/KeyHandler.zig");
const Grid = @import("core/Grid.zig");
const Scrollback = @import("persist/Scrollback.zig");
// Cross-platform keyboard: selected at comptime per OS.
// macOS/Windows keyboard modules provide the same Keyboard interface as Linux.
const Keyboard = switch (builtin.os.tag) {
    .linux => if (build_options.enable_x11 or build_options.enable_wayland)
        @import("platform/linux/keyboard.zig").Keyboard
    else
        void,
    .macos => @import("platform/macos/keyboard.zig").Keyboard,
    .windows => @import("platform/windows/keyboard.zig").Keyboard,
    else => void,
};

const Session = @import("persist/Session.zig");
const UrlDetector = @import("core/UrlDetector.zig");
const HookListener = @import("agent/HookListener.zig");
const HookHandler = @import("agent/HookHandler.zig");
const SignalManager = @import("core/SignalManager.zig");
const Daemon = @import("server/daemon.zig");
const daemon_proto = @import("server/protocol.zig");

const setenv = if (builtin.os.tag == .windows) struct {
    fn f(_: [*:0]const u8, _: [*:0]const u8, _: c_int) c_int { return 0; }
}.f else struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
}.setenv;

const version = build_options.version;

const session_path = "/tmp/teru-session.bin";

// Default PTY/grid dimensions
const DEFAULT_ROWS: u16 = 24;
const DEFAULT_COLS: u16 = 80;

// Master ratio clamps for mouse drag resize
const MASTER_RATIO_MIN: f32 = 0.15;
const MASTER_RATIO_MAX: f32 = 0.85;

// Timing constants (nanoseconds)
const DOUBLE_CLICK_NS: i128 = 300_000_000; // 300ms
const CURSOR_BLINK_NS: i128 = 530_000_000; // 530ms on/off cycle
const PERSIST_DEBOUNCE_NS: i128 = 100_000_000; // 100ms

// Daemon connection retry parameters
const DAEMON_RETRY_ATTEMPTS: u32 = 20;
const DAEMON_RETRY_DELAY_MS: u32 = 100;

fn out(msg: []const u8) void {
    if (builtin.os.tag == .windows) {
        const k = struct {
            extern "kernel32" fn GetStdHandle(n: u32) callconv(.c) *anyopaque;
        };
        _ = std.c.write(k.GetStdHandle(@bitCast(@as(i32, -11))), msg.ptr, msg.len);
    } else {
        _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
    }
}

fn outFmt(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(buf, fmt, args) catch return;
    out(msg);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Parse command line args (initAllocator required on Windows; works everywhere)
    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip argv[0]

    var mode_raw = false;
    var mode_attach = false;
    var mode_mcp_bridge = false;
    var daemon_session: ?[]const u8 = null;
    var session_name: ?[]const u8 = null; // -n NAME: persistent named session
    var template_name: ?[]const u8 = null; // -t NAME: apply template on start
    var list_sessions = false;
    var wm_class_override: ?[]const u8 = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            var buf: [64]u8 = undefined;
            outFmt(&buf, "teru {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            out(
                \\teru — AI-first terminal emulator
                \\
                \\Usage:
                \\  teru                          Fresh terminal (scratchpad)
                \\  teru -n <name>                Persistent named session
                \\  teru -n <name> -t <template>  Start session from template
                \\  teru -l                       List active sessions
                \\
                \\Options:
                \\  -n, --name <name>       Connect to (or start) named session
                \\  -t, --template <name>   Apply template (.tsess) on first start
                \\  -f, --fresh             Force fresh start (ignore saved layout)
                \\  -l, --list              List active sessions
                \\  -v, --version           Show version
                \\  -h, --help              Show this help
                \\  --raw                   Raw TTY mode (no window)
                \\  --daemon <name>         Start headless daemon (server use)
                \\  --mcp-bridge            MCP stdio bridge
                \\  --class <name>          Set WM_CLASS
                \\
                \\Templates:
                \\  Searched in: ~/.config/teru/templates/, then ./examples/
                \\  Export current session: teru_session_save via MCP
                \\
                \\Keybindings:
                \\  Alt+1-9,0   Switch workspace     Alt+C       New pane
                \\  Alt+J/K     Focus next/prev       Alt+X       Close pane
                \\  Alt+Space   Cycle layout          Alt+Z       Zoom pane
                \\  Alt+V       Vi/copy mode          Alt+D       Detach
                \\  RAlt+J/K    Swap pane              RAlt+H/L   Resize
                \\
                \\
            );
            return;
        }
        if (std.mem.eql(u8, arg, "--raw")) { mode_raw = true; continue; }
        if (std.mem.eql(u8, arg, "--attach")) { mode_attach = true; continue; }
        if (std.mem.eql(u8, arg, "--mcp-bridge")) { mode_mcp_bridge = true; continue; }
        if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) { list_sessions = true; continue; }
        if (std.mem.eql(u8, arg, "--daemon")) { daemon_session = args_iter.next(); continue; }
        if (std.mem.eql(u8, arg, "--session")) { session_name = args_iter.next(); continue; }
        if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) { session_name = args_iter.next(); continue; }
        if (std.mem.eql(u8, arg, "--template") or std.mem.eql(u8, arg, "-t")) { template_name = args_iter.next(); continue; }
        if (std.mem.eql(u8, arg, "--class")) { wm_class_override = args_iter.next(); continue; }
    }
    if (list_sessions) {
        var buf: [1024]u8 = undefined;
        if (Daemon.listSessions(&buf)) |sessions| {
            out("Active sessions:\n");
            out(sessions);
        } else {
            out("No active sessions\n");
        }
        return;
    }

    if (daemon_session) |name| {
        return runDaemonMode(allocator, io, name, template_name);
    }

    // -n NAME: persistent named session (auto-start daemon + connect windowed)
    if (session_name) |name| {
        return runNamedSession(allocator, io, name, template_name, wm_class_override);
    }

    if (mode_mcp_bridge) return McpBridge.run(io);
    if (mode_attach) return runAttachMode(allocator, io, wm_class_override);

    // Detect rendering tier
    const tier = render.detectTier();
    if (tier == .tty or mode_raw) {
        return runRawMode(allocator, io);
    }
    return runWindowedMode(allocator, io, null, wm_class_override);
}

/// Session restore info passed from --attach to runWindowedMode.
const LayoutEngine = @import("tiling/LayoutEngine.zig");

const RestoreInfo = struct {
    pane_count: u16,
    workspace_panes: [10]u16 = .{0} ** 10,
    workspace_layouts: [10]u8 = .{0} ** 10,
    workspace_ratios: [10]f32 = .{0.55} ** 10,
    active_workspace: u8 = 0,
};

fn runAttachMode(allocator: std.mem.Allocator, io: std.Io, wm_class: ?[]const u8) !void {
    var sess = Session.loadFromFile(session_path, allocator, io) catch {
        out("[teru] No saved session found, starting fresh\n");
        return runWindowedMode(allocator, io, null, wm_class);
    };
    defer sess.deinit();

    // Count shell nodes (kind == 0) to determine how many panes to restore
    var shell_count: u16 = 0;
    for (sess.graph_snapshot) |node| {
        if (node.kind == 0) shell_count += 1;
    }
    if (shell_count == 0) shell_count = 1;

    var msg_buf: [128]u8 = undefined;
    outFmt(&msg_buf, "[teru] Restoring session ({d} panes)\n", .{shell_count});

    return runWindowedMode(allocator, io, .{ .pane_count = shell_count }, wm_class);
}

/// -n NAME: connect to (or start) a named daemon session with full windowed UI.
fn runNamedSession(allocator: std.mem.Allocator, io: std.Io, name: []const u8, template: ?[]const u8, wm_class: ?[]const u8) !void {
    // 1. Try connecting to existing daemon (template ignored if daemon exists)
    if (Daemon.connectToSession(name)) |sock| {
        var buf: [128]u8 = undefined;
        outFmt(&buf, "[teru] Connecting to session '{s}'\n", .{name});
        return runWindowedDaemonMode(allocator, io, sock, wm_class);
    } else |_| {}

    // 2. Auto-start daemon with optional template (POSIX only)
    if (builtin.os.tag != .windows) {
        if (autoStartNamedDaemon(name, template)) {
            var attempts: u32 = 0;
            while (attempts < DAEMON_RETRY_ATTEMPTS) : (attempts += 1) {
                if (Daemon.connectToSession(name)) |sock| {
                    var buf: [128]u8 = undefined;
                    outFmt(&buf, "[teru] Connected to session '{s}'\n", .{name});
                    return runWindowedDaemonMode(allocator, io, sock, wm_class);
                } else |_| {}
                io.sleep(.fromMilliseconds(DAEMON_RETRY_DELAY_MS), .awake) catch {}; // sleep failure is harmless
            }
        }
    }

    // 3. Fallback: TTY relay if no display, or fresh windowed if display available
    const tier = render.detectTier();
    if (tier == .tty) {
        var buf: [128]u8 = undefined;
        outFmt(&buf, "[teru] Session '{s}' not available\n", .{name});
        return;
    }
    return runWindowedMode(allocator, io, null, wm_class);
}

/// Fork a daemon with a specific session name.
fn autoStartNamedDaemon(name: []const u8, template: ?[]const u8) bool {
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

/// persist_session = true: full daemon persistence.
/// Auto-starts daemon, connects windowed UI. Processes survive window close.
fn runPersistentMode(allocator: std.mem.Allocator, io: std.Io, wm_class: ?[]const u8) !void {
    // 1. Check if daemon "default" is already running → connect
    if (Daemon.connectToSession("default")) |sock| {
        out("[teru] Connecting to existing daemon\n");
        return runWindowedDaemonMode(allocator, io, sock, wm_class);
    } else |_| {}

    // 2. Auto-start daemon (POSIX only — Windows falls through to restore)
    if (builtin.os.tag != .windows) {
        if (autoStartDaemon()) {
            var attempts: u32 = 0;
            while (attempts < DAEMON_RETRY_ATTEMPTS) : (attempts += 1) {
                if (Daemon.connectToSession("default")) |sock| {
                    out("[teru] Connected to daemon\n");
                    return runWindowedDaemonMode(allocator, io, sock, wm_class);
                } else |_| {}
                io.sleep(.fromMilliseconds(DAEMON_RETRY_DELAY_MS), .awake) catch {};
            }
            out("[teru] Daemon failed, falling back to layout restore\n");
        }
    }

    // 3. Fallback: restore layout from file (no daemon)
    return runRestoreMode(allocator, io, wm_class);
}

/// restore_layout = true: save layout on exit, restore on launch (fresh shells).
/// No daemon, no background process. Lightweight.
fn runRestoreMode(allocator: std.mem.Allocator, io: std.Io, wm_class: ?[]const u8) !void {
    const sess_dir = Session.getSessionDir(allocator) catch
        return runWindowedMode(allocator, io, null, wm_class);
    defer allocator.free(sess_dir);

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/default.bin", .{sess_dir}) catch
        return runWindowedMode(allocator, io, null, wm_class);

    var sess = Session.loadFromFile(path, allocator, io) catch {
        out("[teru] No saved layout, starting fresh\n");
        return runWindowedMode(allocator, io, null, wm_class);
    };
    defer sess.deinit();

    var restore = RestoreInfo{ .pane_count = 0 };
    restore.active_workspace = sess.active_workspace;
    for (sess.workspace_states, 0..) |ws, i| {
        restore.workspace_panes[i] = ws.pane_count;
        restore.workspace_layouts[i] = ws.layout;
        restore.workspace_ratios[i] = ws.master_ratio;
        restore.pane_count += ws.pane_count;
    }
    if (restore.pane_count == 0) restore.pane_count = 1;

    var msg_buf: [128]u8 = undefined;
    outFmt(&msg_buf, "[teru] Restoring layout ({d} panes)\n", .{restore.pane_count});

    return runWindowedMode(allocator, io, restore, wm_class);
}

/// Fork a teru daemon process in the background. Returns true if fork succeeded.
fn autoStartDaemon() bool {
    return autoStartNamedDaemon("default", null);
}


/// Start a headless daemon session. PTYs persist after this process forks.
fn runDaemonMode(allocator: std.mem.Allocator, io: std.Io, session_name: []const u8, template: ?[]const u8) !void {
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

    // Apply template if provided, otherwise spawn a single default pane
    if (template) |tmpl| {
        applyTemplate(allocator, &mux, &graph, tmpl, io);
    } else {
        const pid = try mux.spawnPane(DEFAULT_ROWS, DEFAULT_COLS);
        _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = if (mux.getPaneById(pid)) |p| p.childPid() else null }) catch {};
    }
    // Ensure at least one pane exists
    if (mux.panes.items.len == 0) {
        const pid = try mux.spawnPane(DEFAULT_ROWS, DEFAULT_COLS);
        _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = if (mux.getPaneById(pid)) |p| p.childPid() else null }) catch {};
    }

    // Start MCP server
    var mcp = McpServer.init(allocator, &mux, &graph) catch null;
    defer if (mcp) |*m| m.deinit();

    // Create daemon
    var daemon = try Daemon.init(allocator, session_name, &mux, &graph, if (mcp) |*m| m else null, &hooks);
    defer daemon.deinit();
    daemon.persist_session = config.persist_session;
    daemon.io = io;
    mux.persist_session_name = session_name;

    var buf: [128]u8 = undefined;
    outFmt(&buf, "[teru] Daemon started: {s}\n", .{daemon.getSocketPath()});

    // Run daemon loop (blocks until all panes close)
    daemon.run();

    outFmt(&buf, "[teru] Daemon {s} exited\n", .{session_name});
}

/// Attach to a running daemon session in TTY raw mode (POSIX only).
fn runSessionAttach(session_name: []const u8) !void {
    if (builtin.os.tag == .windows) return error.Unsupported;
    const sock = Daemon.connectToSession(session_name) catch {
        var buf: [128]u8 = undefined;
        outFmt(&buf, "[teru] Session '{s}' not found\n", .{session_name});
        return;
    };
    defer _ = posix.system.close(sock);

    out("[teru] Attached to session\n");

    // Enter raw terminal mode
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

    // Set socket non-blocking
    const flags = std.c.fcntl(sock, posix.F.GETFL);
    if (flags >= 0) _ = std.c.fcntl(sock, posix.F.SETFL, flags | compat.O_NONBLOCK);

    // Set stdin non-blocking
    const stdin_flags = std.c.fcntl(0, posix.F.GETFL);
    if (stdin_flags >= 0) _ = std.c.fcntl(0, posix.F.SETFL, stdin_flags | compat.O_NONBLOCK);
    defer _ = std.c.fcntl(0, posix.F.SETFL, stdin_flags); // restore

    // Relay loop: stdin → daemon, daemon → stdout
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

        // stdin → daemon (as input message)
        if (fds[0].revents & POLLIN != 0) {
            const n = posix.read(0, &in_buf) catch break;
            if (n == 0) break;
            // Check for detach sequence: Ctrl+\ (0x1C)
            for (in_buf[0..n]) |b| {
                if (b == 0x1C) {
                    _ = daemon_proto.sendMessage(sock, .detach, &.{});
                    out("\r\n[teru] Detached\r\n");
                    return;
                }
            }
            _ = daemon_proto.sendMessage(sock, .active_input, in_buf[0..n]);
        }

        // daemon → stdout (raw PTY output)
        if (fds[1].revents & POLLIN != 0) {
            var hdr: daemon_proto.Header = undefined;
            while (daemon_proto.recvMessage(sock, &hdr, &out_buf)) |payload| {
                if (hdr.tag == .output) {
                    _ = std.c.write(1, payload.ptr, payload.len);
                }
            }
        }

        // Daemon disconnected
        if (fds[1].revents & POLLHUP != 0) {
            out("\r\n[teru] Session ended\r\n");
            return;
        }
    }
}

fn runWindowedMode(allocator: std.mem.Allocator, io: std.Io, restore: ?RestoreInfo, wm_class: ?[]const u8) !void {
    return runWindowedModeImpl(allocator, io, restore, null, wm_class);
}

fn runWindowedDaemonMode(allocator: std.mem.Allocator, io: std.Io, daemon_fd: posix.fd_t, wm_class: ?[]const u8) !void {
    return runWindowedModeImpl(allocator, io, null, daemon_fd, wm_class);
}

fn runWindowedModeImpl(allocator: std.mem.Allocator, io: std.Io, restore: ?RestoreInfo, daemon_fd: ?posix.fd_t, wm_class: ?[]const u8) !void {
    // Load configuration from ~/.config/teru/teru.conf (defaults if missing)
    var config = try Config.load(allocator, io);
    defer config.deinit();

    // Watch config file for live reload (inotify, zero polling)
    var config_watcher = ConfigWatcher.init();
    defer if (config_watcher) |*w| w.deinit();

    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var win = try platform.Platform.init(config.initial_width, config.initial_height, "teru", wm_class);
    defer win.deinit();
    win.setOpacity(config.opacity);

    var font_size = config.font_size;
    var atlas = try render.FontAtlas.init(allocator, config.font_path, font_size, io);
    defer atlas.deinit();

    // Load font variants for bold/italic (optional — silently fall back to primary)
    var variant_bold: ?render.FontAtlas.VariantAtlas = null;
    var variant_italic: ?render.FontAtlas.VariantAtlas = null;
    var variant_bold_italic: ?render.FontAtlas.VariantAtlas = null;
    defer if (variant_bold) |*v| v.deinit(allocator);
    defer if (variant_italic) |*v| v.deinit(allocator);
    defer if (variant_bold_italic) |*v| v.deinit(allocator);

    if (config.font_bold) |path| {
        variant_bold = atlas.loadVariant(allocator, path, io) catch null;
    }
    if (config.font_italic) |path| {
        variant_italic = atlas.loadVariant(allocator, path, io) catch null;
    }
    if (config.font_bold_italic) |path| {
        variant_bold_italic = atlas.loadVariant(allocator, path, io) catch null;
    }

    // CPU SIMD renderer — no GPU needed (cursor color from config)
    var renderer = try render.tier.Renderer.initCpuWithCursor(
        allocator,
        config.initial_width,
        config.initial_height,
        atlas.cell_width,
        atlas.cell_height,
        config.cursor_color,
    );
    defer renderer.deinit();
    renderer.updateAtlas(atlas.atlas_data, atlas.atlas_width, atlas.atlas_height);

    // Apply variant atlases to the CPU renderer
    switch (renderer) {
        .cpu => |*cpu| {
            if (variant_bold) |v| cpu.glyph_atlas_bold = v.data;
            if (variant_italic) |v| cpu.glyph_atlas_italic = v.data;
            if (variant_bold_italic) |v| cpu.glyph_atlas_bold_italic = v.data;
        },
        .tty => {},
    }

    const padding: u32 = config.padding;
    var status_bar_h: u32 = if (config.show_status_bar) atlas.cell_height + 4 else 0;
    var grid_cols: u16 = @intCast((config.initial_width -| padding * 2) / atlas.cell_width);
    var grid_rows: u16 = @intCast((config.initial_height -| padding * 2 -| status_bar_h) / atlas.cell_height);

    // Apply padding and full color scheme to renderer
    switch (renderer) {
        .cpu => |*cpu| {
            cpu.padding = padding;
            cpu.scheme = config.colorScheme();
        },
        .tty => {},
    }

    // Multiplexer: manages all panes (linked to process graph for agent rendering)
    var mux = Multiplexer.init(allocator);
    defer mux.deinit();
    mux.graph = &graph;
    mux.spawn_config = .{
        .shell = config.shell,
        .scrollback_lines = config.scrollback_lines,
        .term = config.term,
        .tab_width = config.tab_width,
        .cursor_shape = config.cursor_shape,
    };
    mux.notification_duration_ns = @as(i128, config.notification_duration_ms) * 1_000_000;
    mux.persist_session_name = "default";

    // Apply per-workspace config
    for (0..10) |i| {
        // Layout list takes priority over single layout
        if (config.workspace_layout_counts[i] > 0) {
            mux.layout_engine.workspaces[i].setLayouts(
                config.workspace_layout_lists[i][0..config.workspace_layout_counts[i]],
            );
        } else if (config.workspace_layouts[i]) |layout| {
            mux.layout_engine.workspaces[i].layout = layout;
        }
        if (config.workspace_ratios[i]) |ratio| {
            mux.layout_engine.workspaces[i].master_ratio = ratio;
        }
        if (config.workspace_names[i]) |name| {
            mux.layout_engine.workspaces[i].name = name;
        }
    }

    // Plugin hooks: external commands fired on terminal events
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();
    loadHooks(&config, &hooks);

    // MCP server: exposes pane/graph state to Claude Code over Unix socket
    var mcp = McpServer.init(allocator, &mux, &graph) catch |err| blk: {
        var err_buf: [128]u8 = undefined;
        outFmt(&err_buf, "[teru] MCP server init failed: {s}\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (mcp) |*m| m.deinit();

    // Set screen dimensions and renderer for MCP pane creation + screenshots
    if (mcp) |*m| {
        m.screen_width = config.initial_width;
        m.screen_height = config.initial_height;
        m.cell_width = atlas.cell_width;
        m.cell_height = atlas.cell_height;
        m.padding = padding;
        m.status_bar_h = status_bar_h;
        m.renderer = &renderer;
    }

    // PaneBackend: Claude Code agent team protocol (NDJSON over Unix socket)
    var pane_backend = PaneBackend.init(allocator, &mux, &graph) catch null;
    defer if (pane_backend) |*pb| pb.deinit();

    // Hook listener: receives Claude Code lifecycle events over Unix socket
    var hook_listener = HookListener.init(allocator) catch null;
    defer if (hook_listener) |*hl| hl.deinit();

    // Set env vars so Claude Code instances know about teru's sockets
    if (pane_backend) |*pb| {
        const path = pb.getSocketPath();
        var env_buf: [128:0]u8 = [_:0]u8{0} ** 128;
        @memcpy(env_buf[0..path.len], path);
        _ = setenv("CLAUDE_PANE_BACKEND_SOCKET", &env_buf, 1);
    }
    if (hook_listener) |*hl| {
        const path = hl.getSocketPath();
        var env_buf: [128:0]u8 = [_:0]u8{0} ** 128;
        @memcpy(env_buf[0..path.len], path);
        _ = setenv("TERU_HOOK_SOCKET", &env_buf, 1);
    }
    if (mcp) |*m| {
        const path = m.getSocketPath();
        var env_buf: [128:0]u8 = [_:0]u8{0} ** 128;
        @memcpy(env_buf[0..path.len], path);
        _ = setenv("TERU_MCP_SOCKET", &env_buf, 1);
    }

    // Spawn panes (restore or fresh)
    if (restore) |r| {
        if (r.pane_count > 1 or r.workspace_panes[0] > 0) {
            // Workspace-aware restore: spawn panes into their original workspaces
            for (0..10) |wi| {
                const ws_panes = r.workspace_panes[wi];
                if (ws_panes == 0) continue;

                // Set layout and ratio for this workspace
                mux.layout_engine.workspaces[wi].layout = @enumFromInt(r.workspace_layouts[wi]);
                mux.layout_engine.workspaces[wi].master_ratio = r.workspace_ratios[wi];

                // Switch to this workspace to spawn panes into it
                mux.switchWorkspace(@intCast(wi));
                for (0..ws_panes) |_| {
                    const pid = try mux.spawnPane(grid_rows, grid_cols);
                    if (mux.getPaneById(pid)) |pane| {
                        _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid(), .workspace = @intCast(wi) });
                    }
                    hooks.fire(.spawn);
                }
            }
            // Switch back to the active workspace
            mux.switchWorkspace(r.active_workspace);
        } else {
            // Simple restore: just pane count on workspace 0
            const pid = try mux.spawnPane(grid_rows, grid_cols);
            if (mux.getPaneById(pid)) |pane| {
                _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid() });
            }
            hooks.fire(.spawn);
        }
    } else {
        // Fresh start: single pane
        const pid = try mux.spawnPane(grid_rows, grid_cols);
        if (mux.getPaneById(pid)) |pane| {
            _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid() });
        }
        hooks.fire(.spawn);
    }

    // Keyboard input: xkbcommon translates XCB keycodes → UTF-8
    // Uses the LIVE X11 keymap (supports dvorak, colemak, any layout)
    var keyboard: ?Keyboard = if (Keyboard != void) blk: {
        const x11_info = win.getX11Info();
        if (x11_info) |info| {
            break :blk Keyboard.initFromX11(info.conn, info.root) catch
                (Keyboard.init() catch null);
        } else {
            const result = Keyboard.init();
            // Handle both error-union and plain return (depends on platform)
            break :blk if (@typeInfo(@TypeOf(result)) == .error_union)
                result catch null
            else
                result;
        }
    } else null;
    defer if (Keyboard != void) {
        if (keyboard) |*kb| kb.deinit();
    };

    var prefix = KeyHandler.PrefixState{ .timeout_ns = @as(i128, config.prefix_timeout_ms) * 1_000_000 };
    var selection = Selection{};
    _ = &selection;
    var vi_mode = ViMode{};
    _ = &vi_mode;
    var ralt_held = false; // Right Alt tracked for pane manipulation shortcuts
    _ = &ralt_held;
    var force_redraw: bool = false; // force framebuffer update (workspace switch, etc.)
    _ = &force_redraw;
    var zoom_pending_resize: bool = false; // deferred grid resize after font zoom
    _ = &zoom_pending_resize;
    var zoom_timestamp: i128 = 0; // last zoom event time (ns)
    _ = &zoom_timestamp;
    var mouse_down = false;
    _ = &mouse_down;
    var mouse_start_row: u16 = 0;
    var mouse_start_col: u16 = 0;
    _ = &mouse_start_row;
    _ = &mouse_start_col;
    var border_dragging = false;
    _ = &border_dragging;
    var border_drag_x: u32 = 0; // initial mouse x for drag
    _ = &border_drag_x;
    var border_drag_ratio: f32 = 0.6; // initial ratio
    _ = &border_drag_ratio;
    var border_drag_node: u16 = 0; // split node index for tree drag
    _ = &border_drag_node;
    // Shift+hover URL underline state
    var hover_url_row: u16 = 0;
    var hover_url_start: u16 = 0;
    var hover_url_end: u16 = 0;
    var hover_url_active: bool = false;
    _ = &hover_url_row;
    _ = &hover_url_start;
    _ = &hover_url_end;
    _ = &hover_url_active;
    var pty_buf: [8192]u8 = undefined;
    var running = true;
    var mouse_cursor_hidden = false;
    var last_click_time: i128 = 0;
    var last_click_row: u16 = 0;
    var last_click_col: u16 = 0;
    const default_word_delimiters = " \t{}[]()\"'`,;:@";
    var last_blink_time: i128 = compat.monotonicNow();
    var cursor_blink_visible: bool = true;

    // Scrollback state lives on mux (accessible from McpServer for teru_scroll)
    // No saved_cells needed — scroll is non-destructive (renders overlay on framebuffer)

    // Search mode state (Feature 9)
    var search_mode = false;
    var search_query: [256]u8 = undefined;
    var search_len: usize = 0;
    _ = &search_mode;
    _ = &search_query;
    _ = &search_len;

    while (running) {
        // Check prefix timeout
        if (prefix.isExpired()) {
            prefix.reset();
        }

        while (win.pollEvents()) |event| {
            switch (event) {
                .close => running = false,
                .expose => {
                    // Window exposed (uncovered, mapped, scratchpad toggle)
                    // Force full redraw to prevent black fragments
                    for (mux.panes.items) |*pane| pane.grid.dirty = true;
                },
                .focus_in => {
                    // Reset keyboard modifier state on focus regain.
                    if (Keyboard != void) {
                        if (keyboard) |*kb| kb.resetState();
                    }
                    prefix.reset();
                    // Send focus-in event to PTY (neovim, etc. use this)
                    if (mux.getActivePaneMut()) |pane| {
                        _ = pane.ptyWrite("\x1b[I") catch {};
                    }
                },
                .focus_out => {
                    // Send focus-out event to PTY
                    if (mux.getActivePaneMut()) |pane| {
                        _ = pane.ptyWrite("\x1b[O") catch {};
                    }
                },
                .wl_modifiers => |mods| {
                    // Wayland modifier/layout group update
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            kb.updateModifiers(mods.depressed, mods.latched, mods.locked, mods.group);
                        }
                    }
                },
                .resize => |sz| {
                    // Resize renderer
                    renderer.resize(sz.width, sz.height);

                    // Update MCP screen dimensions
                    if (mcp) |*m| {
                        m.screen_width = sz.width;
                        m.screen_height = sz.height;
                    }

                    // Recalculate grid dimensions
                    const new_cols: u16 = @intCast((sz.width -| padding * 2) / atlas.cell_width);
                    const new_rows: u16 = @intCast((sz.height -| padding * 2 -| status_bar_h) / atlas.cell_height);
                    grid_cols = new_cols;
                    grid_rows = new_rows;

                    // Proportional pane resize: calculate layout rects and
                    // resize each pane to its allocated portion of the screen.
                    const LayoutRect = @import("tiling/LayoutEngine.zig").Rect;
                    const screen_rect = LayoutRect{
                        .x = 0,
                        .y = 0,
                        .width = @intCast(@min(sz.width, std.math.maxInt(u16))),
                        .height = @intCast(@min(sz.height, std.math.maxInt(u16))),
                    };
                    const ws = &mux.layout_engine.workspaces[mux.active_workspace];
                    const node_ids = ws.node_ids.items;
                    if (node_ids.len > 1) {
                        if (mux.layout_engine.calculate(mux.active_workspace, screen_rect)) |rects| {
                            defer allocator.free(rects);
                            for (rects, 0..) |rect, i| {
                                if (i >= node_ids.len) break;
                                if (rect.width == 0 or rect.height == 0) continue;
                                const cw16: u16 = @intCast(atlas.cell_width);
                                const ch16: u16 = @intCast(atlas.cell_height);
                                const pane_cols: u16 = rect.width / cw16;
                                const pane_rows: u16 = rect.height / ch16;
                                if (pane_cols == 0 or pane_rows == 0) continue;
                                if (mux.getPaneById(node_ids[i])) |pane| {
                                    if (pane_cols != pane.grid.cols or pane_rows != pane.grid.rows) {
                                        pane.resize(allocator, pane_rows, pane_cols) catch continue;
                                    }
                                }
                            }
                        } else |_| {
                            // Layout calc failed — fall back to uniform resize
                            for (mux.panes.items) |*pane| {
                                if (new_cols != pane.grid.cols or new_rows != pane.grid.rows) {
                                    pane.resize(allocator, new_rows, new_cols) catch continue;
                                }
                            }
                        }
                    } else {
                        // Single pane: resize to full grid
                        for (mux.panes.items) |*pane| {
                            if (new_cols != pane.grid.cols or new_rows != pane.grid.rows) {
                                pane.resize(allocator, new_rows, new_cols) catch continue;
                            }
                        }
                    }

                    // Exit scroll on resize
                    mux.setScrollOffset(0);
                },
                .key_press => |key| {
                    // Hide mouse cursor while typing
                    if (config.mouse_hide_when_typing and !mouse_cursor_hidden) {
                        win.hideCursor();
                        mouse_cursor_hidden = true;
                    }
                    // Reset cursor blink on keypress (cursor stays solid while typing)
                    if (config.cursor_blink) {
                        cursor_blink_visible = true;
                        last_blink_time = compat.monotonicNow();
                        switch (renderer) {
                            .cpu => |*cpu| cpu.cursor_blink_on = true,
                            .tty => {},
                        }
                    }
                    const XKB_KEY_Page_Up: u32 = 0xff55;
                    const XKB_KEY_Page_Down: u32 = 0xff56;
                    const XKB_KEY_Return: u32 = 0xff0d;
                    const XKB_KEY_Escape: u32 = 0xff1b;
                    const XKB_KEY_BackSpace: u32 = 0xff08;

                    if (key.keycode == platform.types.keycodes.RALT) ralt_held = true;

                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            // Feed key press into xkbcommon for modifier/group tracking.
                            // This handles layout switching (Alt+Shift), Caps Lock, etc.
                            kb.updateKey(key.keycode, true);

                            const keysym = kb.getKeysym(key.keycode);

                            // Vi/copy mode: intercept ALL keys
                            if (vi_mode.active) {
                                // Try keysym first (arrows, PageUp/Down, ESC)
                                const sb_lines: u32 = mux.getScrollbackLineCount();
                                var vi_scroll = mux.getScrollOffset();
                                const ksym_action = vi_mode.handleKeysym(keysym, &vi_scroll, sb_lines);
                                mux.setScrollOffset(vi_scroll);

                                if (ksym_action != .none) {
                                    switch (ksym_action) {
                                        .exit => {
                                            vi_mode.exit();
                                            mux.setScrollOffset(0);
                                        },
                                        .yank => {
                                            if (vi_mode.toYankSelection(sb_lines)) |sel| {
                                                if (mux.getActivePane()) |pane| {
                                                    var sel_buf: [65536]u8 = undefined;
                                                    const sbl = pane.grid.scrollback;
                                                    var sel_copy = sel;
                                                    const len = sel_copy.getText(&pane.grid, sbl, &sel_buf);
                                                    if (len > 0) {
                                                        Clipboard.copy(sel_buf[0..len]);
                                                        mux.notify("Yanked to clipboard");
                                                    }
                                                }
                                            }
                                            vi_mode.exit();
                                            mux.setScrollOffset(0);
                                        },
                                        .search => { search_mode = true; },
                                        .none => {},
                                    }
                                    if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    continue;
                                }

                                // Try as ASCII key byte
                                var vi_key_buf: [32]u8 = undefined;
                                const vi_len = kb.processKey(key.keycode, &vi_key_buf);
                                if (vi_len > 0) {
                                    const active_pane = mux.getActivePane() orelse continue;
                                    vi_scroll = mux.getScrollOffset();
                                    const vi_action = vi_mode.handleKey(vi_key_buf[0], &active_pane.grid, &vi_scroll, sb_lines);
                                    mux.setScrollOffset(vi_scroll);
                                    switch (vi_action) {
                                        .exit => {
                                            vi_mode.exit();
                                            mux.setScrollOffset(0);
                                        },
                                        .yank => {
                                            if (vi_mode.toYankSelection(sb_lines)) |sel| {
                                                if (mux.getActivePane()) |pane| {
                                                    var sel_buf: [65536]u8 = undefined;
                                                    const sbl = pane.grid.scrollback;
                                                    var sel_copy = sel;
                                                    const len = sel_copy.getText(&pane.grid, sbl, &sel_buf);
                                                    if (len > 0) {
                                                        Clipboard.copy(sel_buf[0..len]);
                                                        mux.notify("Yanked to clipboard");
                                                    }
                                                }
                                            }
                                            vi_mode.exit();
                                            mux.setScrollOffset(0);
                                        },
                                        .search => { search_mode = true; },
                                        .none => {},
                                    }
                                    if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                }
                                continue;
                            }

                            // Search mode: intercept all keys for the search query
                            if (search_mode) {
                                var search_key_buf: [32]u8 = undefined;
                                const slen = kb.processKey(key.keycode, &search_key_buf);

                                if (keysym == XKB_KEY_Escape) {
                                    // Cancel search
                                    search_mode = false;
                                    search_len = 0;
                                    if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                } else if (keysym == XKB_KEY_Return) {
                                    // Confirm and exit search
                                    search_mode = false;
                                    if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                } else if (keysym == XKB_KEY_BackSpace) {
                                    if (search_len > 0) {
                                        search_len -= 1;
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                } else if (slen > 0 and search_key_buf[0] >= 32 and search_key_buf[0] < 127) {
                                    // Printable ASCII character
                                    if (search_len < search_query.len) {
                                        search_query[search_len] = search_key_buf[0];
                                        search_len += 1;
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                }
                                continue;
                            }

                            // PageUp/Down: scrollback browsing (with or without Shift)
                            if (keysym == XKB_KEY_Page_Up) {
                                const max_offset = mux.getScrollbackLineCount();
                                if (max_offset > 0) {
                                    mux.setScrollOffset(@min(mux.getScrollOffset() + grid_rows, max_offset));
                                }
                                var dummy: [32]u8 = undefined;
                                _ = kb.processKey(key.keycode, &dummy);
                                continue;
                            } else if (keysym == XKB_KEY_Page_Down) {
                                if (mux.getScrollOffset() > 0) {
                                    { const so = mux.getScrollOffset(); mux.setScrollOffset(so -| grid_rows); }
                                }
                                var dummy: [32]u8 = undefined;
                                _ = kb.processKey(key.keycode, &dummy);
                                continue;
                            }

                            // Ctrl+Shift+C: copy selection to clipboard
                            const CTRL_MASK: u32 = 4;
                            const SHIFT_MASK_COPY: u32 = 1;
                            if (key.modifiers & CTRL_MASK != 0 and key.modifiers & SHIFT_MASK_COPY != 0) {
                                const XKB_KEY_C: u32 = 0x0043;
                                const XKB_KEY_c: u32 = 0x0063;
                                const XKB_KEY_V: u32 = 0x0056;
                                const XKB_KEY_v: u32 = 0x0076;
                                if (keysym == XKB_KEY_C or keysym == XKB_KEY_c) {
                                    // Copy selection
                                    if (selection.active) {
                                        if (mux.getActivePane()) |pane| {
                                            var sel_buf: [65536]u8 = undefined;
                                            const sb = pane.grid.scrollback;
                                            const copy_len = selection.getText(&pane.grid, sb, &sel_buf);
                                            if (copy_len > 0) {
                                                Clipboard.copy(sel_buf[0..copy_len]);
                                                mux.notify("Copied to clipboard");
                                            }
                                        }
                                    }
                                    continue;
                                }
                                if (keysym == XKB_KEY_V or keysym == XKB_KEY_v) {
                                    // Paste (with bracketed paste wrapping)
                                    if (mux.getActivePaneMut()) |pane| {
                                        if (pane.vt.bracketed_paste) {
                                            _ = pane.ptyWrite("\x1b[200~") catch {};
                                        }
                                        Clipboard.paste(&pane.backend.local);
                                        if (pane.vt.bracketed_paste) {
                                            _ = pane.ptyWrite("\x1b[201~") catch {};
                                        }
                                    }
                                    continue;
                                }
                            }

                            var key_buf: [32]u8 = undefined;
                            const len = kb.processKey(key.keycode, &key_buf);

                            // Global shortcuts: Alt+key (workspace, focus, zoom, split)
                            // Checked before len==0 because xkbcommon may produce no
                            // UTF-8 for Alt+symbol keys. Use keysym for the key identity.
                            {
                                const ks_char: u8 = if (keysym > 0x1f and keysym < 0x80) @intCast(keysym) else 0;
                                // Config-driven keybind lookup (normal mode for global shortcuts)
                                const kb_mode: @import("config/Keybinds.zig").Mode = if (prefix.awaiting) .prefix else .normal;
                                if (KeyHandler.lookupConfigAction(&config.keybinds, kb_mode, key.modifiers, ks_char, ralt_held)) |kb_action| {
                                    if (prefix.awaiting) prefix.reset();
                                    const action = KeyHandler.executeAction(kb_action, &mux);
                                    // Handle mode transitions from KB action directly
                                    if (kb_action == .mode_prefix) {
                                        prefix.activate();
                                        continue;
                                    }
                                    if (kb_action == .mode_normal) {
                                        prefix.reset();
                                        continue;
                                    }
                                    if (action == .panes_changed) {
                                        const sz = win.getSize();
                                        mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                        // Force redraw — empty workspaces have no dirty grids
                                        // but the status bar and background still need updating.
                                        for (mux.panes.items) |*p| p.grid.dirty = true;
                                        force_redraw = true;
                                    }
                                    if (action == .close_pane) {
                                        if (mux.getActivePane()) |pane| {
                                            const id = pane.id;
                                            mux.closePane(id);
                                            hooks.fire(.close);
                                            if (mux.panes.items.len == 0) {
                                                running = false;
                                                continue;
                                            }
                                            const sz = win.getSize();
                                            mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                        }
                                    }
                                    if (action == .split_vertical or action == .split_horizontal) {
                                        const dir: @import("tiling/LayoutEngine.zig").SplitDirection = if (action == .split_horizontal) .horizontal else .vertical;
                                        const id = mux.spawnPane(grid_rows, grid_cols) catch continue;
                                        if (mux.getPaneById(id)) |pane| {
                                            _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid() }) catch {};
                                        }
                                        hooks.fire(.spawn);
                                        const ws = &mux.layout_engine.workspaces[mux.active_workspace];
                                        ws.addNodeSplit(mux.allocator, id, dir) catch {};
                                        const sz = win.getSize();
                                        mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                    }
                                    if (action == .enter_search) {
                                        search_mode = true;
                                        continue;
                                    }
                                    if (action == .enter_vi_mode) {
                                        if (mux.getActivePane()) |pane| {
                                            const sb_n: u32 = mux.getScrollbackLineCount();
                                            vi_mode.enter(grid_rows, grid_cols, pane.grid.cursor_row, pane.grid.cursor_col, mux.getScrollOffset(), sb_n);
                                            pane.grid.dirty = true;
                                        }
                                        continue;
                                    }
                                    if (action == .detach) {
                                        const path = "/tmp/teru-session.bin";
                                        mux.saveSession(&graph, path, io) catch {};
                                        hooks.fire(.session_save);
                                        running = false;
                                        continue;
                                    }
                                    if (action == .toggle_zoom) {
                                        const sz = win.getSize();
                                        mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                        for (mux.panes.items) |*p| p.grid.dirty = true;
                                        force_redraw = true;
                                        continue;
                                    }
                                    if (action == .zoom_in or action == .zoom_out or action == .zoom_reset) {
                                        const new_size: u16 = if (action == .zoom_in)
                                            font_size +| 1
                                        else if (action == .zoom_reset)
                                            config.font_size
                                        else
                                            @max(6, font_size -| 1);
                                        if (new_size != font_size) {
                                            // Re-rasterize primary atlas from memory (no file I/O)
                                            const new_atlas = atlas.rasterizeAtSize(new_size) catch continue;
                                            atlas.deinit();
                                            atlas = new_atlas;
                                            font_size = new_size;

                                            // Variants deferred to debounce timer — clear for now
                                            // (renderer falls back to primary atlas for bold/italic)
                                            switch (renderer) {
                                                .cpu => |*cpu| {
                                                    cpu.glyph_atlas_bold = &.{};
                                                    cpu.glyph_atlas_italic = &.{};
                                                    cpu.glyph_atlas_bold_italic = &.{};
                                                },
                                                .tty => {},
                                            }

                                            // Update renderer with new primary atlas
                                            renderer.updateAtlas(atlas.atlas_data, atlas.atlas_width, atlas.atlas_height);
                                            switch (renderer) {
                                                .cpu => |*cpu| {
                                                    cpu.cell_width = atlas.cell_width;
                                                    cpu.cell_height = atlas.cell_height;
                                                },
                                                .tty => {},
                                            }
                                            status_bar_h = if (config.show_status_bar) atlas.cell_height + 4 else 0;

                                            // Resize grid + send SIGWINCH immediately.
                                            // The renderer framebuffer is resized by the
                                            // ConfigureNotify handler, so we must NOT call
                                            // win.setSize() here (would desync framebuffer).
                                            const sz = win.getSize();
                                            grid_cols = @intCast((sz.width -| padding * 2) / atlas.cell_width);
                                            grid_rows = @intCast((sz.height -| padding * 2 -| status_bar_h) / atlas.cell_height);
                                            for (mux.panes.items) |*pane| {
                                                if (grid_rows != pane.grid.rows or grid_cols != pane.grid.cols) {
                                                    pane.grid.resize(allocator, grid_rows, grid_cols) catch {};
                                                    pane.linkVt(allocator);
                                                }
                                                pane.grid.dirty = true;
                                            }
                                            mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);

                                            // Defer variant atlas rebuild (150ms after zoom stops)
                                            zoom_pending_resize = true;
                                            zoom_timestamp = compat.monotonicNow();
                                        }
                                    }
                                    continue;
                                }
                            }

                            // Modifier-only keys (Ctrl, Super, Shift, Alt) produce no output.
                            // Don't exit scroll mode or interfere with anything.
                            if (len == 0) continue;

                            // Exit scroll mode only for keys that type into the terminal:
                            // printable chars, Enter, Backspace, Tab, Space.
                            // Escape sequences (F-keys, arrows) keep scroll position.
                            if (mux.getScrollOffset() > 0 or mux.getScrollPixel() > 0) {
                                const exits_scroll = if (len == 1)
                                    key_buf[0] >= 0x20 or // printable ASCII (includes space, DEL)
                                        key_buf[0] == 0x0D or // Enter
                                        key_buf[0] == 0x0A or // Newline
                                        key_buf[0] == 0x08 or // Backspace
                                        key_buf[0] == 0x09 // Tab
                                else
                                    false; // escape sequences (F-keys, arrows) — don't exit
                                if (exits_scroll) {
                                    mux.setScrollOffset(0);
                                }
                            }

                            // Check for prefix key (default: Ctrl+Space = NUL)
                            if (len == 1 and key_buf[0] == config.prefix_key) {
                                prefix.activate();
                                continue;
                            }

                            if (prefix.awaiting) {
                                prefix.reset();
                                const action = KeyHandler.handleMuxCommand(key_buf[0], &mux, &graph, &hooks, &running, grid_rows, grid_cols, io, config.prefix_key);
                                if (action == .enter_search) search_mode = true;
                                if (action == .enter_vi_mode) {
                                    if (mux.getActivePane()) |pane| {
                                        const sb_n: u32 = mux.getScrollbackLineCount();
                                        vi_mode.enter(grid_rows, grid_cols, pane.grid.cursor_row, pane.grid.cursor_col, mux.getScrollOffset(), sb_n);
                                        pane.grid.dirty = true;
                                    }
                                }
                                if (action == .panes_changed) {
                                    const sz = win.getSize();
                                    mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                    for (mux.panes.items) |*p| p.grid.dirty = true;
                                    force_redraw = true;
                                }
                                if (action == .split_vertical or action == .split_horizontal) {
                                    const dir: @import("tiling/LayoutEngine.zig").SplitDirection = if (action == .split_horizontal) .horizontal else .vertical;
                                    const id = mux.spawnPane(grid_rows, grid_cols) catch continue;
                                    if (mux.getPaneById(id)) |pane| {
                                        _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid() }) catch {};
                                    }
                                    hooks.fire(.spawn);
                                    // Add to split tree
                                    const ws = &mux.layout_engine.workspaces[mux.active_workspace];
                                    ws.addNodeSplit(mux.allocator, id, dir) catch {};
                                    // Resize all PTYs to match new layout
                                    const sz = win.getSize();
                                    mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                }
                                continue;
                            }

                            // Forward key to active pane's PTY.
                            // Alt (Mod1) sends ESC prefix before the character.
                            const ALT_MASK: u32 = 8; // Mod1Mask
                            if (mux.getActivePane()) |pane| {
                                if (key.modifiers & ALT_MASK != 0 and len > 0 and key_buf[0] != 0x1b) {
                                    // Alt+key: send ESC prefix + character
                                    var alt_buf: [33]u8 = undefined;
                                    alt_buf[0] = 0x1b;
                                    @memcpy(alt_buf[1..][0..len], key_buf[0..len]);
                                    _ = pane.ptyWrite(alt_buf[0 .. len + 1]) catch {};
                                } else {
                                    _ = pane.ptyWrite(key_buf[0..len]) catch {};
                                }
                            }
                        }
                    } else {
                        // Fallback: raw keycode passthrough (no xkbcommon)
                        if (key.keycode >= 128) continue; // modifier-only, ignore
                        if (mux.getScrollOffset() > 0) {
                            mux.setScrollOffset(0);
                        }
                        if (prefix.awaiting) {
                            prefix.reset();
                            const action = KeyHandler.handleMuxCommand(@truncate(key.keycode), &mux, &graph, &hooks, &running, grid_rows, grid_cols, io, config.prefix_key);
                            if (action == .enter_search) search_mode = true;
                            if (action == .enter_vi_mode) {
                                if (mux.getActivePane()) |pane| {
                                    const sb_n: u32 = mux.getScrollbackLineCount();
                                    vi_mode.enter(grid_rows, grid_cols, pane.grid.cursor_row, pane.grid.cursor_col, mux.getScrollOffset(), sb_n);
                                    pane.grid.dirty = true;
                                }
                            }
                            if (action == .panes_changed) {
                                const sz = win.getSize();
                                mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                for (mux.panes.items) |*p| p.grid.dirty = true;
                                force_redraw = true;
                            }
                            continue;
                        }
                        if (mux.getActivePane()) |pane| {
                            const byte = [1]u8{@truncate(key.keycode)};
                            _ = pane.ptyWrite(&byte) catch {};
                        }
                    }
                },
                .key_release => |key| {
                    if (key.keycode == platform.types.keycodes.RALT) ralt_held = false;
                    // Feed key release into xkbcommon for modifier/group tracking
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            kb.updateKey(key.keycode, false);
                        }
                    }
                },
                .mouse_press => |mouse| {
                    // Mouse reporting to PTY (modes 1000/1002/1003)
                    if (mux.getActivePaneMut()) |pane| {
                        if (pane.vt.mouse_tracking != .none) {
                            const mcol: u16 = @intCast(@min(mouse.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                            const mrow: u16 = @intCast(@min(mouse.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                            const btn: u8 = switch (mouse.button) {
                                .left => 0,
                                .middle => 1,
                                .right => 2,
                                .scroll_up => 64,
                                .scroll_down => 65,
                            };
                            var mbuf: [32]u8 = undefined;
                            if (pane.vt.mouse_sgr) {
                                const mlen = std.fmt.bufPrint(&mbuf, "\x1b[<{d};{d};{d}M", .{ btn, mcol + 1, mrow + 1 }) catch continue;
                                _ = pane.ptyWrite(mlen) catch {};
                            } else {
                                // X10 legacy encoding
                                if (mcol + 33 < 256 and mrow + 33 < 256) {
                                    mbuf[0] = 0x1b;
                                    mbuf[1] = '[';
                                    mbuf[2] = 'M';
                                    mbuf[3] = @intCast(btn + 32);
                                    mbuf[4] = @intCast(mcol + 33);
                                    mbuf[5] = @intCast(mrow + 33);
                                    _ = pane.ptyWrite(mbuf[0..6]) catch {};
                                }
                            }
                            // Track button state for motion reporting (mode 1002)
                            if (mouse.button == .left) mouse_down = true;
                            // Scroll events: don't consume, let teru handle them too
                            if (mouse.button != .scroll_up and mouse.button != .scroll_down) continue;
                        }
                    }
                    switch (mouse.button) {
                        .left => {
                            // Status bar click: switch workspace
                            if (config.show_status_bar) {
                                const sz = win.getSize();
                                const bar_h: u32 = atlas.cell_height + 4;
                                if (Ui.hitTestStatusBar(&mux, atlas.cell_width, padding, sz.height, bar_h, mouse.x, mouse.y)) |ws| {
                                    mux.switchWorkspace(ws);
                                    const sz2 = win.getSize();
                                    mux.resizePanePtys(sz2.width, sz2.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                    for (mux.panes.items) |*p| p.grid.dirty = true;
                                    force_redraw = true;
                                    continue;
                                }
                            }

                            const col: u16 = @intCast(@min(mouse.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                            const row: u16 = @intCast(@min(mouse.y / atlas.cell_height, @as(u32, grid_rows -| 1)));

                            // Shift+click: open URL under cursor
                            // Prefer OSC 8 hyperlink (explicit), fall back to regex detection
                            const SHIFT_MASK: u32 = 1; // XCB ShiftMask
                            if (mouse.modifiers & SHIFT_MASK != 0) {
                                if (mux.getActivePane()) |pane| {
                                    const cell = pane.grid.cellAtConst(row, col);
                                    if (cell.hyperlink_id != 0) {
                                        // OSC 8 hyperlink — use explicit URI
                                        const entry = &pane.grid.hyperlinks[cell.hyperlink_id];
                                        if (entry.uri_len > 0) {
                                            UrlDetector.openUrl(entry.uri[0..entry.uri_len]);
                                        }
                                    } else if (UrlDetector.findUrlAt(&pane.grid, row, col)) |match| {
                                        // Regex-free URL detection fallback
                                        const row_start = @as(usize, match.row) * @as(usize, pane.grid.cols);
                                        const row_cells = pane.grid.cells[row_start..][0..pane.grid.cols];
                                        var url_buf: [2048]u8 = undefined;
                                        const url_len = UrlDetector.extractUrl(row_cells, match, &url_buf);
                                        if (url_len > 0) {
                                            UrlDetector.openUrl(url_buf[0..url_len]);
                                        }
                                    }
                                }
                                continue;
                            }

                            // Click-to-focus + border drag detection
                            const ClickRect = @import("tiling/LayoutEngine.zig").Rect;
                            const click_ws = &mux.layout_engine.workspaces[mux.active_workspace];

                            var click_ids_buf: [64]u64 = undefined;
                            const click_pane_ids = if (click_ws.split_root != null) blk: {
                                const n = click_ws.getTreePaneIds(&click_ids_buf);
                                break :blk click_ids_buf[0..n];
                            } else click_ws.node_ids.items;

                            if (click_pane_ids.len > 1) {
                                const sz = win.getSize();
                                const click_screen = ClickRect{
                                    .x = @intCast(padding),
                                    .y = @intCast(padding),
                                    .width = @intCast(@min(sz.width -| padding * 2, std.math.maxInt(u16))),
                                    .height = @intCast(@min(sz.height -| padding * 2, std.math.maxInt(u16))),
                                };

                                // Border drag: check if click is on a split or layout border
                                if (click_ws.split_root != null) {
                                    if (mux.layout_engine.workspaces[mux.active_workspace].findSplitForBorder(click_screen, mouse.x, mouse.y, 4)) |hit| {
                                        border_dragging = true;
                                        // Store the correct axis for drag delta
                                        const split_dir = mux.layout_engine.workspaces[mux.active_workspace].split_nodes[hit.node_idx].split.dir;
                                        border_drag_x = if (split_dir == .horizontal) mouse.y else mouse.x;
                                        border_drag_ratio = mux.layout_engine.workspaces[mux.active_workspace].split_nodes[hit.node_idx].split.ratio;
                                        border_drag_node = hit.node_idx;
                                        continue;
                                    }
                                } else if (click_pane_ids.len >= 2) {
                                    // Flat layout: detect master ratio border
                                    const layout = click_ws.layout;
                                    const ratio = click_ws.master_ratio;
                                    const zone: u32 = 4;
                                    const is_vertical = (layout == .master_stack or layout == .three_col);
                                    const is_horizontal = (layout == .dishes);
                                    if (is_vertical) {
                                        const border_x: u32 = @as(u32, click_screen.x) + @as(u32, @intFromFloat(@as(f32, @floatFromInt(click_screen.width)) * ratio));
                                        if (mouse.x >= border_x -| zone and mouse.x <= border_x + zone) {
                                            border_dragging = true;
                                            border_drag_x = mouse.x;
                                            border_drag_ratio = ratio;
                                            border_drag_node = std.math.maxInt(u16); // sentinel: flat layout
                                            continue;
                                        }
                                    } else if (is_horizontal) {
                                        const border_y: u32 = @as(u32, click_screen.y) + @as(u32, @intFromFloat(@as(f32, @floatFromInt(click_screen.height)) * ratio));
                                        if (mouse.y >= border_y -| zone and mouse.y <= border_y + zone) {
                                            border_dragging = true;
                                            border_drag_x = mouse.y; // store Y for horizontal
                                            border_drag_ratio = ratio;
                                            border_drag_node = std.math.maxInt(u16); // sentinel: flat layout
                                            continue;
                                        }
                                    }
                                }

                                // Click-to-focus
                                if (mux.layout_engine.calculate(mux.active_workspace, click_screen)) |click_rects| {
                                    defer allocator.free(click_rects);
                                    for (click_rects, 0..) |cr, ci| {
                                        if (ci >= click_pane_ids.len) break;
                                        if (mouse.x >= cr.x and mouse.x < @as(u32, cr.x) + cr.width and
                                            mouse.y >= cr.y and mouse.y < @as(u32, cr.y) + cr.height)
                                        {
                                            if (click_ws.split_root != null) {
                                                mux.layout_engine.workspaces[mux.active_workspace].active_node = click_pane_ids[ci];
                                            } else if (ci != click_ws.active_index) {
                                                mux.layout_engine.workspaces[mux.active_workspace].active_index = ci;
                                            }
                                            for (mux.panes.items) |*p| p.grid.dirty = true;
                                            break;
                                        }
                                    }
                                } else |_| {}
                            }

                            // Double-click: select word
                            const click_now = compat.monotonicNow();
                            if (click_now - last_click_time < DOUBLE_CLICK_NS and
                                row == last_click_row and col == last_click_col)
                            {
                                if (mux.getActivePane()) |pane| {
                                    const delims = config.word_delimiters orelse default_word_delimiters;
                                    const so = mux.getScrollOffset();
                                    const sbl: u32 = mux.getScrollbackLineCount();
                                    selection.selectWord(&pane.grid, row, col, delims, so, sbl);
                                    pane.grid.dirty = true;
                                    if (config.copy_on_select) {
                                        var sel_buf: [65536]u8 = undefined;
                                        const sb = pane.grid.scrollback;
                                        const len = selection.getText(&pane.grid, sb, &sel_buf);
                                        if (len > 0) {
                                            Clipboard.copy(sel_buf[0..len]);
                                            mux.notify("Copied to clipboard");
                                        }
                                    }
                                }
                                last_click_time = 0; // prevent triple-click triggering
                                continue;
                            }
                            last_click_time = click_now;
                            last_click_row = row;
                            last_click_col = col;

                            // Clear any existing selection on click
                            if (selection.active) {
                                selection.clear();
                                if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                            }
                            // Record click position — don't start selection yet.
                            // Selection only begins on mouse_motion (drag).
                            mouse_start_row = row;
                            mouse_start_col = col;
                            mouse_down = true;
                        },
                        .middle => {
                            // Paste from clipboard (with bracketed paste wrapping)
                            if (mux.getActivePaneMut()) |pane| {
                                if (pane.vt.bracketed_paste) {
                                    _ = pane.ptyWrite("\x1b[200~") catch {};
                                }
                                Clipboard.paste(&pane.backend.local);
                                if (pane.vt.bracketed_paste) {
                                    _ = pane.ptyWrite("\x1b[201~") catch {};
                                }
                            }
                        },
                        .scroll_up => {
                            // Don't scroll teru's scrollback when alt screen is active
                            // (tmux, vim, etc. handle scrolling themselves)
                            const in_alt = if (mux.getActivePane()) |pane| pane.vt.alt_screen else false;
                            if (!in_alt) {
                                const max_offset = mux.getScrollbackLineCount();
                                if (max_offset > 0) {
                                    _ = mux.smoothScroll(@as(i32, @intCast(atlas.cell_height)) * @as(i32, @intCast(config.scroll_speed)), atlas.cell_height, max_offset);
                                }
                            }
                        },
                        .scroll_down => {
                            const in_alt = if (mux.getActivePane()) |pane| pane.vt.alt_screen else false;
                            if (!in_alt) {
                                if (mux.getScrollOffset() > 0 or mux.getScrollPixel() > 0) {
                                    const max_offset = mux.getScrollbackLineCount();
                                    _ = mux.smoothScroll(-@as(i32, @intCast(atlas.cell_height)) * @as(i32, @intCast(config.scroll_speed)), atlas.cell_height, max_offset);
                                }
                            }
                        },
                        else => {},
                    }
                },
                .mouse_release => |mouse| {
                    // Mouse release reporting to PTY
                    if (mux.getActivePaneMut()) |pane| {
                        if (pane.vt.mouse_tracking != .none) {
                            const mcol: u16 = @intCast(@min(mouse.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                            const mrow: u16 = @intCast(@min(mouse.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                            var mbuf: [32]u8 = undefined;
                            if (pane.vt.mouse_sgr) {
                                const btn: u8 = switch (mouse.button) {
                                    .left => 0,
                                    .middle => 1,
                                    .right => 2,
                                    else => 0,
                                };
                                const mlen = std.fmt.bufPrint(&mbuf, "\x1b[<{d};{d};{d}m", .{ btn, mcol + 1, mrow + 1 }) catch continue;
                                _ = pane.ptyWrite(mlen) catch {};
                            } else {
                                if (mcol + 33 < 256 and mrow + 33 < 256) {
                                    mbuf[0] = 0x1b;
                                    mbuf[1] = '[';
                                    mbuf[2] = 'M';
                                    mbuf[3] = 35; // release = button 3
                                    mbuf[4] = @intCast(mcol + 33);
                                    mbuf[5] = @intCast(mrow + 33);
                                    _ = pane.ptyWrite(mbuf[0..6]) catch {};
                                }
                            }
                        }
                    }
                    if (mouse.button == .left and border_dragging) {
                        border_dragging = false;
                        const sz = win.getSize();
                        mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                        continue;
                    }
                    if (mouse.button == .left and mouse_down) {
                        mouse_down = false;
                        // Don't process selection when mouse tracking is active
                        const track_active = if (mux.getActivePane()) |pane| pane.vt.mouse_tracking != .none else false;
                        if (track_active) continue;
                        const col: u16 = @intCast(@min(mouse.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                        const row: u16 = @intCast(@min(mouse.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                        {
                            const so = mux.getScrollOffset();
                            const sbl: u32 = mux.getScrollbackLineCount();
                            selection.update(row, col, so, sbl);
                        }

                        // Only finalize selection if mouse actually moved (not a single click)
                        if (selection.start_row != selection.end_row or selection.start_col != selection.end_col) {
                            selection.finish();
                            if (config.copy_on_select) {
                                if (mux.getActivePane()) |pane| {
                                    var sel_buf: [65536]u8 = undefined;
                                    const sb = pane.grid.scrollback;
                                    const len = selection.getText(&pane.grid, sb, &sel_buf);
                                    if (len > 0) {
                                        Clipboard.copy(sel_buf[0..len]);
                                        mux.notify("Copied to clipboard");
                                    }
                                }
                            }
                        } else {
                            // Single click: clear selection (already cleared on press)
                            selection.clear();
                        }
                    }
                },
                .mouse_motion => |motion| {
                    // Show mouse cursor when mouse moves
                    if (mouse_cursor_hidden) {
                        win.showCursor();
                        mouse_cursor_hidden = false;
                    }
                    // Border drag-to-resize
                    if (border_dragging) {
                        const sz = win.getSize();
                        const ws_mut = &mux.layout_engine.workspaces[mux.active_workspace];
                        if (ws_mut.split_root != null and border_drag_node != std.math.maxInt(u16)) {
                            // Tree split drag — use correct axis based on split direction
                            const SplitNode = @import("tiling/types.zig").SplitNode;
                            const node = ws_mut.split_nodes[border_drag_node];
                            const is_h = switch (node) {
                                .split => |s| s.dir == .horizontal,
                                .leaf => false,
                            };
                            _ = SplitNode;
                            const content_dim = if (is_h) sz.height -| padding * 2 else sz.width -| padding * 2;
                            const mouse_pos = if (is_h) motion.y else motion.x;
                            if (content_dim > 0) {
                                const delta_px: i32 = @as(i32, @intCast(mouse_pos)) - @as(i32, @intCast(border_drag_x));
                                const delta_ratio: f32 = @as(f32, @floatFromInt(delta_px)) / @as(f32, @floatFromInt(content_dim));
                                ws_mut.resizeSplit(border_drag_node, std.math.clamp(border_drag_ratio + delta_ratio, MASTER_RATIO_MIN, MASTER_RATIO_MAX));
                            }
                        } else {
                            // Flat layout master_ratio drag
                            const is_horizontal = (ws_mut.layout == .dishes);
                            const content_size = if (is_horizontal) sz.height -| padding * 2 else sz.width -| padding * 2;
                            const mouse_pos = if (is_horizontal) motion.y else motion.x;
                            if (content_size > 0) {
                                const delta_px: i32 = @as(i32, @intCast(mouse_pos)) - @as(i32, @intCast(border_drag_x));
                                const delta_ratio: f32 = @as(f32, @floatFromInt(delta_px)) / @as(f32, @floatFromInt(content_size));
                                ws_mut.master_ratio = std.math.clamp(border_drag_ratio + delta_ratio, MASTER_RATIO_MIN, MASTER_RATIO_MAX);
                            }
                        }
                        for (mux.panes.items) |*p| p.grid.dirty = true;
                        continue;
                    }
                    // Mouse motion reporting to PTY (modes 1002/1003)
                    if (mux.getActivePaneMut()) |pane| {
                        const report_motion = switch (pane.vt.mouse_tracking) {
                            .any_event => true,
                            .button_event => mouse_down,
                            else => false,
                        };
                        if (report_motion) {
                            const mcol: u16 = @intCast(@min(motion.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                            const mrow: u16 = @intCast(@min(motion.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                            var mbuf: [32]u8 = undefined;
                            if (pane.vt.mouse_sgr) {
                                const btn: u8 = if (mouse_down) 32 else 35; // 32 = motion + left button
                                const mlen = std.fmt.bufPrint(&mbuf, "\x1b[<{d};{d};{d}M", .{ btn, mcol + 1, mrow + 1 }) catch continue;
                                _ = pane.ptyWrite(mlen) catch {};
                            } else {
                                if (mcol + 33 < 256 and mrow + 33 < 256) {
                                    mbuf[0] = 0x1b;
                                    mbuf[1] = '[';
                                    mbuf[2] = 'M';
                                    mbuf[3] = if (mouse_down) 64 else 67; // motion flag + button
                                    mbuf[4] = @intCast(mcol + 33);
                                    mbuf[5] = @intCast(mrow + 33);
                                    _ = pane.ptyWrite(mbuf[0..6]) catch {};
                                }
                            }
                        }
                    }
                    // Shift+hover: detect URL under cursor for underline
                    const SHIFT_MOTION: u32 = 1;
                    if (motion.modifiers & SHIFT_MOTION != 0) {
                        const hcol: u16 = @intCast(@min(motion.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                        const hrow: u16 = @intCast(@min(motion.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                        if (mux.getActivePane()) |pane| {
                            if (UrlDetector.findUrlAt(&pane.grid, hrow, hcol)) |match| {
                                if (!hover_url_active or hover_url_row != match.row or hover_url_start != match.start_col or hover_url_end != match.end_col) {
                                    hover_url_active = true;
                                    hover_url_row = match.row;
                                    hover_url_start = match.start_col;
                                    hover_url_end = match.end_col;
                                    pane.grid.dirty = true;
                                }
                            } else if (hover_url_active) {
                                hover_url_active = false;
                                pane.grid.dirty = true;
                            }
                        }
                    } else if (hover_url_active) {
                        hover_url_active = false;
                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                    }

                    // Only handle selection when mouse tracking is off (app handles mouse)
                    const tracking_active = if (mux.getActivePane()) |pane| pane.vt.mouse_tracking != .none else false;
                    if (mouse_down and !tracking_active) {
                        const col: u16 = @intCast(@min(motion.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                        const row: u16 = @intCast(@min(motion.y / atlas.cell_height, @as(u32, grid_rows -| 1)));

                        // Start selection on first drag movement
                        if (!selection.active) {
                            const so = mux.getScrollOffset();
                            const sbl: u32 = mux.getScrollbackLineCount();
                            selection.begin(mouse_start_row, mouse_start_col, so, sbl);
                        }

                        // Auto-scroll when dragging near viewport edges
                        const in_alt = if (mux.getActivePane()) |pane| pane.vt.alt_screen else false;
                        if (!in_alt) {
                            const sz_scroll = win.getSize();
                            const pane_rect = mux.getActivePaneRect(sz_scroll.width, sz_scroll.height, padding, status_bar_h);
                            const edge_zone = atlas.cell_height;
                            const top_edge = if (pane_rect) |pr| @as(u32, pr.y) else 0;
                            const bot_edge = if (pane_rect) |pr| @as(u32, pr.y) + pr.height else grid_rows * atlas.cell_height;

                            if (motion.y < top_edge + edge_zone) {
                                const max_offset = mux.getScrollbackLineCount();
                                if (max_offset > 0) {
                                    _ = mux.smoothScroll(@as(i32, @intCast(atlas.cell_height)), atlas.cell_height, max_offset);
                                }
                            } else if (motion.y >= bot_edge -| edge_zone) {
                                if (mux.getScrollOffset() > 0) {
                                    const max_offset = mux.getScrollbackLineCount();
                                    _ = mux.smoothScroll(-@as(i32, @intCast(atlas.cell_height)), atlas.cell_height, max_offset);
                                }
                            }
                        }

                        // Update selection AFTER auto-scroll so scroll_offset is current
                        {
                            const so = mux.getScrollOffset();
                            const sbl: u32 = mux.getScrollbackLineCount();
                            selection.update(row, col, so, sbl);
                        }

                        // Mark grid dirty so selection highlight redraws
                        if (mux.getActivePane()) |pane| {
                            pane.grid.dirty = true;
                        }
                    }
                },
                else => {},
            }
        }

        // Track scrollback size before polling so we can pin scroll position
        const sb_count_before: u64 = if (mux.getActivePane()) |pane|
            if (pane.grid.scrollback) |sb| sb.lineCount() else 0
        else
            0;

        // Deferred variant atlas rebuild after font zoom (150ms after last zoom)
        if (zoom_pending_resize) {
            const now = compat.monotonicNow();
            if (now - zoom_timestamp > 150_000_000) {
                zoom_pending_resize = false;

                // Rebuild variant atlases from cached font data (no disk I/O)
                if (variant_bold) |*v| {
                    const new_v = atlas.rasterizeVariant(allocator, v) catch null;
                    v.deinit(allocator);
                    variant_bold = new_v;
                }
                if (variant_italic) |*v| {
                    const new_v = atlas.rasterizeVariant(allocator, v) catch null;
                    v.deinit(allocator);
                    variant_italic = new_v;
                }
                if (variant_bold_italic) |*v| {
                    const new_v = atlas.rasterizeVariant(allocator, v) catch null;
                    v.deinit(allocator);
                    variant_bold_italic = new_v;
                }
                switch (renderer) {
                    .cpu => |*cpu| {
                        cpu.glyph_atlas_bold = if (variant_bold) |v| v.data else &.{};
                        cpu.glyph_atlas_italic = if (variant_italic) |v| v.data else &.{};
                        cpu.glyph_atlas_bold_italic = if (variant_bold_italic) |v| v.data else &.{};
                    },
                    .tty => {},
                }
            }
        }

        // Poll PTYs: local mode reads from PTY fds, daemon mode reads from IPC socket
        const had_output = if (daemon_fd) |dfd|
            pollDaemonOutput(dfd, &mux, &pty_buf)
        else
            mux.pollPtys(&pty_buf);

        // If new lines were added to scrollback, adjust scroll_offset and
        // active selection to keep them pinned to the same content.
        // If the selection overlaps the visible grid (not purely scrollback),
        // clear it — PTY output has changed the cell content underneath.
        if (had_output) {
            if (mux.getActivePane()) |pane| {
                const sb_lines: u32 = if (pane.grid.scrollback) |sb| blk: {
                    const sb_count_after = sb.lineCount();
                    if (sb_count_after > sb_count_before) {
                        const new_lines: u32 = @intCast(sb_count_after - sb_count_before);
                        if (mux.getScrollOffset() > config.scroll_speed) {
                            pane.scroll_offset += new_lines;
                        }
                        if (selection.active) {
                            selection.start_row += new_lines;
                            selection.end_row += new_lines;
                        }
                    }
                    break :blk @intCast(sb_count_after);
                } else 0;

                // Selection that overlaps the grid is now stale — clear it.
                // Selections purely in scrollback remain valid (content is immutable there).
                if (selection.active and selection.end_row >= sb_lines) {
                    selection.clear();
                }
            }
        }

        // Poll MCP server for incoming connections
        if (mcp) |*m| m.poll();

        // Poll PaneBackend for Claude Code agent team protocol
        if (pane_backend) |*pb| {
            pb.poll();
            pb.checkExits();
        }

        // Poll hook listener for Claude Code lifecycle events
        if (hook_listener) |*hl| {
            hl.poll();
            while (hl.nextEvent()) |ev| {
                processHookEvent(&graph, &hooks, ev, allocator);
            }
        }

        // Layout/session save: debounced (100ms after last mutation)
        if ((config.restore_layout or config.persist_session) and mux.persist_dirty) {
            const elapsed = compat.monotonicNow() - mux.persist_dirty_since;
            if (elapsed >= PERSIST_DEBOUNCE_NS) {
                mux.persist_dirty = false;
                persistSave(&mux, &graph, allocator, io);
            }
        }

        // Check for agent protocol events on all panes
        for (mux.panes.items) |*pane| {
            if (pane.vt.consumeAgentEvent()) |payload| {
                if (protocol.parsePayload(payload)) |event_data| {
                    switch (event_data.command) {
                        .start => {
                            const node_id = graph.spawn(.{
                                .name = event_data.name orelse "agent",
                                .kind = .agent,
                                .pid = null,
                                .agent = .{
                                    .group = event_data.group orelse "default",
                                    .role = event_data.role orelse "worker",
                                },
                            }) catch continue;
                            hooks.fire(.agent_start);

                            // Auto-workspace: if group specified, move to/create workspace
                            if (event_data.group) |group_name| {
                                autoAssignAgentWorkspace(&mux, node_id, group_name);
                            }
                        },
                        .stop => {
                            // Find agent node by name and mark finished
                            if (event_data.name) |name| {
                                markAgentFinished(&graph, name, event_data.exit_status);
                            }
                        },
                        .status => {
                            // Update progress/task on the agent node
                            if (event_data.name) |name| {
                                updateAgentStatusByName(&graph, name, event_data.task_desc, event_data.progress);
                            }
                        },
                        .task => {
                            if (event_data.name) |name| {
                                updateAgentStatusByName(&graph, name, event_data.task_desc, null);
                            }
                        },
                        .group => {}, // handled at start
                        .meta => {}, // future use
                    }
                }
            }
        }

        // Window title: update from active pane's VT parser
        if (mux.getActivePane()) |pane| {
            if (pane.vt.title_changed) {
                if (pane.vt.title_len > 0) {
                    win.setTitle(pane.vt.title[0..pane.vt.title_len]);
                }
                pane.vt.title_changed = false;
            }
        }

        // Live config reload (inotify — triggers only on file change)
        if (config_watcher) |*w| {
            if (w.poll()) {
                if (Config.reload(allocator, io)) |new_config| {
                    // Apply hot-reloadable values
                    switch (renderer) {
                        .cpu => |*cpu| {
                            cpu.scheme = new_config.colorScheme();
                            cpu.padding = new_config.padding;
                        },
                        .tty => {},
                    }
                    win.setOpacity(new_config.opacity);
                    mux.notification_duration_ns = @as(i128, new_config.notification_duration_ms) * 1_000_000;
                    prefix.timeout_ns = @as(i128, new_config.prefix_timeout_ms) * 1_000_000;

                    // Hot-reload per-workspace layout lists and ratios
                    // (names are not hot-reloaded — they're owned by Config and freed below)
                    for (0..10) |i| {
                        if (new_config.workspace_layout_counts[i] > 0) {
                            mux.layout_engine.workspaces[i].setLayouts(
                                new_config.workspace_layout_lists[i][0..new_config.workspace_layout_counts[i]],
                            );
                        }
                        if (new_config.workspace_ratios[i]) |ratio| {
                            mux.layout_engine.workspaces[i].master_ratio = ratio;
                        }
                    }

                    // Update config fields that don't need subsystem propagation
                    config.scroll_speed = new_config.scroll_speed;
                    config.cursor_blink = new_config.cursor_blink;
                    config.cursor_shape = new_config.cursor_shape;
                    config.bold_is_bright = new_config.bold_is_bright;
                    config.bell = new_config.bell;
                    config.copy_on_select = new_config.copy_on_select;
                    config.mouse_hide_when_typing = new_config.mouse_hide_when_typing;
                    config.restore_layout = new_config.restore_layout;
                    config.persist_session = new_config.persist_session;
                    config.show_status_bar = new_config.show_status_bar;

                    // Force full redraw
                    for (mux.panes.items) |*pane| pane.grid.dirty = true;
                    mux.notify("Config reloaded");

                    // Free the new config's allocated strings (we only copied scalars)
                    var tmp = new_config;
                    tmp.deinit();
                }
            }
        }

        // Check if any pane's grid is dirty
        var any_dirty = had_output or force_redraw;
        force_redraw = false;
        if (!any_dirty) {
            for (mux.panes.items) |*pane| {
                if (pane.grid.dirty) {
                    any_dirty = true;
                    break;
                }
            }
        }

        // Cursor blink timer
        if (config.cursor_blink) {
            const now_blink = compat.monotonicNow();
            if (now_blink - last_blink_time >= CURSOR_BLINK_NS) {
                cursor_blink_visible = !cursor_blink_visible;
                last_blink_time = now_blink;
                any_dirty = true;
            }
            switch (renderer) {
                .cpu => |*cpu| cpu.cursor_blink_on = cursor_blink_visible,
                .tty => {},
            }
        }

        // Synchronized output (DEC 2026): defer rendering while an app is
        // sending a batch of screen updates. Prevents flickering in TUI apps
        // like Claude Code that rapidly rewrite the screen.
        var sync_active = false;
        for (mux.panes.items) |*pane| {
            if (pane.vt.sync_output) {
                sync_active = true;
                break;
            }
        }

        if (any_dirty and !sync_active) {
            // Bell handling (configurable: visual or none)
            if (config.bell == .visual) {
                for (mux.panes.items) |*pane| {
                    if (pane.grid.bell) {
                        pane.grid.bell = false;
                        switch (renderer) {
                            .cpu => |*cpu| {
                                for (cpu.framebuffer) |*pixel| {
                                    pixel.* ^= 0x00FFFFFF;
                                }
                            },
                            .tty => {},
                        }
                    }
                }
            } else {
                for (mux.panes.items) |*pane| pane.grid.bell = false;
            }

            // Get the underlying SoftwareRenderer for multi-pane rendering
            switch (renderer) {
                .cpu => |*cpu| {
                    const sz = win.getSize();
                    // Use vi mode selection if active, else mouse selection
                    const vi_sb: u32 = mux.getScrollbackLineCount();
                    var vi_sel = if (vi_mode.active) vi_mode.toSelection(mux.getScrollOffset(), vi_sb) else null;
                    const sel_ptr: ?*const Selection = if (vi_sel != null) &vi_sel.? else if (selection.active) &selection else null;
                    mux.renderAllWithSelection(cpu, sz.width, sz.height, atlas.cell_width, atlas.cell_height, sel_ptr, status_bar_h);

                    // Search overlay: highlight matches + draw search bar
                    if (search_mode or search_len > 0) {
                        if (mux.getActivePane()) |pane| {
                            Ui.renderSearchOverlay(cpu, &pane.grid, search_query[0..search_len], search_mode, atlas.cell_width, atlas.cell_height);
                        }
                    }

                    // Scroll overlay: render scrollback lines within the active pane's rect
                    if (mux.getScrollOffset() > 0 or mux.getScrollPixel() > 0) {
                        if (mux.getActivePane()) |pane| {
                            if (pane.grid.scrollback) |sb| {
                                if (mux.getActivePaneRect(sz.width, sz.height, cpu.padding, status_bar_h)) |pane_rect| {
                                    Ui.renderScrollOverlay(cpu, sb, mux.getScrollOffset(), atlas.cell_width, atlas.cell_height, pane_rect, mux.getScrollPixel(), sel_ptr);
                                }
                            }
                        }
                    }

                    // Shift+hover URL underline
                    if (hover_url_active) {
                        if (mux.getActivePaneRect(sz.width, sz.height, cpu.padding, status_bar_h)) |pr| {
                            const cw = atlas.cell_width;
                            const ch = atlas.cell_height;
                            // Draw 1px underline at the bottom of each cell in the URL
                            var ucol: u16 = hover_url_start;
                            while (ucol <= hover_url_end) : (ucol += 1) {
                                const ux = @as(usize, pr.x) + @as(usize, ucol) * cw;
                                const uy = @as(usize, pr.y) + @as(usize, hover_url_row) * ch + ch - 1;
                                if (uy >= cpu.height) break;
                                const ux_end = @min(ux + cw, @as(usize, pr.x) + pr.width);
                                if (ux >= cpu.width or ux >= ux_end) continue;
                                const row_start = uy * cpu.width;
                                if (row_start + ux_end <= cpu.framebuffer.len) {
                                    @memset(cpu.framebuffer[row_start + ux .. row_start + ux_end], cpu.scheme.cursor);
                                }
                            }
                        }
                    }

                    // Vi mode cursor overlay (inverted block)
                    if (vi_mode.active) {
                        if (vi_mode.viewportRow(mux.getScrollOffset(), vi_sb)) |vrow| {
                            if (mux.getActivePaneRect(sz.width, sz.height, cpu.padding, status_bar_h)) |pr| {
                                const cx = pr.x + @as(u16, vi_mode.cursor_col) * atlas.cell_width;
                                const cy = pr.y + vrow * atlas.cell_height;
                                const max_x = @min(cx + atlas.cell_width, pr.x + pr.width);
                                const max_y = @min(cy + atlas.cell_height, pr.y + pr.height);
                                for (cy..max_y) |py| {
                                    if (py >= cpu.height) break;
                                    for (cx..max_x) |px| {
                                        if (px >= cpu.width) break;
                                        const idx = py * cpu.width + px;
                                        if (idx < cpu.framebuffer.len) {
                                            cpu.framebuffer[idx] ^= 0x00FFFFFF; // invert RGB
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Status bar
                    if (config.show_status_bar) {
                        Ui.renderTextStatusBar(cpu, &mux, grid_cols, grid_rows, atlas.cell_width, atlas.cell_height, prefix.awaiting, vi_mode.modeString());
                    }

                    win.putFramebuffer(cpu.getFramebuffer(), sz.width, sz.height);
                },
                .tty => {},
            }
            // Clear dirty flags
            for (mux.panes.items) |*pane| {
                pane.grid.dirty = false;
            }

            // Frame rate limiter: cap at ~120fps to prevent CPU spin.
            // Without this, continuous PTY output (e.g., Claude Code) causes
            // 100% CPU on one core because the loop never sleeps when dirty.
            io.sleep(.fromMilliseconds(8), .awake) catch {}; // sleep failure is harmless
        } else {
            // Idle: sleep longer when nothing to render
            io.sleep(.fromMilliseconds(16), .awake) catch {}; // sleep failure is harmless
        }
    }

    // Final layout save on exit
    if (config.restore_layout or config.persist_session) {
        persistSave(&mux, &graph, allocator, io);
    }
}

/// Poll daemon IPC socket for tagged PTY output and feed to the right pane's VtParser.
/// Returns true if any output was received.
fn pollDaemonOutput(fd: posix.fd_t, mux: *Multiplexer, buf: []u8) bool {
    var any = false;
    var hdr: daemon_proto.Header = undefined;
    var recv_buf: [daemon_proto.max_payload]u8 = undefined;
    _ = buf;

    // Non-blocking read of all available messages
    while (daemon_proto.recvMessage(fd, &hdr, &recv_buf)) |payload| {
        switch (hdr.tag) {
            .output => {
                // Payload: [8-byte pane_id LE][PTY data]
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
                // Pane created/closed on daemon side
                if (payload.len >= 9) {
                    const pane_id = std.mem.readInt(u64, payload[0..8], .little);
                    const event = payload[8];
                    if (event == 1) {
                        // Pane closed — remove from local mux
                        mux.closePane(pane_id);
                    }
                    // event == 0 (created) handled via state_sync
                }
                any = true;
            },
            else => {},
        }
    }
    return any;
}

/// Parse state_sync from daemon and create/update remote panes in the multiplexer.
/// Format: [active_ws:1][ws_count:1][per-ws: layout:1 + pane_count:1 × N]
///         [per-pane: pane_id:8 + rows:2 + cols:2 + ws_idx:1]
/// Parse state_sync from daemon and create/update remote panes.
/// Restores exact workspace position, active pane, layout, ratio, and zoom.
/// Format: [active_ws:1][ws_count:1]
///   per-ws × N: [layout:1][pane_count:1][active_node:1][ratio_x100:1][zoomed:1]
///   per-pane (ordered by workspace position): [pane_id:8][rows:2][cols:2][ws_idx:1]
fn parseDaemonStateSync(daemon_fd: posix.fd_t, mux: *Multiplexer, payload: []const u8) void {
    if (payload.len < 2) return;
    const active_ws = payload[0];
    const ws_count = @min(payload[1], 10);
    var pos: usize = 2;

    const LE = @import("tiling/LayoutEngine.zig");

    // Parse per-workspace info (12 bytes each):
    //   [layout:1][pane_count:1][ratio_x100:1][reserved:1][active_pane_id:8]
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

    // Parse per-pane info and create remote panes (preserving workspace order)
    const Pane = @import("core/Pane.zig");
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
fn sendDaemonCommand(fd: posix.fd_t, cmd: daemon_proto.Command, arg: ?u8) void {
    var buf: [2]u8 = undefined;
    buf[0] = @intFromEnum(cmd);
    const len: usize = if (arg) |a| blk: {
        buf[1] = a;
        break :blk 2;
    } else 1;
    _ = daemon_proto.sendMessage(fd, .command, buf[0..len]);
}

/// Send keyboard input to daemon's active pane.
fn sendDaemonInput(fd: posix.fd_t, data: []const u8) void {
    _ = daemon_proto.sendMessage(fd, .active_input, data);
}

/// Save session state to the persist directory (best-effort, errors silently ignored).
/// Resolve a template name to a file path. Search order:
/// 1. Exact path (contains '/' or ends with '.tsess')
/// 2. ~/.config/teru/templates/<name>.tsess
/// 3. ./examples/<name>.tsess
fn resolveTemplatePath(name: []const u8, buf: *[512]u8) ?[]const u8 {
    // Exact path
    if (std.mem.indexOf(u8, name, "/") != null or std.mem.endsWith(u8, name, ".tsess")) {
        if (name.len < buf.len) {
            @memcpy(buf[0..name.len], name);
            return buf[0..name.len];
        }
        return null;
    }

    // ~/.config/teru/templates/<name>.tsess
    const home = compat.getenv("HOME") orelse "/tmp";
    if (std.fmt.bufPrint(buf, "{s}/.config/teru/templates/{s}.tsess", .{ home, name })) |path| {
        // Check if file exists using C fopen
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

    // ./examples/<name>.tsess
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

/// Apply a .tsess template: parse it, create workspaces and panes as defined.
fn applyTemplate(allocator: std.mem.Allocator, mux: *Multiplexer, graph: *ProcessGraph, template: []const u8, _: std.Io) void {
    var path_buf: [512]u8 = undefined;
    const path = resolveTemplatePath(template, &path_buf) orelse {
        var msg: [128]u8 = undefined;
        outFmt(&msg, "[teru] Template '{s}' not found\n", .{template});
        return;
    };

    // Read template file
    const SessionConfig = @import("config/Session.zig");
    var file_path_z: [513:0]u8 = undefined;
    if (path.len >= file_path_z.len) return;
    @memcpy(file_path_z[0..path.len], path);
    file_path_z[path.len] = 0;

    var file_buf: [SessionConfig.max_file_size]u8 = undefined;
    var file_len: usize = 0;
    {
        const f = std.c.fopen(@ptrCast(file_path_z[0..path.len :0]), "r");
        if (f == null) {
            var msg: [128]u8 = undefined;
            outFmt(&msg, "[teru] Cannot read template: {s}\n", .{path});
            return;
        }
        file_len = std.c.fread(&file_buf, 1, file_buf.len, f.?);
        _ = std.c.fclose(f.?);
    }
    if (file_len == 0) return;

    var def = SessionConfig.parse(allocator, file_buf[0..file_len]) catch {
        var msg: [128]u8 = undefined;
        outFmt(&msg, "[teru] Failed to parse template: {s}\n", .{path});
        return;
    };
    defer def.deinit();

    // Restore: creates panes in workspaces as defined by the template
    SessionConfig.restore(&def, mux, graph, DEFAULT_ROWS, DEFAULT_COLS);

    var msg: [128]u8 = undefined;
    outFmt(&msg, "[teru] Applied template '{s}' ({d} workspaces)\n", .{ template, def.workspace_count });
}

fn persistSave(mux: *Multiplexer, graph: *const ProcessGraph, allocator: std.mem.Allocator, io: std.Io) void {
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

/// Fill the grid with scrollback + saved screen content for browsing mode.
/// The virtual viewport is: [scrollback lines] ++ [saved screen lines].
/// Transfer hook commands from Config into the Hooks struct.
fn loadHooks(config: *const Config, hooks: *Hooks) void {
    if (config.hook_on_spawn) |cmd| hooks.setHook(.spawn, cmd);
    if (config.hook_on_close) |cmd| hooks.setHook(.close, cmd);
    if (config.hook_on_agent_start) |cmd| hooks.setHook(.agent_start, cmd);
    if (config.hook_on_session_save) |cmd| hooks.setHook(.session_save, cmd);
}

// ── Agent lifecycle helpers ────────────────────────────────────

/// Assign an agent node to a workspace matching its group name.
/// Uses a simple hash of the group name to pick workspace 1-8.
fn autoAssignAgentWorkspace(mux: *Multiplexer, node_id: u64, group: []const u8) void {
    // Hash group name to a workspace index (1-8, workspace 0 is the default shell workspace)
    var hash: u32 = 0;
    for (group) |c| {
        hash = hash *% 31 +% c;
    }
    const ws: u8 = @truncate((hash % 8) + 1);

    // Ensure the pane is in the layout engine's workspace
    const ws_engine = &mux.layout_engine.workspaces[ws];
    ws_engine.addNode(mux.allocator, node_id) catch {
        // Layout tracking failure — agent runs but won't appear in workspace view
        return;
    };

    // Update the graph node's workspace
    if (mux.graph) |g| {
        g.moveToWorkspace(node_id, ws);
    }
}

/// Mark an agent as finished by looking it up by name.
fn markAgentFinished(graph: *ProcessGraph, name: []const u8, exit_status: ?[]const u8) void {
    const node_id = graph.findAgentByName(name) orelse return;
    const exit_code: u8 = if (exit_status) |status| blk: {
        if (std.mem.eql(u8, status, "success") or std.mem.eql(u8, status, "0")) {
            break :blk 0;
        }
        break :blk 1;
    } else 1;
    graph.markFinished(node_id, exit_code);
}

/// Update an agent's task description and progress by name.
fn updateAgentStatusByName(graph: *ProcessGraph, name: []const u8, task: ?[]const u8, progress: ?f32) void {
    const node_id = graph.findAgentByName(name) orelse return;
    graph.updateAgentStatus(node_id, task, progress);
}

/// Process a Claude Code hook event: update ProcessGraph and fire hooks.
fn processHookEvent(
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
        .subagent_stop => |e| {
            markAgentFinished(graph, e.agent_id, null);
        },
        .teammate_idle => |e| {
            // Mark agent as paused (idle)
            if (graph.findAgentByName(e.agent_id)) |node_id| {
                if (graph.nodes.getPtr(node_id)) |node| {
                    node.state = .paused;
                }
            }
        },
        .task_created => |e| {
            // Find the most recent agent and update its task description
            updateLatestAgentTask(graph, e.description);
        },
        .task_completed => {
            // Task done — no graph update needed (agent stop handles lifecycle)
        },
        .pre_tool_use => |e| {
            // Update the most recent running agent's task to show tool activity
            updateLatestAgentTask(graph, e.tool_name);
        },
        .post_tool_use => {
            // Clear tool activity (agent returns to default task)
        },
        .post_tool_use_failure => {
            // Could mark agent border red briefly — for now, just clear
        },
        .session_start => {
            // Could show session indicator in status bar
        },
        .session_end => {
            // Could clean up session-related graph nodes
        },
        .stop => {
            // Agent finished a turn — mark as paused (waiting for input)
        },
        .stop_failure => {
            // Rate limit or billing error — could show in status bar
        },
        .notification => {
            // Permission prompt or idle notification — future: inline approval widget
        },
        .pre_compact, .post_compact => {
            // Future: context gauge in status bar
        },
        .unknown => {},
    }
}

/// Update the most recently spawned running agent's task description.
fn updateLatestAgentTask(graph: *ProcessGraph, task: []const u8) void {
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
    if (latest_id) |id| {
        graph.updateAgentStatus(id, task, null);
    }
}

fn runRawMode(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var terminal = Terminal.init();
    defer terminal.deinit();

    const size = terminal.getSize() catch Terminal.TermSize{ .rows = DEFAULT_ROWS, .cols = DEFAULT_COLS };

    var buf: [256]u8 = undefined;
    outFmt(&buf, "\x1b[38;5;208m[teru {s}]\x1b[0m AI-first terminal · {d}x{d}\n", .{ version, size.cols, size.rows });

    var pty_inst = try Pty.spawn(.{ .rows = size.rows, .cols = size.cols });
    defer pty_inst.deinit();

    const node_id = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = if (builtin.os.tag == .windows) null else pty_inst.child_pid });

    var sig = SignalManager.init(pty_inst.master, terminal.hostFd());
    sig.registerWinch();

    try terminal.enterRawMode();
    out("\x1b[2J\x1b[H");
    terminal.runLoop(&pty_inst) catch |err| {
        var ebuf: [128]u8 = undefined;
        outFmt(&ebuf, "[teru] terminal loop error: {s}\n", .{@errorName(err)});
    };
    terminal.exitRawMode();

    if (pty_inst.child_pid != null) {
        const status = pty_inst.waitForExit() catch 0;
        graph.markFinished(node_id, @truncate(status >> 8));
    }
    outFmt(&buf, "\n\x1b[38;5;208m[teru]\x1b[0m session ended · {d} node(s)\n", .{graph.nodeCount()});
}


