const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Pty = @import("pty/Pty.zig");
const Multiplexer = @import("core/Multiplexer.zig");
const ProcessGraph = @import("graph/ProcessGraph.zig");
const Terminal = @import("core/Terminal.zig");
const platform = @import("platform/platform.zig");
const render = @import("render/render.zig");
const protocol = @import("agent/protocol.zig");
const McpServer = @import("agent/McpServer.zig");
const PaneBackend = @import("agent/PaneBackend.zig");
const build_options = @import("build_options");
const Config = @import("config/Config.zig");
const Hooks = @import("config/Hooks.zig");
const Selection = @import("core/Selection.zig");
const Clipboard = @import("core/Clipboard.zig");
const KeyHandler = @import("core/KeyHandler.zig");
const Grid = @import("core/Grid.zig");
const Scrollback = @import("persist/Scrollback.zig");
const Keyboard = if (builtin.os.tag == .linux and (build_options.enable_x11 or build_options.enable_wayland))
    @import("platform/linux/keyboard.zig").Keyboard
else
    void;

const Session = @import("persist/Session.zig");
const UrlDetector = @import("core/UrlDetector.zig");
const HookListener = @import("agent/HookListener.zig");
const HookHandler = @import("agent/HookHandler.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const version = "0.1.3";

const session_path = "/tmp/teru-session.bin";

fn out(msg: []const u8) void {
    _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
}

fn outFmt(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(buf, fmt, args) catch return;
    out(msg);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Parse command line args
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip argv[0]
    const first_arg: ?[:0]const u8 = args_iter.next();

    if (first_arg) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var buf: [64]u8 = undefined;
            outFmt(&buf, "teru {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            out("teru — AI-first terminal emulator\n\nUsage: teru [options]\n\nOptions:\n  --help       Show this help\n  --version    Show version\n  --raw        Raw passthrough mode (no window)\n  --attach     Restore session from last detach\n\nMultiplexer keys (prefix: Ctrl+Space):\n  c     Spawn new pane\n  x     Close active pane\n  n     Focus next pane\n  p     Focus prev pane\n  1-9   Switch workspace\n  Space Cycle layout\n  d     Detach (save session, exit)\n  /     Search visible grid\n\nScrollback:\n  Shift+PageUp    Scroll up one page\n  Shift+PageDown  Scroll down one page\n  Any key         Exit scroll mode\n\nURL detection:\n  Ctrl+click on a URL to open in browser\n\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--attach")) {
            return runAttachMode(allocator, io);
        }
        if (std.mem.eql(u8, arg, "--raw")) {
            return runRawMode(allocator, io);
        }
    }

    // Detect rendering tier
    const tier = render.detectTier();
    if (tier == .tty) {
        return runRawMode(allocator, io); // No display server, fall back to TTY
    }
    return runWindowedMode(allocator, io, null);
}

/// Session restore info passed from --attach to runWindowedMode.
const RestoreInfo = struct {
    pane_count: u16,
};

fn runAttachMode(allocator: std.mem.Allocator, io: std.Io) !void {
    var sess = Session.loadFromFile(session_path, allocator, io) catch {
        out("[teru] No saved session found, starting fresh\n");
        return runWindowedMode(allocator, io, null);
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

    return runWindowedMode(allocator, io, .{ .pane_count = shell_count });
}

fn runWindowedMode(allocator: std.mem.Allocator, io: std.Io, restore: ?RestoreInfo) !void {
    // Load configuration from ~/.config/teru/teru.conf (defaults if missing)
    var config = try Config.load(allocator, io);
    defer config.deinit();

    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var win = try platform.Platform.init(config.initial_width, config.initial_height, "teru");
    defer win.deinit();

    var atlas = try render.FontAtlas.init(allocator, config.font_path, config.font_size, io);
    defer atlas.deinit();

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

    const padding: u32 = 4; // must match SoftwareRenderer.padding
    var grid_cols: u16 = @intCast((config.initial_width -| padding * 2) / atlas.cell_width);
    var grid_rows: u16 = @intCast((config.initial_height -| padding * 2) / atlas.cell_height);

    // Multiplexer: manages all panes (linked to process graph for agent rendering)
    var mux = Multiplexer.init(allocator);
    defer mux.deinit();
    mux.graph = &graph;

    // Plugin hooks: external commands fired on terminal events
    var hooks = Hooks.init(allocator);
    defer hooks.deinit();
    loadHooks(&config, &hooks);

    // MCP server: exposes pane/graph state to Claude Code over Unix socket
    var mcp = McpServer.init(allocator, &mux, &graph) catch null;
    defer if (mcp) |*m| m.deinit();

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

    // Spawn panes (restore or fresh)
    const pane_count: u16 = if (restore) |r| r.pane_count else 1;
    for (0..pane_count) |_| {
        const pid = try mux.spawnPane(grid_rows, grid_cols);
        if (mux.getPaneById(pid)) |pane| {
            _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.pty.child_pid });
        }
        hooks.fire(.spawn);
    }

    // Keyboard input: xkbcommon translates XCB keycodes → UTF-8
    // Uses the LIVE X11 keymap (supports dvorak, colemak, any layout)
    var keyboard = if (Keyboard != void) blk: {
        // Try to get X11 connection info for layout query
        const x11_info = win.getX11Info();
        if (x11_info) |info| {
            break :blk Keyboard.initFromX11(info.conn, info.root) catch
                Keyboard.init() catch null;
        } else {
            break :blk Keyboard.init() catch null;
        }
    } else null;
    defer if (Keyboard != void) {
        if (keyboard) |*kb| kb.deinit();
    };

    var prefix = KeyHandler.PrefixState{};
    var selection = Selection{};
    _ = &selection;
    var mouse_down = false;
    _ = &mouse_down;
    var mouse_start_row: u16 = 0;
    var mouse_start_col: u16 = 0;
    _ = &mouse_start_row;
    _ = &mouse_start_col;
    var pty_buf: [8192]u8 = undefined;
    var running = true;

    // Scrollback browsing state
    var scroll_offset: u32 = 0;
    var saved_cells: ?[]Grid.Cell = null;
    defer if (saved_cells) |sc| allocator.free(sc);

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
                .resize => |sz| {
                    // Resize renderer
                    renderer.resize(sz.width, sz.height);

                    // Recalculate grid dimensions
                    const new_cols: u16 = @intCast((sz.width -| padding * 2) / atlas.cell_width);
                    const new_rows: u16 = @intCast((sz.height -| padding * 2) / atlas.cell_height);
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

                    // Exit scroll mode on resize — grid dimensions changed,
                    // saved_cells is stale. PTY output will refresh the grid.
                    if (scroll_offset > 0) {
                        scroll_offset = 0;
                        if (saved_cells) |sc| {
                            allocator.free(sc);
                            saved_cells = null;
                        }
                    }
                },
                .key_press => |key| {
                    const XKB_KEY_Page_Up: u32 = 0xff55;
                    const XKB_KEY_Page_Down: u32 = 0xff56;
                    const XKB_KEY_Return: u32 = 0xff0d;
                    const XKB_KEY_Escape: u32 = 0xff1b;
                    const XKB_KEY_BackSpace: u32 = 0xff08;
                    const SHIFT_MASK: u32 = 1; // XCB ShiftMask

                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            // Peek keysym before processKey updates state
                            const keysym = kb.getKeysym(key.keycode);

                            // Search mode: intercept all keys for the search query
                            if (search_mode) {
                                var search_key_buf: [32]u8 = undefined;
                                const slen = kb.processKey(key.keycode, true, &search_key_buf);

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

                            // Shift+PageUp/Down: scrollback browsing
                            if (key.modifiers & SHIFT_MASK != 0) {
                                if (keysym == XKB_KEY_Page_Up) {
                                    const max_offset = if (mux.getActivePane()) |pane|
                                        if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                                    else
                                        0;
                                    if (max_offset > 0) {
                                        scroll_offset = @min(scroll_offset + grid_rows, max_offset);
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                    // Update xkb state without forwarding to PTY
                                    var dummy: [32]u8 = undefined;
                                    _ = kb.processKey(key.keycode, true, &dummy);
                                    continue;
                                } else if (keysym == XKB_KEY_Page_Down) {
                                    if (scroll_offset > 0) {
                                        scroll_offset -|= grid_rows;
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                    var dummy: [32]u8 = undefined;
                                    _ = kb.processKey(key.keycode, true, &dummy);
                                    continue;
                                }
                            }

                            // Any other key while in scroll mode: exit scroll mode
                            if (scroll_offset > 0) {
                                scroll_offset = 0;
                                // Restore saved cells
                                if (saved_cells) |sc| {
                                    if (mux.getActivePane()) |pane| {
                                        if (sc.len == pane.grid.cells.len) {
                                            @memcpy(pane.grid.cells, sc);
                                        }
                                        pane.grid.dirty = true;
                                    }
                                    allocator.free(sc);
                                    saved_cells = null;
                                }
                            }

                            var key_buf: [32]u8 = undefined;
                            const len = kb.processKey(key.keycode, true, &key_buf);

                            // Check for prefix key (default: Ctrl+Space = NUL)
                            if (len == 1 and key_buf[0] == config.prefix_key) {
                                prefix.activate();
                                continue;
                            }

                            if (prefix.awaiting) {
                                prefix.reset();
                                if (len > 0) {
                                    const action = KeyHandler.handleMuxCommand(key_buf[0], &mux, &graph, &hooks, &running, grid_rows, grid_cols, io, config.prefix_key);
                                    if (action == .enter_search) search_mode = true;
                                    continue;
                                }
                            }

                            // Normal key — forward to active pane's PTY
                            if (len > 0) {
                                if (mux.getActivePane()) |pane| {
                                    _ = pane.pty.write(key_buf[0..len]) catch {};
                                }
                            }
                        }
                    } else {
                        // Fallback: raw keycode passthrough (no xkbcommon)
                        if (scroll_offset > 0) {
                            scroll_offset = 0;
                            if (saved_cells) |sc| {
                                if (mux.getActivePane()) |pane| {
                                    if (sc.len == pane.grid.cells.len) {
                                        @memcpy(pane.grid.cells, sc);
                                    }
                                    pane.grid.dirty = true;
                                }
                                allocator.free(sc);
                                saved_cells = null;
                            }
                        }
                        if (prefix.awaiting) {
                            prefix.reset();
                            if (key.keycode < 128) {
                                const action = KeyHandler.handleMuxCommand(@truncate(key.keycode), &mux, &graph, &hooks, &running, grid_rows, grid_cols, io, config.prefix_key);
                                if (action == .enter_search) search_mode = true;
                                continue;
                            }
                        }
                        if (key.keycode < 128) {
                            if (mux.getActivePane()) |pane| {
                                const byte = [1]u8{@truncate(key.keycode)};
                                _ = pane.pty.write(&byte) catch {};
                            }
                        }
                    }
                },
                .key_release => |key| {
                    // Update xkbcommon modifier state on key release
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            var dummy: [1]u8 = undefined;
                            _ = kb.processKey(key.keycode, false, &dummy);
                        }
                    }
                },
                .mouse_press => |mouse| {
                    switch (mouse.button) {
                        .left => {
                            const col: u16 = @intCast(@min(mouse.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                            const row: u16 = @intCast(@min(mouse.y / atlas.cell_height, @as(u32, grid_rows -| 1)));

                            // Ctrl+click: open URL under cursor
                            // Prefer OSC 8 hyperlink (explicit), fall back to regex detection
                            const CTRL_MASK: u32 = 4; // XCB ControlMask
                            if (mouse.modifiers & CTRL_MASK != 0) {
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
                            // Paste from clipboard
                            if (mux.getActivePane()) |pane| {
                                Clipboard.paste(&pane.pty);
                            }
                        },
                        .scroll_up => {
                            // Scroll up (future: scrollback navigation)
                        },
                        .scroll_down => {
                            // Scroll down (future: scrollback navigation)
                        },
                        else => {},
                    }
                },
                .mouse_release => |mouse| {
                    if (mouse.button == .left and mouse_down) {
                        mouse_down = false;
                        const col: u16 = @intCast(@min(mouse.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                        const row: u16 = @intCast(@min(mouse.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                        selection.update(row, col);

                        // Only finalize selection if mouse actually moved (not a single click)
                        if (selection.start_row != selection.end_row or selection.start_col != selection.end_col) {
                            selection.finish();
                            if (mux.getActivePane()) |pane| {
                                var sel_buf: [8192]u8 = undefined;
                                const len = selection.getText(&pane.grid, &sel_buf);
                                if (len > 0) {
                                    Clipboard.copy(sel_buf[0..len]);
                                }
                            }
                        } else {
                            // Single click: clear selection (already cleared on press)
                            selection.clear();
                        }
                    }
                },
                .mouse_motion => |motion| {
                    if (mouse_down) {
                        const col: u16 = @intCast(@min(motion.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                        const row: u16 = @intCast(@min(motion.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                        // Start selection on first drag movement
                        if (!selection.active) {
                            selection.begin(mouse_start_row, mouse_start_col);
                        }
                        selection.update(row, col);
                        // Mark grid dirty so selection highlight redraws
                        if (mux.getActivePane()) |pane| {
                            pane.grid.dirty = true;
                        }
                    }
                },
                else => {},
            }
        }

        // Poll all PTYs
        const had_output = mux.pollPtys(&pty_buf);

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

        // Check if any pane's grid is dirty
        var any_dirty = had_output;
        if (!any_dirty) {
            for (mux.panes.items) |*pane| {
                if (pane.grid.dirty) {
                    any_dirty = true;
                    break;
                }
            }
        }

        if (any_dirty) {
            // Visual bell: invert framebuffer for one frame when BEL received
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

            // Scrollback overlay: temporarily replace grid cells with scrollback text
            if (scroll_offset > 0) {
                if (mux.getActivePane()) |pane| {
                    if (pane.grid.scrollback) |sb| {
                        // Save original cells on first entry
                        if (saved_cells == null) {
                            saved_cells = allocator.dupe(Grid.Cell, pane.grid.cells) catch null;
                        }
                        // Fill grid with scrollback content
                        fillGridWithScrollback(&pane.grid, sb, scroll_offset);
                    }
                }
            }

            // Get the underlying SoftwareRenderer for multi-pane rendering
            switch (renderer) {
                .cpu => |*cpu| {
                    const sz = win.getSize();
                    const sel_ptr: ?*const Selection = if (selection.active) &selection else null;
                    mux.renderAllWithSelection(cpu, sz.width, sz.height, atlas.cell_width, atlas.cell_height, sel_ptr);

                    // Search overlay: highlight matches + draw search bar
                    if (search_mode or search_len > 0) {
                        if (mux.getActivePane()) |pane| {
                            renderSearchOverlay(cpu, &pane.grid, search_query[0..search_len], search_mode, atlas.cell_width, atlas.cell_height);
                        }
                    }

                    // Status bar with text (Feature 10)
                    renderTextStatusBar(cpu, &mux, grid_cols, grid_rows, atlas.cell_width, atlas.cell_height);

                    win.putFramebuffer(cpu.getFramebuffer(), sz.width, sz.height);
                },
                .tty => {},
            }
            // Clear dirty flags
            for (mux.panes.items) |*pane| {
                pane.grid.dirty = false;
            }
        } else {
            // 1ms idle sleep via native Io.sleep
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }
}

// ── Search overlay rendering (Feature 9) ─────────────────────────

/// Render search highlights on matching cells and draw search input bar.
fn renderSearchOverlay(
    cpu: *render.SoftwareRenderer,
    grid: *const Grid,
    query: []const u8,
    active: bool,
    cell_width: u32,
    cell_height: u32,
) void {
    const fb_w: usize = cpu.width;
    const fb_h: usize = cpu.height;
    const cw: usize = cell_width;
    const ch: usize = cell_height;

    // Highlight matching cells with a yellow tint
    if (query.len > 0) {
        for (0..grid.rows) |row| {
            var col: usize = 0;
            while (col + query.len <= grid.cols) {
                var match = true;
                for (query, 0..) |qch, qi| {
                    const cell = grid.cellAtConst(@intCast(row), @intCast(col + qi));
                    const cell_lower: u8 = if (cell.char >= 'A' and cell.char <= 'Z') @intCast(cell.char + 32) else if (cell.char < 128) @intCast(cell.char) else 0;
                    const q_lower: u8 = if (qch >= 'A' and qch <= 'Z') qch + 32 else qch;
                    if (cell_lower != q_lower) {
                        match = false;
                        break;
                    }
                }

                if (match) {
                    for (0..query.len) |qi| {
                        const sx = (col + qi) * cw;
                        const sy = row * ch;
                        for (sy..@min(sy + ch, fb_h)) |py| {
                            for (sx..@min(sx + cw, fb_w)) |px| {
                                const idx = py * fb_w + px;
                                if (idx < cpu.framebuffer.len) {
                                    const orig = cpu.framebuffer[idx];
                                    const r: u32 = (orig >> 16) & 0xFF;
                                    const g: u32 = (orig >> 8) & 0xFF;
                                    const b: u32 = orig & 0xFF;
                                    const nr: u32 = @min(255, (r * 6 + 255 * 4) / 10);
                                    const ng: u32 = @min(255, (g * 6 + 204 * 4) / 10);
                                    const nb: u32 = b * 6 / 10;
                                    cpu.framebuffer[idx] = (@as(u32, 0xFF) << 24) | (nr << 16) | (ng << 8) | nb;
                                }
                            }
                        }
                    }
                    col += query.len;
                } else {
                    col += 1;
                }
            }
        }
    }

    // Draw search bar at the bottom if actively searching
    if (active) {
        const bar_h: usize = ch + 4;
        if (fb_h < bar_h + 10) return;
        const bar_y = fb_h - bar_h;
        const bar_bg: u32 = 0xFF2A2A36;

        for (bar_y..fb_h) |y| {
            if (y >= fb_h) break;
            const row_start = y * fb_w;
            const end = @min(row_start + fb_w, cpu.framebuffer.len);
            if (row_start < end) {
                @memset(cpu.framebuffer[row_start..end], bar_bg);
            }
        }

        // Orange separator line
        if (bar_y > 0) {
            const sep_start = bar_y * fb_w;
            const sep_end = @min(sep_start + fb_w, cpu.framebuffer.len);
            if (sep_start < sep_end) {
                @memset(cpu.framebuffer[sep_start..sep_end], 0xFFFF9922);
            }
        }

        // Render prompt and query text
        const text_y = bar_y + 2;
        var text_x: usize = 4;

        blitCharAt(cpu, '/', text_x, text_y, 0xFFFF9922);
        text_x += cw;

        for (query) |qch| {
            blitCharAt(cpu, qch, text_x, text_y, 0xFFFAF8FB);
            text_x += cw;
        }

        // Cursor line
        for (text_y..@min(text_y + ch, fb_h)) |py| {
            if (text_x < fb_w) {
                const idx = py * fb_w + text_x;
                if (idx < cpu.framebuffer.len) {
                    cpu.framebuffer[idx] = 0xFFFAF8FB;
                }
            }
        }
    }
}

// ── Text status bar rendering (Feature 10) ───────────────────────

/// Render a text status bar at the very bottom of the framebuffer.
fn renderTextStatusBar(
    cpu: *render.SoftwareRenderer,
    mux: *const Multiplexer,
    grid_cols: u16,
    grid_rows: u16,
    cell_width: u32,
    cell_height: u32,
) void {
    const fb_w: usize = cpu.width;
    const fb_h: usize = cpu.height;
    const ch: usize = cell_height;
    const cw: usize = cell_width;

    const bar_h: usize = ch + 4;
    if (fb_h < bar_h + ch) return;
    const bar_y = fb_h - bar_h;
    const bar_bg: u32 = 0xFF1D1D23;

    for (bar_y..fb_h) |y| {
        if (y >= fb_h) break;
        const row_start = y * fb_w;
        const end = @min(row_start + fb_w, cpu.framebuffer.len);
        if (row_start < end) {
            @memset(cpu.framebuffer[row_start..end], bar_bg);
        }
    }

    // Top separator
    if (bar_y > 0 and bar_y < fb_h) {
        const sep_start = bar_y * fb_w;
        const sep_end = @min(sep_start + fb_w, cpu.framebuffer.len);
        if (sep_start < sep_end) {
            @memset(cpu.framebuffer[sep_start..sep_end], 0xFF38384C);
        }
    }

    const text_y = bar_y + 2;

    // Left: workspace + pane info
    var left_buf: [64]u8 = undefined;
    const ws_num = mux.active_workspace + 1;
    const active_idx = blk: {
        const ws = &mux.layout_engine.workspaces[mux.active_workspace];
        break :blk ws.active_index + 1;
    };
    const total_panes = mux.panes.items.len;
    const left_text = std.fmt.bufPrint(&left_buf, " [{d}] {d}/{d}", .{ ws_num, active_idx, total_panes }) catch " [?]";

    var x: usize = 0;
    for (left_text) |ch_byte| {
        if (ch_byte == '[' or ch_byte == ']') {
            blitCharAt(cpu, ch_byte, x, text_y, 0xFFFF9922);
        } else if (ch_byte >= '0' and ch_byte <= '9') {
            blitCharAt(cpu, ch_byte, x, text_y, 0xFF2DD9F0);
        } else {
            blitCharAt(cpu, ch_byte, x, text_y, 0xFF64647E);
        }
        x += cw;
    }

    // Separator
    x += cw;
    blitCharAt(cpu, '|', x, text_y, 0xFF38384C);
    x += cw * 2;

    // Center: label
    const center_text = "shell";
    for (center_text) |ch_byte| {
        blitCharAt(cpu, ch_byte, x, text_y, 0xFFC9CBD7);
        x += cw;
    }

    // Right: dimensions + help hint
    var right_buf: [64]u8 = undefined;
    const right_text = std.fmt.bufPrint(&right_buf, "{d}x{d}  C-Space ?", .{ grid_cols, grid_rows }) catch "";
    const right_start = if (fb_w > right_text.len * cw + cw) fb_w - right_text.len * cw - cw else 0;
    var rx = right_start;
    for (right_text) |ch_byte| {
        if (ch_byte >= '0' and ch_byte <= '9') {
            blitCharAt(cpu, ch_byte, rx, text_y, 0xFF8683FF);
        } else {
            blitCharAt(cpu, ch_byte, rx, text_y, 0xFF64647E);
        }
        rx += cw;
    }
}

/// Blit a single character at a pixel position using the atlas.
fn blitCharAt(cpu: *render.SoftwareRenderer, char: u8, screen_x: usize, screen_y: usize, fg: u32) void {
    if (char < 32 or char >= 127) return;
    if (cpu.atlas_width == 0 or cpu.glyph_atlas.len == 0) return;

    const cw: usize = cpu.cell_width;
    const ch: usize = cpu.cell_height;
    const aw: usize = cpu.atlas_width;
    const fb_w: usize = cpu.width;
    const fb_h: usize = cpu.height;

    const glyph_index: usize = char - 32;
    const glyphs_per_row = if (aw >= cw) aw / cw else return;
    const glyph_row = glyph_index / glyphs_per_row;
    const glyph_col = glyph_index % glyphs_per_row;
    const atlas_x = glyph_col * cw;
    const atlas_y = glyph_row * ch;

    const fg_r: u16 = @truncate((fg >> 16) & 0xFF);
    const fg_g: u16 = @truncate((fg >> 8) & 0xFF);
    const fg_b: u16 = @truncate(fg & 0xFF);

    for (0..ch) |dy| {
        if (screen_y + dy >= fb_h) break;
        if (atlas_y + dy >= cpu.atlas_height) break;
        const atlas_row_offset = (atlas_y + dy) * aw + atlas_x;
        if (atlas_row_offset + cw > cpu.glyph_atlas.len) break;

        for (0..cw) |dx| {
            if (screen_x + dx >= fb_w) break;
            const alpha: u16 = cpu.glyph_atlas[atlas_row_offset + dx];
            if (alpha == 0) continue;

            const fb_idx = (screen_y + dy) * fb_w + (screen_x + dx);
            if (fb_idx >= cpu.framebuffer.len) continue;

            if (alpha == 255) {
                cpu.framebuffer[fb_idx] = fg;
            } else {
                const bg = cpu.framebuffer[fb_idx];
                const bg_r: u16 = @truncate((bg >> 16) & 0xFF);
                const bg_g: u16 = @truncate((bg >> 8) & 0xFF);
                const bg_b: u16 = @truncate(bg & 0xFF);
                const inv: u16 = 255 - alpha;
                const r = (fg_r * alpha + bg_r * inv) / 255;
                const g = (fg_g * alpha + bg_g * inv) / 255;
                const b = (fg_b * alpha + bg_b * inv) / 255;
                cpu.framebuffer[fb_idx] = (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
            }
        }
    }
}

/// Fill the grid with scrollback text for browsing mode.
/// scroll_offset is the number of lines from the bottom of scrollback.
/// The last row shows a "[SCROLL +N]" indicator.
fn fillGridWithScrollback(grid: *Grid, sb: *const Scrollback, scroll_offset: u32) void {
    const rows = grid.rows;
    const cols = grid.cols;

    // Clear entire grid
    for (grid.cells) |*c| c.* = Grid.Cell.blank();

    // Reserve last row for scroll indicator
    const content_rows: u16 = if (rows > 1) rows - 1 else rows;

    // scroll_offset=1 means show the most recent scrollback line at the bottom.
    // We want to show lines [offset - content_rows, offset) from the end,
    // where offset 0 is the most recent line.
    // Line at offset (scroll_offset - 1) is the bottom content line.
    // Line at offset (scroll_offset - 1 + content_rows - 1) is the top content line.

    var row: u16 = 0;
    while (row < content_rows) : (row += 1) {
        // Which scrollback line to show on this grid row?
        // Top row = furthest back, bottom row = most recent in this view
        const lines_from_bottom = scroll_offset -| 1 + (content_rows - 1 - row);
        const text = sb.getLineByOffset(lines_from_bottom) orelse continue;

        // Write text into grid row
        var col: u16 = 0;
        for (text) |byte| {
            if (col >= cols) break;
            grid.cellAt(row, col).char = byte;
            grid.cellAt(row, col).fg = .default;
            col += 1;
        }
    }

    // Draw scroll indicator on the last row
    if (rows > 0) {
        const indicator_row = rows - 1;
        var buf: [64]u8 = undefined;
        const indicator = std.fmt.bufPrint(&buf, "[SCROLL +{d}]", .{scroll_offset}) catch "[SCROLL]";

        var col: u16 = 0;
        for (indicator) |byte| {
            if (col >= cols) break;
            const cell = grid.cellAt(indicator_row, col);
            cell.char = byte;
            cell.fg = .{ .indexed = 208 }; // orange
            cell.attrs.bold = true;
            col += 1;
        }

        // Show total lines available
        const total = sb.lineCount();
        const info = std.fmt.bufPrint(buf[indicator.len..], " ({d} lines)", .{total}) catch "";
        for (info) |byte| {
            if (col >= cols) break;
            const cell = grid.cellAt(indicator_row, col);
            cell.char = byte;
            cell.fg = .{ .indexed = 245 }; // gray
            col += 1;
        }
    }
}

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

    const size = terminal.getSize() catch Terminal.TermSize{ .rows = 24, .cols = 80 };

    var buf: [256]u8 = undefined;
    outFmt(&buf, "\x1b[38;5;208m[teru {s}]\x1b[0m AI-first terminal · {d}x{d}\n", .{ version, size.cols, size.rows });

    var pty_inst = try Pty.spawn(.{ .rows = size.rows, .cols = size.cols });
    defer pty_inst.deinit();

    const node_id = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pty_inst.child_pid });

    const SA_RESTART = 0x10000000; // linux/signal.h: restart interrupted syscalls
    const sa = posix.Sigaction{
        .handler = .{ .handler = handleSigwinch },
        .mask = posix.sigemptyset(),
        .flags = SA_RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa, null);
    g_pty_master_fd = pty_inst.master;
    g_host_fd = terminal.host_fd;

    try terminal.enterRawMode();
    out("\x1b[2J\x1b[H");
    terminal.runLoop(&pty_inst) catch {};
    terminal.exitRawMode();

    if (pty_inst.child_pid != null) {
        const status = pty_inst.waitForExit() catch 0;
        graph.markFinished(node_id, @truncate(status >> 8));
    }
    outFmt(&buf, "\n\x1b[38;5;208m[teru]\x1b[0m session ended · {d} node(s)\n", .{graph.nodeCount()});
}

var g_pty_master_fd: posix.fd_t = -1;
var g_host_fd: posix.fd_t = posix.STDIN_FILENO;

fn handleSigwinch(_: posix.SIG) callconv(.c) void {
    if (g_pty_master_fd < 0) return;
    var ws: posix.winsize = undefined;
    if (posix.system.ioctl(g_host_fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return;
    _ = posix.system.ioctl(g_pty_master_fd, posix.T.IOCSWINSZ, @intFromPtr(&ws));
}

