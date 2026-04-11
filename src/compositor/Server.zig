//! Compositor server state. Owns all wlroots objects, listeners, and the
//! connection between libteru's tiling engine and the wlroots scene graph.

const std = @import("std");
const wlr = @import("wlr.zig");
const Output = @import("Output.zig");
const XdgView = @import("XdgView.zig");
const TerminalPane = @import("TerminalPane.zig");
const StatusBar = @import("StatusBar.zig");
const NodeRegistry = @import("Node.zig");
const teru = @import("teru");
const LayoutEngine = teru.LayoutEngine;
const Keybinds = teru.Keybinds;
const KB = Keybinds.Keybinds;
const KBAction = Keybinds.Action;
const KBMods = Keybinds.Mods;

const Server = @This();

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
status_bar: ?*StatusBar = null,
workspace_trees: [10]?*wlr.wlr_scene_tree = [_]?*wlr.wlr_scene_tree{null} ** 10,

// Scratchpads: 9 floating terminal panes (Alt+RAlt+1-9)
scratchpads: [9]?*TerminalPane = [_]?*TerminalPane{null} ** 9,
scratchpad_visible: [9]bool = [_]bool{false} ** 9,

// ── Listeners ──────────────────────────────────────────────────

new_output: wlr.wl_listener = makeListener(handleNewOutput),
new_input: wlr.wl_listener = makeListener(handleNewInput),
new_xdg_toplevel: wlr.wl_listener = makeListener(handleNewXdgToplevel),
cursor_motion: wlr.wl_listener = makeListener(handleCursorMotion),
cursor_motion_absolute: wlr.wl_listener = makeListener(handleCursorMotionAbsolute),
cursor_button: wlr.wl_listener = makeListener(handleCursorButton),
cursor_frame: wlr.wl_listener = makeListener(handleCursorFrame),
request_set_cursor: wlr.wl_listener = makeListener(handleRequestSetCursor),

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
    // Backend
    const backend = wlr.wlr_backend_autocreate(event_loop, null) orelse
        return error.BackendCreateFailed;

    // Renderer + allocator
    const renderer = wlr.wlr_renderer_autocreate(backend) orelse
        return error.RendererCreateFailed;
    _ = wlr.wlr_renderer_init_wl_display(renderer, display);

    const wlr_alloc = wlr.wlr_allocator_autocreate(backend, renderer) orelse
        return error.AllocatorCreateFailed;

    // Compositor protocol (wl_compositor, wl_subcompositor)
    _ = wlr.wlr_compositor_create(display, 5, renderer);
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
}

pub fn deinit(self: *Server) void {
    wlr.xkb_context_unref(self.xkb_ctx);
}

// ── Signal handlers ────────────────────────────────────────────

fn handleNewOutput(listener: *wlr.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "new_output", listener);
    const wlr_output: *wlr.wlr_output = @ptrCast(@alignCast(data orelse return));

    _ = Output.create(server, wlr_output, server.zig_allocator) catch {
        std.debug.print("miozu: failed to create output\n", .{});
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
    _ = wlr.wlr_seat_pointer_notify_button(server.seat, wlr.miozu_pointer_button_time(event), wlr.miozu_pointer_button_button(event), wlr.miozu_pointer_button_state(event));
}

fn handleCursorFrame(listener: *wlr.wl_listener, _: ?*anyopaque) callconv(.c) void {
    const server = wlr.listenerParent(Server, "cursor_frame", listener);
    wlr.wlr_seat_pointer_notify_frame(server.seat);
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

    std.debug.print("miozu: keyboard configured\n", .{});
}

// ── Cursor processing ──────────────────────────────────────────

fn processCursorMotion(self: *Server, time: u32) void {
    // Find surface under cursor via scene graph hit test
    const cx = wlr.miozu_cursor_x(self.cursor);
    const cy = wlr.miozu_cursor_y(self.cursor);
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

    // Convert xkb sym to ASCII key for teru's keybind lookup
    // (teru keybinds use ASCII characters, not keysyms)
    const key: u8 = if (sym >= 0x20 and sym <= 0x7e) @intCast(sym) else switch (sym) {
        0xff0d => '\r', // Return
        0xff1b => 0x1b, // Escape
        0xff09 => '\t', // Tab
        0xffff => 0x7f, // Delete → Backspace
        else => return false,
    };

    // Build modifier flags matching teru's Keybinds.Mods
    var mods = KBMods{};
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_ALT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.alt = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.shift = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_CTRL, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.ctrl = true;
    if (wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0) mods.super_ = true;

    // ── Scratchpad toggle: Alt+RAlt+1-9 ──
    if (mods.alt and mods.ralt and key >= '1' and key <= '9') {
        self.toggleScratchpad(key - '1');
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
        if (self.status_bar) |sb| sb.render(self);
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
            if (self.status_bar) |sb| sb.render(self);
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
        else => return false,
    }
}

// ── Tiling ─────────────────────────────────────────────────────

/// Recalculate layout for a workspace and apply rects to all scene nodes.
pub fn arrangeworkspace(self: *Server, ws_index: u8) void {
    // Get dimensions from the primary output, minus status bar height
    const w: u16 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const full_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
    const bar_h: u32 = if (self.status_bar) |sb| sb.bar_height else 0;
    const h: u16 = @intCast(@max(1, full_h - bar_h));
    const screen = LayoutEngine.Rect{ .x = 0, .y = 0, .width = w, .height = h };

    const rects = self.layout_engine.calculate(ws_index, screen) catch return;
    defer self.zig_allocator.free(rects);

    const ws = &self.layout_engine.workspaces[ws_index];
    const node_ids = ws.node_ids.items;

    // Apply each rect to its corresponding node in the registry
    for (node_ids, 0..) |nid, i| {
        if (i >= rects.len) break;
        if (self.nodes.findById(nid)) |slot| {
            self.nodes.applyRect(slot, rects[i].x, rects[i].y, rects[i].width, rects[i].height);

            // Resize terminal panes to match their assigned rect
            if (self.nodes.kind[slot] == .terminal) {
                for (self.terminal_panes) |maybe_tp| {
                    if (maybe_tp) |tp| {
                        if (tp.node_id == nid) {
                            tp.resize(rects[i].width, rects[i].height);
                            // Position the scene buffer at the rect position
                            if (wlr.miozu_scene_buffer_node(tp.scene_buffer)) |scene_node| {
                                wlr.wlr_scene_node_set_position(scene_node, rects[i].x, rects[i].y);
                            }
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

    if (self.status_bar) |sb| sb.render(self);
}

// ── Terminal pane management ───────────────────────────────────

/// Spawn an embedded terminal pane on the given workspace, sized to fill the output.
pub fn spawnTerminal(self: *Server, ws: u8) void {
    // Calculate rows/cols from output dimensions
    const cell_w: u32 = if (self.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (self.font_atlas) |fa| fa.cell_height else 16;
    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
    const cols: u16 = @intCast(@max(1, out_w / cell_w));
    const rows: u16 = @intCast(@max(1, out_h / cell_h));

    const tp = TerminalPane.create(self, ws, rows, cols) orelse {
        std.debug.print("miozu: failed to spawn terminal pane\n", .{});
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
        std.debug.print("miozu: scratchpad {d} created\n", .{index + 1});
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
    std.debug.print("miozu: terminal exited node={d}\n", .{tp.node_id});

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
    if (self.status_bar) |sb| sb.render(self);
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
                if (self.status_bar) |sb| sb.render(self);
                return;
            }
        }
    }
    // Active node is not a terminal — might be an external view
    self.focused_terminal = null;
}

// ── Process spawning ───────────────────────────────────────────

/// Spawn a process detached from the compositor (double-fork to avoid zombies).
fn spawnProcess(_: *Server, cmd: [*:0]const u8) void {
    const pid = std.os.linux.fork();
    if (pid == 0) {
        // Child: fork again to detach, then exec
        const pid2 = std.os.linux.fork();
        if (pid2 == 0) {
            // Grandchild: exec the command
            const argv = [_:null]?[*:0]const u8{ cmd, null };
            const envp = [_:null]?[*:0]const u8{null};
            _ = std.os.linux.execve(cmd, &argv, &envp);
            std.os.linux.exit(1);
        }
        // First child exits immediately — grandchild is orphaned to init
        std.os.linux.exit(0);
    }
    // Parent: reap the first child immediately
    if (pid > 0) {
        _ = std.c.waitpid(@intCast(pid), null, 0);
    }
}

// ── Helper ─────────────────────────────────────────────────────

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{
        .link = .{ .prev = null, .next = null },
        .notify = func,
    };
}
