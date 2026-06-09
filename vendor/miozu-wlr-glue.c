/**
 * miozu-wlr-glue.c — Thin C accessors for wlroots struct fields (teruwm).
 *
 * wlroots types are opaque in Zig. Rather than replicating exact C struct
 * layouts (fragile, version-dependent), we expose the specific fields teruwm
 * needs through accessor functions. The C compiler verifies correctness.
 */

#include <wlr/backend.h>
#include <wlr/backend/libinput.h>
#include <libinput.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/allocator.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_xcursor_manager.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_idle_inhibit_v1.h>
#include <wlr/types/wlr_output_power_management_v1.h>
#include <wlr/types/wlr_virtual_keyboard_v1.h>
#include <wlr/types/wlr_virtual_pointer_v1.h>
#include <wlr/types/wlr_output_management_v1.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_foreign_toplevel_management_v1.h>
/* wlr_cursor_shape_v1.h #includes "cursor-shape-v1-protocol.h" which normally
 * comes from wayland-protocols + wayland-scanner. To avoid adding a build-time
 * dependency we ship a vendored minimal shim (vendor/cursor-shape-v1-protocol.h)
 * that declares only the wp_cursor_shape_device_v1_shape enum wlroots actually
 * reads. vendor/ is already on the -I path for build.zig. */
#include <wlr/types/wlr_cursor_shape_v1.h>
#include <wayland-server-core.h>

/* ── Backend signals ─────────────────────────────────────────── */

struct wl_signal *miozu_backend_new_output(struct wlr_backend *b) {
    return &b->events.new_output;
}

struct wl_signal *miozu_backend_new_input(struct wlr_backend *b) {
    return &b->events.new_input;
}

/* ── Output signals & fields ─────────────────────────────────── */

struct wl_signal *miozu_output_frame(struct wlr_output *o) {
    return &o->events.frame;
}

struct wl_signal *miozu_output_request_state(struct wlr_output *o) {
    return &o->events.request_state;
}

struct wl_signal *miozu_output_destroy(struct wlr_output *o) {
    return &o->events.destroy;
}

int miozu_output_width(struct wlr_output *o) { return o->width; }
int miozu_output_height(struct wlr_output *o) { return o->height; }
const char *miozu_output_name(struct wlr_output *o) { return o->name; }

/* ── XDG shell signals ───────────────────────────────────────── */

struct wl_signal *miozu_xdg_shell_new_toplevel(struct wlr_xdg_shell *s) {
    return &s->events.new_toplevel;
}

/* ── XDG toplevel signals & fields ───────────────────────────── */

struct wl_signal *miozu_xdg_toplevel_request_move(struct wlr_xdg_toplevel *t) {
    return &t->events.request_move;
}

struct wl_signal *miozu_xdg_toplevel_request_resize(struct wlr_xdg_toplevel *t) {
    return &t->events.request_resize;
}

struct wl_signal *miozu_xdg_toplevel_request_maximize(struct wlr_xdg_toplevel *t) {
    return &t->events.request_maximize;
}

struct wl_signal *miozu_xdg_toplevel_request_fullscreen(struct wlr_xdg_toplevel *t) {
    return &t->events.request_fullscreen;
}

struct wl_signal *miozu_xdg_toplevel_request_show_window_menu(struct wlr_xdg_toplevel *t) {
    return &t->events.request_show_window_menu;
}

struct wl_signal *miozu_xdg_toplevel_destroy(struct wlr_xdg_toplevel *t) {
    return &t->events.destroy;
}

/* ── XDG surface new_popup signal ───────────────────────────────── */

struct wl_signal *miozu_xdg_surface_new_popup(struct wlr_xdg_surface *s) {
    return &s->events.new_popup;
}

/* ── XDG popup fields ───────────────────────────────────────────── */

struct wlr_xdg_surface *miozu_xdg_popup_base(struct wlr_xdg_popup *p) {
    return p->base;
}

/* Fires when an xdg_popup is destroyed. Lets us free the per-popup tracking
 * struct + unhook the recursive new_popup listener that catches submenus. */
struct wl_signal *miozu_xdg_popup_destroy(struct wlr_xdg_popup *p) {
    return &p->events.destroy;
}

struct wlr_xdg_surface *miozu_xdg_toplevel_base(struct wlr_xdg_toplevel *t) {
    return t->base;
}

const char *miozu_xdg_toplevel_app_id(struct wlr_xdg_toplevel *t) {
    return t->app_id;
}

const char *miozu_xdg_toplevel_title(struct wlr_xdg_toplevel *t) {
    return t->title;
}

/* The transient parent, if any. Non-NULL marks a dialog / modal (delete
 * confirmation, file chooser, properties) the client anchored to another
 * toplevel — teruwm floats these instead of tiling them. */
struct wlr_xdg_toplevel *miozu_xdg_toplevel_parent(struct wlr_xdg_toplevel *t) {
    return t->parent;
}

/* ── XDG surface fields ──────────────────────────────────────── */

struct wlr_surface *miozu_xdg_surface_surface(struct wlr_xdg_surface *s) {
    return s->surface;
}

/* True when the most recent commit is the client's initial commit.
 * The compositor MUST respond with an initial configure (e.g.,
 * wlr_xdg_toplevel_set_size) before the client can map the surface. */
bool miozu_xdg_surface_initial_commit(struct wlr_xdg_surface *s) {
    return s->initial_commit;
}

/* ── wlr_surface signals (map/unmap/commit are here in 0.18) ── */

struct wl_signal *miozu_surface_map(struct wlr_surface *s) {
    return &s->events.map;
}

struct wl_signal *miozu_surface_unmap(struct wlr_surface *s) {
    return &s->events.unmap;
}

struct wl_signal *miozu_surface_commit(struct wlr_surface *s) {
    return &s->events.commit;
}

/* ── Cursor signals ──────────────────────────────────────────── */

struct wl_signal *miozu_cursor_motion(struct wlr_cursor *c) {
    return &c->events.motion;
}

struct wl_signal *miozu_cursor_motion_absolute(struct wlr_cursor *c) {
    return &c->events.motion_absolute;
}

struct wl_signal *miozu_cursor_button(struct wlr_cursor *c) {
    return &c->events.button;
}

struct wl_signal *miozu_cursor_axis(struct wlr_cursor *c) {
    return &c->events.axis;
}

struct wl_signal *miozu_cursor_frame(struct wlr_cursor *c) {
    return &c->events.frame;
}

double miozu_cursor_x(struct wlr_cursor *c) { return c->x; }
double miozu_cursor_y(struct wlr_cursor *c) { return c->y; }

/* ── Keyboard signals & fields ───────────────────────────────── */

struct wl_signal *miozu_keyboard_key(struct wlr_keyboard *k) {
    return &k->events.key;
}

struct wl_signal *miozu_keyboard_modifiers(struct wlr_keyboard *k) {
    return &k->events.modifiers;
}

struct xkb_state *miozu_keyboard_xkb_state(struct wlr_keyboard *k) {
    return k->xkb_state;
}

struct wlr_keyboard_modifiers *miozu_keyboard_modifiers_ptr(struct wlr_keyboard *k) {
    return &k->modifiers;
}

/* ── Input device fields ─────────────────────────────────────── */

enum wlr_input_device_type miozu_input_device_type(struct wlr_input_device *d) {
    return d->type;
}

struct wlr_keyboard *miozu_input_device_keyboard(struct wlr_input_device *d) {
    return wlr_keyboard_from_input_device(d);
}

struct wl_signal *miozu_input_device_destroy(struct wlr_input_device *d) {
    return &d->events.destroy;
}

/* ── Scene graph fields ──────────────────────────────────────── */

struct wlr_scene_tree *miozu_scene_tree(struct wlr_scene *s) {
    if (!s) return NULL;
    return &s->tree;
}

struct wlr_scene_node *miozu_scene_buffer_node(struct wlr_scene_buffer *b) {
    if (!b) return NULL;
    return &b->node;
}

struct wlr_scene_node *miozu_scene_tree_node(struct wlr_scene_tree *t) {
    if (!t) return NULL;
    return &t->node;
}

/* ── Output layout fields ────────────────────────────────────── */

struct wl_signal *miozu_output_layout_change(struct wlr_output_layout *l) {
    return &l->events.change;
}

/* ── Output enable+commit helper ─────────────────────────────── */

bool miozu_output_enable_and_commit(struct wlr_output *output) {
    struct wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, true);

    /* Pick the preferred mode if the output has modes */
    struct wlr_output_mode *mode = wlr_output_preferred_mode(output);
    if (mode != NULL) {
        wlr_output_state_set_mode(&state, mode);
    }

    bool ok = wlr_output_commit_state(output, &state);
    wlr_output_state_finish(&state);
    return ok;
}

/* ── Pointer event accessors ─────────────────────────────────── */

#include <wlr/types/wlr_pointer.h>

double miozu_pointer_motion_dx(struct wlr_pointer_motion_event *e) { return e->delta_x; }
double miozu_pointer_motion_dy(struct wlr_pointer_motion_event *e) { return e->delta_y; }
uint32_t miozu_pointer_motion_time(struct wlr_pointer_motion_event *e) { return e->time_msec; }

double miozu_pointer_motion_abs_x(struct wlr_pointer_motion_absolute_event *e) { return e->x; }
double miozu_pointer_motion_abs_y(struct wlr_pointer_motion_absolute_event *e) { return e->y; }
uint32_t miozu_pointer_motion_abs_time(struct wlr_pointer_motion_absolute_event *e) { return e->time_msec; }

uint32_t miozu_pointer_button_button(struct wlr_pointer_button_event *e) { return e->button; }
uint32_t miozu_pointer_button_state(struct wlr_pointer_button_event *e) { return e->state; }
uint32_t miozu_pointer_button_time(struct wlr_pointer_button_event *e) { return e->time_msec; }

/* ── Axis (scroll wheel) event accessors ─────────────────────── */

double miozu_pointer_axis_delta(struct wlr_pointer_axis_event *e) { return e->delta; }
uint32_t miozu_pointer_axis_orientation(struct wlr_pointer_axis_event *e) { return e->orientation; }
uint32_t miozu_pointer_axis_source(struct wlr_pointer_axis_event *e) { return e->source; }
uint32_t miozu_pointer_axis_time(struct wlr_pointer_axis_event *e) { return e->time_msec; }
int32_t miozu_pointer_axis_delta_discrete(struct wlr_pointer_axis_event *e) { return e->delta_discrete; }

/* ── Keyboard event accessors ────────────────────────────────── */

uint32_t miozu_keyboard_key_keycode(struct wlr_keyboard_key_event *e) { return e->keycode; }
uint32_t miozu_keyboard_key_state(struct wlr_keyboard_key_event *e) { return e->state; }
uint32_t miozu_keyboard_key_time(struct wlr_keyboard_key_event *e) { return e->time_msec; }

/* ── Scene surface accessor ──────────────────────────────────── */

#include <wlr/types/wlr_scene.h>

struct wlr_surface *miozu_scene_surface_get_surface(struct wlr_scene_surface *ss) {
    return ss->surface;
}

/* ── Request set cursor event accessors ──────────────────────── */

struct wlr_surface *miozu_set_cursor_event_surface(
    struct wlr_seat_pointer_request_set_cursor_event *e) {
    return e->surface;
}
int32_t miozu_set_cursor_event_hotspot_x(
    struct wlr_seat_pointer_request_set_cursor_event *e) {
    return e->hotspot_x;
}
int32_t miozu_set_cursor_event_hotspot_y(
    struct wlr_seat_pointer_request_set_cursor_event *e) {
    return e->hotspot_y;
}

/* Compare the event's originating seat client against the seat's current
 * pointer focus. Only the focused pointer client should be allowed to
 * set the cursor image — otherwise a background / defocused / stale
 * client can poke cursor state and trigger scene invariants like
 * `active_outputs && !primary_output` during updates.
 * Returns 1 iff the event's client matches the focused pointer client. */
int miozu_set_cursor_event_from_focused(
    struct wlr_seat_pointer_request_set_cursor_event *e,
    struct wlr_seat *seat) {
    return (e && seat && e->seat_client &&
            e->seat_client == seat->pointer_state.focused_client) ? 1 : 0;
}

/* ── cursor-shape-v1 accessors (Chromium / GTK / Qt pointer shape) ──
 *
 * Chromium since M111 and most modern toolkits use wp_cursor_shape_device_v1
 * rather than the legacy wl_pointer.set_cursor(surface) path. Without
 * wiring request_set_shape, hovering over a link, text field, or resize
 * edge inside a browser leaves the default arrow — there's no "pointer",
 * "text", or "grab" feedback. Symptom looks like the whole browser chrome
 * is un-interactive even when clicks actually land. */

struct wl_signal *miozu_cursor_shape_request_set_shape(
    struct wlr_cursor_shape_manager_v1 *mgr) {
    return &mgr->events.request_set_shape;
}

struct wlr_seat_client *miozu_cursor_shape_event_seat_client(
    struct wlr_cursor_shape_manager_v1_request_set_shape_event *e) {
    return e->seat_client;
}

int miozu_cursor_shape_event_device_type(
    struct wlr_cursor_shape_manager_v1_request_set_shape_event *e) {
    return (int)e->device_type;
}

int miozu_cursor_shape_event_shape(
    struct wlr_cursor_shape_manager_v1_request_set_shape_event *e) {
    return (int)e->shape;
}

/* Returns the xcursor theme name ("default", "text", "pointer", etc.) for
 * the given wp_cursor_shape_device_v1 shape enum. Forwarded to
 * wlr_cursor_set_xcursor on the compositor's xcursor_manager. */
const char *miozu_cursor_shape_name(int shape) {
    return wlr_cursor_shape_v1_name((enum wp_cursor_shape_device_v1_shape)shape);
}

/* Only the seat-client that currently owns pointer focus may change the
 * shape — same invariant as request_set_cursor. */
int miozu_cursor_shape_event_from_focused(
    struct wlr_cursor_shape_manager_v1_request_set_shape_event *e,
    struct wlr_seat *seat) {
    return (e && seat && e->seat_client &&
            e->seat_client == seat->pointer_state.focused_client) ? 1 : 0;
}

/* ── libinput device configuration ───────────────────────────────
 *
 * libinput ships with tap-to-click OFF, natural-scroll OFF, and no
 * secondary-click via two-finger tap. That's fine for dedicated mice but
 * terrible for laptop touchpads — every xmonad / sway / Hyprland config
 * I've seen turns these on unconditionally for any device that supports
 * them. Applied per-device at new_input time. If the device isn't
 * libinput-backed (headless backend, virtual pointer) the handle lookup
 * returns NULL and we silently skip — no-op is the correct behavior. */

void miozu_configure_libinput_pointer(struct wlr_input_device *dev, int natural_scroll) {
    if (!dev) return;
    if (!wlr_input_device_is_libinput(dev)) return;

    struct libinput_device *h = wlr_libinput_get_device_handle(dev);
    if (!h) return;

    /* Tap-to-click: tap registers as left-click, two-finger tap as right,
     * three-finger as middle. Only enabled on devices that report the
     * capability (true touchpads, not plain mice). */
    if (libinput_device_config_tap_get_finger_count(h) > 0) {
        libinput_device_config_tap_set_enabled(h, LIBINPUT_CONFIG_TAP_ENABLED);
        libinput_device_config_tap_set_drag_enabled(h,
            LIBINPUT_CONFIG_DRAG_ENABLED);
        libinput_device_config_tap_set_drag_lock_enabled(h,
            LIBINPUT_CONFIG_DRAG_LOCK_DISABLED);
        /* Button map: 1f→left, 2f→right, 3f→middle. Matches GNOME/KDE
         * defaults and what users migrating from xmonad expect. */
        libinput_device_config_tap_set_button_map(h,
            LIBINPUT_CONFIG_TAP_MAP_LRM);
    }

    /* Natural scrolling (macOS-style) for touchpads — driven by the
     * `natural_scroll` config key (default ON). Set natural_scroll=false in
     * ~/.config/teruwm/config for traditional/reverse scrolling. */
    if (libinput_device_config_scroll_has_natural_scroll(h)) {
        libinput_device_config_scroll_set_natural_scroll_enabled(h, natural_scroll ? 1 : 0);
    }

    /* Disable-while-typing: prevents palm hits while writing code. */
    if (libinput_device_config_dwt_is_available(h)) {
        libinput_device_config_dwt_set_enabled(h,
            LIBINPUT_CONFIG_DWT_ENABLED);
    }

    /* Click method: clickfinger (same gesture as tap buttons above). */
    uint32_t click_methods = libinput_device_config_click_get_methods(h);
    if (click_methods & LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER) {
        libinput_device_config_click_set_method(h,
            LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER);
    }
}

/* ── Custom pixel buffer for terminal pane rendering ──────────── */
/* Implements wlr_buffer backed by a raw ARGB8888 pixel array.    */
/* Zero-copy: SoftwareRenderer writes directly into this buffer,  */
/* wlroots reads it via begin_data_ptr_access.                    */

#include <wlr/interfaces/wlr_buffer.h>
#include <wlr/util/log.h>
#include <stdlib.h>
#include <string.h>

struct miozu_pixel_buffer {
    struct wlr_buffer base;
    void *data;
    uint32_t format;
    size_t stride;
};

static void pixel_buffer_destroy(struct wlr_buffer *wlr_buf) {
    struct miozu_pixel_buffer *buf =
        wl_container_of(wlr_buf, buf, base);
    free(buf->data);
    free(buf);
}

static bool pixel_buffer_begin_data_ptr_access(struct wlr_buffer *wlr_buf,
        uint32_t flags, void **data, uint32_t *format, size_t *stride) {
    struct miozu_pixel_buffer *buf =
        wl_container_of(wlr_buf, buf, base);
    (void)flags;
    *data = buf->data;
    *format = buf->format;
    *stride = buf->stride;
    return true;
}

static void pixel_buffer_end_data_ptr_access(struct wlr_buffer *wlr_buf) {
    (void)wlr_buf;
}

static const struct wlr_buffer_impl pixel_buffer_impl = {
    .destroy = pixel_buffer_destroy,
    .begin_data_ptr_access = pixel_buffer_begin_data_ptr_access,
    .end_data_ptr_access = pixel_buffer_end_data_ptr_access,
};

/* DRM_FORMAT_ARGB8888 = 0x34325241 */
#define MIOZU_FORMAT_ARGB8888 0x34325241

struct wlr_buffer *miozu_pixel_buffer_create(int width, int height) {
    struct miozu_pixel_buffer *buf = calloc(1, sizeof(*buf));
    if (!buf) return NULL;

    buf->stride = (size_t)width * 4;
    buf->format = MIOZU_FORMAT_ARGB8888;
    buf->data = calloc((size_t)height, buf->stride);
    if (!buf->data) { free(buf); return NULL; }

    wlr_buffer_init(&buf->base, &pixel_buffer_impl, width, height);
    return &buf->base;
}

/* Get the raw pixel pointer for direct writes from SoftwareRenderer */
void *miozu_pixel_buffer_data(struct wlr_buffer *wlr_buf) {
    struct miozu_pixel_buffer *buf =
        wl_container_of(wlr_buf, buf, base);
    return buf->data;
}

/* Resize the backing store (called on output/pane resize) */
bool miozu_pixel_buffer_resize(struct wlr_buffer *wlr_buf, int width, int height) {
    struct miozu_pixel_buffer *buf =
        wl_container_of(wlr_buf, buf, base);
    size_t new_stride = (size_t)width * 4;
    void *new_data = calloc((size_t)height, new_stride);
    if (!new_data) return false;
    free(buf->data);
    buf->data = new_data;
    buf->stride = new_stride;
    buf->base.width = width;
    buf->base.height = height;
    return true;
}

/* ── XWayland signals & fields ────────────────────────────────── */

#include <wlr/xwayland/xwayland.h>

struct wl_signal *miozu_xwayland_new_surface(struct wlr_xwayland *xwl) {
    return &xwl->events.new_surface;
}

struct wl_signal *miozu_xwayland_ready(struct wlr_xwayland *xwl) {
    return &xwl->events.ready;
}

const char *miozu_xwayland_display_name(struct wlr_xwayland *xwl) {
    return xwl->display_name;
}

/* ── scene_rect node accessor ───────────────────────────────── */

struct wlr_scene_node *miozu_scene_rect_node(struct wlr_scene_rect *rect) {
    return &rect->node;
}

/* ── Surface client equality ─────────────────────────────────── */

/* Returns 1 iff a and b are both valid surfaces owned by the same
 * wl_client. Used when deciding whether to pass the pointer-entered
 * leaf surface or the xdg_toplevel root to wlr_seat_keyboard_notify_enter
 * — chromium uses subsurfaces for its content, and keyboard focus must
 * target the same leaf the pointer entered for document.activeElement
 * updates to propagate. Fall back to the xdg root if the cached leaf
 * belongs to a different client (stale, or the pointer wandered onto
 * another window between motion and click). */
int miozu_surfaces_same_client(struct wlr_surface *a, struct wlr_surface *b) {
    if (!a || !b || !a->resource || !b->resource) return 0;
    return wl_resource_get_client(a->resource) == wl_resource_get_client(b->resource) ? 1 : 0;
}

/* Pointer to the keyboard's pressed-keycodes buffer + count. Passed
 * to wlr_seat_keyboard_notify_enter so the client knows which keys
 * are currently held when focus arrives — without them the client
 * treats the focus-enter as "no keys pressed" which can confuse
 * browsers when focus arrives mid-modifier-hold. */
const uint32_t *miozu_keyboard_keycodes(struct wlr_keyboard *k) {
    return k->keycodes;
}

size_t miozu_keyboard_num_keycodes(struct wlr_keyboard *k) {
    return k->num_keycodes;
}

/* ── xdg-decoration-v1 ───────────────────────────────────────── */

#include <wlr/types/wlr_xdg_decoration_v1.h>

struct wl_signal *miozu_xdg_decoration_new_toplevel_decoration(
    struct wlr_xdg_decoration_manager_v1 *mgr) {
    return &mgr->events.new_toplevel_decoration;
}

struct wlr_surface *miozu_xwayland_surface_surface(struct wlr_xwayland_surface *s) {
    return s->surface;
}

bool miozu_xwayland_surface_override_redirect(struct wlr_xwayland_surface *s) {
    return s->override_redirect;
}

const char *miozu_xwayland_surface_class(struct wlr_xwayland_surface *s) {
    return s->class;
}

const char *miozu_xwayland_surface_title(struct wlr_xwayland_surface *s) {
    return s->title;
}

int16_t miozu_xwayland_surface_x(struct wlr_xwayland_surface *s) { return s->x; }
int16_t miozu_xwayland_surface_y(struct wlr_xwayland_surface *s) { return s->y; }
uint16_t miozu_xwayland_surface_width(struct wlr_xwayland_surface *s) { return s->width; }
uint16_t miozu_xwayland_surface_height(struct wlr_xwayland_surface *s) { return s->height; }

struct wl_signal *miozu_xwayland_surface_map(struct wlr_xwayland_surface *s) {
    return &s->events.associate;
}

struct wl_signal *miozu_xwayland_surface_unmap(struct wlr_xwayland_surface *s) {
    return &s->events.dissociate;
}

struct wl_signal *miozu_xwayland_surface_destroy(struct wlr_xwayland_surface *s) {
    return &s->events.destroy;
}

struct wl_signal *miozu_xwayland_surface_request_configure(struct wlr_xwayland_surface *s) {
    return &s->events.request_configure;
}

/* ── Float-detection for X11 auxiliary windows ────────────────
 *
 * Notifications, menus, dialogs, tooltips, and similar are X11 windows
 * that are NOT override-redirect (so the existing OR branch in
 * XwaylandView.handleMap doesn't catch them) but absolutely must NOT
 * be tiled. The user's notification daemon (dunst) is the canonical
 * case: dunst maps a regular X11 window with _NET_WM_WINDOW_TYPE_NOTIFICATION
 * and a fixed size_hints, expecting the WM to honour the requested
 * geometry. Tiling it stretches it across half the workspace.
 *
 * We avoid round-tripping through xcb_intern_atom (which would mean
 * opening a separate xcb connection to the xwayland display) by
 * checking the simpler signals wlroots already exposes: size_hints
 * (fixed size) and `parent` (transient_for, i.e. dialog).
 *
 * Atom names like _NET_WM_WINDOW_TYPE_NOTIFICATION are stored in
 * s->window_type as opaque xcb_atom_t IDs that wlroots doesn't
 * resolve for us. Apps that set those atoms but don't also set
 * size_hints / transient_for fall back on the class allowlist on
 * the Zig side (XwaylandView.zig).
 */

/* Returns true if the surface declares both PMinSize + PMaxSize hints
 * with min == max, i.e. the client wants this window to stay at a
 * fixed size. dunst, dmenu, polybar, conky, slock all do this. */
bool miozu_xwayland_surface_is_fixed_size(struct wlr_xwayland_surface *s) {
    if (s == NULL || s->size_hints == NULL) return false;
    /* xcb size_hints flags — see xcb/icccm.h. */
    const int32_t P_MIN_SIZE = 1 << 4;
    const int32_t P_MAX_SIZE = 1 << 5;
    const xcb_size_hints_t *h = s->size_hints;
    if ((h->flags & P_MIN_SIZE) == 0) return false;
    if ((h->flags & P_MAX_SIZE) == 0) return false;
    return h->min_width == h->max_width && h->min_height == h->max_height
        && h->min_width > 0 && h->min_height > 0;
}

/* Returns true if the surface has an X11 transient_for parent.
 * Modal dialogs, file pickers, "About" boxes etc. all set this. */
bool miozu_xwayland_surface_has_parent(struct wlr_xwayland_surface *s) {
    return s != NULL && s->parent != NULL;
}

/* Returns true if surface->modal is set (_NET_WM_STATE_MODAL).
 * Backstop for modal dialogs that don't set transient_for. */
bool miozu_xwayland_surface_is_modal(struct wlr_xwayland_surface *s) {
    return s != NULL && s->modal;
}

/* ── Seat keyboard accessor ──────────────────────────────────── */

struct wlr_keyboard *miozu_seat_get_keyboard(struct wlr_seat *s) {
    return wlr_seat_get_keyboard(s);
}

/* The pointer's currently-focused surface. wlroots keeps this valid and
 * auto-nulls it on surface destroy (its own internal destroy listener), so
 * it is always safe to read — unlike a raw latched surface pointer, which
 * dangles when a popup/subsurface under the cursor is destroyed (e.g. a
 * right-click menu) and then dereferenced. */
struct wlr_surface *miozu_seat_pointer_focused_surface(struct wlr_seat *s) {
    return s->pointer_state.focused_surface;
}

/* ── Seat request signals ────────────────────────────────────── */

struct wl_signal *miozu_seat_request_set_cursor(struct wlr_seat *s) {
    return &s->events.request_set_cursor;
}

struct wl_signal *miozu_seat_request_set_selection(struct wlr_seat *s) {
    return &s->events.request_set_selection;
}

/* ── Compositor-owned clipboard (screenshot → clipboard) ──────── */
/* teruwm IS the Wayland server, so instead of shelling out to wl-copy   */
/* we register our own wlr_data_source offering image/png and hand it to */
/* wlr_seat_set_selection. The PNG bytes live in the source until a newer */
/* selection replaces it (wlroots then calls our destroy cb). On paste we */
/* double-fork a short-lived writer so a slow/non-reading client can      */
/* never stall the compositor event loop. No runtime dependency.          */

#include <wlr/types/wlr_data_device.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <signal.h>

struct miozu_png_source {
    struct wlr_data_source base;
    unsigned char *data;
    size_t len;
};

static void miozu_png_source_send(struct wlr_data_source *src,
        const char *mime_type, int32_t fd) {
    (void)mime_type; /* we only ever offer image/png */
    struct miozu_png_source *s = wl_container_of(src, s, base);

    /* Double-fork: the grandchild streams the bytes, the immediate child
     * exits at once (reaped below) so the grandchild reparents to init —
     * no zombie. The child path uses only async-signal-safe calls. */
    pid_t pid = fork();
    if (pid == 0) {
        if (fork() == 0) {
            /* If the paste target closes the read end early, write() would
             * raise SIGPIPE whose default action kills this writer before the
             * graceful EPIPE break below. Ignore it so the loop exits cleanly. */
            signal(SIGPIPE, SIG_IGN);
            size_t off = 0;
            while (off < s->len) {
                ssize_t n = write(fd, s->data + off, s->len - off);
                if (n < 0) {
                    if (errno == EINTR) continue;
                    break;
                }
                off += (size_t)n;
            }
            close(fd);
            _exit(0);
        }
        _exit(0);
    }
    close(fd); /* parent never uses the write end */
    if (pid > 0) {
        waitpid(pid, NULL, 0); /* reap the immediate child */
    }
}

static void miozu_png_source_destroy(struct wlr_data_source *src) {
    struct miozu_png_source *s = wl_container_of(src, s, base);
    /* wlroots already freed the strdup'd mime strings + the array. */
    free(s->data);
    free(s);
}

static const struct wlr_data_source_impl miozu_png_source_impl = {
    .send = miozu_png_source_send,
    .destroy = miozu_png_source_destroy,
};

/* Read `path` into memory and publish it as the seat selection (image/png).
 * Returns 0 on success, -1 on failure (the caller's PNG is still on disk). */
int miozu_set_clipboard_png_from_file(struct wlr_seat *seat,
        struct wl_display *display, const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;

    struct stat st;
    if (fstat(fd, &st) < 0 || st.st_size <= 0) {
        close(fd);
        return -1;
    }
    size_t len = (size_t)st.st_size;
    unsigned char *buf = malloc(len);
    if (buf == NULL) {
        close(fd);
        return -1;
    }
    size_t off = 0;
    while (off < len) {
        ssize_t n = read(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            close(fd);
            return -1;
        }
        if (n == 0) break;
        off += (size_t)n;
    }
    close(fd);
    if (off != len) {
        free(buf);
        return -1;
    }

    struct miozu_png_source *s = calloc(1, sizeof(*s));
    if (s == NULL) {
        free(buf);
        return -1;
    }
    wlr_data_source_init(&s->base, &miozu_png_source_impl);
    s->data = buf;
    s->len = len;

    char **mime = wl_array_add(&s->base.mime_types, sizeof(char *));
    if (mime == NULL) {
        wlr_data_source_destroy(&s->base); /* frees buf via destroy cb */
        return -1;
    }
    *mime = strdup("image/png");

    wlr_seat_set_selection(seat, &s->base, wl_display_next_serial(display));
    return 0;
}

/* ── Clipboard relay: forward client copy requests to the seat ── */
/* teruwm only CREATED the data_device + primary-selection managers; it    */
/* never listened for clients asking to OWN the selection, so a client's   */
/* copy was silently dropped and nothing could be pasted between apps.     */
/* Standard wlroots wiring (matches tinywl/sway): relay the event's        */
/* source + serial straight to wlr_seat_set_selection. Serial validation   */
/* happens inside wlroots.                                                  */

#include <wlr/types/wlr_primary_selection.h>

struct wl_signal *miozu_seat_request_set_primary_selection(struct wlr_seat *s) {
    return &s->events.request_set_primary_selection;
}

void miozu_relay_set_selection(void *event, struct wlr_seat *seat) {
    struct wlr_seat_request_set_selection_event *e = event;
    wlr_seat_set_selection(seat, e->source, e->serial);
}

void miozu_relay_set_primary_selection(void *event, struct wlr_seat *seat) {
    struct wlr_seat_request_set_primary_selection_event *e = event;
    wlr_seat_set_primary_selection(seat, e->source, e->serial);
}

/* ── xdg_activation_v1 (v0.4.17) ─────────────────────────────── */

struct wl_signal *miozu_xdg_activation_request_activate(struct wlr_xdg_activation_v1 *a) {
    return &a->events.request_activate;
}

struct wlr_surface *miozu_xdg_activation_event_surface(
    struct wlr_xdg_activation_v1_request_activate_event *e) {
    return e->surface;
}

/* Wrapper for wlr_xdg_toplevel_try_from_wlr_surface — expose as a function
 * pointer callable from Zig with a stable name. */
struct wlr_xdg_toplevel *miozu_xdg_toplevel_from_surface(struct wlr_surface *s) {
    return wlr_xdg_toplevel_try_from_wlr_surface(s);
}

/* Surface-lifetime guard for the pointer-motion path. wlr_seat_pointer_
 * notify_enter calls wl_resource_get_client(surface->resource), which
 * asserts when the resource is freed. Scene nodes can out-live their
 * underlying surface during the unmap→destroy window — we check the
 * mapped bit explicitly before routing pointer focus. */
int miozu_surface_is_live(struct wlr_surface *s) {
    return s && s->resource && s->mapped;
}

/* wlr_scene_buffer_from_node asserts node->type == WLR_SCENE_NODE_BUFFER
 * — passing a TREE or RECT node crashes the compositor. scene_node_at
 * happily returns any visible node type (e.g. the bg_rect we create at
 * output init), so callers must pre-filter. */
int miozu_scene_node_is_buffer(struct wlr_scene_node *n) {
    return n && n->type == WLR_SCENE_NODE_BUFFER;
}

/* ── idle_inhibit_v1 ─────────────────────────────────────────── */

struct wl_signal *miozu_idle_inhibit_new_inhibitor(struct wlr_idle_inhibit_manager_v1 *m) {
    return &m->events.new_inhibitor;
}

struct wl_signal *miozu_idle_inhibitor_destroy(struct wlr_idle_inhibitor_v1 *i) {
    return &i->events.destroy;
}

/* Returns the live inhibitor count. Used after new/destroy to decide
 * whether to flip wlr_idle_notifier_v1_set_inhibited. */
int miozu_idle_inhibit_count(struct wlr_idle_inhibit_manager_v1 *m) {
    return wl_list_length(&m->inhibitors);
}

/* ── output_power_management_v1 ──────────────────────────────── */

struct wl_signal *miozu_output_power_mgr_set_mode(struct wlr_output_power_manager_v1 *m) {
    return &m->events.set_mode;
}

struct wlr_output *miozu_output_power_event_output(struct wlr_output_power_v1_set_mode_event *e) {
    return e->output;
}

int miozu_output_power_event_mode_on(struct wlr_output_power_v1_set_mode_event *e) {
    return e->mode == ZWLR_OUTPUT_POWER_V1_MODE_ON;
}

/* One-shot enabled-state commit. wlr_output_state is opaque in Zig so
 * we stack-allocate on the C side and run the usual init/set/commit/
 * finish pattern inline. Returns 1 on commit success. */
int miozu_output_commit_enabled(struct wlr_output *output, int enabled) {
    struct wlr_output_state state;
    wlr_output_state_init(&state);
    wlr_output_state_set_enabled(&state, enabled != 0);
    int ok = wlr_output_commit_state(output, &state);
    wlr_output_state_finish(&state);
    return ok ? 1 : 0;
}

/* Expose wlr_output->enabled so the set_mode handler can short-circuit
 * when the client asks for the state we're already in (wlopm spam
 * protection). */
int miozu_output_enabled(struct wlr_output *output) {
    return output->enabled ? 1 : 0;
}

/* ── virtual_keyboard / virtual_pointer ──────────────────────── */

struct wl_signal *miozu_virtual_keyboard_mgr_new(struct wlr_virtual_keyboard_manager_v1 *m) {
    return &m->events.new_virtual_keyboard;
}

struct wl_signal *miozu_virtual_pointer_mgr_new(struct wlr_virtual_pointer_manager_v1 *m) {
    return &m->events.new_virtual_pointer;
}

/* Virtual keyboard embeds wlr_keyboard{.base: wlr_input_device} — return the
 * embedded input device so setupKeyboard() in Server.zig works unchanged. */
struct wlr_input_device *miozu_virtual_keyboard_input_device(struct wlr_virtual_keyboard_v1 *vkbd) {
    return &vkbd->keyboard.base;
}

/* Virtual pointer embeds wlr_pointer, and wlr_pointer embeds wlr_input_device
 * at .base. The new-pointer event hands us the wlr_virtual_pointer_v1*; we
 * resolve to the input device suitable for wlr_cursor_attach_input_device. */
struct wlr_input_device *miozu_virtual_pointer_new_pointer(struct wlr_virtual_pointer_v1_new_pointer_event *e) {
    return &e->new_pointer->pointer.base;
}

/* ── output_management_v1 ────────────────────────────────────── */

struct wl_signal *miozu_output_manager_apply(struct wlr_output_manager_v1 *m) {
    return &m->events.apply;
}

struct wl_signal *miozu_output_manager_test(struct wlr_output_manager_v1 *m) {
    return &m->events.test;
}

/* Walk the heads in a client-supplied configuration, apply (or test)
 * each one via wlroots' helpers, keep the output_layout position in
 * sync. Returns 1 iff every head committed/tested successfully.
 *
 * The two-phase design is why clients call test_configuration before
 * apply_configuration — kanshi/wdisplays preview before confirming.
 * test_only=1 forbids state mutation; wlroots enforces that
 * wlr_output_test_state doesn't commit. */
int miozu_output_apply_config(
    struct wlr_output_layout *layout,
    struct wlr_output_configuration_v1 *cfg,
    int test_only
) {
    int all_ok = 1;
    struct wlr_output_configuration_head_v1 *head;
    wl_list_for_each(head, &cfg->heads, link) {
        struct wlr_output *output = head->state.output;
        struct wlr_output_state state;
        wlr_output_state_init(&state);
        wlr_output_head_v1_state_apply(&head->state, &state);

        int ok;
        if (test_only) {
            ok = wlr_output_test_state(output, &state);
        } else {
            ok = wlr_output_commit_state(output, &state);
            if (ok) {
                /* head_v1_state_apply doesn't touch x/y — we must mirror
                 * the client's layout position into output_layout or the
                 * cursor warp/scene coords drift from the reported head
                 * position. */
                if (head->state.enabled) {
                    wlr_output_layout_add(layout, output,
                                          head->state.x, head->state.y);
                } else {
                    wlr_output_layout_remove(layout, output);
                }
            }
        }

        wlr_output_state_finish(&state);
        if (!ok) all_ok = 0;
    }
    return all_ok;
}

/* Build an output_configuration_v1 reflecting current state of each
 * connected wlr_output and push it to the manager. Called on output
 * add/destroy/mode-change so clients see live heads. */
void miozu_output_push_state(
    struct wlr_output_manager_v1 *mgr,
    struct wlr_output_layout *layout,
    struct wlr_output **outputs,
    int n_outputs
) {
    struct wlr_output_configuration_v1 *cfg = wlr_output_configuration_v1_create();
    if (!cfg) return;
    for (int i = 0; i < n_outputs; i++) {
        struct wlr_output *output = outputs[i];
        struct wlr_output_configuration_head_v1 *head =
            wlr_output_configuration_head_v1_create(cfg, output);
        if (!head) continue;
        /* Pre-fill from output is done by _create — just override
         * x/y with the real layout position. */
        struct wlr_output_layout_output *lo =
            wlr_output_layout_get(layout, output);
        if (lo) {
            head->state.x = lo->x;
            head->state.y = lo->y;
        }
    }
    wlr_output_manager_v1_set_configuration(mgr, cfg);
}

void miozu_output_config_send_succeeded(struct wlr_output_configuration_v1 *cfg) {
    wlr_output_configuration_v1_send_succeeded(cfg);
    wlr_output_configuration_v1_destroy(cfg);
}

void miozu_output_config_send_failed(struct wlr_output_configuration_v1 *cfg) {
    wlr_output_configuration_v1_send_failed(cfg);
    wlr_output_configuration_v1_destroy(cfg);
}

/* ── foreign_toplevel_management_v1 ──────────────────────────── */

struct wl_signal *miozu_ftl_request_activate(struct wlr_foreign_toplevel_handle_v1 *h) {
    return &h->events.request_activate;
}

struct wl_signal *miozu_ftl_request_close(struct wlr_foreign_toplevel_handle_v1 *h) {
    return &h->events.request_close;
}

/* wlroots' own destroy signal on the handle fires when the manager /
 * display tears down (or we call _destroy ourselves). Let XdgView null
 * its ftl_handle + unhook its request listeners so we don't later call
 * _destroy on freed memory. */
struct wl_signal *miozu_ftl_handle_destroy_signal(struct wlr_foreign_toplevel_handle_v1 *h) {
    return &h->events.destroy;
}

/* ── pixman damage regions ───────────────────────────────────── */

#include <pixman-1/pixman.h>

/* Commit a scene buffer with a minimal damage region.
 *
 * dirty_y0 / dirty_y1 are pixel-space Y bounds of the rows that
 * changed (half-open: [y0, y1)). Pass -1 for dirty_y0 to signal
 * "fall back to full-buffer damage" without a separate code path.
 *
 * border_thickness, when > 0, unions in four edge strips so the
 * ~FFD39A focus border gets recomposited on focus flips. The math
 * mirrors TerminalPane.drawBorder's 2-px perimeter. */
void miozu_scene_buffer_commit_dirty(
    struct wlr_scene_buffer *sb,
    struct wlr_buffer *buf,
    int fb_w, int fb_h,
    int dirty_y0, int dirty_y1,
    int border_thickness)
{
    pixman_region32_t region;
    pixman_region32_init(&region);
    /* dirty_y0 < 0 is the "whole buffer" sentinel. dirty_y1 == dirty_y0 is a
     * ZERO-height middle band: borders only (repaintBorderOnly). Only a truly
     * inverted range (dirty_y1 < dirty_y0) falls back to full damage. The old
     * `<=` test made the borders-only case re-damage the entire pane on every
     * focus change. */
    if (dirty_y0 < 0 || dirty_y1 < dirty_y0 || fb_w <= 0 || fb_h <= 0) {
        /* Fall back to full-buffer damage. */
        pixman_region32_union_rect(&region, &region, 0, 0, fb_w, fb_h);
    } else {
        int y0 = dirty_y0;
        int y1 = dirty_y1 > fb_h ? fb_h : dirty_y1;
        if (y1 > y0) pixman_region32_union_rect(&region, &region, 0, y0, fb_w, y1 - y0);
        if (border_thickness > 0 && fb_h > 2 * border_thickness && fb_w > 2 * border_thickness) {
            int bt = border_thickness;
            pixman_region32_union_rect(&region, &region, 0, 0, fb_w, bt);
            pixman_region32_union_rect(&region, &region, 0, fb_h - bt, fb_w, bt);
            pixman_region32_union_rect(&region, &region, 0, bt, bt, fb_h - 2 * bt);
            pixman_region32_union_rect(&region, &region, fb_w - bt, bt, bt, fb_h - 2 * bt);
        }
    }
    wlr_scene_buffer_set_buffer_with_damage(sb, buf, &region);
    pixman_region32_fini(&region);
}
