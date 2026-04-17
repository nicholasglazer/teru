//! Windowed mode — teru running in a local window (X11 or Wayland).
//!
//! The 1300-LoC event loop: window creation, font/atlas setup, CPU
//! renderer init, pane spawn/restore, keyboard / mouse / PTY polling,
//! MCP + hook plumbing, config hot-reload, frame pacing.
//!
//! Two public entrypoints that both delegate to the same impl:
//!   * run(...)        — standalone window (no daemon)
//!   * runDaemon(...)  — window attached to a daemon Unix socket
//!
//! Historically all of this lived inline in main.zig; it's unchanged
//! code, just re-homed into its own file with the implicit helpers
//! now reached via `common.xxx`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");
const common = @import("common.zig");
const Multiplexer = @import("../core/Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const platform = @import("../platform/platform.zig");
const render = @import("../render/render.zig");
const Ui = @import("../render/Ui.zig");
const protocol = @import("../agent/protocol.zig");
const in_band = @import("../agent/in_band.zig");
const McpServer = @import("../agent/McpServer.zig");
const PaneBackend = @import("../agent/PaneBackend.zig");
const HookListener = @import("../agent/HookListener.zig");
const Config = @import("../config/Config.zig");
const ConfigWatcher = @import("../config/ConfigWatcher.zig");
const Hooks = @import("../config/Hooks.zig");
const Selection = @import("../core/Selection.zig");
const ViMode = @import("../core/ViMode.zig");
const Clipboard = @import("../core/Clipboard.zig");
const KeyHandler = @import("../core/KeyHandler.zig");
const mouse_handler = @import("../input/mouse.zig");
const ks = @import("../input/keysyms.zig");
const build_options = @import("build_options");

// Cross-platform keyboard: selected at comptime per OS.
const Keyboard = switch (builtin.os.tag) {
    .linux => if (build_options.enable_x11 or build_options.enable_wayland)
        @import("../platform/linux/keyboard.zig").Keyboard
    else
        void,
    .macos => @import("../platform/macos/keyboard.zig").Keyboard,
    .windows => @import("../platform/windows/keyboard.zig").Keyboard,
    else => void,
};

const RestoreInfo = common.RestoreInfo;

pub fn run(allocator: std.mem.Allocator, io: std.Io, restore: ?RestoreInfo, wm_class: ?[]const u8) !void {
    return runImpl(allocator, io, restore, null, wm_class);
}

pub fn runDaemon(allocator: std.mem.Allocator, io: std.Io, daemon_fd: posix.fd_t, wm_class: ?[]const u8) !void {
    return runImpl(allocator, io, null, daemon_fd, wm_class);
}

fn runImpl(allocator: std.mem.Allocator, io: std.Io, restore: ?RestoreInfo, daemon_fd: ?posix.fd_t, wm_class: ?[]const u8) !void {
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

    if (common.cli_no_bar) config.show_status_bar = false;
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
    // exec_argv is consumed by the first pane spawn only
    mux.spawn_config.exec_argv = common.cli_exec_argv;
    mux.notification_duration_ns = @as(i128, config.notification_duration_ms) * 1_000_000;
    mux.persist_session_name = "default";

    // Apply per-workspace config
    for (0..10) |i| {
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
    common.loadHooks(&config, &hooks);

    // MCP server: exposes pane/graph state to Claude Code over Unix socket
    var mcp = McpServer.init(allocator, &mux, &graph) catch |err| blk: {
        var err_buf: [128]u8 = undefined;
        common.outFmt(&err_buf, "[teru] MCP server init failed: {s}\n", .{@errorName(err)});
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
        _ = common.setenv("CLAUDE_PANE_BACKEND_SOCKET", &env_buf, 1);
    }
    if (hook_listener) |*hl| {
        const path = hl.getSocketPath();
        var env_buf: [128:0]u8 = [_:0]u8{0} ** 128;
        @memcpy(env_buf[0..path.len], path);
        _ = common.setenv("TERU_HOOK_SOCKET", &env_buf, 1);
    }
    if (mcp) |*m| {
        const path = m.getSocketPath();
        var env_buf: [128:0]u8 = [_:0]u8{0} ** 128;
        @memcpy(env_buf[0..path.len], path);
        _ = common.setenv("TERU_MCP_SOCKET", &env_buf, 1);
    }

    // Spawn panes (restore or fresh)
    if (restore) |r| {
        if (r.pane_count > 1 or r.workspace_panes[0] > 0) {
            // Workspace-aware restore: spawn panes into their original workspaces
            for (0..10) |wi| {
                const ws_panes = r.workspace_panes[wi];
                if (ws_panes == 0) continue;

                mux.layout_engine.workspaces[wi].layout = @enumFromInt(r.workspace_layouts[wi]);
                mux.layout_engine.workspaces[wi].master_ratio = r.workspace_ratios[wi];

                mux.switchWorkspace(@intCast(wi));
                for (0..ws_panes) |_| {
                    const pid = try mux.spawnPane(grid_rows, grid_cols);
                    if (mux.getPaneById(pid)) |pane| {
                        _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid(), .workspace = @intCast(wi) });
                    }
                    hooks.fire(.spawn);
                }
            }
            mux.switchWorkspace(r.active_workspace);
        } else {
            const pid = try mux.spawnPane(grid_rows, grid_cols);
            if (mux.getPaneById(pid)) |pane| {
                _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid() });
            }
            hooks.fire(.spawn);
        }
    } else {
        const pid = try mux.spawnPane(grid_rows, grid_cols);
        if (mux.getPaneById(pid)) |pane| {
            _ = try graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid() });
        }
        hooks.fire(.spawn);
    }

    // Clear exec_argv so new panes (Alt+C) get the normal shell
    mux.spawn_config.exec_argv = null;

    // Keyboard input: xkbcommon translates XCB keycodes → UTF-8
    // Uses the LIVE X11 keymap (supports dvorak, colemak, any layout)
    var keyboard: ?Keyboard = if (Keyboard != void) blk: {
        const x11_info = win.getX11Info();
        if (x11_info) |info| {
            break :blk Keyboard.initFromX11(info.conn, info.root) catch
                (Keyboard.init() catch null);
        } else {
            const result = Keyboard.init();
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
    var ralt_held = false;
    _ = &ralt_held;
    var force_redraw: bool = false;
    _ = &force_redraw;
    var zoom_pending_resize: bool = false;
    _ = &zoom_pending_resize;
    var zoom_timestamp: i128 = 0;
    _ = &zoom_timestamp;
    var ms = mouse_handler.MouseState{};
    _ = &ms;
    var pty_buf: [8192]u8 = undefined;
    var running = true;
    var last_blink_time: i128 = compat.monotonicNow();
    var cursor_blink_visible: bool = true;

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
                    // Force full redraw to prevent black fragments after uncover / scratchpad.
                    for (mux.panes.items) |*pane| pane.grid.dirty = true;
                },
                .focus_in => {
                    if (Keyboard != void) {
                        if (keyboard) |*kb| kb.resetState();
                    }
                    prefix.reset();
                    if (mux.getActivePaneMut()) |pane| {
                        _ = pane.ptyWrite("\x1b[I") catch {};
                    }
                },
                .focus_out => {
                    if (mux.getActivePaneMut()) |pane| {
                        _ = pane.ptyWrite("\x1b[O") catch {};
                    }
                },
                .wl_modifiers => |mods| {
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            kb.updateModifiers(mods.depressed, mods.latched, mods.locked, mods.group);
                        }
                    }
                },
                .resize => |sz| {
                    renderer.resize(sz.width, sz.height);

                    if (mcp) |*m| {
                        m.screen_width = sz.width;
                        m.screen_height = sz.height;
                    }

                    const new_cols: u16 = @intCast((sz.width -| padding * 2) / atlas.cell_width);
                    const new_rows: u16 = @intCast((sz.height -| padding * 2 -| status_bar_h) / atlas.cell_height);
                    grid_cols = new_cols;
                    grid_rows = new_rows;

                    // Proportional pane resize
                    const LayoutRect = @import("../tiling/LayoutEngine.zig").Rect;
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
                            for (mux.panes.items) |*pane| {
                                if (new_cols != pane.grid.cols or new_rows != pane.grid.rows) {
                                    pane.resize(allocator, new_rows, new_cols) catch continue;
                                }
                            }
                        }
                    } else {
                        for (mux.panes.items) |*pane| {
                            if (new_cols != pane.grid.cols or new_rows != pane.grid.rows) {
                                pane.resize(allocator, new_rows, new_cols) catch continue;
                            }
                        }
                    }

                    mux.setScrollOffset(0);
                },
                .key_press => |key| {
                    if (config.mouse_hide_when_typing and !ms.mouse_cursor_hidden) {
                        win.hideCursor();
                        ms.mouse_cursor_hidden = true;
                    }
                    if (config.cursor_blink) {
                        cursor_blink_visible = true;
                        last_blink_time = compat.monotonicNow();
                        switch (renderer) {
                            .cpu => |*cpu| cpu.cursor_blink_on = true,
                            .tty => {},
                        }
                    }

                    if (key.keycode == platform.types.keycodes.RALT) ralt_held = true;

                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            kb.updateKey(key.keycode, true);

                            const keysym = kb.getKeysym(key.keycode);

                            // Vi/copy mode: intercept ALL keys
                            if (vi_mode.active) {
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
                                        .search => {
                                            search_mode = true;
                                        },
                                        .none => {},
                                    }
                                    if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    continue;
                                }

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
                                        .search => {
                                            search_mode = true;
                                        },
                                        .none => {},
                                    }
                                    if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                }
                                continue;
                            }

                            if (search_mode) {
                                var search_key_buf: [32]u8 = undefined;
                                const slen = kb.processKey(key.keycode, &search_key_buf);

                                if (keysym == ks.Escape) {
                                    search_mode = false;
                                    search_len = 0;
                                    if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                } else if (keysym == ks.Return) {
                                    search_mode = false;
                                    if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                } else if (keysym == ks.BackSpace) {
                                    if (search_len > 0) {
                                        search_len -= 1;
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                } else if (slen > 0 and search_key_buf[0] >= 32 and search_key_buf[0] < 127) {
                                    if (search_len < search_query.len) {
                                        search_query[search_len] = search_key_buf[0];
                                        search_len += 1;
                                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                                    }
                                }
                                continue;
                            }

                            // PageUp/Down: scrollback browsing
                            if (keysym == ks.Page_Up) {
                                const max_offset = mux.getScrollbackLineCount();
                                if (max_offset > 0) {
                                    mux.setScrollOffset(@min(mux.getScrollOffset() + grid_rows, max_offset));
                                }
                                var dummy: [32]u8 = undefined;
                                _ = kb.processKey(key.keycode, &dummy);
                                continue;
                            } else if (keysym == ks.Page_Down) {
                                if (mux.getScrollOffset() > 0) {
                                    const so = mux.getScrollOffset();
                                    mux.setScrollOffset(so -| grid_rows);
                                }
                                var dummy: [32]u8 = undefined;
                                _ = kb.processKey(key.keycode, &dummy);
                                continue;
                            }

                            // Ctrl+Shift+C/V: copy selection / paste
                            if (key.modifiers & ks.CTRL_MASK != 0 and key.modifiers & ks.SHIFT_MASK != 0) {
                                if (keysym == ks.C_upper or keysym == ks.C_lower) {
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
                                if (keysym == ks.V_upper or keysym == ks.V_lower) {
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
                            {
                                const ks_char: u8 = if (keysym > 0x1f and keysym < 0x80) @intCast(keysym) else if (keysym == ks.Return) '\r' else 0;
                                const kb_mode: @import("../config/Keybinds.zig").Mode = if (prefix.awaiting) .prefix else .normal;
                                if (KeyHandler.lookupConfigAction(&config.keybinds, kb_mode, key.modifiers, ks_char, ralt_held)) |kb_action| {
                                    if (prefix.awaiting) prefix.reset();
                                    const action = KeyHandler.executeAction(kb_action, &mux);
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
                                        const dir: @import("../tiling/LayoutEngine.zig").SplitDirection = if (action == .split_horizontal) .horizontal else .vertical;
                                        const id = mux.spawnPane(grid_rows, grid_cols) catch continue;
                                        if (mux.getPaneById(id)) |pane| {
                                            _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid() }) catch |e| {
                                            std.debug.print("teru: graph.spawn after split failed: {s}\n", .{@errorName(e)});
                                        };
                                        }
                                        hooks.fire(.spawn);
                                        const ws = &mux.layout_engine.workspaces[mux.active_workspace];
                                        ws.addNodeSplit(mux.allocator, id, dir) catch |e| {
                                            std.debug.print("teru: addNodeSplit failed: {s}\n", .{@errorName(e)});
                                        };
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
                                        if (daemon_fd != null) {
                                            running = false;
                                        } else {
                                            mux.notify("No daemon — use teru -n NAME for persistent sessions");
                                        }
                                        continue;
                                    }
                                    if (action == .copy_selection) {
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
                                    if (action == .paste_clipboard) {
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
                                    if (action == .toggle_zoom) {
                                        const sz = win.getSize();
                                        mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                        for (mux.panes.items) |*p| p.grid.dirty = true;
                                        force_redraw = true;
                                        continue;
                                    }
                                    if (action == .toggle_status_bar) {
                                        config.show_status_bar = !config.show_status_bar;
                                        status_bar_h = if (config.show_status_bar) atlas.cell_height + 4 else 0;
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
                                            const new_atlas = atlas.rasterizeAtSize(new_size) catch continue;
                                            atlas.deinit();
                                            atlas = new_atlas;
                                            font_size = new_size;

                                            switch (renderer) {
                                                .cpu => |*cpu| {
                                                    cpu.glyph_atlas_bold = &.{};
                                                    cpu.glyph_atlas_italic = &.{};
                                                    cpu.glyph_atlas_bold_italic = &.{};
                                                },
                                                .tty => {},
                                            }

                                            renderer.updateAtlas(atlas.atlas_data, atlas.atlas_width, atlas.atlas_height);
                                            switch (renderer) {
                                                .cpu => |*cpu| {
                                                    cpu.cell_width = atlas.cell_width;
                                                    cpu.cell_height = atlas.cell_height;
                                                },
                                                .tty => {},
                                            }
                                            status_bar_h = if (config.show_status_bar) atlas.cell_height + 4 else 0;

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

                                            zoom_pending_resize = true;
                                            zoom_timestamp = compat.monotonicNow();
                                        }
                                    }
                                    continue;
                                }
                            }

                            if (len == 0) continue;

                            if (mux.getScrollOffset() > 0 or mux.getScrollPixel() > 0) {
                                const exits_scroll = if (len == 1)
                                    key_buf[0] >= 0x20 or
                                        key_buf[0] == 0x0D or
                                        key_buf[0] == 0x0A or
                                        key_buf[0] == 0x08 or
                                        key_buf[0] == 0x09
                                else
                                    false;
                                if (exits_scroll) {
                                    mux.setScrollOffset(0);
                                }
                            }

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
                                    const dir: @import("../tiling/LayoutEngine.zig").SplitDirection = if (action == .split_horizontal) .horizontal else .vertical;
                                    const id = mux.spawnPane(grid_rows, grid_cols) catch continue;
                                    if (mux.getPaneById(id)) |pane| {
                                        _ = graph.spawn(.{ .name = "shell", .kind = .shell, .pid = pane.childPid() }) catch |e| {
                                            std.debug.print("teru: graph.spawn after split failed: {s}\n", .{@errorName(e)});
                                        };
                                    }
                                    hooks.fire(.spawn);
                                    const ws = &mux.layout_engine.workspaces[mux.active_workspace];
                                    ws.addNodeSplit(mux.allocator, id, dir) catch |e| {
                                        std.debug.print("teru: addNodeSplit failed: {s}\n", .{@errorName(e)});
                                    };
                                    const sz = win.getSize();
                                    mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                                }
                                continue;
                            }

                            // Forward to active pane; Alt prefix sends ESC first.
                            const ALT_MASK: u32 = 8;
                            if (mux.getActivePane()) |pane| {
                                if (key.modifiers & ALT_MASK != 0 and len > 0 and key_buf[0] != 0x1b) {
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
                        if (key.keycode >= 128) continue;
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
                    if (Keyboard != void) {
                        if (keyboard) |*kb| {
                            kb.updateKey(key.keycode, false);
                        }
                    }
                },
                .mouse_press => |mouse| {
                    if (ms.mouse_cursor_hidden) {
                        win.showCursor();
                        ms.mouse_cursor_hidden = false;
                    }
                    const lp = mouse_handler.LayoutParams{
                        .cell_width = atlas.cell_width,
                        .cell_height = atlas.cell_height,
                        .grid_rows = grid_rows,
                        .grid_cols = grid_cols,
                        .padding = padding,
                        .status_bar_h = status_bar_h,
                    };
                    const cfg = mouse_handler.MouseConfig{
                        .copy_on_select = config.copy_on_select,
                        .scroll_speed = config.scroll_speed,
                        .word_delimiters = config.word_delimiters orelse " \t{}[]()\"'`,;:@",
                        .show_status_bar = config.show_status_bar,
                    };
                    const sz = win.getSize();
                    const result = mouse_handler.handleMousePress(&mux, mouse, &selection, &ms, lp, cfg, allocator, sz.width, sz.height);
                    if (result.panes_changed) {
                        const sz2 = win.getSize();
                        mux.resizePanePtys(sz2.width, sz2.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                        for (mux.panes.items) |*p| p.grid.dirty = true;
                        force_redraw = true;
                    }
                    if (result.dirty) {
                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                        force_redraw = true;
                    }
                    if (result.consumed) continue;
                },
                .mouse_release => |mouse| {
                    const lp = mouse_handler.LayoutParams{
                        .cell_width = atlas.cell_width,
                        .cell_height = atlas.cell_height,
                        .grid_rows = grid_rows,
                        .grid_cols = grid_cols,
                        .padding = padding,
                        .status_bar_h = status_bar_h,
                    };
                    const sz = win.getSize();
                    const release_cfg = mouse_handler.MouseConfig{
                        .copy_on_select = config.copy_on_select,
                        .scroll_speed = config.scroll_speed,
                        .word_delimiters = config.word_delimiters orelse " \t{}[]()\"'`,;:@",
                        .show_status_bar = config.show_status_bar,
                    };
                    const result = mouse_handler.handleMouseRelease(&mux, mouse, &selection, &ms, lp, release_cfg);
                    if (result.border_drag_finished) {
                        mux.resizePanePtys(sz.width, sz.height, atlas.cell_width, atlas.cell_height, padding, status_bar_h);
                        for (mux.panes.items) |*p| p.grid.dirty = true;
                        force_redraw = true;
                    }
                    if (result.dirty) {
                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                    }
                },
                .mouse_motion => |motion| {
                    const lp = mouse_handler.LayoutParams{
                        .cell_width = atlas.cell_width,
                        .cell_height = atlas.cell_height,
                        .grid_rows = grid_rows,
                        .grid_cols = grid_cols,
                        .padding = padding,
                        .status_bar_h = status_bar_h,
                    };
                    const sz = win.getSize();
                    const result = mouse_handler.handleMouseMotion(&mux, motion.x, motion.y, motion.modifiers, &selection, &ms, lp, sz.width, sz.height);
                    if (result.show_cursor) {
                        win.showCursor();
                    }
                    if (result.dirty) {
                        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
                        force_redraw = true;
                    }
                },
                else => {},
            }
        }

        // Track scrollback size before polling so we can pin scroll position.
        const sb_count_before: u64 = if (mux.getActivePane()) |pane|
            if (pane.grid.scrollback) |sb| sb.lineCount() else 0
        else
            0;

        // Deferred variant atlas rebuild after font zoom (150ms after last zoom)
        if (zoom_pending_resize) {
            const now = compat.monotonicNow();
            if (now - zoom_timestamp > 150_000_000) {
                zoom_pending_resize = false;

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
            common.pollDaemonOutput(dfd, &mux, &pty_buf)
        else
            mux.pollPtys(&pty_buf);

        // If new lines were added to scrollback, adjust scroll_offset and
        // selection to keep them pinned to the same content.
        if (had_output) {
            if (mux.getActivePane()) |pane| {
                var scrolled = false;
                if (pane.grid.scrollback) |sb| {
                    const sb_count_after = sb.lineCount();
                    if (sb_count_after > sb_count_before) {
                        const new_lines: u32 = @intCast(sb_count_after - sb_count_before);
                        scrolled = true;
                        if (mux.getScrollOffset() > config.scroll_speed) {
                            pane.scroll_offset += new_lines;
                        }
                        if (selection.active) {
                            selection.start_row += new_lines;
                            selection.end_row += new_lines;
                        }
                    }
                }

                if (selection.active and scrolled and !ms.mouse_down) {
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
                common.processHookEvent(&graph, &hooks, ev, allocator);
            }
        }

        // Layout/session save: debounced 100ms after last mutation.
        if ((config.restore_layout or config.persist_session) and mux.persist_dirty) {
            const elapsed = compat.monotonicNow() - mux.persist_dirty_since;
            if (elapsed >= common.PERSIST_DEBOUNCE_NS) {
                mux.persist_dirty = false;
                common.persistSave(&mux, &graph, allocator, io);
            }
        }

        // Agent protocol events on all panes
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

                            if (event_data.group) |group_name| {
                                common.autoAssignAgentWorkspace(&mux, node_id, group_name);
                            }
                        },
                        .stop => {
                            if (event_data.name) |name| {
                                common.markAgentFinished(&graph, name, event_data.exit_status);
                            }
                        },
                        .status => {
                            if (event_data.name) |name| {
                                common.updateAgentStatusByName(&graph, name, event_data.task_desc, event_data.progress);
                            }
                        },
                        .task => {
                            if (event_data.name) |name| {
                                common.updateAgentStatusByName(&graph, name, event_data.task_desc, null);
                            }
                        },
                        .group => {},
                        .meta => {},
                        .query => {
                            if (mcp) |*m| {
                                in_band.handleQuery(pane, event_data, m);
                            }
                        },
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

                    for (mux.panes.items) |*pane| pane.grid.dirty = true;
                    mux.notify("Config reloaded");

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
            if (now_blink - last_blink_time >= common.CURSOR_BLINK_NS) {
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
        // sending a batch of screen updates. Prevents flicker in TUI apps.
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

            switch (renderer) {
                .cpu => |*cpu| {
                    const sz = win.getSize();
                    const vi_sb: u32 = mux.getScrollbackLineCount();
                    var vi_sel = if (vi_mode.active) vi_mode.toSelection(mux.getScrollOffset(), vi_sb) else null;
                    const sel_ptr: ?*const Selection = if (vi_sel != null) &vi_sel.? else if (selection.active) &selection else null;
                    mux.renderAllWithSelection(cpu, sz.width, sz.height, atlas.cell_width, atlas.cell_height, sel_ptr, status_bar_h);

                    if (search_mode or search_len > 0) {
                        if (mux.getActivePane()) |pane| {
                            Ui.renderSearchOverlay(cpu, &pane.grid, search_query[0..search_len], search_mode, atlas.cell_width, atlas.cell_height);
                        }
                    }

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
                    if (ms.hover_url_active) {
                        if (mux.getActivePaneRect(sz.width, sz.height, cpu.padding, status_bar_h)) |pr| {
                            const cw = atlas.cell_width;
                            const ch = atlas.cell_height;
                            var ucol: u16 = ms.hover_url_start;
                            while (ucol <= ms.hover_url_end) : (ucol += 1) {
                                const ux = @as(usize, pr.x) + @as(usize, ucol) * cw;
                                const uy = @as(usize, pr.y) + @as(usize, ms.hover_url_row) * ch + ch - 1;
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
                                            cpu.framebuffer[idx] ^= 0x00FFFFFF;
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

            for (mux.panes.items) |*pane| {
                pane.grid.dirty = false;
            }

            // Frame rate limiter: cap at ~120fps to prevent CPU spin.
            io.sleep(.fromMilliseconds(8), .awake) catch {};
        } else {
            // Idle: sleep longer when nothing to render.
            io.sleep(.fromMilliseconds(16), .awake) catch {};
        }
    }

    if (config.restore_layout or config.persist_session) {
        common.persistSave(&mux, &graph, allocator, io);
    }
}
