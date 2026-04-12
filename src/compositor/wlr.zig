//! Hand-declared wlroots 0.18 + libwayland-server C externs.
//!
//! No @cImport — all types and functions declared manually following
//! Zig 0.16 conventions: callconv(.c), opaque {}, extern struct.
//! Only declares what miozu actually uses.

// ── Opaque types (forward-declared C structs) ──────────────────

pub const wl_display = opaque {};
pub const wl_event_loop = opaque {};
pub const wl_client = opaque {};
pub const wl_resource = opaque {};

pub const wlr_backend = opaque {};
pub const wlr_renderer = opaque {};
pub const wlr_allocator = opaque {};
pub const wlr_session = opaque {};

pub const wlr_scene = opaque {};
pub const wlr_scene_tree = opaque {};
pub const wlr_scene_output = opaque {};
pub const wlr_scene_output_layout = opaque {};
pub const wlr_scene_surface = opaque {};
pub const wlr_scene_buffer = opaque {};
pub const wlr_scene_rect = opaque {};

pub const wlr_output = opaque {};
pub const wlr_output_layout = opaque {};
pub const wlr_output_state = opaque {};

pub const wlr_xdg_shell = opaque {};
pub const wlr_xdg_surface = opaque {};
pub const wlr_xdg_toplevel = opaque {};

pub const wlr_seat = opaque {};
pub const wlr_keyboard = opaque {};
pub const wlr_pointer = opaque {};
pub const wlr_cursor = opaque {};
pub const wlr_xcursor_manager = opaque {};
pub const wlr_input_device = opaque {};

pub const wlr_surface = opaque {};
pub const wlr_compositor = opaque {};
pub const wlr_subcompositor = opaque {};
pub const wlr_data_device_manager = opaque {};

pub const wlr_layer_shell_v1 = opaque {};

pub const xkb_context = opaque {};
pub const xkb_keymap = opaque {};

// ── Wayland linked list (wl_list) ──────────────────────────────

pub const wl_list = extern struct {
    prev: ?*wl_list,
    next: ?*wl_list,
};

// ── Wayland signal/listener ────────────────────────────────────

pub const wl_signal = extern struct {
    listener_list: wl_list,
};

pub const wl_listener = extern struct {
    link: wl_list,
    notify: ?*const fn (*wl_listener, ?*anyopaque) callconv(.c) void,
};

// ── libwayland-server functions ────────────────────────────────

pub extern "wayland-server" fn wl_display_create() callconv(.c) ?*wl_display;
pub extern "wayland-server" fn wl_display_destroy(display: *wl_display) callconv(.c) void;
pub extern "wayland-server" fn wl_display_run(display: *wl_display) callconv(.c) void;
pub extern "wayland-server" fn wl_display_terminate(display: *wl_display) callconv(.c) void;
pub extern "wayland-server" fn wl_display_get_event_loop(display: *wl_display) callconv(.c) ?*wl_event_loop;
pub extern "wayland-server" fn wl_display_add_socket_auto(display: *wl_display) callconv(.c) ?[*:0]const u8;

pub const wl_event_source = opaque {};
pub extern "wayland-server" fn wl_event_loop_add_fd(loop: *wl_event_loop, fd: c_int, mask: u32, func: *const fn (c_int, u32, ?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) callconv(.c) ?*wl_event_source;
pub extern "wayland-server" fn wl_event_source_remove(source: *wl_event_source) callconv(.c) c_int;
pub const WL_EVENT_READABLE: u32 = 0x01;

/// wl_signal_add is static inline in wayland headers — implement in Zig.
/// Inserts listener at the end of the signal's listener list.
pub fn wl_signal_add(signal: *wl_signal, listener: *wl_listener) void {
    wl_list_insert(signal.listener_list.prev orelse &signal.listener_list, &listener.link);
}

pub extern "wayland-server" fn wl_list_insert(list: *wl_list, elm: *wl_list) callconv(.c) void;
pub extern "wayland-server" fn wl_list_remove(elm: *wl_list) callconv(.c) void;

// ── wlroots backend ────────────────────────────────────────────

pub extern "wlroots-0.18" fn wlr_backend_autocreate(event_loop: *wl_event_loop, session_ptr: ?*?*wlr_session) callconv(.c) ?*wlr_backend;
pub extern "wlroots-0.18" fn wlr_backend_start(backend: *wlr_backend) callconv(.c) bool;
pub extern "wlroots-0.18" fn wlr_backend_destroy(backend: *wlr_backend) callconv(.c) void;

// ── wlroots renderer ──────────────────────────────────────────

pub extern "wlroots-0.18" fn wlr_renderer_autocreate(backend: *wlr_backend) callconv(.c) ?*wlr_renderer;
pub extern "wlroots-0.18" fn wlr_renderer_init_wl_display(renderer: *wlr_renderer, display: *wl_display) callconv(.c) bool;

// ── wlroots allocator ─────────────────────────────────────────

pub extern "wlroots-0.18" fn wlr_allocator_autocreate(backend: *wlr_backend, renderer: *wlr_renderer) callconv(.c) ?*wlr_allocator;

// ── wlroots scene graph ───────────────────────────────────────

pub extern "wlroots-0.18" fn wlr_scene_create() callconv(.c) ?*wlr_scene;
pub extern "wlroots-0.18" fn wlr_scene_output_layout_create(scene: *wlr_scene) callconv(.c) ?*wlr_scene_output_layout;
pub extern "wlroots-0.18" fn wlr_scene_output_create(scene: *wlr_scene, output: *wlr_output) callconv(.c) ?*wlr_scene_output;
pub extern "wlroots-0.18" fn wlr_scene_attach_output_layout(scene: *wlr_scene, layout: *wlr_output_layout) callconv(.c) ?*wlr_scene_output_layout;

// ── wlroots output ────────────────────────────────────────────

pub extern "wlroots-0.18" fn wlr_output_layout_create(display: *wl_display) callconv(.c) ?*wlr_output_layout;
pub extern "wlroots-0.18" fn wlr_output_layout_add_auto(layout: *wlr_output_layout, output: *wlr_output) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_output_init_render(output: *wlr_output, allocator: *wlr_allocator, renderer: *wlr_renderer) callconv(.c) bool;
pub extern "wlroots-0.18" fn wlr_output_schedule_frame(output: *wlr_output) callconv(.c) void;

// ── wlroots xdg-shell ─────────────────────────────────────────

pub extern "wlroots-0.18" fn wlr_xdg_shell_create(display: *wl_display, version: u32) callconv(.c) ?*wlr_xdg_shell;

// ── wlroots seat ──────────────────────────────────────────────

pub extern "wlroots-0.18" fn wlr_seat_create(display: *wl_display, name: [*:0]const u8) callconv(.c) ?*wlr_seat;

// ── wlroots compositor + subcompositor + data device ──────────

pub extern "wlroots-0.18" fn wlr_compositor_create(display: *wl_display, version: u32, renderer: *wlr_renderer) callconv(.c) ?*wlr_compositor;
pub extern "wlroots-0.18" fn wlr_subcompositor_create(display: *wl_display) callconv(.c) ?*wlr_subcompositor;
pub extern "wlroots-0.18" fn wlr_data_device_manager_create(display: *wl_display) callconv(.c) ?*wlr_data_device_manager;

// ── wlroots cursor ────────────────────────────────────────────

pub extern "wlroots-0.18" fn wlr_cursor_create() callconv(.c) ?*wlr_cursor;
pub extern "wlroots-0.18" fn wlr_cursor_attach_output_layout(cursor: *wlr_cursor, layout: *wlr_output_layout) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_xcursor_manager_create(name: ?[*:0]const u8, size: u32) callconv(.c) ?*wlr_xcursor_manager;
pub extern "wlroots-0.18" fn wlr_cursor_attach_input_device(cursor: *wlr_cursor, device: *wlr_input_device) callconv(.c) void;

// ── wlroots layer shell (for waybar, rofi, etc.) ──────────────

pub extern "wlroots-0.18" fn wlr_layer_shell_v1_create(display: *wl_display, version: u32) callconv(.c) ?*wlr_layer_shell_v1;

// ── C stdlib (for setenv) ──────────────────────────────────────

pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int;

// ── C glue accessors (vendor/miozu-wlr-glue.c) ────────────────
// Safe access to wlroots struct fields without replicating C layouts.

// Backend signals
pub extern "c" fn miozu_backend_new_output(backend: *wlr_backend) callconv(.c) *wl_signal;
pub extern "c" fn miozu_backend_new_input(backend: *wlr_backend) callconv(.c) *wl_signal;

// Output signals & fields
pub extern "c" fn miozu_output_frame(output: *wlr_output) callconv(.c) *wl_signal;
pub extern "c" fn miozu_output_request_state(output: *wlr_output) callconv(.c) *wl_signal;
pub extern "c" fn miozu_output_destroy(output: *wlr_output) callconv(.c) *wl_signal;
pub extern "c" fn miozu_output_width(output: *wlr_output) callconv(.c) c_int;
pub extern "c" fn miozu_output_height(output: *wlr_output) callconv(.c) c_int;
pub extern "c" fn miozu_output_name(output: *wlr_output) callconv(.c) ?[*:0]const u8;

// XDG shell signals
pub extern "c" fn miozu_xdg_shell_new_toplevel(shell: *wlr_xdg_shell) callconv(.c) *wl_signal;

// XDG toplevel signals & fields
pub extern "c" fn miozu_xdg_toplevel_destroy(toplevel: *wlr_xdg_toplevel) callconv(.c) *wl_signal;
pub extern "c" fn miozu_xdg_toplevel_request_move(toplevel: *wlr_xdg_toplevel) callconv(.c) *wl_signal;
pub extern "c" fn miozu_xdg_toplevel_request_resize(toplevel: *wlr_xdg_toplevel) callconv(.c) *wl_signal;
pub extern "c" fn miozu_xdg_toplevel_request_fullscreen(toplevel: *wlr_xdg_toplevel) callconv(.c) *wl_signal;
pub extern "c" fn miozu_xdg_toplevel_base(toplevel: *wlr_xdg_toplevel) callconv(.c) ?*wlr_xdg_surface;
pub extern "c" fn miozu_xdg_toplevel_app_id(toplevel: *wlr_xdg_toplevel) callconv(.c) ?[*:0]const u8;
pub extern "c" fn miozu_xdg_toplevel_title(toplevel: *wlr_xdg_toplevel) callconv(.c) ?[*:0]const u8;

// XDG surface fields
pub extern "c" fn miozu_xdg_surface_surface(surface: *wlr_xdg_surface) callconv(.c) ?*wlr_surface;
pub extern "c" fn miozu_xdg_surface_initial_commit(surface: *wlr_xdg_surface) callconv(.c) bool;

// wlr_surface signals (map/unmap/commit live on wlr_surface in 0.18)
pub extern "c" fn miozu_surface_map(surface: *wlr_surface) callconv(.c) *wl_signal;
pub extern "c" fn miozu_surface_unmap(surface: *wlr_surface) callconv(.c) *wl_signal;
pub extern "c" fn miozu_surface_commit(surface: *wlr_surface) callconv(.c) *wl_signal;

// Cursor signals & fields
pub extern "c" fn miozu_cursor_motion(cursor: *wlr_cursor) callconv(.c) *wl_signal;
pub extern "c" fn miozu_cursor_motion_absolute(cursor: *wlr_cursor) callconv(.c) *wl_signal;
pub extern "c" fn miozu_cursor_button(cursor: *wlr_cursor) callconv(.c) *wl_signal;
pub extern "c" fn miozu_cursor_axis(cursor: *wlr_cursor) callconv(.c) *wl_signal;
pub extern "c" fn miozu_cursor_frame(cursor: *wlr_cursor) callconv(.c) *wl_signal;
pub extern "c" fn miozu_cursor_x(cursor: *wlr_cursor) callconv(.c) f64;
pub extern "c" fn miozu_cursor_y(cursor: *wlr_cursor) callconv(.c) f64;

// Keyboard signals & fields
pub extern "c" fn miozu_keyboard_key(keyboard: *wlr_keyboard) callconv(.c) *wl_signal;
pub extern "c" fn miozu_keyboard_modifiers(keyboard: *wlr_keyboard) callconv(.c) *wl_signal;
pub extern "c" fn miozu_keyboard_xkb_state(keyboard: *wlr_keyboard) callconv(.c) ?*xkb_state;
pub extern "c" fn miozu_keyboard_modifiers_ptr(keyboard: *wlr_keyboard) callconv(.c) ?*anyopaque;

// Input device fields
pub extern "c" fn miozu_input_device_type(device: *wlr_input_device) callconv(.c) c_int;
pub extern "c" fn miozu_input_device_keyboard(device: *wlr_input_device) callconv(.c) ?*wlr_keyboard;

// Scene graph fields
pub extern "c" fn miozu_scene_tree(scene: *wlr_scene) callconv(.c) ?*wlr_scene_tree;
pub extern "c" fn miozu_scene_tree_node(tree: *wlr_scene_tree) callconv(.c) ?*wlr_scene_node;
pub extern "c" fn miozu_scene_buffer_node(buffer: *wlr_scene_buffer) callconv(.c) ?*wlr_scene_node;

// Output enable+commit helper
pub extern "c" fn miozu_output_enable_and_commit(output: *wlr_output) callconv(.c) bool;

// Output layout signals
pub extern "c" fn miozu_output_layout_change(layout: *wlr_output_layout) callconv(.c) *wl_signal;

// Seat keyboard accessor
pub extern "c" fn miozu_seat_get_keyboard(seat: *wlr_seat) callconv(.c) ?*wlr_keyboard;

// Seat request signals
pub extern "c" fn miozu_seat_request_set_cursor(seat: *wlr_seat) callconv(.c) *wl_signal;
pub extern "c" fn miozu_seat_request_set_selection(seat: *wlr_seat) callconv(.c) *wl_signal;

// ── Additional opaque types for glue ───────────────────────────

pub const wlr_scene_node = opaque {};
pub const xkb_state = opaque {};
pub const wlr_output_event_request_state = opaque {};

// ── Constants ──────────────────────────────────────────────────

pub const WLR_INPUT_DEVICE_KEYBOARD: c_int = 0;
pub const WLR_INPUT_DEVICE_POINTER: c_int = 1;

// ── Additional wlroots functions needed for output handling ────

pub extern "wlroots-0.18" fn wlr_output_commit_state(output: *wlr_output, state: *wlr_output_state) callconv(.c) bool;
pub extern "wlroots-0.18" fn wlr_output_state_init(state: *wlr_output_state) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_output_state_finish(state: *wlr_output_state) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_output_state_set_enabled(state: *wlr_output_state, enabled: bool) callconv(.c) void;

pub extern "wlroots-0.18" fn wlr_scene_get_scene_output(scene: *wlr_scene, output: *wlr_output) callconv(.c) ?*wlr_scene_output;
pub extern "wlroots-0.18" fn wlr_scene_output_commit(scene_output: *wlr_scene_output, options: ?*anyopaque) callconv(.c) bool;

pub extern "wlroots-0.18" fn wlr_keyboard_set_keymap(keyboard: *wlr_keyboard, keymap: *xkb_keymap) callconv(.c) bool;
pub extern "wlroots-0.18" fn wlr_keyboard_set_repeat_info(keyboard: *wlr_keyboard, rate: i32, delay: i32) callconv(.c) void;

pub extern "wlroots-0.18" fn wlr_seat_set_keyboard(seat: *wlr_seat, keyboard: *wlr_keyboard) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_seat_set_capabilities(seat: *wlr_seat, capabilities: u32) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_seat_keyboard_notify_enter(seat: *wlr_seat, surface: *wlr_surface, keycodes: ?[*]const u32, num_keycodes: usize, modifiers: ?*anyopaque) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_seat_keyboard_notify_key(seat: *wlr_seat, time_msec: u32, key: u32, state: u32) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_seat_keyboard_notify_modifiers(seat: *wlr_seat, modifiers: ?*anyopaque) callconv(.c) void;

pub extern "wlroots-0.18" fn wlr_scene_xdg_surface_create(parent: *wlr_scene_tree, surface: *wlr_xdg_surface) callconv(.c) ?*wlr_scene_tree;
pub extern "wlroots-0.18" fn wlr_scene_subsurface_tree_create(parent: *wlr_scene_tree, surface: *wlr_surface) callconv(.c) ?*wlr_scene_tree;
pub extern "wlroots-0.18" fn wlr_scene_node_set_position(node: *wlr_scene_node, x: c_int, y: c_int) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_scene_node_set_enabled(node: *wlr_scene_node, enabled: bool) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_xdg_toplevel_set_size(toplevel: *wlr_xdg_toplevel, width: u32, height: u32) callconv(.c) u32;
pub extern "wlroots-0.18" fn wlr_xdg_toplevel_set_activated(toplevel: *wlr_xdg_toplevel, activated: bool) callconv(.c) u32;
pub extern "wlroots-0.18" fn wlr_scene_rect_create(parent: *wlr_scene_tree, width: c_int, height: c_int, color: *const [4]f32) callconv(.c) ?*wlr_scene_rect;
pub extern "wlroots-0.18" fn wlr_scene_rect_set_size(rect: *wlr_scene_rect, width: c_int, height: c_int) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_scene_rect_set_color(rect: *wlr_scene_rect, color: *const [4]f32) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_scene_node_lower_to_bottom(node: *wlr_scene_node) callconv(.c) void;
pub extern "c" fn miozu_scene_rect_node(rect: *wlr_scene_rect) callconv(.c) *wlr_scene_node;

// xkbcommon
pub extern "xkbcommon" fn xkb_context_new(flags: c_int) callconv(.c) ?*xkb_context;
pub extern "xkbcommon" fn xkb_context_unref(context: *xkb_context) callconv(.c) void;
pub extern "xkbcommon" fn xkb_keymap_new_from_names(context: *xkb_context, names: ?*anyopaque, flags: c_int) callconv(.c) ?*xkb_keymap;
pub extern "xkbcommon" fn xkb_keymap_unref(keymap: *xkb_keymap) callconv(.c) void;
pub extern "xkbcommon" fn xkb_state_key_get_one_sym(state: *xkb_state, key: u32) callconv(.c) u32;
pub extern "xkbcommon" fn xkb_state_mod_name_is_active(state: *xkb_state, name: [*:0]const u8, kind: c_int) callconv(.c) c_int;
pub extern "xkbcommon" fn xkb_state_key_get_utf8(state: *xkb_state, key: u32, buffer: [*]u8, size: usize) callconv(.c) c_int;

// xkb modifier name constants
pub const XKB_MOD_NAME_LOGO = "Mod4";
pub const XKB_MOD_NAME_ALT = "Mod1";
pub const XKB_MOD_NAME_SHIFT = "Shift";
pub const XKB_MOD_NAME_CTRL = "Control";
pub const XKB_STATE_MODS_EFFECTIVE: c_int = 8;

// xkb keysym constants (from xkbcommon-keysyms.h)
pub const XKB_KEY_Return: u32 = 0xff0d;
pub const XKB_KEY_Escape: u32 = 0xff1b;
pub const XKB_KEY_space: u32 = 0x0020;
pub const XKB_KEY_j: u32 = 0x006a;
pub const XKB_KEY_k: u32 = 0x006b;
pub const XKB_KEY_h: u32 = 0x0068;
pub const XKB_KEY_l: u32 = 0x006c;
pub const XKB_KEY_d: u32 = 0x0064;
pub const XKB_KEY_f: u32 = 0x0066;
pub const XKB_KEY_c: u32 = 0x0063;
pub const XKB_KEY_q: u32 = 0x0071;
pub const XKB_KEY_1: u32 = 0x0031;
pub const XKB_KEY_0: u32 = 0x0030;

// cursor motion event types
pub const wlr_pointer_motion_event = opaque {};
pub const wlr_pointer_motion_absolute_event = opaque {};
pub const wlr_pointer_button_event = opaque {};

// Cursor motion helpers
pub extern "wlroots-0.18" fn wlr_cursor_move(cursor: *wlr_cursor, device: ?*wlr_input_device, delta_x: f64, delta_y: f64) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_cursor_warp_absolute(cursor: *wlr_cursor, device: ?*wlr_input_device, x: f64, y: f64) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_cursor_set_xcursor(cursor: *wlr_cursor, mgr: *wlr_xcursor_manager, name: [*:0]const u8) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_cursor_set_surface(cursor: *wlr_cursor, surface: ?*wlr_surface, hotspot_x: i32, hotspot_y: i32) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_seat_pointer_notify_enter(seat: *wlr_seat, surface: *wlr_surface, sx: f64, sy: f64) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_seat_pointer_notify_motion(seat: *wlr_seat, time_msec: u32, sx: f64, sy: f64) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_seat_pointer_notify_button(seat: *wlr_seat, time_msec: u32, button: u32, state: u32) callconv(.c) u32;
pub extern "wlroots-0.18" fn wlr_seat_pointer_notify_frame(seat: *wlr_seat) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_seat_pointer_clear_focus(seat: *wlr_seat) callconv(.c) void;

// Scene node hit testing + surface resolution
pub extern "wlroots-0.18" fn wlr_scene_node_at(node: *wlr_scene_node, lx: f64, ly: f64, nx: *f64, ny: *f64) callconv(.c) ?*wlr_scene_node;
pub extern "wlroots-0.18" fn wlr_scene_buffer_from_node(node: *wlr_scene_node) callconv(.c) ?*wlr_scene_buffer;
pub extern "wlroots-0.18" fn wlr_scene_surface_try_from_buffer(buffer: *wlr_scene_buffer) callconv(.c) ?*wlr_scene_surface;

// XDG toplevel close
pub extern "wlroots-0.18" fn wlr_xdg_toplevel_send_close(toplevel: *wlr_xdg_toplevel) callconv(.c) void;

// Scene surface → wlr_surface accessor (in glue)
pub extern "c" fn miozu_scene_surface_get_surface(scene_surface: *wlr_scene_surface) callconv(.c) ?*wlr_surface;

// Output primary dimensions (in glue — returns first output w/h)
pub extern "c" fn miozu_output_layout_first_width(layout: *wlr_output_layout) callconv(.c) c_int;
pub extern "c" fn miozu_output_layout_first_height(layout: *wlr_output_layout) callconv(.c) c_int;

// Request set cursor event accessors (in glue)
pub extern "c" fn miozu_set_cursor_event_surface(event: *anyopaque) callconv(.c) ?*wlr_surface;
pub extern "c" fn miozu_set_cursor_event_hotspot_x(event: *anyopaque) callconv(.c) i32;
pub extern "c" fn miozu_set_cursor_event_hotspot_y(event: *anyopaque) callconv(.c) i32;

// Pointer motion event accessors (in glue)
pub extern "c" fn miozu_pointer_motion_dx(event: *wlr_pointer_motion_event) callconv(.c) f64;
pub extern "c" fn miozu_pointer_motion_dy(event: *wlr_pointer_motion_event) callconv(.c) f64;
pub extern "c" fn miozu_pointer_motion_time(event: *wlr_pointer_motion_event) callconv(.c) u32;
pub extern "c" fn miozu_pointer_motion_abs_x(event: *wlr_pointer_motion_absolute_event) callconv(.c) f64;
pub extern "c" fn miozu_pointer_motion_abs_y(event: *wlr_pointer_motion_absolute_event) callconv(.c) f64;
pub extern "c" fn miozu_pointer_motion_abs_time(event: *wlr_pointer_motion_absolute_event) callconv(.c) u32;
pub extern "c" fn miozu_pointer_button_button(event: *wlr_pointer_button_event) callconv(.c) u32;
pub extern "c" fn miozu_pointer_button_state(event: *wlr_pointer_button_event) callconv(.c) u32;
pub extern "c" fn miozu_pointer_button_time(event: *wlr_pointer_button_event) callconv(.c) u32;

// Axis (scroll wheel) event accessors (in glue)
pub const wlr_pointer_axis_event = opaque {};
pub extern "c" fn miozu_pointer_axis_delta(event: *wlr_pointer_axis_event) callconv(.c) f64;
pub extern "c" fn miozu_pointer_axis_orientation(event: *wlr_pointer_axis_event) callconv(.c) u32;
pub extern "c" fn miozu_pointer_axis_source(event: *wlr_pointer_axis_event) callconv(.c) u32;
pub extern "c" fn miozu_pointer_axis_time(event: *wlr_pointer_axis_event) callconv(.c) u32;
pub extern "c" fn miozu_pointer_axis_delta_discrete(event: *wlr_pointer_axis_event) callconv(.c) i32;
pub extern "c" fn wlr_seat_pointer_notify_axis(seat: *wlr_seat, time: u32, orientation: u32, delta: f64, delta_discrete: i32, source: u32, relative_direction: u32) callconv(.c) void;

// Keyboard event accessor (in glue)
pub extern "c" fn miozu_keyboard_key_keycode(event: *anyopaque) callconv(.c) u32;
pub extern "c" fn miozu_keyboard_key_state(event: *anyopaque) callconv(.c) u32;
pub extern "c" fn miozu_keyboard_key_time(event: *anyopaque) callconv(.c) u32;

// WL_SEAT capability bits
pub const WL_SEAT_CAPABILITY_POINTER: u32 = 1;
pub const WL_SEAT_CAPABILITY_KEYBOARD: u32 = 2;

// ── Session (VT switching) ──────────────────────────────────────

pub extern "wlroots-0.18" fn wlr_session_change_vt(session: *wlr_session, vt: c_uint) callconv(.c) bool;

// XKB keysyms for VT switching (Ctrl+Alt+F1-F12)
pub const XKB_KEY_XF86Switch_VT_1: u32 = 0x1008FE01;

// ── XWayland ───────────────────────────────────────────────────

pub const wlr_xwayland = opaque {};
pub const wlr_xwayland_surface = opaque {};

pub extern "wlroots-0.18" fn wlr_xwayland_create(display: *wl_display, compositor: *wlr_compositor, lazy: bool) callconv(.c) ?*wlr_xwayland;
pub extern "wlroots-0.18" fn wlr_xwayland_destroy(xwayland: *wlr_xwayland) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_xwayland_surface_configure(surface: *wlr_xwayland_surface, x: i16, y: i16, width: u16, height: u16) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_xwayland_surface_activate(surface: *wlr_xwayland_surface, activated: bool) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_xwayland_surface_close(surface: *wlr_xwayland_surface) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_xwayland_set_seat(xwayland: *wlr_xwayland, seat: *wlr_seat) callconv(.c) void;

// XWayland C glue accessors
pub extern "c" fn miozu_xwayland_new_surface(xwl: *wlr_xwayland) callconv(.c) *wl_signal;
pub extern "c" fn miozu_xwayland_ready(xwl: *wlr_xwayland) callconv(.c) *wl_signal;
pub extern "c" fn miozu_xwayland_display_name(xwl: *wlr_xwayland) callconv(.c) ?[*:0]const u8;
pub extern "c" fn miozu_xwayland_surface_surface(surface: *wlr_xwayland_surface) callconv(.c) ?*wlr_surface;
pub extern "c" fn miozu_xwayland_surface_override_redirect(surface: *wlr_xwayland_surface) callconv(.c) bool;
pub extern "c" fn miozu_xwayland_surface_class(surface: *wlr_xwayland_surface) callconv(.c) ?[*:0]const u8;
pub extern "c" fn miozu_xwayland_surface_title(surface: *wlr_xwayland_surface) callconv(.c) ?[*:0]const u8;
pub extern "c" fn miozu_xwayland_surface_x(surface: *wlr_xwayland_surface) callconv(.c) i16;
pub extern "c" fn miozu_xwayland_surface_y(surface: *wlr_xwayland_surface) callconv(.c) i16;
pub extern "c" fn miozu_xwayland_surface_width(surface: *wlr_xwayland_surface) callconv(.c) u16;
pub extern "c" fn miozu_xwayland_surface_height(surface: *wlr_xwayland_surface) callconv(.c) u16;
pub extern "c" fn miozu_xwayland_surface_map(surface: *wlr_xwayland_surface) callconv(.c) *wl_signal;
pub extern "c" fn miozu_xwayland_surface_unmap(surface: *wlr_xwayland_surface) callconv(.c) *wl_signal;
pub extern "c" fn miozu_xwayland_surface_destroy(surface: *wlr_xwayland_surface) callconv(.c) *wl_signal;
pub extern "c" fn miozu_xwayland_surface_request_configure(surface: *wlr_xwayland_surface) callconv(.c) *wl_signal;

// ── Custom pixel buffer for terminal panes ─────────────────────

pub extern "c" fn miozu_pixel_buffer_create(width: c_int, height: c_int) callconv(.c) ?*wlr_buffer;
pub extern "c" fn miozu_pixel_buffer_data(buffer: *wlr_buffer) callconv(.c) ?[*]u32;
pub extern "c" fn miozu_pixel_buffer_resize(buffer: *wlr_buffer, width: c_int, height: c_int) callconv(.c) bool;

pub const wlr_buffer = opaque {};

pub extern "wlroots-0.18" fn wlr_scene_buffer_create(parent: *wlr_scene_tree, buffer: ?*wlr_buffer) callconv(.c) ?*wlr_scene_buffer;
pub extern "wlroots-0.18" fn wlr_scene_buffer_set_buffer(scene_buffer: *wlr_scene_buffer, buffer: ?*wlr_buffer) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_scene_buffer_set_buffer_with_damage(scene_buffer: *wlr_scene_buffer, buffer: ?*wlr_buffer, damage: ?*anyopaque) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_scene_buffer_set_dest_size(scene_buffer: *wlr_scene_buffer, width: c_int, height: c_int) callconv(.c) void;
pub extern "wlroots-0.18" fn wlr_buffer_drop(buffer: *wlr_buffer) callconv(.c) void;

// ── Utility: container-of pattern ──────────────────────────────

/// Helper to get the container struct from a wl_listener pointer.
/// Usage: const server = listenerParent(Server, "new_output", listener);
pub fn listenerParent(comptime T: type, comptime field: []const u8, listener: *wl_listener) *T {
    return @fieldParentPtr(field, listener);
}
