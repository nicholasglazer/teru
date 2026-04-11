//! Compositor server state. Owns all wlroots objects, listeners, and the
//! connection between libteru's tiling engine and the wlroots scene graph.

const std = @import("std");
const wlr = @import("wlr.zig");
const Output = @import("Output.zig");
const XdgView = @import("XdgView.zig");
const TerminalPane = @import("TerminalPane.zig");
const XwaylandView = @import("XwaylandView.zig");
const Launcher = @import("Launcher.zig");
const Bar = @import("Bar.zig");
const WmConfig = @import("WmConfig.zig");
const NodeRegistry = @import("Node.zig");
const teru = @import("teru");
const LayoutEngine = teru.LayoutEngine;
const Keybinds = teru.Keybinds;
const KB = Keybinds.Keybinds;
const KBAction = Keybinds.Action;
const KBMods = Keybinds.Mods;

const Server = @This();

pub const CursorMode = enum { normal, move, resize };

// ── Zig allocator ─────────────────────────────────────────────

zig_allocator: std.mem.Allocator,

// ── wlroots objects (owned) ────────────────────────────────────

display: *wlr.wl_display,
backend: *wlr.wlr_backend,
renderer: *wlr.wlr_renderer,
allocator: *wlr.wlr_allocator,
scene: *wlr.wlr_scene,
output_layout: *wlr.wlr_output_layout,
xdg_shell: *wlr.wlr_xdg_shell,
seat: *wlr.wlr_seat,
cursor: *wlr.wlr_cursor,
cursor_mgr: *wlr.wlr_xcursor_manager,
xkb_ctx: *wlr.xkb_context,
session: ?*wlr.wlr_session = null,
xwayland: ?*wlr.wlr_xwayland = null,
wlr_compositor: ?*wlr.wlr_compositor = null, // needed for xwayland_create

// ── Tiling & nodes ─────────────────────────────────────────────

layout_engine: LayoutEngine,
nodes: NodeRegistry,
keybinds: KB = .{},
font_atlas: ?*teru.render.FontAtlas = null, // shared across all terminal panes
next_node_id: u64 = 1,
focused_view: ?*XdgView = null,
focused_terminal: ?*TerminalPane = null,
terminal_panes: [NodeRegistry.max_nodes]?*TerminalPane = [_]?*TerminalPane{null} ** NodeRegistry.max_nodes,
terminal_count: u16 = 0,
bar: ?*Bar = null,
workspace_trees: [10]?*wlr.wlr_scene_tree = [_]?*wlr.wlr_scene_tree{null} ** 10,

// Fullscreen state: tracks which node is fullscreen (null = none)
fullscreen_node: ?u64 = null,
fullscreen_prev_bar_top: bool = true,
fullscreen_prev_bar_bottom: bool = false,

// Scratchpads: 9 floating terminal panes (Alt+RAlt+1-9)
scratchpads: [9]?*TerminalPane = [_]?*TerminalPane{null} ** 9,
scratchpad_visible: [9]bool = [_]bool{false} ** 9,

// Mouse move/resize state for floating windows
cursor_mode: CursorMode = .normal,
grab_node_id: ?u64 = null,
grab_x: f64 = 0,
grab_y: f64 = 0,
grab_w: u32 = 0,
grab_h: u32 = 0,

// Internal clipboard buffer (Ctrl+Shift+C/V between terminal panes)
clipboard_buf: [8192]u8 = undefined,
clipboard_len: u16 = 0,

// Built-in launcher
launcher: Launcher = .{},

// teruwm-specific config (~/.config/teruwm/config)
wm_config: WmConfig = .{},

// ── Listeners ──────────────────────────────────────────────────

new_output: wlr.wl_listener = makeListener(handleNewOutput),
new_input: wlr.wl_listener = makeListener(handleNewInput),
new_xdg_toplevel: wlr.wl_listener = makeListener(handleNewXdgToplevel),
cursor_motion: wlr.wl_listener = makeListener(handleCursorMotion),
cursor_motion_absolute: wlr.wl_listener = makeListener(handleCursorMotionAbsolute),
cursor_button: wlr.wl_listener = makeListener(handleCursorButton),
cursor_frame: wlr.wl_listener = makeListener(handleCursorFrame),
request_set_cursor: wlr.wl_listener = makeListener(handleRequestSetCursor),
new_xwayland_surface: wlr.wl_listener = makeListener(handleNewXwaylandSurface),

// ── Init ───────────────────────────────────────────────────────

/// Allocate Server on the heap and initialize in-place.
/// Critical: wl_listeners are registered by pointer. If Server is on the stack
/// and later moved/copied, those pointers dangle. This function ensures the
/// Server has a stable heap address before any listener is registered.
pub fn initOnHeap(display: *wlr.wl_display, event_loop: *wlr.wl_event_loop, allocator: std.mem.Allocator) !*Server {
    const self = try allocator.create(Server);
    errdefer allocator.destroy(self);
    self.* = try initFields(display, event_loop, allocator);
    registerListeners(self);
    return self;
}

fn initFields(display: *wlr.wl_display, event_loop: *wlr.wl_event_loop, allocator: std.mem.Allocator) !Server {
    // Backend (capture session for VT switching)
    var session_ptr: ?*wlr.wlr_session = null;
    const backend = wlr.wlr_backend_autocreate(event_loop, &session_ptr) orelse
        return error.BackendCreateFailed;

    // Renderer + allocator
    const renderer = wlr.wlr_renderer_autocreate(backend) orelse
        return error.RendererCreateFailed;
    _ = wlr.wlr_renderer_init_wl_display(renderer, display);

    const wlr_alloc = wlr.wlr_allocator_autocreate(backend, renderer) orelse
        return error.AllocatorCreateFailed;

    // Compositor protocol (wl_compositor, wl_subcompositor)
    const wlr_comp = wlr.wlr_compositor_create(display, 5, renderer);
    _ = wlr.wlr_subcompositor_create(display);
    _ = wlr.wlr_data_device_manager_create(display);

    // Scene graph
    const scene = wlr.wlr_scene_create() orelse
        return error.SceneCreateFailed;

    // Note: background color is handled by wlr_renderer_clear in the
    // Output frame handler, not by a scene rect (avoids node type issues).

    // Output layout
    const output_layout = wlr.wlr_output_layout_create(display) orelse
        return error.OutputLayoutCreateFailed;
    _ = wlr.wlr_scene_attach_output_layout(scene, output_layout);

    // XDG shell
    const xdg_shell = wlr.wlr_xdg_shell_create(display, 3) orelse
        return error.XdgShellCreateFailed;

    // Cursor
    const cursor = wlr.wlr_cursor_create() orelse
        return error.CursorCreateFailed;
    wlr.wlr_cursor_attach_output_layout(cursor, output_layout);

    const cursor_mgr = wlr.wlr_xcursor_manager_create(null, 24) orelse
        return error.CursorMgrCreateFailed;

    // Seat
    const seat = wlr.wlr_seat_create(display, "seat0") orelse
        return error.SeatCreateFailed;

    // XKB context for keyboards
    const xkb_ctx = wlr.xkb_context_new(0) orelse
        return error.XkbContextFailed;

    // Load keybinds: teru defaults (Alt+key) + compositor layer (Super+key)
    var keybinds = KB{};
    keybinds.loadDefaults();
    keybinds.loadCompositorDefaults();

    // Return fields only — listeners are registered separately by initOnHeap
    // after the struct has its final heap address.
    return Server{
        .zig_allocator = allocator,
        .keybinds = keybinds,
        .layout_engine = LayoutEngine.init(allocator),
        .nodes = .{},
        .display = display,
        .backend = backend,
        .renderer = renderer,
        .allocator = wlr_alloc,
        .scene = scene,
        .output_layout = output_layout,
        .xdg_shell = xdg_shell,
        .seat = seat,
        .cursor = cursor,
        .cursor_mgr = cursor_mgr,
        .xkb_ctx = xkb_ctx,
        .session = session_ptr,
        .wlr_compositor = wlr_comp,
    };
}

/// Register wl_signal listeners. Must be called AFTER the Server has its
/// final heap address (listeners are stored by pointer in wlroots linked lists).
fn registerListeners(self: *Server) void {
    wlr.wl_signal_add(wlr.miozu_backend_new_output(self.backend), &self.new_output);
    wlr.wl_signal_add(wlr.miozu_backend_new_input(self.backend), &self.new_input);
    wlr.wl_signal_add(wlr.miozu_xdg_shell_new_toplevel(self.xdg_shell), &self.new_xdg_toplevel);
    wlr.wl_signal_add(wlr.miozu_cursor_motion(self.cursor), &self.cursor_motion);
    wlr.wl_signal_add(wlr.miozu_cursor_motion_absolute(self.cursor), &self.cursor_motion_absolute);
    wlr.wl_signal_add(wlr.miozu_cursor_button(self.cursor), &self.cursor_button);
    wlr.wl_signal_add(wlr.miozu_cursor_frame(self.cursor), &self.cursor_frame);
    wlr.wl_signal_add(wlr.miozu_seat_request_set_cursor(self.seat), &self.request_set_cursor);

    // XWayland (lazy start — only spawns Xwayland process when an X11 client connects)
    if (self.wlr_compositor) |comp| {
        if (wlr.wlr_xwayland_create(self.display, comp, true)) |xwl| {
            self.xwayland = xwl;
            wlr.wl_signal_add(wlr.miozu_xwayland_new_surface(xwl), &self.new_xwayland_surface);
            wlr.wlr_xwayland_set_seat(xwl, self.seat);
            std.debug.print("teruwm: XWayland enabled\n", .{});
        } else {
            std.debug.print("teruwm: XWayland init failed (X11 apps won't work)\n", .{});
        }
    }
}

/// Apply loaded config to server state: font, colors, keybinds, workspace layouts, bars.
pub fn applyConfig(self: *Server, config: *const teru.Config, allocator: std.mem.Allocator, io: std.Io) void {
    // ── Font atlas from config ──────────────────────────────
    if (teru.render.FontAtlas.init(allocator, config.font_path, config.font_size, io)) |atlas| {
        const fa = allocator.create(teru.render.FontAtlas) catch return;
        fa.* = atlas;
        self.font_atlas = fa;
        std.debug.print("teruwm: font loaded ({d}x{d} cells)\n", .{ fa.cell_width, fa.cell_height });
    } else |err| {
        std.debug.print("teruwm: font init failed: {}, using fallback\n", .{err});
    }

    // ── Keybinds: load teru defaults + config overrides + compositor layer ──
    self.keybinds = config.keybinds;
    self.keybinds.loadCompositorDefaults();

    // ── Launcher ($PATH scan) ─────────────────────────────────
    self.launcher.init();

    // ── Per-workspace layouts from config ────────────────────
    for (0..10) |i| {
        if (config.workspace_layout_counts[i] > 0) {
            self.layout_engine.workspaces[i].setLayouts(
                config.workspace_layout_lists[i][0..config.workspace_layout_counts[i]],
            );
        } else if (config.workspace_layouts[i]) |layout| {
            self.layout_engine.workspaces[i].layout = layout;
        }
        if (config.workspace_ratios[i]) |ratio| {
            self.layout_engine.workspaces[i].master_ratio = ratio;
        }
        if (config.workspace_names[i]) |name| {
            self.layout_engine.workspaces[i].name = name;
        }
    }

    // ── Color scheme for terminal pane rendering ─────────────
    // Stored on server, applied to each TerminalPane's SoftwareRenderer

    // ── teruwm-specific config (~/.config/teruwm/config) ────
    self.wm_config = WmConfig.load(io);
    if (self.wm_config.rule_count > 0) {
        std.debug.print("teruwm: loaded {d} window rules\n", .{self.wm_config.rule_count});
    }
}

/// Apply teruwm bar config to the bar instance (called after bar creation).
pub fn applyWmBar(self: *Server) void {
    if (self.bar) |b| {
        const wc = &self.wm_config;
        b.configure(
            wc.bar_top_left,
            wc.bar_top_center,
            wc.bar_top_right,
            wc.bar_bottom_left,
            wc.bar_bottom_center,
            wc.bar_bottom_right,
        );
    }
}

pub fn deinit(self: *Server) void {
    wlr.xkb_context_unref(self.xkb_ctx);
}

// ── Signal handlers ────────────────────────────────────────────

fn handleNewOutput(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_output", listener);
    const wlr_output: *wlr.wlr_output = @ptrCast(@alignCast(data orelse return));

    _ = Output.create(server, wlr_output, server.zig_allocator) catch {
        std.debug.print("teruwm: failed to create output\n", .{});
        return;
    };
}

fn handleNewInput(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_input", listener);
    const device: *wlr.wlr_input_device = @ptrCast(@alignCast(data orelse return));

    const device_type = wlr.miozu_input_device_type(device);

    if (device_type == wlr.WLR_INPUT_DEVICE_KEYBOARD) {
        server.setupKeyboard(device);
    } else if (device_type == wlr.WLR_INPUT_DEVICE_POINTER) {
        wlr.wlr_cursor_attach_input_device(server.cursor, device);
    }

    // Update seat capabilities
    var caps: u32 = wlr.WL_SEAT_CAPABILITY_POINTER;
    caps |= wlr.WL_SEAT_CAPABILITY_KEYBOARD;
    wlr.wlr_seat_set_capabilities(server.seat, caps);
}

fn handleNewXdgToplevel(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_xdg_toplevel", listener);
    const toplevel: *wlr.wlr_xdg_toplevel = @ptrCast(@alignCast(data orelse return));

    _ = XdgView.create(server, toplevel);
}

fn handleCursorMotion(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_motion", listener);
    const event: *wlr.wlr_pointer_motion_event = @ptrCast(@alignCast(data orelse return));
    wlr.wlr_cursor_move(server.cursor, null, wlr.miozu_pointer_motion_dx(event), wlr.miozu_pointer_motion_dy(event));
    server.processCursorMotion(wlr.miozu_pointer_motion_time(event));
}

fn handleCursorMotionAbsolute(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_motion_absolute", listener);
    const event: *wlr.wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(data orelse return));
    wlr.wlr_cursor_warp_absolute(server.cursor, null, wlr.miozu_pointer_motion_abs_x(event), wlr.miozu_pointer_motion_abs_y(event));
    server.processCursorMotion(wlr.miozu_pointer_motion_abs_time(event));
}

fn handleCursorButton(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_button", listener);
    const event: *wlr.wlr_pointer_button_event = @ptrCast(@alignCast(data orelse return));

    const button = wlr.miozu_pointer_button_button(event);
    const state = wlr.miozu_pointer_button_state(event);

    // Button release: end any active grab
    if (state == 0) {
        if (server.cursor_mode != .normal) {
            server.cursor_mode = .normal;
            server.grab_node_id = null;
        }
        _ = wlr.wlr_seat_pointer_notify_button(server.seat, wlr.miozu_pointer_button_time(event), button, state);
        return;
    }

    // Button press: check for Super modifier to initiate move/resize on floating windows
    const keyboard = wlr.miozu_seat_get_keyboard(server.seat);
    const super_held = if (keyboard) |kb|
        if (wlr.miozu_keyboard_xkb_state(kb)) |xkb_st|
            wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0
        else
            false
    else
        false;

    if (super_held) {
        // Find the focused floating node to grab
        const nid: ?u64 = if (server.focused_terminal) |tp|
            tp.node_id
        else if (server.focused_view) |view|
            view.node_id
        else
            null;

        if (nid) |id| {
            if (server.nodes.findById(id)) |slot| {
                if (server.nodes.floating[slot]) {
                    const cx = wlr.miozu_cursor_x(server.cursor);
                    const cy = wlr.miozu_cursor_y(server.cursor);

                    if (button == 272) { // BTN_LEFT: move
                        server.cursor_mode = .move;
                        server.grab_node_id = id;
                        server.grab_x = cx - @as(f64, @floatFromInt(server.nodes.pos_x[slot]));
                        server.grab_y = cy - @as(f64, @floatFromInt(server.nodes.pos_y[slot]));
                        return;
                    } else if (button == 274) { // BTN_RIGHT: resize
                        server.cursor_mode = .resize;
                        server.grab_node_id = id;
                        server.grab_x = cx;
                        server.grab_y = cy;
                        server.grab_w = server.nodes.width[slot];
                        server.grab_h = server.nodes.height[slot];
                        return;
                    }
                }
            }
        }
    }

    // Click-to-focus: find which terminal pane is under the cursor
    if (state == 1) { // press
        const cx = wlr.miozu_cursor_x(server.cursor);
        const cy = wlr.miozu_cursor_y(server.cursor);
        // Check each terminal pane's rect
        for (server.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| {
                if (server.nodes.findById(tp.node_id)) |slot| {
                    const px = server.nodes.pos_x[slot];
                    const py = server.nodes.pos_y[slot];
                    const pw: i32 = @intCast(server.nodes.width[slot]);
                    const ph: i32 = @intCast(server.nodes.height[slot]);
                    if (@as(i32, @intFromFloat(cx)) >= px and @as(i32, @intFromFloat(cx)) < px + pw and
                        @as(i32, @intFromFloat(cy)) >= py and @as(i32, @intFromFloat(cy)) < py + ph)
                    {
                        server.focused_terminal = tp;
                        server.focused_view = null;
                        // Update layout engine focus
                        const ws = server.layout_engine.getActiveWorkspace();
                        for (ws.node_ids.items, 0..) |nid, idx| {
                            if (nid == tp.node_id) {
                                ws.active_index = @intCast(idx);
                                break;
                            }
                        }
                        // Re-render borders + bar
                        for (server.terminal_panes) |mtp| {
                            if (mtp) |t| t.render();
                        }
                        if (server.bar) |b| b.render(server);
                        break;
                    }
                }
            }
        }
    }

    _ = wlr.wlr_seat_pointer_notify_button(server.seat, wlr.miozu_pointer_button_time(event), button, state);
}

fn handleCursorFrame(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_frame", listener);
    wlr.wlr_seat_pointer_notify_frame(server.seat);
}

fn handleNewXwaylandSurface(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_xwayland_surface", listener);
    const surface: *wlr.wlr_xwayland_surface = @ptrCast(@alignCast(data orelse return));
    _ = XwaylandView.create(server, surface);
}

fn handleRequestSetCursor(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "request_set_cursor", listener);
    const event_ptr = data orelse return;
    // Allow the focused client to set the cursor image
    const surface = wlr.miozu_set_cursor_event_surface(event_ptr);
    const hx = wlr.miozu_set_cursor_event_hotspot_x(event_ptr);
    const hy = wlr.miozu_set_cursor_event_hotspot_y(event_ptr);
    if (surface) |s| {
        wlr.wlr_cursor_set_surface(server.cursor, s, hx, hy);
    } else {
        wlr.wlr_cursor_set_surface(server.cursor, null, 0, 0);
    }
}

// ── Keyboard setup ─────────────────────────────────────────────

/// Per-keyboard state — allocated once per keyboard device, freed never
/// (keyboards rarely disconnect). Embeds listeners for O(1) dispatch.
const Keyboard = struct {
    server: *Server,
    wlr_keyboard: *wlr.wlr_keyboard,
    key_listener: wlr.wl_listener,
    modifiers_listener: wlr.wl_listener,

    fn handleKey(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
        const kb: *Keyboard = @fieldParentPtr("key_listener", listener);
        const event_ptr = data orelse return;

        const keycode = wlr.miozu_keyboard_key_keycode(event_ptr);
        const key_state = wlr.miozu_keyboard_key_state(event_ptr);
        const time = wlr.miozu_keyboard_key_time(event_ptr);
        const xkb_st = wlr.miozu_keyboard_xkb_state(kb.wlr_keyboard) orelse return;

        // Only handle keybinds on key press, not release
        if (key_state == 1) {
            if (kb.server.handleKey(keycode, xkb_st)) return;
        }

        // Route to focused terminal pane (convert keysym → UTF-8 → PTY)
        if (kb.server.focused_terminal) |tp| {
            if (key_state == 1) { // press only
                var buf: [8]u8 = undefined;
                const sym = wlr.xkb_state_key_get_one_sym(xkb_st, keycode + 8);
                const ctrl = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_CTRL, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;
                const shift = wlr.xkb_state_mod_name_is_active(xkb_st, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;

                // Ctrl+Shift+C: copy cursor line to internal clipboard
                if (ctrl and shift and (sym == 'C' or sym == 'c')) {
                    kb.server.clipboardCopyCursorLine(tp);
                    return;
                }

                // Ctrl+Shift+V: paste internal clipboard to terminal PTY
                if (ctrl and shift and (sym == 'V' or sym == 'v')) {
                    kb.server.clipboardPaste(tp);
                    return;
                }

                // Ctrl+key → control character (Ctrl+C = 0x03, etc.)
                if (ctrl and sym >= 'a' and sym <= 'z') {
                    buf[0] = @intCast(sym - 'a' + 1);
                    tp.writeInput(buf[0..1]);
                } else {
                    // Normal key → UTF-8
                    const len = wlr.xkb_state_key_get_utf8(xkb_st, keycode + 8, &buf, buf.len);
                    if (len > 0) {
                        tp.writeInput(buf[0..@intCast(len)]);
                    }
                }
            }
            return;
        }

        // Forward to focused Wayland client surface
        wlr.wlr_seat_keyboard_notify_key(kb.server.seat, time, keycode, key_state);
    }

    fn handleModifiers(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
        const kb: *Keyboard = @fieldParentPtr("modifiers_listener", listener);
        wlr.wlr_seat_set_keyboard(kb.server.seat, kb.wlr_keyboard);
        wlr.wlr_seat_keyboard_notify_modifiers(kb.server.seat, wlr.miozu_keyboard_modifiers_ptr(kb.wlr_keyboard));
    }
};

fn setupKeyboard(self: *Server, device: *wlr.wlr_input_device) void {
    const keyboard = wlr.miozu_input_device_keyboard(device) orelse return;

    // Create keymap from system defaults (respects XKB_DEFAULT_LAYOUT etc.)
    const keymap = wlr.xkb_keymap_new_from_names(self.xkb_ctx, null, 0) orelse return;
    defer wlr.xkb_keymap_unref(keymap);

    _ = wlr.wlr_keyboard_set_keymap(keyboard, keymap);
    wlr.wlr_keyboard_set_repeat_info(keyboard, 25, 600);

    // Allocate per-keyboard state
    const kb = self.zig_allocator.create(Keyboard) catch return;
    kb.* = .{
        .server = self,
        .wlr_keyboard = keyboard,
        .key_listener = .{ .link = .{ .prev = null, .next = null }, .notify = Keyboard.handleKey },
        .modifiers_listener = .{ .link = .{ .prev = null, .next = null }, .notify = Keyboard.handleModifiers },
    };

    wlr.wl_signal_add(wlr.miozu_keyboard_key(keyboard), &kb.key_listener);
    wlr.wl_signal_add(wlr.miozu_keyboard_modifiers(keyboard), &kb.modifiers_listener);

    wlr.wlr_seat_set_keyboard(self.seat, keyboard);

    std.debug.print("teruwm: keyboard configured\n", .{});
}

// ── Cursor processing ──────────────────────────────────────────

fn processCursorMotion(self: *Server, time: u32) void {
    const cx = wlr.miozu_cursor_x(self.cursor);
    const cy = wlr.miozu_cursor_y(self.cursor);

    // Handle floating window move/resize
    if (self.cursor_mode == .move) {
        if (self.grab_node_id) |id| {
            if (self.nodes.findById(id)) |slot| {
                const new_x: i32 = @intFromFloat(cx - self.grab_x);
                const new_y: i32 = @intFromFloat(cy - self.grab_y);
                self.nodes.pos_x[slot] = new_x;
                self.nodes.pos_y[slot] = new_y;

                // Update scene graph position
                if (self.nodes.scene_tree[slot]) |tree| {
                    if (wlr.miozu_scene_tree_node(tree)) |node| {
                        wlr.wlr_scene_node_set_position(node, new_x, new_y);
                    }
                }
                // Update terminal pane position
                if (self.nodes.kind[slot] == .terminal) {
                    for (self.terminal_panes) |maybe_tp| {
                        if (maybe_tp) |tp| {
                            if (tp.node_id == id) {
                                tp.setPosition(new_x, new_y);
                                break;
                            }
                        }
                    }
                }
            }
        }
        return;
    }

    if (self.cursor_mode == .resize) {
        if (self.grab_node_id) |id| {
            if (self.nodes.findById(id)) |slot| {
                const dx = cx - self.grab_x;
                const dy = cy - self.grab_y;
                const new_w: u32 = @intCast(@max(100, @as(i64, self.grab_w) + @as(i64, @intFromFloat(dx))));
                const new_h: u32 = @intCast(@max(100, @as(i64, self.grab_h) + @as(i64, @intFromFloat(dy))));
                self.nodes.width[slot] = new_w;
                self.nodes.height[slot] = new_h;

                // Resize xdg toplevel
                if (self.nodes.kind[slot] == .wayland_surface) {
                    if (self.nodes.xdg_toplevel[slot]) |toplevel| {
                        _ = wlr.wlr_xdg_toplevel_set_size(toplevel, new_w, new_h);
                    }
                }
                // Resize terminal pane
                if (self.nodes.kind[slot] == .terminal) {
                    for (self.terminal_panes) |maybe_tp| {
                        if (maybe_tp) |tp| {
                            if (tp.node_id == id) {
                                tp.resize(new_w, new_h);
                                break;
                            }
                        }
                    }
                }
            }
        }
        return;
    }

    // Find surface under cursor via scene graph hit test
    const scene_tree_root = wlr.miozu_scene_tree(self.scene) orelse return;
    const root_node = wlr.miozu_scene_tree_node(scene_tree_root) orelse return;

    var sx: f64 = 0;
    var sy: f64 = 0;
    const node_under = wlr.wlr_scene_node_at(root_node, cx, cy, &sx, &sy);

    if (node_under) |scene_node| {
        // Resolve scene node → wlr_scene_buffer → wlr_scene_surface → wlr_surface
        if (wlr.wlr_scene_buffer_from_node(scene_node)) |buffer| {
            if (wlr.wlr_scene_surface_try_from_buffer(buffer)) |scene_surface| {
                if (wlr.miozu_scene_surface_get_surface(scene_surface)) |surface| {
                    wlr.wlr_seat_pointer_notify_enter(self.seat, surface, sx, sy);
                    wlr.wlr_seat_pointer_notify_motion(self.seat, time, sx, sy);
                    return;
                }
            }
        }
        // Scene node exists but isn't a client surface — show default cursor
        wlr.wlr_cursor_set_xcursor(self.cursor, self.cursor_mgr, "default");
        wlr.wlr_seat_pointer_clear_focus(self.seat);
    } else {
        // No node under cursor — desktop background
        wlr.wlr_cursor_set_xcursor(self.cursor, self.cursor_mgr, "default");
        wlr.wlr_seat_pointer_clear_focus(self.seat);
    }
}

// ── Keyboard handling ──────────────────────────────────────────

/// Called from per-keyboard key listener. Looks up the key in teru's
/// config-driven keybind system and executes the action. Returns true
/// if the key was consumed (not forwarded to client).
pub fn handleKey(self: *Server, keycode: u32, xkb_state_ptr: *wlr.xkb_state) bool {
    // xkb keycodes are offset by 8 from evdev
    const sym = wlr.xkb_state_key_get_one_sym(xkb_state_ptr, keycode + 8);

    // ── VT switching (Ctrl+Alt+F1-F12) — must be handled before anything else ──
    if (sym >= wlr.XKB_KEY_XF86Switch_VT_1 and sym <= wlr.XKB_KEY_XF86Switch_VT_1 + 11) {
        if (self.session) |session| {
            _ = wlr.wlr_session_change_vt(session, @intCast(sym - wlr.XKB_KEY_XF86Switch_VT_1 + 1));
        }
        return true;
    }

    // Convert xkb sym to key for teru's keybind lookup
    const key: u32 = if (sym >= 0x20 and sym <= 0x7e) sym else switch (sym) {
        0xff0d => '\r', // Return
        0xff1b => 0x1b, // Escape
        0xff09 => '\t', // Tab
        0xff08 => 0x7f, // BackSpace
        else => sym, // Pass full keysym for XF86/media keys
    };

    // Build modifier flags matching teru's Keybinds.Mods
    var mods = KBMods{};
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_ALT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.alt = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.shift = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_CTRL, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.ctrl = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.super_ = true;

    // ── Launcher mode: intercept all keys (raw keysym, not ASCII) ──
    if (self.launcher.active) {
        if (self.launcher.handleKey(sym, self)) {
            self.renderLauncherBar();
            return true;
        }
    }

    // ── Scratchpad toggle: Alt+RAlt+1-9 ──
    if (mods.alt and mods.ralt and key >= '1' and key <= '9') {
        self.toggleScratchpad(@intCast(key - '1'));
        return true;
    }

    // Lookup in teru's config-driven keybind table (same system standalone teru uses)
    const action = self.keybinds.lookup(.normal, mods, key) orelse return false;

    return self.executeAction(action);
}

/// Execute a keybind action. Shared by both compositor keybinds and
/// terminal pane keybinds (same Action enum, same execution logic).
fn executeAction(self: *Server, action: KBAction) bool {
    // Workspace switching
    if (action.workspaceIndex()) |ws| {
        const old_ws = self.layout_engine.active_workspace;
        self.layout_engine.switchWorkspace(ws);
        self.setWorkspaceVisibility(old_ws, false);
        self.setWorkspaceVisibility(ws, true);
        self.arrangeworkspace(ws);
        self.updateFocusedTerminal();
        if (self.bar) |b| b.render(self);
        return true;
    }

    // Move node to workspace
    if (action.moveToIndex()) |ws| {
        const active_ws = self.layout_engine.getActiveWorkspace();
        if (active_ws.getActiveNodeId()) |nid| {
            self.layout_engine.moveNodeToWorkspace(nid, ws) catch {};
            self.arrangeworkspace(self.layout_engine.active_workspace);
            self.arrangeworkspace(ws);
        }
        return true;
    }

    switch (action) {
        .spawn_terminal => {
            self.spawnTerminal(self.layout_engine.active_workspace);
            return true;
        },
        .window_close, .pane_close => {
            if (self.focused_view) |view| {
                wlr.wlr_xdg_toplevel_send_close(view.toplevel);
            }
            return true;
        },
        .compositor_quit => {
            wlr.wl_display_terminate(self.display);
            return true;
        },
        .layout_cycle => {
            self.layout_engine.getActiveWorkspace().cycleLayout();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            if (self.bar) |b| b.render(self);
            return true;
        },
        .pane_focus_next => {
            self.layout_engine.getActiveWorkspace().focusNext();
            self.updateFocusedTerminal();
            return true;
        },
        .pane_focus_prev => {
            self.layout_engine.getActiveWorkspace().focusPrev();
            self.updateFocusedTerminal();
            return true;
        },
        .pane_swap_next => {
            self.layout_engine.getActiveWorkspace().swapWithNext();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .pane_swap_prev => {
            self.layout_engine.getActiveWorkspace().swapWithPrev();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .pane_set_master => {
            self.layout_engine.getActiveWorkspace().promoteToMaster();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .resize_shrink_w => {
            const ws = self.layout_engine.getActiveWorkspace();
            ws.master_ratio = @max(0.1, ws.master_ratio - 0.05);
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .resize_grow_w => {
            const ws = self.layout_engine.getActiveWorkspace();
            ws.master_ratio = @min(0.9, ws.master_ratio + 0.05);
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        .split_vertical => {
            self.spawnTerminal(self.layout_engine.active_workspace);
            return true;
        },
        .float_toggle => {
            self.toggleFloat();
            return true;
        },
        .fullscreen_toggle => {
            self.toggleFullscreen();
            return true;
        },
        .launcher_toggle => {
            if (self.launcher.active) {
                self.launcher.deactivate();
                if (self.bar) |b| b.render(self); // restore normal bar
            } else {
                self.launcher.activate();
                self.renderLauncherBar();
            }
            return true;
        },
        .screenshot => {
            self.takeScreenshot();
            return true;
        },
        .bar_toggle_top => {
            if (self.bar) |b| {
                b.top.enabled = !b.top.enabled;
                if (b.top.enabled) b.render(self);
                self.arrangeworkspace(self.layout_engine.active_workspace);
            }
            return true;
        },
        .bar_toggle_bottom => {
            if (self.bar) |b| {
                b.bottom.enabled = !b.bottom.enabled;
                if (b.bottom.enabled) b.render(self);
                self.arrangeworkspace(self.layout_engine.active_workspace);
            }
            return true;
        },
        .volume_up => {
            self.spawnProcess("wpctl set-volume @DEFAULT_SINK@ 5%+");
            return true;
        },
        .volume_down => {
            self.spawnProcess("wpctl set-volume @DEFAULT_SINK@ 5%-");
            return true;
        },
        .volume_mute => {
            self.spawnProcess("wpctl set-mute @DEFAULT_SINK@ toggle");
            return true;
        },
        .brightness_up => {
            self.spawnProcess("brightnessctl set +5%");
            return true;
        },
        .brightness_down => {
            self.spawnProcess("brightnessctl set 5%-");
            return true;
        },
        .media_play => {
            self.spawnProcess("playerctl play-pause");
            return true;
        },
        .media_next => {
            self.spawnProcess("playerctl next");
            return true;
        },
        .media_prev => {
            self.spawnProcess("playerctl previous");
            return true;
        },
        else => return false,
    }
}

// ── Tiling ─────────────────────────────────────────────────────

/// Recalculate layout for a workspace and apply rects to all scene nodes.
pub fn arrangeworkspace(self: *Server, ws_index: u8) void {
    // Get dimensions from the primary output, minus status bar height
    const w: u16 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const full_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
    const bar_h: u32 = if (self.bar) |b| b.totalHeight() else 0;
    const bar_y_offset: i32 = if (self.bar) |b| @intCast(b.tilingOffsetY()) else 0;
    const h: u16 = @intCast(@max(1, full_h - bar_h));
    const screen = LayoutEngine.Rect{ .x = 0, .y = @intCast(bar_y_offset), .width = w, .height = h };

    const rects = self.layout_engine.calculate(ws_index, screen) catch return;
    defer self.zig_allocator.free(rects);

    const ws = &self.layout_engine.workspaces[ws_index];
    const node_ids = ws.node_ids.items;

    // Apply each rect (with gap inset) to its corresponding node
    for (node_ids, 0..) |nid, i| {
        if (i >= rects.len) break;
        if (self.nodes.findById(nid)) |slot| {
            // Inset rect by gap (half on each side)
            const g = self.wm_config.gap;
            const rx = rects[i].x + @as(i32, g);
            const ry = rects[i].y + @as(i32, g);
            const rw = if (rects[i].width > g * 2) rects[i].width - g * 2 else rects[i].width;
            const rh = if (rects[i].height > g * 2) rects[i].height - g * 2 else rects[i].height;
            self.nodes.applyRect(slot, rx, ry, rw, rh);

            // Resize terminal panes to match their assigned rect
            if (self.nodes.kind[slot] == .terminal) {
                for (self.terminal_panes) |maybe_tp| {
                    if (maybe_tp) |tp| {
                        if (tp.node_id == nid) {
                            tp.resize(rw, rh);
                            tp.setPosition(rx, ry);
                            break;
                        }
                    }
                }
            }
        }
    }
}

/// Focus a view — activate its toplevel and send keyboard focus.
pub fn focusView(self: *Server, view: *XdgView) void {
    // Deactivate previous
    if (self.focused_view) |prev| {
        _ = wlr.wlr_xdg_toplevel_set_activated(prev.toplevel, false);
    }

    // Activate new — clear terminal focus, external view gets keyboard
    _ = wlr.wlr_xdg_toplevel_set_activated(view.toplevel, true);
    self.focused_view = view;
    self.focused_terminal = null;

    // Send keyboard focus to the surface
    const surface = wlr.miozu_xdg_surface_surface(
        wlr.miozu_xdg_toplevel_base(view.toplevel) orelse return,
    ) orelse return;
    wlr.wlr_seat_keyboard_notify_enter(self.seat, surface, null, 0, null);

    if (self.bar) |b| b.render(self);
}

// ── Terminal pane management ───────────────────────────────────

/// Spawn an embedded terminal pane on the given workspace, sized to fill the output.
pub fn spawnTerminal(self: *Server, ws: u8) void {
    // Calculate rows/cols from output dimensions minus bar height
    const cell_w: u32 = if (self.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (self.font_atlas) |fa| fa.cell_height else 16;
    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
    const bar_h: u32 = if (self.bar) |b| b.totalHeight() else 0;
    const usable_h = @max(cell_h, out_h -| bar_h);
    const cols: u16 = @intCast(@max(1, out_w / cell_w));
    const rows: u16 = @intCast(@max(1, usable_h / cell_h));

    const tp = TerminalPane.create(self, ws, rows, cols) orelse {
        std.debug.print("teruwm: failed to spawn terminal pane\n", .{});
        return;
    };

    // Store in terminal_panes array
    for (&self.terminal_panes) |*slot| {
        if (slot.* == null) {
            slot.* = tp;
            self.terminal_count += 1;
            break;
        }
    }

    // Focus the new terminal
    self.focused_terminal = tp;
    self.focused_view = null; // terminal takes priority over external views
}

// ── Clipboard (internal buffer for Ctrl+Shift+C/V) ───────────

/// Copy the cursor line from a terminal pane into the internal clipboard buffer.
/// Extracts the full line at the cursor row, trimming trailing whitespace.
fn clipboardCopyCursorLine(self: *Server, tp: *TerminalPane) void {
    const grid = &tp.pane.grid;
    const row = grid.cursor_row;
    var pos: usize = 0;

    var col: u16 = 0;
    while (col < grid.cols) : (col += 1) {
        const cell = grid.cellAtConst(row, col);
        const cp = cell.char;
        // Encode codepoint as UTF-8 into clipboard_buf
        if (cp < 0x80) {
            if (pos < self.clipboard_buf.len) {
                self.clipboard_buf[pos] = @intCast(cp);
                pos += 1;
            }
        } else if (cp < 0x800) {
            if (pos + 2 <= self.clipboard_buf.len) {
                self.clipboard_buf[pos] = @intCast(0xC0 | (cp >> 6));
                self.clipboard_buf[pos + 1] = @intCast(0x80 | (cp & 0x3F));
                pos += 2;
            }
        } else if (cp < 0x10000) {
            if (pos + 3 <= self.clipboard_buf.len) {
                self.clipboard_buf[pos] = @intCast(0xE0 | (cp >> 12));
                self.clipboard_buf[pos + 1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                self.clipboard_buf[pos + 2] = @intCast(0x80 | (cp & 0x3F));
                pos += 3;
            }
        } else {
            if (pos + 4 <= self.clipboard_buf.len) {
                self.clipboard_buf[pos] = @intCast(0xF0 | (cp >> 18));
                self.clipboard_buf[pos + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
                self.clipboard_buf[pos + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                self.clipboard_buf[pos + 3] = @intCast(0x80 | (cp & 0x3F));
                pos += 4;
            }
        }
    }

    // Trim trailing spaces
    while (pos > 0 and self.clipboard_buf[pos - 1] == ' ') {
        pos -= 1;
    }

    self.clipboard_len = @intCast(@min(pos, std.math.maxInt(u16)));
    std.debug.print("teruwm: clipboard copy ({d} bytes)\n", .{self.clipboard_len});
}

/// Paste internal clipboard buffer to a terminal pane's PTY.
/// Wraps with bracketed paste escape sequences if the terminal has it enabled.
fn clipboardPaste(self: *Server, tp: *TerminalPane) void {
    if (self.clipboard_len == 0) return;

    const data = self.clipboard_buf[0..self.clipboard_len];

    if (tp.pane.vt.bracketed_paste) {
        tp.writeInput("\x1b[200~");
    }
    tp.writeInput(data);
    if (tp.pane.vt.bracketed_paste) {
        tp.writeInput("\x1b[201~");
    }

    std.debug.print("teruwm: clipboard paste ({d} bytes)\n", .{self.clipboard_len});
}

/// Poll all terminal panes for PTY output. Called from the event loop.
/// Returns true if any pane produced output (needs re-render).
pub fn pollTerminals(self: *Server) bool {
    var any_output = false;
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            if (tp.poll()) any_output = true;
        }
    }
    return any_output;
}

// ── Launcher bar rendering ─────────────────────────────────────

fn renderLauncherBar(self: *Server) void {
    if (self.bar) |b| {
        if (self.launcher.active) {
            // Render launcher UI into the top bar's buffer
            self.launcher.render(&b.top.renderer);
            wlr.wlr_scene_buffer_set_buffer_with_damage(b.top.scene_buffer, b.top.pixel_buffer, null);
        } else {
            b.render(self); // restore normal bar
        }
    }
}

// ── Workspace visibility ──────────────────────────────────────

/// Show or hide all nodes in a workspace.
fn setWorkspaceVisibility(self: *Server, ws: u8, visible: bool) void {
    const ws_nodes = self.layout_engine.workspaces[ws].node_ids.items;
    for (ws_nodes) |nid| {
        // Terminal panes
        for (self.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| {
                if (tp.node_id == nid) tp.setVisible(visible);
            }
        }
        // External views: handled by the scene tree (XdgView nodes)
        if (self.nodes.findById(nid)) |slot| {
            if (self.nodes.kind[slot] == .wayland_surface) {
                if (self.nodes.scene_tree[slot]) |tree| {
                    if (wlr.miozu_scene_tree_node(tree)) |node| {
                        wlr.wlr_scene_node_set_enabled(node, visible);
                    }
                }
            }
        }
    }
}

// ── Float toggle ────────────────────────────────────────────

/// Toggle the focused node between floating and tiled.
/// Floating nodes are removed from the LayoutEngine workspace (not tiled)
/// but remain in the NodeRegistry for rendering. Tiling nodes are added
/// back to the workspace and re-arranged.
fn toggleFloat(self: *Server) void {
    // Determine the focused node ID
    const nid: u64 = if (self.focused_terminal) |tp|
        tp.node_id
    else if (self.focused_view) |view|
        view.node_id
    else
        return;

    const slot = self.nodes.findById(nid) orelse return;
    const ws = self.layout_engine.active_workspace;

    if (self.nodes.floating[slot]) {
        // ── Unfloat: add back to tiling ──
        self.nodes.floating[slot] = false;
        self.layout_engine.workspaces[ws].addNode(self.zig_allocator, nid) catch {};
        self.arrangeworkspace(ws);
        std.debug.print("teruwm: unfloat node={d}\n", .{nid});
    } else {
        // ── Float: remove from tiling, keep in registry ──
        self.nodes.floating[slot] = true;
        self.layout_engine.workspaces[ws].removeNode(nid);
        self.arrangeworkspace(ws);

        // Center the floating window at 50% of output size
        const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
        const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
        const float_w: u32 = out_w / 2;
        const float_h: u32 = out_h / 2;
        const float_x: i32 = @intCast(out_w / 4);
        const float_y: i32 = @intCast(out_h / 4);

        self.nodes.applyRect(slot, float_x, float_y, float_w, float_h);

        // Also resize terminal pane if applicable
        if (self.nodes.kind[slot] == .terminal) {
            if (self.focused_terminal) |tp| {
                tp.resize(float_w, float_h);
                tp.setPosition(float_x, float_y);
            }
        }

        std.debug.print("teruwm: float node={d}\n", .{nid});
    }

    if (self.bar) |b| b.render(self);
}

// ── Fullscreen ───────────────────────────────────────────────

/// Toggle the focused terminal pane to fill the entire output.
/// When entering fullscreen: hide bars, hide other panes, expand focused pane.
/// When leaving fullscreen: restore bars, re-arrange workspace.
fn toggleFullscreen(self: *Server) void {
    if (self.fullscreen_node != null) {
        // ── Exit fullscreen ──
        self.fullscreen_node = null;

        // Restore bar visibility
        if (self.bar) |b| {
            b.top.enabled = self.fullscreen_prev_bar_top;
            b.bottom.enabled = self.fullscreen_prev_bar_bottom;
            if (b.top.enabled) {
                if (wlr.miozu_scene_buffer_node(b.top.scene_buffer)) |node| {
                    wlr.wlr_scene_node_set_enabled(node, true);
                }
            }
            if (b.bottom.enabled) {
                if (wlr.miozu_scene_buffer_node(b.bottom.scene_buffer)) |node| {
                    wlr.wlr_scene_node_set_enabled(node, true);
                }
            }
        }

        // Show all panes in the active workspace
        const ws = self.layout_engine.active_workspace;
        self.setWorkspaceVisibility(ws, true);

        // Re-tile (respects bar height again)
        self.arrangeworkspace(ws);
        if (self.bar) |b| b.render(self);

        std.debug.print("teruwm: fullscreen off\n", .{});
        return;
    }

    // ── Enter fullscreen ──
    const tp = self.focused_terminal orelse return;

    self.fullscreen_node = tp.node_id;

    // Save and hide bars
    if (self.bar) |b| {
        self.fullscreen_prev_bar_top = b.top.enabled;
        self.fullscreen_prev_bar_bottom = b.bottom.enabled;
        if (wlr.miozu_scene_buffer_node(b.top.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_enabled(node, false);
        }
        if (wlr.miozu_scene_buffer_node(b.bottom.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_enabled(node, false);
        }
    }

    // Hide all other panes in the workspace
    const ws = self.layout_engine.active_workspace;
    const ws_nodes = self.layout_engine.workspaces[ws].node_ids.items;
    for (ws_nodes) |nid| {
        if (nid == tp.node_id) continue;
        for (self.terminal_panes) |maybe_tp| {
            if (maybe_tp) |other_tp| {
                if (other_tp.node_id == nid) other_tp.setVisible(false);
            }
        }
        // Also hide external views
        if (self.nodes.findById(nid)) |slot| {
            if (self.nodes.kind[slot] == .wayland_surface) {
                if (self.nodes.scene_tree[slot]) |tree| {
                    if (wlr.miozu_scene_tree_node(tree)) |node| {
                        wlr.wlr_scene_node_set_enabled(node, false);
                    }
                }
            }
        }
    }

    // Expand focused pane to fill entire output (no bar, no gaps)
    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
    tp.resize(out_w, out_h);
    tp.setPosition(0, 0);

    std.debug.print("teruwm: fullscreen on node={d}\n", .{tp.node_id});
}

// ── Scratchpads ───────────────────────────────────────────────

/// Toggle a numbered scratchpad (0-8, mapped from keys 1-9).
/// Creates the terminal pane on first toggle. Subsequent toggles show/hide.
/// Scratchpads are floating — not part of workspace tiling.
fn toggleScratchpad(self: *Server, index: u8) void {
    if (index >= 9) return;

    // Create on first use
    if (self.scratchpads[index] == null) {
        // 3x3 grid positions (same as XMonad config)
        const positions = [9][2]f32{
            .{ 0.1, 0.1 }, .{ 0.3, 0.1 }, .{ 0.5, 0.1 },
            .{ 0.1, 0.3 }, .{ 0.3, 0.3 }, .{ 0.5, 0.3 },
            .{ 0.1, 0.5 }, .{ 0.3, 0.5 }, .{ 0.5, 0.5 },
        };
        const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
        const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
        const sp_w: u32 = out_w * 35 / 100; // 35% width
        const sp_h: u32 = out_h * 40 / 100; // 40% height
        const cell_w: u32 = if (self.font_atlas) |fa| fa.cell_width else 8;
        const cell_h: u32 = if (self.font_atlas) |fa| fa.cell_height else 16;
        const cols: u16 = @intCast(@max(1, sp_w / cell_w));
        const rows: u16 = @intCast(@max(1, sp_h / cell_h));

        // Create scratchpad terminal (not added to any workspace's tiling)
        const tp = TerminalPane.createFloating(self, rows, cols) orelse return;
        self.scratchpads[index] = tp;

        // Position it
        const pos_x: i32 = @intFromFloat(positions[index][0] * @as(f32, @floatFromInt(out_w)));
        const pos_y: i32 = @intFromFloat(positions[index][1] * @as(f32, @floatFromInt(out_h)));
        if (wlr.miozu_scene_buffer_node(tp.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_position(node, pos_x, pos_y);
        }

        self.scratchpad_visible[index] = true;
        self.focused_terminal = tp;
        self.focused_view = null;
        std.debug.print("teruwm: scratchpad {d} created\n", .{index + 1});
        return;
    }

    // Toggle visibility
    self.scratchpad_visible[index] = !self.scratchpad_visible[index];
    if (self.scratchpads[index]) |tp| {
        if (wlr.miozu_scene_buffer_node(tp.scene_buffer)) |node| {
            wlr.wlr_scene_node_set_enabled(node, self.scratchpad_visible[index]);
        }
        if (self.scratchpad_visible[index]) {
            self.focused_terminal = tp;
            self.focused_view = null;
            tp.render(); // re-render in case content changed while hidden
        }
    }
}

// ── Terminal lifecycle ─────────────────────────────────────────

/// Handle terminal pane exit (shell process died).
pub fn handleTerminalExit(self: *Server, tp: *TerminalPane) void {
    std.debug.print("teruwm: terminal exited node={d}\n", .{tp.node_id});

    // Remove from node registry and tiling engine
    _ = self.nodes.remove(tp.node_id);
    for (&self.layout_engine.workspaces) |*ws| {
        ws.removeNode(tp.node_id);
    }

    // Remove event source
    if (tp.event_source) |es| {
        _ = wlr.wl_event_source_remove(es);
        tp.event_source = null;
    }

    // Hide scene buffer
    if (wlr.miozu_scene_buffer_node(tp.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, false);
    }

    // Remove from terminal_panes array
    var found_in_tiled = false;
    for (&self.terminal_panes) |*slot| {
        if (slot.* == tp) {
            slot.* = null;
            self.terminal_count -= 1;
            found_in_tiled = true;
            break;
        }
    }

    // Also check scratchpads
    if (!found_in_tiled) {
        for (&self.scratchpads, 0..) |*slot, i| {
            if (slot.* == tp) {
                slot.* = null;
                self.scratchpad_visible[i] = false;
                break;
            }
        }
    }

    // Clear focus if this was focused
    if (self.focused_terminal == tp) {
        self.focused_terminal = null;
        self.updateFocusedTerminal();
    }

    // Re-tile
    self.arrangeworkspace(self.layout_engine.active_workspace);
    if (self.bar) |b| b.render(self);
}

// ── Focus management ──────────────────────────────────────────

/// Update focused_terminal to match the LayoutEngine's active node.
/// Also updates visual focus indicators (border color).
fn updateFocusedTerminal(self: *Server) void {
    const ws = self.layout_engine.getActiveWorkspace();
    const active_id = ws.getActiveNodeId() orelse return;

    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            if (tp.node_id == active_id) {
                self.focused_terminal = tp;
                self.focused_view = null;
                if (self.bar) |b| b.render(self);
                return;
            }
        }
    }
    // Active node is not a terminal — might be an external view
    self.focused_terminal = null;
}

// ── Process spawning ───────────────────────────────────────────

/// Spawn a shell command detached from the compositor (double-fork to avoid zombies).
/// Uses /bin/sh -c to handle commands with arguments and pipes.
pub fn spawnProcess(_: *Server, cmd: [*:0]const u8) void {
    const pid = std.os.linux.fork();
    if (pid == 0) {
        const pid2 = std.os.linux.fork();
        if (pid2 == 0) {
            // Grandchild: exec via shell to handle args/pipes
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
            const envp = [_:null]?[*:0]const u8{null};
            _ = std.os.linux.execve("/bin/sh", &argv, &envp);
            std.os.linux.exit(1);
        }
        std.os.linux.exit(0);
    }
    if (pid > 0) {
        _ = std.c.waitpid(@intCast(pid), null, 0);
    }
}

/// Take a screenshot of the entire output and save as PNG.
fn takeScreenshot(self: *Server) void {
    // Get output dimensions
    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));

    // Build path: ~/Pictures/screenshot_TIMESTAMP.png
    var path_buf: [256]u8 = undefined;
    const home = teru.compat.getenv("HOME") orelse "/tmp";
    const timestamp = teru.compat.monotonicNow();
    const path = std.fmt.bufPrint(&path_buf, "{s}/Pictures/screenshot_{d}.png", .{ home, timestamp }) catch return;

    // TODO: grab the composed framebuffer from wlroots and encode via png.zig
    // For now, spawn grim (standard Wayland screenshot tool)
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "grim {s}", .{path}) catch return;
    cmd_buf[@min(cmd.len, cmd_buf.len - 1)] = 0;
    self.spawnProcess(@ptrCast(cmd.ptr));

    std.debug.print("teruwm: screenshot → {s}\n", .{path});
    _ = out_w;
    _ = out_h;
}

// ── Helper ─────────────────────────────────────────────────────

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{
        .link = .{ .prev = null, .next = null },
        .notify = func,
    };
}
