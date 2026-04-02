const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Pty = @import("pty/Pty.zig");
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
const SignalManager = @import("core/SignalManager.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const version = "0.1.10";

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
            out("teru — AI-first terminal emulator\n\nUsage: teru [options]\n\nOptions:\n  --help        Show this help\n  --version     Show version\n  --raw         Raw passthrough mode (no window)\n  --attach      Restore session from last detach\n  --mcp-bridge  MCP stdio bridge (stdin/stdout <-> teru socket)\n\nMultiplexer keys (prefix: Ctrl+Space):\n  c     Spawn new pane\n  x     Close active pane\n  n     Focus next pane\n  p     Focus prev pane\n  1-9   Switch workspace\n  Space Cycle layout\n  d     Detach (save session, exit)\n  /     Search visible grid\n\nScrollback:\n  Shift+PageUp    Scroll up one page\n  Shift+PageDown  Scroll down one page\n  Any key         Exit scroll mode\n\nURL detection:\n  Ctrl+click on a URL to open in browser\n\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--attach")) {
            return runAttachMode(allocator, io);
        }
        if (std.mem.eql(u8, arg, "--raw")) {
            return runRawMode(allocator, io);
        }
        if (std.mem.eql(u8, arg, "--mcp-bridge")) {
            return McpBridge.run(io);
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

    const padding: u32 = 8; // must match SoftwareRenderer.padding
    const status_bar_h: u32 = atlas.cell_height + 4; // must match renderTextStatusBar
    var grid_cols: u16 = @intCast((config.initial_width -| padding * 2) / atlas.cell_width);
    var grid_rows: u16 = @intCast((config.initial_height -| padding * 2 -| status_bar_h) / atlas.cell_height);

    // Multiplexer: manages all panes (linked to process graph for agent rendering)
    var mux = Multiplexer.init(allocator);
    defer mux.deinit();
    mux.graph = &graph;

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

    // Key repeat tracking: debounce rapid repeats of the same keycode
    var last_keycode: u32 = 0;
    var last_key_time: i128 = 0;
    const KEY_REPEAT_MIN_NS: i128 = 33_000_000; // 33ms (~30Hz) minimum between same-key repeats

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
                    // When a WM intercepts keys (e.g., screenshot shortcut),
                    // the key_release never reaches us, leaving modifiers stuck.
                    // Reinitializing xkb state clears all held modifiers.
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            kb.resetState();
                        }
                    }
                    // Also reset prefix key in case it was stuck
                    prefix.reset();
                    // Reset key repeat tracking
                    last_keycode = 0;
                    last_key_time = 0;
                },
                .resize => |sz| {
                    // Resize renderer
                    renderer.resize(sz.width, sz.height);

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
                    mux.scroll_offset = 0;
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
                            // Sync xkb modifier/group state from X11 before
                            // any key processing. This ensures layout switches
                            // (e.g., Alt+Shift) are reflected immediately.
                            kb.updateModifiers(key.modifiers);

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
                                        mux.scroll_offset = @min(mux.scroll_offset + grid_rows, max_offset);
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                    // Update xkb state without forwarding to PTY
                                    var dummy: [32]u8 = undefined;
                                    _ = kb.processKey(key.keycode, true, &dummy);
                                    continue;
                                } else if (keysym == XKB_KEY_Page_Down) {
                                    if (mux.scroll_offset > 0) {
                                        mux.scroll_offset -|= grid_rows;
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                    var dummy: [32]u8 = undefined;
                                    _ = kb.processKey(key.keycode, true, &dummy);
                                    continue;
                                }
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
                                            var sel_buf: [8192]u8 = undefined;
                                            const copy_len = selection.getText(&pane.grid, &sel_buf);
                                            if (copy_len > 0) {
                                                Clipboard.copy(sel_buf[0..copy_len]);
                                            }
                                        }
                                    }
                                    continue;
                                }
                                if (keysym == XKB_KEY_V or keysym == XKB_KEY_v) {
                                    // Paste
                                    if (mux.getActivePane()) |pane| {
                                        Clipboard.paste(&pane.pty);
                                    }
                                    continue;
                                }
                            }

                            // Any other key while in scroll mode: exit scroll mode
                            if (mux.scroll_offset > 0) {
                                mux.scroll_offset = 0;
                                if (mux.getActivePane()) |pane| pane.grid.dirty = true;
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
                                // Debounce rapid repeats of the same key (prevents
                                // Enter/Backspace runaway when held and released)
                                var ts: std.os.linux.timespec = undefined;
                                _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
                                const now: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
                                const is_repeat = key.keycode == last_keycode and (now - last_key_time) < KEY_REPEAT_MIN_NS;
                                last_keycode = key.keycode;
                                last_key_time = now;
                                if (is_repeat) continue;

                                if (mux.getActivePane()) |pane| {
                                    _ = pane.pty.write(key_buf[0..len]) catch {};
                                }
                            }
                        }
                    } else {
                        // Fallback: raw keycode passthrough (no xkbcommon)
                        if (mux.scroll_offset > 0) {
                            mux.scroll_offset = 0;
                            if (mux.getActivePane()) |pane| pane.grid.dirty = true;
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
                    // Clear repeat tracking so next press isn't debounced
                    if (key.keycode == last_keycode) {
                        last_keycode = 0;
                        last_key_time = 0;
                    }
                    // Sync xkb modifier/group state from X11 on release
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            kb.updateModifiers(key.modifiers);
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

                            // Click-to-focus: switch active pane if click lands in another pane's rect
                            const ClickRect = @import("tiling/LayoutEngine.zig").Rect;
                            const click_ws = &mux.layout_engine.workspaces[mux.active_workspace];
                            const click_node_ids = click_ws.node_ids.items;
                            if (click_node_ids.len > 1) {
                                const sz = win.getSize();
                                const click_screen = ClickRect{
                                    .x = @intCast(padding),
                                    .y = @intCast(padding),
                                    .width = @intCast(@min(sz.width -| padding * 2, std.math.maxInt(u16))),
                                    .height = @intCast(@min(sz.height -| padding * 2, std.math.maxInt(u16))),
                                };
                                if (mux.layout_engine.calculate(mux.active_workspace, click_screen)) |click_rects| {
                                    defer allocator.free(click_rects);
                                    for (click_rects, 0..) |cr, ci| {
                                        if (ci >= click_node_ids.len) break;
                                        if (mouse.x >= cr.x and mouse.x < @as(u32, cr.x) + cr.width and
                                            mouse.y >= cr.y and mouse.y < @as(u32, cr.y) + cr.height)
                                        {
                                            if (ci != click_ws.active_index) {
                                                mux.layout_engine.workspaces[mux.active_workspace].active_index = ci;
                                                // Mark all panes dirty to redraw borders
                                                for (mux.panes.items) |*p| p.grid.dirty = true;
                                            }
                                            break;
                                        }
                                    }
                                } else |_| {}
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
                            // Mouse wheel up: scroll into scrollback history
                            const scroll_lines: u32 = 3; // lines per wheel tick
                            // Max offset = scrollback lines + screen lines - one screenful
                            // (so oldest scrollback line appears at top of screen)
                            const max_offset = if (mux.getActivePane()) |pane|
                                if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                            else
                                0;
                            if (max_offset > 0) {
                                mux.scroll_offset = @min(mux.scroll_offset + scroll_lines, max_offset);
                                if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                            }
                        },
                        .scroll_down => {
                            // Mouse wheel down: scroll back toward live terminal
                            if (mux.scroll_offset > 0) {
                                mux.scroll_offset -|= 3;
                                if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                            }
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

        // Poll all PTYs (grid is never modified by scroll — no save/restore needed)
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

            // Get the underlying SoftwareRenderer for multi-pane rendering
            switch (renderer) {
                .cpu => |*cpu| {
                    const sz = win.getSize();
                    const sel_ptr: ?*const Selection = if (selection.active) &selection else null;
                    mux.renderAllWithSelection(cpu, sz.width, sz.height, atlas.cell_width, atlas.cell_height, sel_ptr);

                    // Search overlay: highlight matches + draw search bar
                    if (search_mode or search_len > 0) {
                        if (mux.getActivePane()) |pane| {
                            Ui.renderSearchOverlay(cpu, &pane.grid, search_query[0..search_len], search_mode, atlas.cell_width, atlas.cell_height);
                        }
                    }

                    // Scroll overlay: render scrollback lines onto framebuffer (non-destructive)
                    if (mux.scroll_offset > 0) {
                        if (mux.getActivePane()) |pane| {
                            if (pane.grid.scrollback) |sb| {
                                Ui.renderScrollOverlay(cpu, sb, mux.scroll_offset, atlas.cell_width, atlas.cell_height);
                            }
                        }
                    }

                    // Status bar with text (Feature 10)
                    Ui.renderTextStatusBar(cpu, &mux, grid_cols, grid_rows, atlas.cell_width, atlas.cell_height, prefix.awaiting);

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

    const size = terminal.getSize() catch Terminal.TermSize{ .rows = 24, .cols = 80 };

    var buf: [256]u8 = undefined;
    outFmt(&buf, "\x1b[38;5;208m[teru {s}]\x1b[0m AI-first terminal · {d}x{d}\n", .{ version, size.cols, size.rows });

    var pty_inst = try Pty.spawn(.{ .rows = size.rows, .cols = size.cols });
    defer pty_inst.deinit();

    const node_id = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pty_inst.child_pid });

    var sig = SignalManager.init(pty_inst.master, terminal.host_fd);
    sig.registerWinch();

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


