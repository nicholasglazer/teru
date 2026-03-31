// Wrapper functions for Wayland inline helpers.
// wl_display_get_registry and wl_registry_bind are inline in the header,
// so they can't be linked directly. This file compiles them into symbols.

#include <wayland-client.h>

struct wl_registry *teru_wl_display_get_registry(struct wl_display *display) {
    return wl_display_get_registry(display);
}

void *teru_wl_registry_bind(struct wl_registry *registry, uint32_t name,
                            const struct wl_interface *interface, uint32_t version) {
    return wl_registry_bind(registry, name, interface, version);
}
