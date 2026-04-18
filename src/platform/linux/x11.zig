//! X11 backend using pure XCB. No Xlib, no EGL, no OpenGL.
//!
//! Creates a window, sets EWMH properties, handles events,
//! blits CPU framebuffer via xcb_put_image. Single dependency: libxcb.

const std = @import("std");
const platform = @import("platform.zig");

pub const Event = platform.Event;
pub const KeyEvent = platform.KeyEvent;
pub const MouseButton = platform.MouseButton;
pub const MouseEvent = platform.MouseEvent;

// ── XCB type declarations (extern linkage against libxcb) ─────────────

const xcb_connection_t = opaque {};
const xcb_window_t = u32;
const xcb_atom_t = u32;
const xcb_gcontext_t = u32;
const xcb_colormap_t = u32;
const xcb_visualid_t = u32;
const xcb_keycode_t = u8;
const xcb_void_cookie_t = extern struct { sequence: c_uint };
const xcb_intern_atom_cookie_t = extern struct { sequence: c_uint };

const xcb_screen_t = extern struct {
    root: xcb_window_t,
    default_colormap: xcb_colormap_t,
    white_pixel: u32,
    black_pixel: u32,
    current_input_masks: u32,
    width_in_pixels: u16,
    height_in_pixels: u16,
    width_in_millimeters: u16,
    height_in_millimeters: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual: xcb_visualid_t,
    backing_stores: u8,
    save_unders: u8,
    root_depth: u8,
    allowed_depths_len: u8,
};

const xcb_setup_t = opaque {};

const xcb_screen_iterator_t = extern struct {
    data: ?*xcb_screen_t,
    rem: c_int,
    index: c_int,
};

const xcb_generic_event_t = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    pad: [7]u32,
    full_sequence: u32,
};

const xcb_configure_notify_event_t = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    event: xcb_window_t,
    window: xcb_window_t,
    above_sibling: xcb_window_t,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    override_redirect: u8,
    pad1: u8,
};

const xcb_key_press_event_t = extern struct {
    response_type: u8,
    detail: xcb_keycode_t,
    sequence: u16,
    time: u32,
    root: xcb_window_t,
    event: xcb_window_t,
    child: xcb_window_t,
    root_x: i16,
    root_y: i16,
    event_x: i16,
    event_y: i16,
    state: u16,
    same_screen: u8,
    pad0: u8,
};

const xcb_key_release_event_t = xcb_key_press_event_t;

// XCB button press/release and motion events share the same layout as key events
const xcb_button_press_event_t = xcb_key_press_event_t;
const xcb_button_release_event_t = xcb_key_press_event_t;
const xcb_motion_notify_event_t = xcb_key_press_event_t;

const xcb_client_message_event_t = extern struct {
    response_type: u8,
    format: u8,
    sequence: u16,
    window: xcb_window_t,
    type_: xcb_atom_t,
    data: extern union {
        data8: [20]u8,
        data16: [10]u16,
        data32: [5]u32,
    },
};

const xcb_intern_atom_reply_t = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    atom: xcb_atom_t,
};

// ── XCB constants ─────────────────────────────────────────────────────

const XCB_COPY_FROM_PARENT: u8 = 0;
const XCB_WINDOW_CLASS_INPUT_OUTPUT: u16 = 1;

const XCB_CW_BACK_PIXEL: u32 = 2;
const XCB_CW_EVENT_MASK: u32 = 2048;

const XCB_EVENT_MASK_EXPOSURE: u32 = 0x8000;
const XCB_EVENT_MASK_STRUCTURE_NOTIFY: u32 = 0x20000;
const XCB_EVENT_MASK_KEY_PRESS: u32 = 1;
const XCB_EVENT_MASK_KEY_RELEASE: u32 = 2;
const XCB_EVENT_MASK_FOCUS_CHANGE: u32 = 0x200000;
const XCB_EVENT_MASK_BUTTON_PRESS: u32 = 0x4;
const XCB_EVENT_MASK_BUTTON_RELEASE: u32 = 0x8;
const XCB_EVENT_MASK_BUTTON_MOTION: u32 = 0x2000; // motion while any button held

const XCB_PROP_MODE_REPLACE: u8 = 0;

const XCB_EXPOSE: u8 = 12;
const XCB_CONFIGURE_NOTIFY: u8 = 22;
const XCB_KEY_PRESS: u8 = 2;
const XCB_KEY_RELEASE: u8 = 3;
const XCB_CLIENT_MESSAGE: u8 = 33;
const XCB_BUTTON_PRESS: u8 = 4;
const XCB_BUTTON_RELEASE: u8 = 5;
const XCB_MOTION_NOTIFY: u8 = 6;
const XCB_FOCUS_IN: u8 = 9;
const XCB_FOCUS_OUT: u8 = 10;

const XCB_ATOM_STRING: xcb_atom_t = 31;
const XCB_ATOM_WM_NAME: xcb_atom_t = 39;
const XCB_ATOM_WM_CLASS: xcb_atom_t = 67;
const XCB_ATOM_ATOM: xcb_atom_t = 4;
const XCB_ATOM_NONE: xcb_atom_t = 0;

const XCB_IMAGE_FORMAT_Z_PIXMAP: u8 = 2;

// ── XCB-SHM types ───────────────────────────────────────────────────
const xcb_shm_seg_t = u32;

// ── XCB extern functions ──────────────────────────────────────────────

extern "xcb" fn xcb_connect(display: ?[*:0]const u8, screen: ?*c_int) callconv(.c) ?*xcb_connection_t;
extern "xcb" fn xcb_disconnect(conn: *xcb_connection_t) callconv(.c) void;
extern "xcb" fn xcb_connection_has_error(conn: *xcb_connection_t) callconv(.c) c_int;
extern "xcb" fn xcb_get_setup(conn: *xcb_connection_t) callconv(.c) *const xcb_setup_t;
extern "xcb" fn xcb_setup_roots_iterator(setup: *const xcb_setup_t) callconv(.c) xcb_screen_iterator_t;
extern "xcb" fn xcb_screen_next(iter: *xcb_screen_iterator_t) callconv(.c) void;
extern "xcb" fn xcb_generate_id(conn: *xcb_connection_t) callconv(.c) u32;
extern "xcb" fn xcb_create_window(conn: *xcb_connection_t, depth: u8, wid: xcb_window_t, parent: xcb_window_t, x: i16, y: i16, width: u16, height: u16, border_width: u16, class: u16, visual: xcb_visualid_t, value_mask: u32, value_list: ?*const anyopaque) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_destroy_window(conn: *xcb_connection_t, window: xcb_window_t) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_map_window(conn: *xcb_connection_t, window: xcb_window_t) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_create_gc(conn: *xcb_connection_t, cid: xcb_gcontext_t, drawable: xcb_window_t, value_mask: u32, value_list: ?*const anyopaque) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_free_gc(conn: *xcb_connection_t, gc: xcb_gcontext_t) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_change_property(conn: *xcb_connection_t, mode: u8, window: xcb_window_t, property: xcb_atom_t, type_: xcb_atom_t, format: u8, data_len: u32, data: ?*const anyopaque) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_poll_for_event(conn: *xcb_connection_t) callconv(.c) ?*xcb_generic_event_t;
extern "xcb" fn xcb_flush(conn: *xcb_connection_t) callconv(.c) c_int;
extern "xcb" fn xcb_put_image(conn: *xcb_connection_t, format: u8, drawable: xcb_window_t, gc: xcb_gcontext_t, width: u16, height: u16, dst_x: i16, dst_y: i16, left_pad: u8, depth: u8, data_len: u32, data: [*]const u8) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_intern_atom(conn: *xcb_connection_t, only_if_exists: u8, name_len: u16, name: [*]const u8) callconv(.c) xcb_intern_atom_cookie_t;
extern "xcb" fn xcb_intern_atom_reply(conn: *xcb_connection_t, cookie: xcb_intern_atom_cookie_t, err: ?*?*anyopaque) callconv(.c) ?*xcb_intern_atom_reply_t;
extern "xcb" fn xcb_create_pixmap(conn: *xcb_connection_t, depth: u8, pid: u32, drawable: xcb_window_t, width: u16, height: u16) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_free_pixmap(conn: *xcb_connection_t, pixmap: u32) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_create_cursor(conn: *xcb_connection_t, cid: u32, source: u32, mask: u32, fore_red: u16, fore_green: u16, fore_blue: u16, back_red: u16, back_green: u16, back_blue: u16, x: u16, y: u16) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_free_cursor(conn: *xcb_connection_t, cursor: u32) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_open_font(conn: *xcb_connection_t, fid: u32, name_len: u16, name: [*]const u8) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_close_font(conn: *xcb_connection_t, fid: u32) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_create_glyph_cursor(conn: *xcb_connection_t, cid: u32, source_font: u32, mask_font: u32, source_char: u16, mask_char: u16, fore_red: u16, fore_green: u16, fore_blue: u16, back_red: u16, back_green: u16, back_blue: u16) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_change_window_attributes(conn: *xcb_connection_t, window: xcb_window_t, value_mask: u32, value_list: ?*const anyopaque) callconv(.c) xcb_void_cookie_t;
extern "xcb" fn xcb_configure_window(conn: *xcb_connection_t, window: xcb_window_t, value_mask: u16, value_list: *const anyopaque) callconv(.c) xcb_void_cookie_t;

const XCB_CW_CURSOR: u32 = 0x4000;
const XCB_EVENT_MASK_POINTER_MOTION: u32 = 0x40; // motion without button held

// ── XCB-SHM extern functions ──────────────────────────────────────────
extern "xcb-shm" fn xcb_shm_attach(conn: *xcb_connection_t, shmseg: xcb_shm_seg_t, shmid: u32, read_only: u8) callconv(.c) xcb_void_cookie_t;
extern "xcb-shm" fn xcb_shm_detach(conn: *xcb_connection_t, shmseg: xcb_shm_seg_t) callconv(.c) xcb_void_cookie_t;
extern "xcb-shm" fn xcb_shm_put_image(conn: *xcb_connection_t, drawable: xcb_window_t, gc: xcb_gcontext_t, total_width: u16, total_height: u16, src_x: u16, src_y: u16, src_width: u16, src_height: u16, dst_x: i16, dst_y: i16, depth: u8, format: u8, send_event: u8, shmseg: xcb_shm_seg_t, offset: u32) callconv(.c) xcb_void_cookie_t;

// ── X11Window ─────────────────────────────────────────────────────────

pub const X11Window = struct {
    connection: *xcb_connection_t,
    window: xcb_window_t,
    screen: *xcb_screen_t,
    gc: xcb_gcontext_t,
    width: u32,
    height: u32,
    is_open: bool,
    wm_delete_window: xcb_atom_t,
    depth: u8,

    // Cursors for mouse_hide_when_typing
    invisible_cursor: u32 = 0,
    default_cursor: u32 = 0,

    // SHM state (zero-copy framebuffer)
    shm_seg: xcb_shm_seg_t = 0,
    shm_ptr: ?[*]u32 = null,
    shm_size: usize = 0,
    shm_width: u32 = 0,
    shm_height: u32 = 0,
    use_shm: bool = false,

    pub fn init(width: u32, height: u32, title: []const u8, wm_class: ?[]const u8) !X11Window {
        // Connect to X server (pure XCB, no Xlib)
        var screen_num: c_int = 0;
        const connection = xcb_connect(null, &screen_num) orelse return error.XcbConnectFailed;
        if (xcb_connection_has_error(connection) != 0) {
            xcb_disconnect(connection);
            return error.XcbConnectionError;
        }

        // Get default screen
        const setup = xcb_get_setup(connection);
        var iter = xcb_setup_roots_iterator(setup);
        var i: c_int = 0;
        while (i < screen_num) : (i += 1) {
            xcb_screen_next(&iter);
        }
        const screen: *xcb_screen_t = iter.data orelse {
            xcb_disconnect(connection);
            return error.XcbNoScreen;
        };

        // Create window
        const win_id = xcb_generate_id(connection);
        const event_mask: u32 = XCB_EVENT_MASK_EXPOSURE |
            XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            XCB_EVENT_MASK_KEY_PRESS |
            XCB_EVENT_MASK_KEY_RELEASE |
            XCB_EVENT_MASK_FOCUS_CHANGE |
            XCB_EVENT_MASK_BUTTON_PRESS |
            XCB_EVENT_MASK_BUTTON_RELEASE |
            XCB_EVENT_MASK_BUTTON_MOTION |
            XCB_EVENT_MASK_POINTER_MOTION;
        const value_mask: u32 = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK;
        const value_list = [2]u32{ screen.black_pixel, event_mask };

        _ = xcb_create_window(connection, XCB_COPY_FROM_PARENT, win_id, screen.root, 0, 0, @intCast(width), @intCast(height), 0, XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, value_mask, &value_list);

        // Graphics context
        const gc = xcb_generate_id(connection);
        _ = xcb_create_gc(connection, gc, win_id, 0, null);

        // WM_CLASS (instance\0class\0) — use --class override if provided
        if (wm_class) |cls| {
            // Build "cls\0cls\0" dynamically
            var class_buf: [512]u8 = undefined;
            if (cls.len * 2 + 2 <= class_buf.len) {
                @memcpy(class_buf[0..cls.len], cls);
                class_buf[cls.len] = 0;
                @memcpy(class_buf[cls.len + 1 ..][0..cls.len], cls);
                class_buf[cls.len * 2 + 1] = 0;
                const total_len: u32 = @intCast(cls.len * 2 + 2);
                _ = xcb_change_property(connection, XCB_PROP_MODE_REPLACE, win_id, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING, 8, total_len, &class_buf);
            }
        } else {
            const default_class = "teru\x00teru\x00";
            _ = xcb_change_property(connection, XCB_PROP_MODE_REPLACE, win_id, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING, 8, default_class.len, default_class.ptr);
        }

        // _NET_WM_NAME (EWMH) — xcb length arg is u32. Title comes
        // from a PTY OSC 0/2 sequence; the VtParser caps it so the
        // clamp here is belt-and-braces.
        const title_len: u32 = @intCast(@min(title.len, std.math.maxInt(u32)));
        const utf8_atom = internAtom(connection, "UTF8_STRING", false);
        const net_wm_name = internAtom(connection, "_NET_WM_NAME", false);
        _ = xcb_change_property(connection, XCB_PROP_MODE_REPLACE, win_id, net_wm_name, utf8_atom, 8, title_len, title.ptr);
        _ = xcb_change_property(connection, XCB_PROP_MODE_REPLACE, win_id, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8, title_len, title.ptr);

        // WM_PROTOCOLS + WM_DELETE_WINDOW
        const wm_protocols = internAtom(connection, "WM_PROTOCOLS", false);
        const wm_delete = internAtom(connection, "WM_DELETE_WINDOW", false);
        _ = xcb_change_property(connection, XCB_PROP_MODE_REPLACE, win_id, wm_protocols, XCB_ATOM_ATOM, 32, 1, @as(*const u32, &wm_delete));

        // Map window
        _ = xcb_map_window(connection, win_id);
        _ = xcb_flush(connection);

        var self = X11Window{
            .connection = connection,
            .window = win_id,
            .screen = screen,
            .gc = gc,
            .width = width,
            .height = height,
            .is_open = true,
            .wm_delete_window = wm_delete,
            .depth = screen.root_depth,
        };

        // Try to set up SHM for zero-copy framebuffer
        self.setupShm(width, height);

        // Create cursors for mouse_hide_when_typing
        // Invisible cursor: 1x1 blank pixmap
        const pixmap = xcb_generate_id(connection);
        _ = xcb_create_pixmap(connection, 1, pixmap, win_id, 1, 1);
        self.invisible_cursor = xcb_generate_id(connection);
        _ = xcb_create_cursor(connection, self.invisible_cursor, pixmap, pixmap, 0, 0, 0, 0, 0, 0, 0, 0);
        _ = xcb_free_pixmap(connection, pixmap);

        // Default cursor: left_ptr from X11 cursor font (glyph 68)
        const cursor_font = xcb_generate_id(connection);
        _ = xcb_open_font(connection, cursor_font, 6, "cursor");
        self.default_cursor = xcb_generate_id(connection);
        // XC_left_ptr = 68, mask = 69 (next glyph)
        _ = xcb_create_glyph_cursor(connection, self.default_cursor, cursor_font, cursor_font, 68, 69, 0, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF);
        _ = xcb_close_font(connection, cursor_font);

        return self;
    }

    pub fn hideCursor(self: *X11Window) void {
        if (self.invisible_cursor == 0) return;
        const cursor_val = [1]u32{self.invisible_cursor};
        _ = xcb_change_window_attributes(self.connection, self.window, XCB_CW_CURSOR, &cursor_val);
        _ = xcb_flush(self.connection);
    }

    pub fn showCursor(self: *X11Window) void {
        const cursor_val = [1]u32{self.default_cursor};
        _ = xcb_change_window_attributes(self.connection, self.window, XCB_CW_CURSOR, &cursor_val);
        _ = xcb_flush(self.connection);
    }

    pub fn deinit(self: *X11Window) void {
        if (self.invisible_cursor != 0) _ = xcb_free_cursor(self.connection, self.invisible_cursor);
        if (self.default_cursor != 0) _ = xcb_free_cursor(self.connection, self.default_cursor);
        self.teardownShm();
        _ = xcb_free_gc(self.connection, self.gc);
        _ = xcb_destroy_window(self.connection, self.window);
        _ = xcb_flush(self.connection);
        xcb_disconnect(self.connection);
        self.is_open = false;
    }

    pub fn pollEvents(self: *X11Window) ?Event {
        const raw_event = xcb_poll_for_event(self.connection) orelse return null;
        defer std.c.free(raw_event);
        const XCB_EVENT_RESPONSE_TYPE_MASK: u8 = 0x7f; // strips sent_event flag
        const response_type: u8 = raw_event.*.response_type & XCB_EVENT_RESPONSE_TYPE_MASK;

        return switch (response_type) {
            XCB_EXPOSE => .expose,
            XCB_CONFIGURE_NOTIFY => {
                const cfg: *const xcb_configure_notify_event_t = @ptrCast(@alignCast(raw_event));
                const new_w: u32 = @intCast(cfg.width);
                const new_h: u32 = @intCast(cfg.height);
                if (new_w != self.width or new_h != self.height) {
                    self.width = new_w;
                    self.height = new_h;
                    return .{ .resize = .{ .width = new_w, .height = new_h } };
                }
                return .none;
            },
            XCB_KEY_PRESS => {
                const key: *const xcb_key_press_event_t = @ptrCast(@alignCast(raw_event));
                return .{ .key_press = .{ .keycode = @intCast(key.detail), .modifiers = @intCast(key.state) } };
            },
            XCB_KEY_RELEASE => {
                const key: *const xcb_key_release_event_t = @ptrCast(@alignCast(raw_event));
                return .{ .key_release = .{ .keycode = @intCast(key.detail), .modifiers = @intCast(key.state) } };
            },
            XCB_BUTTON_PRESS => {
                const btn: *const xcb_button_press_event_t = @ptrCast(@alignCast(raw_event));
                const mouse_btn = xcbButtonToMouse(btn.detail);
                if (mouse_btn) |mb| {
                    return .{ .mouse_press = .{
                        .x = @intCast(@max(0, btn.event_x)),
                        .y = @intCast(@max(0, btn.event_y)),
                        .button = mb,
                        .modifiers = @intCast(btn.state),
                    } };
                }
                return .none;
            },
            XCB_BUTTON_RELEASE => {
                const btn: *const xcb_button_release_event_t = @ptrCast(@alignCast(raw_event));
                const mouse_btn = xcbButtonToMouse(btn.detail);
                if (mouse_btn) |mb| {
                    return .{ .mouse_release = .{
                        .x = @intCast(@max(0, btn.event_x)),
                        .y = @intCast(@max(0, btn.event_y)),
                        .button = mb,
                        .modifiers = @intCast(btn.state),
                    } };
                }
                return .none;
            },
            XCB_MOTION_NOTIFY => {
                const motion: *const xcb_motion_notify_event_t = @ptrCast(@alignCast(raw_event));
                return .{ .mouse_motion = .{
                    .x = @intCast(@max(0, motion.event_x)),
                    .y = @intCast(@max(0, motion.event_y)),
                    .modifiers = @intCast(motion.state),
                } };
            },
            XCB_CLIENT_MESSAGE => {
                const msg: *const xcb_client_message_event_t = @ptrCast(@alignCast(raw_event));
                if (msg.data.data32[0] == self.wm_delete_window) {
                    self.is_open = false;
                    return .close;
                }
                return .none;
            },
            XCB_FOCUS_IN => .focus_in,
            XCB_FOCUS_OUT => .focus_out,
            else => .none,
        };
    }

    pub fn putFramebuffer(self: *X11Window, pixels: []const u32, fb_width: u32, fb_height: u32) void {
        const blit_w = @min(fb_width, self.width);
        const blit_h = @min(fb_height, self.height);
        if (blit_w == 0 or blit_h == 0) return;

        if (self.use_shm) {
            // Reallocate SHM if size changed
            if (fb_width != self.shm_width or fb_height != self.shm_height) {
                self.teardownShm();
                self.setupShm(fb_width, fb_height);
            }

            if (self.use_shm) {
                // Copy pixels into SHM buffer then blit (zero-copy X server side)
                const dst = self.shm_ptr.?;
                const copy_len = @as(usize, fb_width) * fb_height;
                if (copy_len <= self.shm_size / 4) {
                    @memcpy(dst[0..copy_len], pixels[0..copy_len]);
                }

                _ = xcb_shm_put_image(
                    self.connection,
                    self.window,
                    self.gc,
                    @intCast(fb_width),
                    @intCast(fb_height),
                    0,
                    0,
                    @intCast(blit_w),
                    @intCast(blit_h),
                    0,
                    0,
                    self.depth,
                    XCB_IMAGE_FORMAT_Z_PIXMAP,
                    0, // send_event
                    self.shm_seg,
                    0, // offset
                );
                _ = xcb_flush(self.connection);
                return;
            }
        }

        // Fallback: send pixels over the socket (slow)
        const data: [*]const u8 = @ptrCast(pixels.ptr);
        const row_bytes = fb_width * 4;
        _ = xcb_put_image(self.connection, XCB_IMAGE_FORMAT_Z_PIXMAP, self.window, self.gc, @intCast(blit_w), @intCast(blit_h), 0, 0, 0, self.depth, blit_h * row_bytes, data);
        _ = xcb_flush(self.connection);
    }

    // ── SHM helpers ───────────────────────────────────────────────────

    const IPC_CREAT = 0o1000;
    const IPC_RMID = 0;

    // System V SHM (not in std.c)
    const shmid_ds = opaque {};
    extern "c" fn shmget(key: c_int, size: usize, shmflg: c_int) callconv(.c) c_int;
    extern "c" fn shmat(shmid: c_int, shmaddr: ?*const anyopaque, shmflg: c_int) callconv(.c) ?*anyopaque;
    extern "c" fn shmdt(shmaddr: *const anyopaque) callconv(.c) c_int;
    extern "c" fn shmctl(shmid: c_int, cmd: c_int, buf: ?*shmid_ds) callconv(.c) c_int;

    fn setupShm(self: *X11Window, width: u32, height: u32) void {
        const size = @as(usize, width) * height * 4;
        if (size == 0) return;

        // Create System V shared memory segment
        const shmid_val = shmget(0, size, IPC_CREAT | 0o600);
        if (shmid_val < 0) return;

        // Attach to our address space
        const ptr = shmat(shmid_val, null, 0);
        const SHM_FAILED: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
        if (ptr == null or ptr == SHM_FAILED) {
            _ = shmctl(shmid_val, IPC_RMID, null);
            return;
        }

        // Mark for deletion when all processes detach
        _ = shmctl(shmid_val, IPC_RMID, null);

        // Attach to X server
        const seg = xcb_generate_id(self.connection);
        _ = xcb_shm_attach(self.connection, seg, @bitCast(shmid_val), 0);
        _ = xcb_flush(self.connection);

        self.shm_seg = seg;
        self.shm_ptr = @ptrCast(@alignCast(ptr));
        self.shm_size = size;
        self.shm_width = width;
        self.shm_height = height;
        self.use_shm = true;
    }

    fn teardownShm(self: *X11Window) void {
        if (!self.use_shm) return;
        _ = xcb_shm_detach(self.connection, self.shm_seg);
        _ = xcb_flush(self.connection);
        if (self.shm_ptr) |p| {
            _ = shmdt(@ptrCast(p));
        }
        self.shm_ptr = null;
        self.shm_size = 0;
        self.shm_width = 0;
        self.shm_height = 0;
        self.shm_seg = 0;
        self.use_shm = false;
    }

    pub fn setOpacity(self: *X11Window, opacity: f32) void {
        if (opacity >= 1.0) return; // fully opaque, no property needed
        const clamped = @max(0.0, @min(1.0, opacity));
        const max_opacity: f64 = 4294967295.0; // 0xFFFFFFFF
        const value: u32 = @intFromFloat(clamped * max_opacity);
        const atom = internAtom(self.connection, "_NET_WM_WINDOW_OPACITY", false);
        const XCB_ATOM_CARDINAL: xcb_atom_t = 6;
        _ = xcb_change_property(self.connection, XCB_PROP_MODE_REPLACE, self.window, atom, XCB_ATOM_CARDINAL, 32, 1, @as(*const u32, &value));
        _ = xcb_flush(self.connection);
    }

    pub fn setTitle(self: *X11Window, title: []const u8) void {
        const net_wm_name = internAtom(self.connection, "_NET_WM_NAME", false);
        const utf8_atom = internAtom(self.connection, "UTF8_STRING", false);
        const title_len: u32 = @intCast(@min(title.len, std.math.maxInt(u32)));
        _ = xcb_change_property(self.connection, XCB_PROP_MODE_REPLACE, self.window, net_wm_name, utf8_atom, 8, title_len, title.ptr);
        _ = xcb_change_property(self.connection, XCB_PROP_MODE_REPLACE, self.window, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8, title_len, title.ptr);
        _ = xcb_flush(self.connection);
    }

    pub fn setSize(self: *X11Window, width: u32, height: u32) void {
        const values = [2]u32{ width, height };
        // XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT = 0x04 | 0x08
        _ = xcb_configure_window(self.connection, self.window, 0x04 | 0x08, &values);
        _ = xcb_flush(self.connection);
        self.width = width;
        self.height = height;
    }

    pub fn getSize(self: *const X11Window) platform.Size {
        return .{ .width = self.width, .height = self.height };
    }

    /// Get XCB connection and root window for keyboard layout query.
    pub fn getX11Info(self: *const X11Window) platform.X11Info {
        return .{ .conn = @ptrCast(self.connection), .root = self.screen.root };
    }

    /// X display connection fd for poll() integration. See
    /// WaylandWindow.displayFd — same purpose, drops idle wake rate
    /// from the fixed-timer path to genuinely event-driven.
    pub fn displayFd(self: *const X11Window) c_int {
        return xcb_get_file_descriptor(self.connection);
    }
};

extern "xcb" fn xcb_get_file_descriptor(conn: *xcb_connection_t) callconv(.c) c_int;

/// Map XCB button detail (1-5) to MouseButton.
fn xcbButtonToMouse(detail: u8) ?MouseButton {
    return switch (detail) {
        1 => .left,
        2 => .middle,
        3 => .right,
        4 => .scroll_up,
        5 => .scroll_down,
        else => null,
    };
}

fn internAtom(conn: *xcb_connection_t, name: [*:0]const u8, only_if_exists: bool) xcb_atom_t {
    const name_len: u16 = @intCast(std.mem.len(name));
    const cookie = xcb_intern_atom(conn, @intFromBool(only_if_exists), name_len, name);
    const reply = xcb_intern_atom_reply(conn, cookie, null) orelse return XCB_ATOM_NONE;
    defer std.c.free(reply);
    return reply.*.atom;
}
