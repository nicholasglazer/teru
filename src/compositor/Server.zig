//! Compositor server state. Owns all wlroots objects, listeners, and the
//! connection between libteru's tiling engine and the wlroots scene graph.

const std = @import("std");
const wlr = @import("wlr.zig");
const Output = @import("Output.zig");
const XdgView = @import("XdgView.zig");
const NodeRegistry = @import("Node.zig");
const teru = @import("teru");
const LayoutEngine = teru.LayoutEngine;

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
next_node_id: u64 = 1,
focused_view: ?*XdgView = null,

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

pub fn init(display: *wlr.wl_display, event_loop: *wlr.wl_event_loop, allocator: std.mem.Allocator) !Server {
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

    var server = Server{
        .zig_allocator = allocator,
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

    // Register signal listeners
    wlr.wl_signal_add(wlr.miozu_backend_new_output(backend), &server.new_output);
    wlr.wl_signal_add(wlr.miozu_backend_new_input(backend), &server.new_input);
    wlr.wl_signal_add(wlr.miozu_xdg_shell_new_toplevel(xdg_shell), &server.new_xdg_toplevel);
    wlr.wl_signal_add(wlr.miozu_cursor_motion(cursor), &server.cursor_motion);
    wlr.wl_signal_add(wlr.miozu_cursor_motion_absolute(cursor), &server.cursor_motion_absolute);
    wlr.wl_signal_add(wlr.miozu_cursor_button(cursor), &server.cursor_button);
    wlr.wl_signal_add(wlr.miozu_cursor_frame(cursor), &server.cursor_frame);
    wlr.wl_signal_add(wlr.miozu_seat_request_set_cursor(seat), &server.request_set_cursor);

    return server;
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

        // Only handle key press, not release
        if (key_state == 1) { // WL_KEYBOARD_KEY_STATE_PRESSED
            const xkb_st = wlr.miozu_keyboard_xkb_state(kb.wlr_keyboard) orelse return;
            if (kb.server.handleCompositorKey(keycode, xkb_st)) return;
        }

        // Forward to focused surface
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

/// Called from per-keyboard key listener. Returns true if the key was
/// consumed by a compositor binding (not forwarded to client).
pub fn handleCompositorKey(self: *Server, keycode: u32, xkb_state_ptr: *wlr.xkb_state) bool {
    // xkb keycodes are offset by 8 from evdev
    const sym = wlr.xkb_state_key_get_one_sym(xkb_state_ptr, keycode + 8);

    // Check if Super (Mod4) is held
    const super_active = wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_LOGO, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;
    const shift_active = wlr.xkb_state_mod_name_is_active(xkb_state_ptr, wlr.XKB_MOD_NAME_SHIFT, wlr.XKB_STATE_MODS_EFFECTIVE) > 0;

    if (!super_active) return false;

    // ── Compositor keybinds (Mod+key) — zero allocation dispatch ──
    if (sym >= wlr.XKB_KEY_1 and sym <= wlr.XKB_KEY_0 + 9) {
        // Mod+1..9 → switch workspace 0..8
        self.layout_engine.switchWorkspace(@intCast(sym - wlr.XKB_KEY_1));
        return true;
    }

    switch (sym) {
        wlr.XKB_KEY_0 => {
            // Mod+0 → workspace 9 (10th, immortal home)
            self.layout_engine.switchWorkspace(9);
            return true;
        },
        wlr.XKB_KEY_Return => {
            // Mod+Return → spawn terminal
            self.spawnProcess("teru");
            return true;
        },
        wlr.XKB_KEY_space => {
            // Mod+Space → cycle layout
            self.layout_engine.getActiveWorkspace().cycleLayout();
            self.arrangeworkspace(self.layout_engine.active_workspace);
            return true;
        },
        wlr.XKB_KEY_j => {
            // Mod+j → focus next
            self.layout_engine.getActiveWorkspace().focusNext();
            return true;
        },
        wlr.XKB_KEY_k => {
            // Mod+k → focus prev
            self.layout_engine.getActiveWorkspace().focusPrev();
            return true;
        },
        wlr.XKB_KEY_c => {
            if (shift_active) {
                // Mod+Shift+c → close focused window
                if (self.focused_view) |view| {
                    wlr.wlr_xdg_toplevel_send_close(view.toplevel);
                }
                return true;
            }
            return false;
        },
        wlr.XKB_KEY_q => {
            if (shift_active) {
                // Mod+Shift+q → quit compositor
                wlr.wl_display_terminate(self.display);
                return true;
            }
            return false;
        },
        else => return false,
    }
}

// ── Tiling ─────────────────────────────────────────────────────

/// Recalculate layout for a workspace and apply rects to all scene nodes.
pub fn arrangeworkspace(self: *Server, ws_index: u8) void {
    // Get dimensions from the primary output (first in layout)
    const w: u16 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.output_layout)));
    const h: u16 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.output_layout)));
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
        }
    }
}

/// Focus a view — activate its toplevel and send keyboard focus.
pub fn focusView(self: *Server, view: *XdgView) void {
    // Deactivate previous
    if (self.focused_view) |prev| {
        _ = wlr.wlr_xdg_toplevel_set_activated(prev.toplevel, false);
    }

    // Activate new
    _ = wlr.wlr_xdg_toplevel_set_activated(view.toplevel, true);
    self.focused_view = view;

    // Send keyboard focus to the surface
    const surface = wlr.miozu_xdg_surface_surface(
        wlr.miozu_xdg_toplevel_base(view.toplevel) orelse return,
    ) orelse return;
    wlr.wlr_seat_keyboard_notify_enter(self.seat, surface, null, 0, null);
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
