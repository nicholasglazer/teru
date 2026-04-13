/**
 * miozu-wlr-glue.c — Thin C accessors for wlroots struct fields (teruwm).
 *
 * wlroots types are opaque in Zig. Rather than replicating exact C struct
 * layouts (fragile, version-dependent), we expose the specific fields teruwm
 * needs through accessor functions. The C compiler verifies correctness.
 */

#include <wlr/backend.h>
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

struct wl_signal *miozu_xdg_toplevel_destroy(struct wlr_xdg_toplevel *t) {
    return &t->events.destroy;
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

/* ── Output layout dimensions (first output) ─────────────────── */

int miozu_output_layout_first_width(struct wlr_output_layout *layout) {
    struct wl_list *outputs = &layout->outputs;
    if (wl_list_empty(outputs)) return 1920;
    struct wlr_output_layout_output *lo;
    lo = wl_container_of(outputs->next, lo, link);
    return lo->output->width;
}

int miozu_output_layout_first_height(struct wlr_output_layout *layout) {
    struct wl_list *outputs = &layout->outputs;
    if (wl_list_empty(outputs)) return 1080;
    struct wlr_output_layout_output *lo;
    lo = wl_container_of(outputs->next, lo, link);
    return lo->output->height;
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

/* ── Seat keyboard accessor ──────────────────────────────────── */

struct wlr_keyboard *miozu_seat_get_keyboard(struct wlr_seat *s) {
    return wlr_seat_get_keyboard(s);
}

/* ── Seat request signals ────────────────────────────────────── */

struct wl_signal *miozu_seat_request_set_cursor(struct wlr_seat *s) {
    return &s->events.request_set_cursor;
}

struct wl_signal *miozu_seat_request_set_selection(struct wlr_seat *s) {
    return &s->events.request_set_selection;
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
