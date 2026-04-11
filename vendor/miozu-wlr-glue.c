/**
 * miozu-wlr-glue.c — Thin C accessors for wlroots struct fields.
 *
 * wlroots types are opaque in Zig. Rather than replicating exact C struct
 * layouts (fragile, version-dependent), we expose the specific fields miozu
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

/* ── Seat request signals ────────────────────────────────────── */

struct wl_signal *miozu_seat_request_set_cursor(struct wlr_seat *s) {
    return &s->events.request_set_cursor;
}

struct wl_signal *miozu_seat_request_set_selection(struct wlr_seat *s) {
    return &s->events.request_set_selection;
}
