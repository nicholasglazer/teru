//! Wayland backend using xdg-shell + wl_shm.
//!
//! Creates a toplevel window via xdg_wm_base, blits CPU framebuffer
//! via shared-memory buffers (wl_shm). Keyboard events delivered as
//! raw keycodes; xkbcommon translation handled by keyboard.zig.
//!
//! Dependencies: libwayland-client, vendored xdg-shell protocol code.

const std = @import("std");
const platform = @import("platform.zig");

pub const Event = platform.Event;
pub const KeyEvent = platform.KeyEvent;
const MouseButton = platform.MouseButton;

// ── Wayland core types (extern linkage against libwayland-client) ─────

const wl_proxy = opaque {};
const wl_display = opaque {};
const wl_registry = opaque {};
const wl_compositor = opaque {};
const wl_surface = opaque {};
const wl_shm = opaque {};
const wl_shm_pool = opaque {};
const wl_buffer = opaque {};
const wl_seat = opaque {};
const wl_keyboard = opaque {};
const wl_pointer = opaque {};

const wl_interface = extern struct {
    name: ?[*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?*const anyopaque,
    event_count: c_int,
    events: ?*const anyopaque,
};

const wl_array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

// ── Wayland listener structs ──────────────────────────────────────────

const wl_registry_listener = extern struct {
    global: ?*const fn (?*anyopaque, ?*wl_registry, u32, ?[*:0]const u8, u32) callconv(.c) void,
    global_remove: ?*const fn (?*anyopaque, ?*wl_registry, u32) callconv(.c) void,
};

const wl_seat_listener = extern struct {
    capabilities: ?*const fn (?*anyopaque, ?*wl_seat, u32) callconv(.c) void,
    name: ?*const fn (?*anyopaque, ?*wl_seat, ?[*:0]const u8) callconv(.c) void,
};

const wl_keyboard_listener = extern struct {
    keymap: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, i32, u32) callconv(.c) void,
    enter: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, ?*wl_surface, ?*wl_array) callconv(.c) void,
    leave: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, ?*wl_surface) callconv(.c) void,
    key: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, u32, u32, u32) callconv(.c) void,
    modifiers: ?*const fn (?*anyopaque, ?*wl_keyboard, u32, u32, u32, u32, u32) callconv(.c) void,
    repeat_info: ?*const fn (?*anyopaque, ?*wl_keyboard, i32, i32) callconv(.c) void,
};

const wl_pointer_listener = extern struct {
    enter: ?*const fn (?*anyopaque, ?*wl_pointer, u32, ?*wl_surface, i32, i32) callconv(.c) void,
    leave: ?*const fn (?*anyopaque, ?*wl_pointer, u32, ?*wl_surface) callconv(.c) void,
    motion: ?*const fn (?*anyopaque, ?*wl_pointer, u32, i32, i32) callconv(.c) void,
    button: ?*const fn (?*anyopaque, ?*wl_pointer, u32, u32, u32, u32) callconv(.c) void,
    axis: ?*const fn (?*anyopaque, ?*wl_pointer, u32, u32, i32) callconv(.c) void,
    frame: ?*const fn (?*anyopaque, ?*wl_pointer) callconv(.c) void,
    axis_source: ?*const fn (?*anyopaque, ?*wl_pointer, u32) callconv(.c) void,
    axis_stop: ?*const fn (?*anyopaque, ?*wl_pointer, u32, u32) callconv(.c) void,
    axis_discrete: ?*const fn (?*anyopaque, ?*wl_pointer, u32, i32) callconv(.c) void,
};

// ── xdg-shell types ──────────────────────────────────────────────────

const xdg_wm_base = opaque {};
const xdg_surface = opaque {};
const xdg_toplevel = opaque {};

const xdg_wm_base_listener = extern struct {
    ping: ?*const fn (?*anyopaque, ?*xdg_wm_base, u32) callconv(.c) void,
};

const xdg_surface_listener = extern struct {
    configure: ?*const fn (?*anyopaque, ?*xdg_surface, u32) callconv(.c) void,
};

const xdg_toplevel_listener = extern struct {
    configure: ?*const fn (?*anyopaque, ?*xdg_toplevel, i32, i32, ?*wl_array) callconv(.c) void,
    close: ?*const fn (?*anyopaque, ?*xdg_toplevel) callconv(.c) void,
    configure_bounds: ?*const fn (?*anyopaque, ?*xdg_toplevel, i32, i32) callconv(.c) void,
    wm_capabilities: ?*const fn (?*anyopaque, ?*xdg_toplevel, ?*wl_array) callconv(.c) void,
};

// ── Wayland constants ─────────────────────────────────────────────────

const WL_SHM_FORMAT_ARGB8888: u32 = 0;
const WL_SEAT_CAPABILITY_POINTER: u32 = 1;
const WL_SEAT_CAPABILITY_KEYBOARD: u32 = 2;
const WL_KEYBOARD_KEY_STATE_PRESSED: u32 = 1;
const WL_KEYBOARD_KEY_STATE_RELEASED: u32 = 0;
const WL_MARSHAL_FLAG_DESTROY: u32 = 1;

// ── Wayland interface externs ─────────────────────────────────────────

extern const wl_registry_interface: wl_interface;
extern const wl_compositor_interface: wl_interface;
extern const wl_shm_interface: wl_interface;
extern const wl_seat_interface: wl_interface;
extern const xdg_wm_base_interface: wl_interface;
extern const xdg_surface_interface: wl_interface;
extern const xdg_toplevel_interface: wl_interface;

// ── Wayland core extern functions ─────────────────────────────────────

extern "wayland-client" fn wl_display_connect(name: ?[*:0]const u8) callconv(.c) ?*wl_display;
extern "wayland-client" fn wl_display_disconnect(display: *wl_display) callconv(.c) void;
extern "wayland-client" fn wl_display_roundtrip(display: *wl_display) callconv(.c) c_int;
extern "wayland-client" fn wl_display_dispatch(display: *wl_display) callconv(.c) c_int;
extern "wayland-client" fn wl_display_dispatch_pending(display: *wl_display) callconv(.c) c_int;
extern "wayland-client" fn wl_display_prepare_read(display: *wl_display) callconv(.c) c_int;
extern "wayland-client" fn wl_display_read_events(display: *wl_display) callconv(.c) c_int;
extern "wayland-client" fn wl_display_cancel_read(display: *wl_display) callconv(.c) void;
extern "wayland-client" fn wl_display_flush(display: *wl_display) callconv(.c) c_int;
extern "wayland-client" fn wl_display_get_fd(display: *wl_display) callconv(.c) c_int;

extern "wayland-client" fn wl_proxy_marshal_flags(proxy: *anyopaque, opcode: u32, iface: ?*const wl_interface, version: u32, flags: u32, ...) callconv(.c) ?*anyopaque;
extern "wayland-client" fn wl_proxy_add_listener(proxy: *anyopaque, listener: *const anyopaque, data: ?*anyopaque) callconv(.c) c_int;
extern "wayland-client" fn wl_proxy_get_version(proxy: *anyopaque) callconv(.c) u32;
extern "wayland-client" fn wl_proxy_destroy(proxy: *anyopaque) callconv(.c) void;

// ── Wrapper functions for wayland-client inline helpers ────────────────
// In C, these are static inline functions in the protocol headers.
// They all delegate to wl_proxy_marshal_flags / wl_proxy_*.

fn wl_display_get_registry(display: *wl_display) ?*wl_registry {
    // WL_DISPLAY_GET_REGISTRY = opcode 1
    return @ptrCast(wl_proxy_marshal_flags(@ptrCast(display), 1, &wl_registry_interface, wl_proxy_get_version(@ptrCast(display)), 0, @as(?*anyopaque, null)));
}

fn wl_registry_bind(registry: *wl_registry, name: u32, iface: *const wl_interface, version: u32) ?*anyopaque {
    // WL_REGISTRY_BIND = opcode 0
    return wl_proxy_marshal_flags(@ptrCast(registry), 0, iface, version, 0, name, iface.name.?, version, @as(?*anyopaque, null));
}

fn wl_registry_add_listener(registry: *wl_registry, listener: *const wl_registry_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(registry), @ptrCast(listener), data);
}

fn wl_registry_destroy(registry: *wl_registry) void {
    wl_proxy_destroy(@ptrCast(registry));
}

fn wl_compositor_create_surface(compositor: *wl_compositor) ?*wl_surface {
    // WL_COMPOSITOR_CREATE_SURFACE = opcode 0
    return @ptrCast(wl_proxy_marshal_flags(@ptrCast(compositor), 0, &wl_surface_interface, wl_proxy_get_version(@ptrCast(compositor)), 0, @as(?*anyopaque, null)));
}

fn wl_compositor_destroy(compositor: *wl_compositor) void {
    wl_proxy_destroy(@ptrCast(compositor));
}

fn wl_surface_attach(surface: *wl_surface, buffer: ?*wl_buffer, x: i32, y: i32) void {
    // WL_SURFACE_ATTACH = opcode 1
    _ = wl_proxy_marshal_flags(@ptrCast(surface), 1, null, wl_proxy_get_version(@ptrCast(surface)), 0, buffer, x, y);
}

fn wl_surface_damage_buffer(surface: *wl_surface, x: i32, y: i32, width: i32, height: i32) void {
    // WL_SURFACE_DAMAGE_BUFFER = opcode 9
    _ = wl_proxy_marshal_flags(@ptrCast(surface), 9, null, wl_proxy_get_version(@ptrCast(surface)), 0, x, y, width, height);
}

fn wl_surface_commit(surface: *wl_surface) void {
    // WL_SURFACE_COMMIT = opcode 6
    _ = wl_proxy_marshal_flags(@ptrCast(surface), 6, null, wl_proxy_get_version(@ptrCast(surface)), 0);
}

fn wl_surface_destroy(surface: *wl_surface) void {
    // WL_SURFACE_DESTROY = opcode 0
    _ = wl_proxy_marshal_flags(@ptrCast(surface), 0, null, wl_proxy_get_version(@ptrCast(surface)), WL_MARSHAL_FLAG_DESTROY);
}

fn wl_shm_create_pool(shm_: *wl_shm, fd: i32, size: i32) ?*wl_shm_pool {
    // WL_SHM_CREATE_POOL = opcode 0
    return @ptrCast(wl_proxy_marshal_flags(@ptrCast(shm_), 0, &wl_shm_pool_interface, wl_proxy_get_version(@ptrCast(shm_)), 0, @as(?*anyopaque, null), fd, size));
}

fn wl_shm_destroy(shm_: *wl_shm) void {
    wl_proxy_destroy(@ptrCast(shm_));
}

fn wl_shm_pool_create_buffer(pool: *wl_shm_pool, offset: i32, width: i32, height: i32, stride: i32, format: u32) ?*wl_buffer {
    // WL_SHM_POOL_CREATE_BUFFER = opcode 0
    return @ptrCast(wl_proxy_marshal_flags(@ptrCast(pool), 0, &wl_buffer_interface, wl_proxy_get_version(@ptrCast(pool)), 0, @as(?*anyopaque, null), offset, width, height, stride, format));
}

fn wl_shm_pool_destroy(pool: *wl_shm_pool) void {
    // WL_SHM_POOL_DESTROY = opcode 1
    _ = wl_proxy_marshal_flags(@ptrCast(pool), 1, null, wl_proxy_get_version(@ptrCast(pool)), WL_MARSHAL_FLAG_DESTROY);
}

fn wl_buffer_destroy(buffer: *wl_buffer) void {
    // WL_BUFFER_DESTROY = opcode 0
    _ = wl_proxy_marshal_flags(@ptrCast(buffer), 0, null, wl_proxy_get_version(@ptrCast(buffer)), WL_MARSHAL_FLAG_DESTROY);
}

fn wl_seat_add_listener(seat: *wl_seat, listener: *const wl_seat_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(seat), @ptrCast(listener), data);
}

fn wl_seat_get_keyboard(seat: *wl_seat) ?*wl_keyboard {
    // WL_SEAT_GET_KEYBOARD = opcode 1
    return @ptrCast(wl_proxy_marshal_flags(@ptrCast(seat), 1, &wl_keyboard_interface, wl_proxy_get_version(@ptrCast(seat)), 0, @as(?*anyopaque, null)));
}

fn wl_seat_get_pointer(seat: *wl_seat) ?*wl_pointer {
    // WL_SEAT_GET_POINTER = opcode 0
    return @ptrCast(wl_proxy_marshal_flags(@ptrCast(seat), 0, &wl_pointer_interface, wl_proxy_get_version(@ptrCast(seat)), 0, @as(?*anyopaque, null)));
}

fn wl_pointer_add_listener(ptr: *wl_pointer, listener: *const wl_pointer_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(ptr), @ptrCast(listener), data);
}

fn wl_pointer_set_cursor(ptr: *wl_pointer, serial: u32, surface: ?*wl_surface, hotspot_x: i32, hotspot_y: i32) void {
    // WL_POINTER_SET_CURSOR = opcode 0
    _ = wl_proxy_marshal_flags(@ptrCast(ptr), 0, null, wl_proxy_get_version(@ptrCast(ptr)), 0, serial, surface, hotspot_x, hotspot_y);
}

fn wl_pointer_destroy(ptr: *wl_pointer) void {
    wl_proxy_destroy(@ptrCast(ptr));
}

fn wl_seat_destroy(seat: *wl_seat) void {
    wl_proxy_destroy(@ptrCast(seat));
}

fn wl_keyboard_add_listener(kb: *wl_keyboard, listener: *const wl_keyboard_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(kb), @ptrCast(listener), data);
}

fn wl_keyboard_destroy(kb: *wl_keyboard) void {
    wl_proxy_destroy(@ptrCast(kb));
}

// ── xdg-shell wrapper functions ───────────────────────────────────────

fn xdg_wm_base_add_listener(wm: *xdg_wm_base, listener: *const xdg_wm_base_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(wm), @ptrCast(listener), data);
}

fn xdg_wm_base_get_xdg_surface(wm: *xdg_wm_base, surface: *wl_surface) ?*xdg_surface {
    // XDG_WM_BASE_GET_XDG_SURFACE = opcode 2
    return @ptrCast(wl_proxy_marshal_flags(@ptrCast(wm), 2, &xdg_surface_interface, wl_proxy_get_version(@ptrCast(wm)), 0, @as(?*anyopaque, null), surface));
}

fn xdg_wm_base_pong(wm: *xdg_wm_base, serial: u32) void {
    // XDG_WM_BASE_PONG = opcode 3
    _ = wl_proxy_marshal_flags(@ptrCast(wm), 3, null, wl_proxy_get_version(@ptrCast(wm)), 0, serial);
}

fn xdg_wm_base_destroy(wm: *xdg_wm_base) void {
    // XDG_WM_BASE_DESTROY = opcode 0
    _ = wl_proxy_marshal_flags(@ptrCast(wm), 0, null, wl_proxy_get_version(@ptrCast(wm)), WL_MARSHAL_FLAG_DESTROY);
}

fn xdg_surface_add_listener(surface: *xdg_surface, listener: *const xdg_surface_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(surface), @ptrCast(listener), data);
}

fn xdg_surface_get_toplevel(surface: *xdg_surface) ?*xdg_toplevel {
    // XDG_SURFACE_GET_TOPLEVEL = opcode 1
    return @ptrCast(wl_proxy_marshal_flags(@ptrCast(surface), 1, &xdg_toplevel_interface, wl_proxy_get_version(@ptrCast(surface)), 0, @as(?*anyopaque, null)));
}

fn xdg_surface_ack_configure(surface: *xdg_surface, serial: u32) void {
    // XDG_SURFACE_ACK_CONFIGURE = opcode 4
    _ = wl_proxy_marshal_flags(@ptrCast(surface), 4, null, wl_proxy_get_version(@ptrCast(surface)), 0, serial);
}

fn xdg_surface_destroy(surface: *xdg_surface) void {
    // XDG_SURFACE_DESTROY = opcode 0
    _ = wl_proxy_marshal_flags(@ptrCast(surface), 0, null, wl_proxy_get_version(@ptrCast(surface)), WL_MARSHAL_FLAG_DESTROY);
}

fn xdg_toplevel_add_listener(toplevel: *xdg_toplevel, listener: *const xdg_toplevel_listener, data: ?*anyopaque) c_int {
    return wl_proxy_add_listener(@ptrCast(toplevel), @ptrCast(listener), data);
}

fn xdg_toplevel_set_title(toplevel: *xdg_toplevel, title: [*:0]const u8) void {
    // XDG_TOPLEVEL_SET_TITLE = opcode 2
    _ = wl_proxy_marshal_flags(@ptrCast(toplevel), 2, null, wl_proxy_get_version(@ptrCast(toplevel)), 0, title);
}

fn xdg_toplevel_set_app_id(toplevel: *xdg_toplevel, app_id: [*:0]const u8) void {
    // XDG_TOPLEVEL_SET_APP_ID = opcode 3
    _ = wl_proxy_marshal_flags(@ptrCast(toplevel), 3, null, wl_proxy_get_version(@ptrCast(toplevel)), 0, app_id);
}

fn xdg_toplevel_destroy(toplevel: *xdg_toplevel) void {
    // XDG_TOPLEVEL_DESTROY = opcode 0
    _ = wl_proxy_marshal_flags(@ptrCast(toplevel), 0, null, wl_proxy_get_version(@ptrCast(toplevel)), WL_MARSHAL_FLAG_DESTROY);
}

// ── Additional wl_interface externs needed by wrappers ────────────────

extern const wl_surface_interface: wl_interface;
extern const wl_shm_pool_interface: wl_interface;
extern const wl_buffer_interface: wl_interface;
extern const wl_keyboard_interface: wl_interface;
extern const wl_pointer_interface: wl_interface;

// ── Linux syscall constants ───────────────────────────────────────────

const MFD_CLOEXEC: c_uint = 0x0001;

// ── WaylandState ──────────────────────────────────────────────────────

/// Shared state for Wayland listener callbacks. Callbacks receive a
/// pointer to this struct via the `data` parameter.
const WaylandState = struct {
    compositor: ?*wl_compositor = null,
    xdg_wm_base_ptr: ?*xdg_wm_base = null,
    shm: ?*wl_shm = null,
    seat: ?*wl_seat = null,
    keyboard: ?*wl_keyboard = null,
    pointer: ?*wl_pointer = null,

    // Pointer state: last known position and serial (for clipboard)
    pointer_x: u32 = 0,
    pointer_y: u32 = 0,
    pointer_serial: u32 = 0,

    // Pending dimensions from xdg_toplevel.configure (0 = use default)
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    configured: bool = false,
    close_requested: bool = false,

    // Keyboard state: ring buffer of events
    key_events: [32]Event = undefined,
    key_head: u32 = 0,
    key_tail: u32 = 0,
    has_focus: bool = false,

    // Modifier state from wl_keyboard.modifiers
    mods_depressed: u32 = 0,

    fn pushEvent(self: *WaylandState, ev: Event) void {
        const next = (self.key_head + 1) % 32;
        if (next == self.key_tail) return; // Full, drop oldest
        self.key_events[self.key_head] = ev;
        self.key_head = next;
    }

    fn popEvent(self: *WaylandState) ?Event {
        if (self.key_head == self.key_tail) return null;
        const ev = self.key_events[self.key_tail];
        self.key_tail = (self.key_tail + 1) % 32;
        return ev;
    }
};

pub const WaylandWindow = struct {
    display: *wl_display,
    registry: *wl_registry,
    surface: *wl_surface,
    xdg_surface_ptr: *xdg_surface,
    xdg_toplevel_ptr: *xdg_toplevel,
    width: u32,
    height: u32,
    is_open: bool,

    // SHM buffer for framebuffer blitting
    buffer: ?*wl_buffer = null,
    shm_fd: std.posix.fd_t = -1,
    shm_data: ?[*]align(4096) u8 = null,
    shm_size: usize = 0,
    buf_width: u32 = 0,
    buf_height: u32 = 0,

    state: WaylandState,

    pub fn init(width: u32, height: u32, title: []const u8) !WaylandWindow {
        // 1. Connect to the Wayland display
        const display: *wl_display = wl_display_connect(null) orelse
            return error.WaylandConnectFailed;
        errdefer wl_display_disconnect(display);

        // 2. Get registry
        const registry: *wl_registry = wl_display_get_registry(display) orelse
            return error.WaylandRegistryFailed;

        // Shared state for callbacks
        var state = WaylandState{};

        // 3. Listen for global objects
        if (wl_registry_add_listener(registry, &registry_listener_impl, &state) < 0)
            return error.WaylandListenerFailed;

        // Roundtrip to receive globals
        if (wl_display_roundtrip(display) < 0)
            return error.WaylandRoundtripFailed;

        // Verify we got the required globals
        const compositor = state.compositor orelse return error.WaylandNoCompositor;
        const xdg_wm = state.xdg_wm_base_ptr orelse return error.WaylandNoXdgWmBase;
        const shm = state.shm orelse return error.WaylandNoShm;
        _ = shm;

        // 4. Set up xdg_wm_base ping listener
        if (xdg_wm_base_add_listener(xdg_wm, &xdg_wm_base_listener_impl, &state) < 0)
            return error.WaylandListenerFailed;

        // 5. Set up seat/keyboard if available
        if (state.seat) |seat| {
            if (wl_seat_add_listener(seat, &seat_listener_impl, &state) < 0)
                return error.WaylandListenerFailed;
        }

        // Another roundtrip to get seat capabilities
        if (wl_display_roundtrip(display) < 0)
            return error.WaylandRoundtripFailed;

        // 6. Create surface
        const surface: *wl_surface = wl_compositor_create_surface(compositor) orelse
            return error.WaylandSurfaceCreateFailed;
        errdefer wl_surface_destroy(surface);

        // 7. Create xdg_surface
        const xdg_surf: *xdg_surface = xdg_wm_base_get_xdg_surface(xdg_wm, surface) orelse
            return error.WaylandXdgSurfaceFailed;
        errdefer xdg_surface_destroy(xdg_surf);

        if (xdg_surface_add_listener(xdg_surf, &xdg_surface_listener_impl, &state) < 0)
            return error.WaylandListenerFailed;

        // 8. Create xdg_toplevel
        const toplevel: *xdg_toplevel = xdg_surface_get_toplevel(xdg_surf) orelse
            return error.WaylandToplevelFailed;
        errdefer xdg_toplevel_destroy(toplevel);

        if (xdg_toplevel_add_listener(toplevel, &xdg_toplevel_listener_impl, &state) < 0)
            return error.WaylandListenerFailed;

        // 9. Set title — need a null-terminated copy
        var title_buf: [256]u8 = undefined;
        const title_len = @min(title.len, title_buf.len - 1);
        @memcpy(title_buf[0..title_len], title[0..title_len]);
        title_buf[title_len] = 0;
        xdg_toplevel_set_title(toplevel, @ptrCast(&title_buf));
        xdg_toplevel_set_app_id(toplevel, "teru");

        // 10. Initial commit (empty, triggers the compositor to send configure)
        wl_surface_commit(surface);

        // 11. Wait for the initial configure event
        while (!state.configured) {
            if (wl_display_dispatch(display) < 0)
                return error.WaylandDispatchFailed;
        }

        // Use compositor-requested size, or fallback to requested size
        const final_w = if (state.pending_width > 0) state.pending_width else width;
        const final_h = if (state.pending_height > 0) state.pending_height else height;

        var self = WaylandWindow{
            .display = display,
            .registry = registry,
            .surface = surface,
            .xdg_surface_ptr = xdg_surf,
            .xdg_toplevel_ptr = toplevel,
            .width = final_w,
            .height = final_h,
            .is_open = true,
            .state = state,
        };

        // 12. Create initial SHM buffer
        self.createShmBuffer(final_w, final_h) catch {
            // Non-fatal — putFramebuffer will just be a no-op until resize succeeds
        };

        return self;
    }

    pub fn deinit(self: *WaylandWindow) void {
        self.destroyShmBuffer();

        if (self.state.pointer) |ptr| {
            wl_pointer_destroy(ptr);
        }
        if (self.state.keyboard) |kb| {
            wl_keyboard_destroy(kb);
        }
        if (self.state.seat) |seat| {
            wl_seat_destroy(seat);
        }

        xdg_toplevel_destroy(self.xdg_toplevel_ptr);
        xdg_surface_destroy(self.xdg_surface_ptr);
        wl_surface_destroy(self.surface);

        if (self.state.xdg_wm_base_ptr) |wm| {
            xdg_wm_base_destroy(wm);
        }
        if (self.state.compositor) |comp| {
            wl_compositor_destroy(comp);
        }
        if (self.state.shm) |shm_| {
            wl_shm_destroy(shm_);
        }

        wl_registry_destroy(self.registry);
        wl_display_disconnect(self.display);
        self.is_open = false;
    }

    pub fn pollEvents(self: *WaylandWindow) ?Event {
        // Dispatch pending Wayland events (non-blocking)
        _ = wl_display_dispatch_pending(self.display);

        // Flush outgoing requests and prepare readable events
        if (wl_display_prepare_read(self.display) == 0) {
            // Check if there's data without blocking
            var fds = [1]std.posix.pollfd{.{
                .fd = wl_display_get_fd(self.display),
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            _ = wl_display_flush(self.display);
            const poll_result = std.posix.poll(&fds, 0) catch 0;
            if (poll_result > 0) {
                _ = wl_display_read_events(self.display);
                _ = wl_display_dispatch_pending(self.display);
            } else {
                wl_display_cancel_read(self.display);
            }
        }

        // Check for close request
        if (self.state.close_requested) {
            self.is_open = false;
            self.state.close_requested = false;
            return .close;
        }

        // Check for pending configure (resize)
        if (self.state.configured) {
            self.state.configured = false;
            const new_w = if (self.state.pending_width > 0) self.state.pending_width else self.width;
            const new_h = if (self.state.pending_height > 0) self.state.pending_height else self.height;
            if (new_w != self.width or new_h != self.height) {
                self.width = new_w;
                self.height = new_h;
                // Recreate SHM buffer for new size — best-effort: keep old buffer on failure
                self.destroyShmBuffer();
                self.createShmBuffer(new_w, new_h) catch {};
                return .{ .resize = .{ .width = new_w, .height = new_h } };
            }
        }

        // Return queued keyboard/focus events
        return self.state.popEvent();
    }

    pub fn putFramebuffer(self: *WaylandWindow, pixels: []const u32, fb_width: u32, fb_height: u32) void {
        if (self.shm_data == null or self.buffer == null) return;

        const blit_w = @min(fb_width, self.buf_width);
        const blit_h = @min(fb_height, self.buf_height);
        if (blit_w == 0 or blit_h == 0) return;

        const dst_stride = self.buf_width;

        // Copy pixels into SHM buffer, row by row
        var y: u32 = 0;
        while (y < blit_h) : (y += 1) {
            const src_offset = y * fb_width;
            const dst_offset = y * dst_stride;
            const src_row = pixels[src_offset..][0..blit_w];
            const dst: [*]u32 = @ptrCast(@alignCast(self.shm_data.?));
            @memcpy(dst[dst_offset..][0..blit_w], src_row);
        }

        // Attach, damage, commit
        wl_surface_attach(self.surface, self.buffer, 0, 0);
        wl_surface_damage_buffer(self.surface, 0, 0, @intCast(blit_w), @intCast(blit_h));
        wl_surface_commit(self.surface);
        _ = wl_display_flush(self.display);
    }

    pub fn hideCursor(self: *WaylandWindow) void {
        if (self.state.pointer) |ptr| {
            wl_pointer_set_cursor(ptr, self.state.pointer_serial, null, 0, 0);
        }
    }

    pub fn showCursor(self: *WaylandWindow) void {
        // Setting cursor to null hides it; to restore default we'd need
        // wl_cursor_theme which requires libwayland-cursor. For now,
        // set cursor to null (hidden) and it will reappear when pointer
        // re-enters the window. This is a reasonable tradeoff.
        // A full implementation would load wl_cursor_theme_load.
        _ = self;
    }

    pub fn setTitle(self: *WaylandWindow, title: []const u8) void {
        // xdg_toplevel_set_title requires a null-terminated string
        var buf: [257]u8 = undefined;
        const len = @min(title.len, buf.len - 1);
        @memcpy(buf[0..len], title[0..len]);
        buf[len] = 0;
        xdg_toplevel_set_title(self.xdg_toplevel_ptr, @ptrCast(&buf));
    }

    pub fn getSize(self: *const WaylandWindow) platform.Size {
        return .{ .width = self.width, .height = self.height };
    }

    // ── SHM buffer management ──────────────────────────────────────────

    fn createShmBuffer(self: *WaylandWindow, w: u32, h: u32) !void {
        const shm_ = self.state.shm orelse return error.WaylandNoShm;
        const stride: u32 = w * 4;
        const size: usize = @as(usize, stride) * @as(usize, h);

        // Create anonymous file via memfd_create
        const fd = memfdCreate("teru-shm");
        if (fd < 0) return error.MemfdCreateFailed;
        errdefer _ = std.posix.system.close(fd);

        // Set size
        if (std.c.ftruncate(fd, @intCast(size)) != 0) return error.FtruncateFailed;

        // mmap the buffer
        const mapped = std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return error.MmapFailed;

        // Create wl_shm_pool and wl_buffer
        const pool: *wl_shm_pool = wl_shm_create_pool(shm_, fd, @intCast(size)) orelse {
            std.posix.munmap(mapped);
            return error.ShmPoolCreateFailed;
        };

        const buf: *wl_buffer = wl_shm_pool_create_buffer(
            pool,
            0,
            @intCast(w),
            @intCast(h),
            @intCast(stride),
            WL_SHM_FORMAT_ARGB8888,
        ) orelse {
            wl_shm_pool_destroy(pool);
            std.posix.munmap(mapped);
            return error.BufferCreateFailed;
        };

        // Pool can be destroyed after buffer creation
        wl_shm_pool_destroy(pool);

        self.buffer = buf;
        self.shm_fd = fd;
        self.shm_data = @ptrCast(mapped.ptr);
        self.shm_size = size;
        self.buf_width = w;
        self.buf_height = h;

        // Zero-fill (transparent black)
        @memset(mapped, 0);
    }

    fn destroyShmBuffer(self: *WaylandWindow) void {
        if (self.buffer) |buf| {
            wl_buffer_destroy(buf);
            self.buffer = null;
        }
        if (self.shm_data) |data| {
            const slice: []align(4096) u8 = @as([*]align(4096) u8, @ptrCast(data))[0..self.shm_size];
            std.posix.munmap(slice);
            self.shm_data = null;
        }
        if (self.shm_fd >= 0) {
            _ = std.posix.system.close(self.shm_fd);
            self.shm_fd = -1;
        }
        self.shm_size = 0;
        self.buf_width = 0;
        self.buf_height = 0;
    }
};

// ── memfd_create via libc ───────────────────────────────────────────────

fn memfdCreate(name: [*:0]const u8) std.posix.fd_t {
    const fd = std.c.memfd_create(name, MFD_CLOEXEC);
    if (fd < 0) return -1;
    return fd;
}

// ── Wayland listener implementations ───────────────────────────────────

// Registry listener: bind to compositor, xdg_wm_base, shm, seat
const registry_listener_impl = wl_registry_listener{
    .global = &registryGlobal,
    .global_remove = &registryGlobalRemove,
};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*wl_registry,
    name: u32,
    iface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    const interface_str = iface orelse return;
    const reg = registry orelse return;

    if (cStrEql(interface_str, wl_compositor_interface.name.?)) {
        state.compositor = @ptrCast(wl_registry_bind(
            reg,
            name,
            &wl_compositor_interface,
            @min(version, 4),
        ));
    } else if (cStrEql(interface_str, xdg_wm_base_interface.name.?)) {
        state.xdg_wm_base_ptr = @ptrCast(wl_registry_bind(
            reg,
            name,
            &xdg_wm_base_interface,
            @min(version, 2),
        ));
    } else if (cStrEql(interface_str, wl_shm_interface.name.?)) {
        state.shm = @ptrCast(wl_registry_bind(
            reg,
            name,
            &wl_shm_interface,
            @min(version, 1),
        ));
    } else if (cStrEql(interface_str, wl_seat_interface.name.?)) {
        state.seat = @ptrCast(wl_registry_bind(
            reg,
            name,
            &wl_seat_interface,
            @min(version, 5),
        ));
    }
}

fn registryGlobalRemove(
    _: ?*anyopaque,
    _: ?*wl_registry,
    _: u32,
) callconv(.c) void {}

// xdg_wm_base listener: respond to pings
const xdg_wm_base_listener_impl = xdg_wm_base_listener{
    .ping = &xdgWmBasePing,
};

fn xdgWmBasePing(
    _: ?*anyopaque,
    wm_base_ptr: ?*xdg_wm_base,
    serial: u32,
) callconv(.c) void {
    if (wm_base_ptr) |wm| {
        xdg_wm_base_pong(wm, serial);
    }
}

// xdg_surface listener: ack configure
const xdg_surface_listener_impl = xdg_surface_listener{
    .configure = &xdgSurfaceConfigure,
};

fn xdgSurfaceConfigure(
    data: ?*anyopaque,
    xdg_surf: ?*xdg_surface,
    serial: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    if (xdg_surf) |xs| {
        xdg_surface_ack_configure(xs, serial);
    }
    state.configured = true;
}

// xdg_toplevel listener: configure (resize) + close
const xdg_toplevel_listener_impl = xdg_toplevel_listener{
    .configure = &xdgToplevelConfigure,
    .close = &xdgToplevelClose,
    .configure_bounds = &xdgToplevelConfigureBounds,
    .wm_capabilities = &xdgToplevelWmCapabilities,
};

fn xdgToplevelConfigure(
    data: ?*anyopaque,
    _: ?*xdg_toplevel,
    w: i32,
    h: i32,
    _: ?*wl_array,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    // Width/height of 0 means "client decides"
    if (w > 0) state.pending_width = @intCast(w);
    if (h > 0) state.pending_height = @intCast(h);
}

fn xdgToplevelClose(
    data: ?*anyopaque,
    _: ?*xdg_toplevel,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.close_requested = true;
}

fn xdgToplevelConfigureBounds(
    _: ?*anyopaque,
    _: ?*xdg_toplevel,
    _: i32,
    _: i32,
) callconv(.c) void {}

fn xdgToplevelWmCapabilities(
    _: ?*anyopaque,
    _: ?*xdg_toplevel,
    _: ?*wl_array,
) callconv(.c) void {}

// wl_seat listener: get keyboard when capability is announced
const seat_listener_impl = wl_seat_listener{
    .capabilities = &seatCapabilities,
    .name = &seatName,
};

fn seatCapabilities(
    data: ?*anyopaque,
    seat: ?*wl_seat,
    caps: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    const has_keyboard = (caps & WL_SEAT_CAPABILITY_KEYBOARD) != 0;

    if (has_keyboard and state.keyboard == null) {
        if (seat) |s| {
            state.keyboard = wl_seat_get_keyboard(s);
            if (state.keyboard) |kb| {
                _ = wl_keyboard_add_listener(kb, &keyboard_listener_impl, data);
            }
        }
    } else if (!has_keyboard and state.keyboard != null) {
        wl_keyboard_destroy(state.keyboard.?);
        state.keyboard = null;
    }

    const has_pointer = (caps & WL_SEAT_CAPABILITY_POINTER) != 0;

    if (has_pointer and state.pointer == null) {
        if (seat) |s| {
            state.pointer = wl_seat_get_pointer(s);
            if (state.pointer) |ptr| {
                _ = wl_pointer_add_listener(ptr, &pointer_listener_impl, data);
            }
        }
    } else if (!has_pointer and state.pointer != null) {
        wl_pointer_destroy(state.pointer.?);
        state.pointer = null;
    }
}

fn seatName(
    _: ?*anyopaque,
    _: ?*wl_seat,
    _: ?[*:0]const u8,
) callconv(.c) void {}

// wl_keyboard listener: key press/release + focus
const keyboard_listener_impl = wl_keyboard_listener{
    .keymap = &keyboardKeymap,
    .enter = &keyboardEnter,
    .leave = &keyboardLeave,
    .key = &keyboardKey,
    .modifiers = &keyboardModifiers,
    .repeat_info = &keyboardRepeatInfo,
};

fn keyboardKeymap(
    _: ?*anyopaque,
    _: ?*wl_keyboard,
    _: u32,
    fd: i32,
    _: u32,
) callconv(.c) void {
    // Close the keymap fd — we pass raw keycodes for now (xkbcommon later)
    if (fd >= 0) _ = std.posix.system.close(@intCast(fd));
}

fn keyboardEnter(
    data: ?*anyopaque,
    _: ?*wl_keyboard,
    _: u32,
    _: ?*wl_surface,
    _: ?*wl_array,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.has_focus = true;
    state.pushEvent(.focus_in);
}

fn keyboardLeave(
    data: ?*anyopaque,
    _: ?*wl_keyboard,
    _: u32,
    _: ?*wl_surface,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.has_focus = false;
    state.pushEvent(.focus_out);
}

fn keyboardKey(
    data: ?*anyopaque,
    _: ?*wl_keyboard,
    _: u32,
    _: u32,
    key: u32,
    key_state: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    // Wayland keycodes are evdev codes. Add 8 to match X11 keycode space
    // (X11 keycodes = evdev + 8). This keeps compatibility with the X11 backend.
    const keycode = key + 8;
    const mods = state.mods_depressed;

    if (key_state == WL_KEYBOARD_KEY_STATE_PRESSED) {
        state.pushEvent(.{ .key_press = .{ .keycode = keycode, .modifiers = mods } });
    } else if (key_state == WL_KEYBOARD_KEY_STATE_RELEASED) {
        state.pushEvent(.{ .key_release = .{ .keycode = keycode, .modifiers = mods } });
    }
}

fn keyboardModifiers(
    data: ?*anyopaque,
    _: ?*wl_keyboard,
    _: u32,
    mods_depressed: u32,
    _: u32,
    _: u32,
    _: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.mods_depressed = mods_depressed;
}

fn keyboardRepeatInfo(
    _: ?*anyopaque,
    _: ?*wl_keyboard,
    _: i32,
    _: i32,
) callconv(.c) void {}

// wl_pointer listener: mouse motion, button, scroll
const pointer_listener_impl = wl_pointer_listener{
    .enter = &pointerEnter,
    .leave = &pointerLeave,
    .motion = &pointerMotion,
    .button = &pointerButton,
    .axis = &pointerAxis,
    .frame = &pointerFrame,
    .axis_source = &pointerAxisSource,
    .axis_stop = &pointerAxisStop,
    .axis_discrete = &pointerAxisDiscrete,
};

fn pointerEnter(
    data: ?*anyopaque,
    _: ?*wl_pointer,
    serial: u32,
    _: ?*wl_surface,
    x: i32,
    y: i32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.pointer_serial = serial;
    // wl_fixed_t is 24.8 fixed-point; >> 8 converts to integer pixels
    state.pointer_x = @intCast(@max(0, x >> 8));
    state.pointer_y = @intCast(@max(0, y >> 8));
}

fn pointerLeave(
    _: ?*anyopaque,
    _: ?*wl_pointer,
    _: u32,
    _: ?*wl_surface,
) callconv(.c) void {}

fn pointerMotion(
    data: ?*anyopaque,
    _: ?*wl_pointer,
    _: u32,
    x: i32,
    y: i32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.pointer_x = @intCast(@max(0, x >> 8));
    state.pointer_y = @intCast(@max(0, y >> 8));
    state.pushEvent(.{ .mouse_motion = .{ .x = state.pointer_x, .y = state.pointer_y } });
}

fn pointerButton(
    data: ?*anyopaque,
    _: ?*wl_pointer,
    serial: u32,
    _: u32,
    button_code: u32,
    button_state: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    state.pointer_serial = serial;
    const btn: ?MouseButton = switch (button_code) {
        0x110 => .left,
        0x111 => .right,
        0x112 => .middle,
        else => null,
    };
    if (btn) |b| {
        if (button_state == 1) {
            state.pushEvent(.{ .mouse_press = .{ .x = state.pointer_x, .y = state.pointer_y, .button = b, .modifiers = state.mods_depressed } });
        } else {
            state.pushEvent(.{ .mouse_release = .{ .x = state.pointer_x, .y = state.pointer_y, .button = b, .modifiers = state.mods_depressed } });
        }
    }
}

fn pointerAxis(
    data: ?*anyopaque,
    _: ?*wl_pointer,
    _: u32,
    axis: u32,
    value: i32,
) callconv(.c) void {
    if (axis != 0) return; // only handle vertical scroll
    const state: *WaylandState = @ptrCast(@alignCast(data orelse return));
    if (value > 0) {
        state.pushEvent(.{ .mouse_press = .{ .x = state.pointer_x, .y = state.pointer_y, .button = .scroll_down, .modifiers = state.mods_depressed } });
    } else if (value < 0) {
        state.pushEvent(.{ .mouse_press = .{ .x = state.pointer_x, .y = state.pointer_y, .button = .scroll_up, .modifiers = state.mods_depressed } });
    }
}

fn pointerFrame(
    _: ?*anyopaque,
    _: ?*wl_pointer,
) callconv(.c) void {}

fn pointerAxisSource(
    _: ?*anyopaque,
    _: ?*wl_pointer,
    _: u32,
) callconv(.c) void {}

fn pointerAxisStop(
    _: ?*anyopaque,
    _: ?*wl_pointer,
    _: u32,
    _: u32,
) callconv(.c) void {}

fn pointerAxisDiscrete(
    _: ?*anyopaque,
    _: ?*wl_pointer,
    _: u32,
    _: i32,
) callconv(.c) void {}

// ── Utility ────────────────────────────────────────────────────────────

fn cStrEql(a: [*:0]const u8, b: [*:0]const u8) bool {
    var i: usize = 0;
    while (a[i] != 0 and b[i] != 0) : (i += 1) {
        if (a[i] != b[i]) return false;
    }
    return a[i] == b[i];
}
