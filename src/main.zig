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
const ConfigWatcher = @import("config/ConfigWatcher.zig");
const Hooks = @import("config/Hooks.zig");
const Selection = @import("core/Selection.zig");
const ViMode = @import("core/ViMode.zig");
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

const version = "0.2.5";

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

    var mode_raw = false;
    var mode_attach = false;
    var mode_mcp_bridge = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var buf: [64]u8 = undefined;
            outFmt(&buf, "teru {s}\n", .{version});
            return;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            out("teru — AI-first terminal emulator\n\nUsage: teru [options]\n\nOptions:\n  --help              Show this help\n  --version           Show version\n  --raw               Raw passthrough mode (no window)\n  --attach            Restore session from last detach\n  --mcp-bridge        MCP stdio bridge\n  --config <path>     Use custom config file\n  --theme <name>      Override theme (built-in or ~/.config/teru/themes/)\n  --class <name>      Set WM_CLASS (X11 window class)\n\nMultiplexer keys (prefix: Ctrl+Space):\n  c     Spawn new pane        n/p   Next/prev pane\n  x     Close active pane     1-9   Switch workspace\n  Space Cycle layout           d    Detach session\n  /     Search                 z    Zoom pane\n  H/L   Resize master ratio\n\nScrollback: PageUp/Down or mouse wheel. Any typing key exits scroll.\nURL: Ctrl+click to open. Double-click to select word.\n\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--raw")) { mode_raw = true; continue; }
        if (std.mem.eql(u8, arg, "--attach")) { mode_attach = true; continue; }
        if (std.mem.eql(u8, arg, "--mcp-bridge")) { mode_mcp_bridge = true; continue; }
        // Args with values: skip next arg
        // These are handled in Config.load via CLI override (future)
    }

    if (mode_mcp_bridge) return McpBridge.run(io);
    if (mode_attach) return runAttachMode(allocator, io);

    // Detect rendering tier
    const tier = render.detectTier();
    if (tier == .tty or mode_raw) {
        return runRawMode(allocator, io);
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

    // Watch config file for live reload (inotify, zero polling)
    var config_watcher = ConfigWatcher.init();
    defer if (config_watcher) |*w| w.deinit();

    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var win = try platform.Platform.init(config.initial_width, config.initial_height, "teru");
    defer win.deinit();
    win.setOpacity(config.opacity);

    var atlas = try render.FontAtlas.init(allocator, config.font_path, config.font_size, io);
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
    const status_bar_h: u32 = if (config.show_status_bar) atlas.cell_height + 4 else 0;
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

    // Apply per-workspace config
    for (0..9) |i| {
        if (config.workspace_layouts[i]) |layout| {
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

    // Set screen dimensions for MCP pane creation
    if (mcp) |*m| {
        m.screen_width = config.initial_width;
        m.screen_height = config.initial_height;
        m.cell_width = atlas.cell_width;
        m.cell_height = atlas.cell_height;
        m.padding = padding;
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

    var prefix = KeyHandler.PrefixState{ .timeout_ns = @as(i128, config.prefix_timeout_ms) * 1_000_000 };
    var selection = Selection{};
    _ = &selection;
    var vi_mode = ViMode{};
    _ = &vi_mode;
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
    var pty_buf: [8192]u8 = undefined;
    var running = true;
    var mouse_cursor_hidden = false;
    var last_click_time: i128 = 0;
    var last_click_row: u16 = 0;
    var last_click_col: u16 = 0;
    const DOUBLE_CLICK_NS: i128 = 300_000_000; // 300ms
    const default_word_delimiters = " \t{}[]()\"'`,;:@";

    // Cursor blink state (530ms on/off cycle)
    const BLINK_INTERVAL_NS: i128 = 530_000_000;
    var last_blink_time: i128 = blk: {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        break :blk @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    };
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
                        _ = pane.pty.write("\x1b[I") catch {};
                    }
                },
                .focus_out => {
                    // Send focus-out event to PTY
                    if (mux.getActivePaneMut()) |pane| {
                        _ = pane.pty.write("\x1b[O") catch {};
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
                        var blink_reset_ts: std.os.linux.timespec = undefined;
                        _ = std.os.linux.clock_gettime(.MONOTONIC, &blink_reset_ts);
                        last_blink_time = @as(i128, blink_reset_ts.sec) * 1_000_000_000 + blink_reset_ts.nsec;
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

                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            // Sync xkb modifier/group state from X11 before
                            // any key processing. This ensures layout switches
                            // (e.g., Alt+Shift) are reflected immediately.
                            kb.updateModifiers(key.modifiers);

                            const keysym = kb.getKeysym(key.keycode);

                            // Vi/copy mode: intercept ALL keys
                            if (vi_mode.active) {
                                // Try keysym first (arrows, PageUp/Down, ESC)
                                const sb_lines: u32 = if (mux.getActivePane()) |pane|
                                    if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                                else
                                    0;
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
                                                    const len = sel_copy.getTextWithScrollback(&pane.grid, sbl, &sel_buf);
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
                                const vi_len = kb.processKey(key.keycode, true, &vi_key_buf);
                                if (vi_len > 0) {
                                    vi_scroll = mux.getScrollOffset();
                                    const vi_action = vi_mode.handleKey(vi_key_buf[0], if (mux.getActivePane()) |p| &p.grid else unreachable, &vi_scroll, sb_lines);
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
                                                    const len = sel_copy.getTextWithScrollback(&pane.grid, sbl, &sel_buf);
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

                            // PageUp/Down: scrollback browsing (with or without Shift)
                            if (keysym == XKB_KEY_Page_Up) {
                                const max_offset = if (mux.getActivePane()) |pane|
                                    if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                                else
                                    0;
                                if (max_offset > 0) {
                                    mux.setScrollOffset(@min(mux.getScrollOffset() + grid_rows, max_offset));
                                }
                                var dummy: [32]u8 = undefined;
                                _ = kb.processKey(key.keycode, true, &dummy);
                                continue;
                            } else if (keysym == XKB_KEY_Page_Down) {
                                if (mux.getScrollOffset() > 0) {
                                    { const so = mux.getScrollOffset(); mux.setScrollOffset(so -| grid_rows); }
                                }
                                var dummy: [32]u8 = undefined;
                                _ = kb.processKey(key.keycode, true, &dummy);
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
                                            const copy_len = selection.getTextWithScrollback(&pane.grid, sb, &sel_buf);
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
                                            _ = pane.pty.write("\x1b[200~") catch {};
                                        }
                                        Clipboard.paste(&pane.pty);
                                        if (pane.vt.bracketed_paste) {
                                            _ = pane.pty.write("\x1b[201~") catch {};
                                        }
                                    }
                                    continue;
                                }
                            }

                            var key_buf: [32]u8 = undefined;
                            const len = kb.processKey(key.keycode, true, &key_buf);

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
                                        const sb_n: u32 = if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0;
                                        vi_mode.enter(grid_rows, grid_cols, pane.grid.cursor_row, pane.grid.cursor_col, mux.getScrollOffset(), sb_n);
                                        pane.grid.dirty = true;
                                    }
                                }
                                if (action == .panes_changed) {
                                    const sz = win.getSize();
                                    mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding);
                                }
                                if (action == .split_vertical or action == .split_horizontal) {
                                    const dir: @import("tiling/LayoutEngine.zig").SplitDirection = if (action == .split_horizontal) .horizontal else .vertical;
                                    const id = mux.spawnPane(grid_rows, grid_cols) catch continue;
                                    if (mux.getPaneById(id)) |pane| {
                                        _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.pty.child_pid }) catch {};
                                    }
                                    hooks.fire(.spawn);
                                    // Add to split tree
                                    const ws = &mux.layout_engine.workspaces[mux.active_workspace];
                                    ws.addNodeSplit(mux.allocator, id, dir) catch {};
                                    // Resize all PTYs to match new layout
                                    const sz = win.getSize();
                                    mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding);
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
                                    _ = pane.pty.write(alt_buf[0 .. len + 1]) catch {};
                                } else {
                                    _ = pane.pty.write(key_buf[0..len]) catch {};
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
                                    const sb_n: u32 = if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0;
                                    vi_mode.enter(grid_rows, grid_cols, pane.grid.cursor_row, pane.grid.cursor_col, mux.getScrollOffset(), sb_n);
                                    pane.grid.dirty = true;
                                }
                            }
                            if (action == .panes_changed) {
                                const sz = win.getSize();
                                mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding);
                            }
                            continue;
                        }
                        if (mux.getActivePane()) |pane| {
                            const byte = [1]u8{@truncate(key.keycode)};
                            _ = pane.pty.write(&byte) catch {};
                        }
                    }
                },
                .key_release => |key| {
                    // Sync xkb modifier/group state from X11 on release
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            kb.updateModifiers(key.modifiers);
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
                                _ = pane.pty.write(mlen) catch {};
                            } else {
                                // X10 legacy encoding
                                if (mcol + 33 < 256 and mrow + 33 < 256) {
                                    mbuf[0] = 0x1b;
                                    mbuf[1] = '[';
                                    mbuf[2] = 'M';
                                    mbuf[3] = @intCast(btn + 32);
                                    mbuf[4] = @intCast(mcol + 33);
                                    mbuf[5] = @intCast(mrow + 33);
                                    _ = pane.pty.write(mbuf[0..6]) catch {};
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

                                // Border drag: check if click is on a split border
                                if (click_ws.split_root != null) {
                                    if (mux.layout_engine.workspaces[mux.active_workspace].findSplitForBorder(click_screen, mouse.x, mouse.y, 4)) |hit| {
                                        border_dragging = true;
                                        border_drag_x = mouse.x;
                                        border_drag_ratio = mux.layout_engine.workspaces[mux.active_workspace].split_nodes[hit.node_idx].split.ratio;
                                        // Store the split node index for the drag handler
                                        border_drag_node = hit.node_idx;
                                        continue;
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
                            var click_ts: std.os.linux.timespec = undefined;
                            _ = std.os.linux.clock_gettime(.MONOTONIC, &click_ts);
                            const click_now: i128 = @as(i128, click_ts.sec) * 1_000_000_000 + click_ts.nsec;
                            if (click_now - last_click_time < DOUBLE_CLICK_NS and
                                row == last_click_row and col == last_click_col)
                            {
                                if (mux.getActivePane()) |pane| {
                                    const delims = config.word_delimiters orelse default_word_delimiters;
                                    selection.selectWord(&pane.grid, row, col, delims);
                                    pane.grid.dirty = true;
                                    if (config.copy_on_select) {
                                        var sel_buf: [65536]u8 = undefined;
                                        const sb = pane.grid.scrollback;
                                        const len = selection.getTextWithScrollback(&pane.grid, sb, &sel_buf);
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
                                    _ = pane.pty.write("\x1b[200~") catch {};
                                }
                                Clipboard.paste(&pane.pty);
                                if (pane.vt.bracketed_paste) {
                                    _ = pane.pty.write("\x1b[201~") catch {};
                                }
                            }
                        },
                        .scroll_up => {
                            // Don't scroll teru's scrollback when alt screen is active
                            // (tmux, vim, etc. handle scrolling themselves)
                            const in_alt = if (mux.getActivePane()) |pane| pane.vt.alt_screen else false;
                            if (!in_alt) {
                                const max_offset = if (mux.getActivePane()) |pane|
                                    if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                                else
                                    0;
                                if (max_offset > 0) {
                                    _ = mux.smoothScroll(@as(i32, @intCast(atlas.cell_height)) * @as(i32, @intCast(config.scroll_speed)), atlas.cell_height, max_offset);
                                }
                            }
                        },
                        .scroll_down => {
                            const in_alt = if (mux.getActivePane()) |pane| pane.vt.alt_screen else false;
                            if (!in_alt) {
                                if (mux.getScrollOffset() > 0 or mux.getScrollPixel() > 0) {
                                    const max_offset = if (mux.getActivePane()) |pane|
                                        if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                                    else
                                        0;
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
                                _ = pane.pty.write(mlen) catch {};
                            } else {
                                if (mcol + 33 < 256 and mrow + 33 < 256) {
                                    mbuf[0] = 0x1b;
                                    mbuf[1] = '[';
                                    mbuf[2] = 'M';
                                    mbuf[3] = 35; // release = button 3
                                    mbuf[4] = @intCast(mcol + 33);
                                    mbuf[5] = @intCast(mrow + 33);
                                    _ = pane.pty.write(mbuf[0..6]) catch {};
                                }
                            }
                        }
                    }
                    if (mouse.button == .left and border_dragging) {
                        border_dragging = false;
                        const sz = win.getSize();
                        mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding);
                        continue;
                    }
                    if (mouse.button == .left and mouse_down) {
                        mouse_down = false;
                        // Don't process selection when mouse tracking is active
                        const track_active = if (mux.getActivePane()) |pane| pane.vt.mouse_tracking != .none else false;
                        if (track_active) continue;
                        const col: u16 = @intCast(@min(mouse.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                        const row: u16 = @intCast(@min(mouse.y / atlas.cell_height, @as(u32, grid_rows -| 1)));
                        selection.update(row, col);

                        // Only finalize selection if mouse actually moved (not a single click)
                        if (selection.start_row != selection.end_row or selection.start_col != selection.end_col) {
                            selection.finish();
                            if (config.copy_on_select) {
                                if (mux.getActivePane()) |pane| {
                                    var sel_buf: [65536]u8 = undefined;
                                    const sb = pane.grid.scrollback;
                                    const len = selection.getTextWithScrollback(&pane.grid, sb, &sel_buf);
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
                        const content_w = sz.width -| padding * 2;
                        if (content_w > 0) {
                            const delta_px: i32 = @as(i32, @intCast(motion.x)) - @as(i32, @intCast(border_drag_x));
                            const delta_ratio: f32 = @as(f32, @floatFromInt(delta_px)) / @as(f32, @floatFromInt(content_w));
                            const new_ratio = std.math.clamp(border_drag_ratio + delta_ratio, 0.15, 0.85);
                            const ws_mut = &mux.layout_engine.workspaces[mux.active_workspace];
                            if (ws_mut.split_root != null) {
                                ws_mut.resizeSplit(border_drag_node, new_ratio);
                            } else {
                                ws_mut.master_ratio = new_ratio;
                            }
                            for (mux.panes.items) |*p| p.grid.dirty = true;
                        }
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
                                _ = pane.pty.write(mlen) catch {};
                            } else {
                                if (mcol + 33 < 256 and mrow + 33 < 256) {
                                    mbuf[0] = 0x1b;
                                    mbuf[1] = '[';
                                    mbuf[2] = 'M';
                                    mbuf[3] = if (mouse_down) 64 else 67; // motion flag + button
                                    mbuf[4] = @intCast(mcol + 33);
                                    mbuf[5] = @intCast(mrow + 33);
                                    _ = pane.pty.write(mbuf[0..6]) catch {};
                                }
                            }
                        }
                    }
                    // Only handle selection when mouse tracking is off (app handles mouse)
                    const tracking_active = if (mux.getActivePane()) |pane| pane.vt.mouse_tracking != .none else false;
                    if (mouse_down and !tracking_active) {
                        const col: u16 = @intCast(@min(motion.x / atlas.cell_width, @as(u32, grid_cols -| 1)));
                        const raw_row = motion.y / atlas.cell_height;
                        const row: u16 = @intCast(@min(raw_row, @as(u32, grid_rows -| 1)));

                        // Start selection on first drag movement
                        if (!selection.active) {
                            const so = mux.getScrollOffset();
                            if (so > 0)
                                selection.beginScrolled(mouse_start_row, mouse_start_col, so)
                            else
                                selection.begin(mouse_start_row, mouse_start_col);
                        }
                        selection.update(row, col);

                        // Auto-scroll when dragging near active pane edges
                        const in_alt = if (mux.getActivePane()) |pane| pane.vt.alt_screen else false;
                        if (!in_alt) {
                            const sz_scroll = win.getSize();
                            const pane_rect = mux.getActivePaneRect(sz_scroll.width, sz_scroll.height, padding);
                            const edge_zone = atlas.cell_height;
                            const top_edge = if (pane_rect) |pr| @as(u32, pr.y) else 0;
                            const bot_edge = if (pane_rect) |pr| @as(u32, pr.y) + pr.height else grid_rows * atlas.cell_height;

                            if (motion.y < top_edge + edge_zone) {
                                const max_offset = if (mux.getActivePane()) |pane|
                                    if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                                else
                                    0;
                                if (max_offset > 0) {
                                    _ = mux.smoothScroll(@as(i32, @intCast(atlas.cell_height)), atlas.cell_height, max_offset);
                                }
                            } else if (motion.y >= bot_edge -| edge_zone) {
                                if (mux.getScrollOffset() > 0) {
                                    const max_offset = if (mux.getActivePane()) |pane|
                                        if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                                    else
                                        0;
                                    _ = mux.smoothScroll(-@as(i32, @intCast(atlas.cell_height)), atlas.cell_height, max_offset);
                                }
                            }
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

        // Poll all PTYs (grid is never modified by scroll — no save/restore needed)
        const had_output = mux.pollPtys(&pty_buf);

        // If user is scrolled up and new lines were added to scrollback,
        // advance scroll_offset to keep the viewport pinned to the same content.
        if (had_output and (mux.getScrollOffset() > 0 or mux.getScrollPixel() > 0)) {
            if (mux.getActivePane()) |pane| {
                if (pane.grid.scrollback) |sb| {
                    const sb_count_after = sb.lineCount();
                    if (sb_count_after > sb_count_before) {
                        const new_lines: u32 = @intCast(sb_count_after - sb_count_before);
                        pane.scroll_offset += new_lines;
                    }
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

                    // Update config fields that don't need subsystem propagation
                    config.scroll_speed = new_config.scroll_speed;
                    config.cursor_blink = new_config.cursor_blink;
                    config.cursor_shape = new_config.cursor_shape;
                    config.bold_is_bright = new_config.bold_is_bright;
                    config.bell = new_config.bell;
                    config.copy_on_select = new_config.copy_on_select;
                    config.mouse_hide_when_typing = new_config.mouse_hide_when_typing;
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
        var any_dirty = had_output;
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
            var blink_ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &blink_ts);
            const now_blink: i128 = @as(i128, blink_ts.sec) * 1_000_000_000 + blink_ts.nsec;
            if (now_blink - last_blink_time >= BLINK_INTERVAL_NS) {
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
                    const vi_sb: u32 = if (mux.getActivePane()) |pane|
                        if (pane.grid.scrollback) |sb| @as(u32, @intCast(sb.lineCount())) else 0
                    else
                        0;
                    var vi_sel = if (vi_mode.active) vi_mode.toSelection(mux.getScrollOffset(), vi_sb) else null;
                    const sel_ptr: ?*const Selection = if (vi_sel != null) &vi_sel.? else if (selection.active) &selection else null;
                    mux.renderAllWithSelection(cpu, sz.width, sz.height, atlas.cell_width, atlas.cell_height, sel_ptr);

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
                                if (mux.getActivePaneRect(sz.width, sz.height, cpu.padding)) |pane_rect| {
                                    Ui.renderScrollOverlay(cpu, sb, mux.getScrollOffset(), atlas.cell_width, atlas.cell_height, pane_rect, mux.getScrollPixel());
                                }
                            }
                        }
                    }

                    // Vi mode selection overlay (re-applied after scroll overlay)
                    if (vi_mode.active and vi_mode.selection_active) {
                        if (vi_mode.getViewportSelection(mux.getScrollOffset(), vi_sb)) |bounds| {
                            if (mux.getActivePaneRect(sz.width, sz.height, cpu.padding)) |pr| {
                                const cw = atlas.cell_width;
                                const ch = atlas.cell_height;
                                const sel_bg = cpu.scheme.selection_bg;
                                var sr: u16 = bounds.start_row;
                                while (sr <= bounds.end_row) : (sr += 1) {
                                    const sc = if (sr == bounds.start_row) bounds.start_col else 0;
                                    const ec = if (sr == bounds.end_row) bounds.end_col else vi_mode.grid_cols -| 1;
                                    var col: u16 = sc;
                                    while (col <= ec) : (col += 1) {
                                        const px = pr.x + @as(usize, col) * cw;
                                        const py = pr.y + @as(usize, sr) * ch;
                                        const mx = @min(px + cw, @as(usize, pr.x) + pr.width);
                                        const my = @min(py + ch, @as(usize, pr.y) + pr.height);
                                        for (py..my) |y| {
                                            if (y >= cpu.height) break;
                                            const row_start = y * cpu.width;
                                            if (row_start + mx <= cpu.framebuffer.len and px < mx) {
                                                @memset(cpu.framebuffer[row_start + px .. row_start + mx], sel_bg);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Vi mode cursor overlay (inverted block)
                    if (vi_mode.active) {
                        if (vi_mode.viewportRow(mux.getScrollOffset(), vi_sb)) |vrow| {
                            if (mux.getActivePaneRect(sz.width, sz.height, cpu.padding)) |pr| {
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


