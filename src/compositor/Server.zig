//! Compositor server state. Owns all wlroots objects, listeners, and the
//! connection between libteru's tiling engine and the wlroots scene graph.

const std = @import("std");
const wlr = @import("wlr.zig");
const Output = @import("Output.zig");
const XdgView = @import("XdgView.zig");
const TerminalPane = @import("TerminalPane.zig");
const Session = @import("Session.zig");
const XwaylandView = @import("XwaylandView.zig");
const Launcher = @import("Launcher.zig");
const Bar = @import("Bar.zig");
const WmConfig = @import("WmConfig.zig");
const WmMcpServer = @import("WmMcpServer.zig");
const NodeRegistry = @import("Node.zig");
const Listeners = @import("ServerListeners.zig");
const Input = @import("ServerInput.zig");
const Cursor = @import("ServerCursor.zig");
const teru = @import("teru");
const LayoutEngine = teru.LayoutEngine;
const Keybinds = teru.Keybinds;
const Mods = Keybinds.Mods;
const KB = Keybinds.Keybinds;
const KBAction = Keybinds.Action;
const KBMods = Keybinds.Mods;

const Server = @This();

pub const CursorMode = enum { normal, move, resize, border_drag };

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

/// Full-screen background scene rect (solid color). Created on output
/// attach, lowered beneath all other scene nodes. Color from wm_config.
bg_rect: ?*wlr.wlr_scene_rect = null,

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
/// Legacy single-output pointer — kept alive because many helpers read
/// from it (cursor warping, screencopy, screenshot). In the multi-
/// output model, `focused_output.wlr_output` is the authoritative
/// choice; primary_output mirrors it for back-compat until we finish
/// the audit.
primary_output: ?*wlr.wlr_output = null,

// ── Multi-output tracking (v0.4.20) ───────────────────────────
//
// outputs is appended-to by Output.create and compacted by
// Output.handleDestroy. The order is connection order; focus cycling
// walks this list. `focused_output` tracks the output that workspace-
// switch / keyboard-focus actions target.

outputs: std.ArrayListUnmanaged(*Output) = .empty,
focused_output: ?*Output = null,
workspace_trees: [10]?*wlr.wlr_scene_tree = [_]?*wlr.wlr_scene_tree{null} ** 10,

// Active XKB layout name (for the {keymap} bar widget).
// Stored as a static buffer because the xkb string can outlive
// the keymap it came from between reads.
active_keymap_name_buf: [64]u8 = [_]u8{0} ** 64,
active_keymap_name: []const u8 = "",

// Every keyboard device seen via setupKeyboard. Append-only while the
// compositor runs — used to re-apply keymaps to *every* attached device
// on config reload (laptop + external dock is the common case). We
// don't remove on unplug today because Keyboard never frees itself;
// stale entries would dereference a dead `wlr_keyboard`. Wiring device-
// destroy listeners + removal is the next step if/when unplug matters.
keyboards: std.ArrayListUnmanaged(*Input.Keyboard) = .empty,

// Diagnostic only — tracks the last surface pointer notify_enter was
// called with, so motion logging can print only on transitions instead
// of every motion event. Not authoritative.
last_pointer_surface: ?*wlr.wlr_surface = null,

/// FixedBufferAllocator-backed scratch for layout_engine.calculate.
/// LayoutEngine allocates a []Rect per call (masterStackN / grid /
/// etc. all end with a `try self.allocator.alloc(Rect, count)`). On
/// border-drag that's 60 heap allocs/sec; during Mod+drag float it's
/// more. With a 16 KiB FBA we cover up to 1024 panes of Rect and
/// arrangeworkspace's outer ArrayListUnmanaged still falls back to
/// the general allocator for tree layouts / edge cases.
arrange_scratch_buf: [16 * 1024]u8 = undefined,

/// Push widgets registered via MCP. Referenced by bar format strings
/// with `{widget:name}`. Fixed-size array; slot 0..N with `.used=false`
/// are empty. No heap allocation. Not persisted across hot-restart.
push_widgets: [teru.render.PushWidget.max_widgets]teru.render.PushWidget.PushWidget =
    [_]teru.render.PushWidget.PushWidget{.{}} ** teru.render.PushWidget.max_widgets,

// Fullscreen state: tracks which node is fullscreen (null = none)
fullscreen_node: ?u64 = null,
fullscreen_prev_bar_top: bool = true,
fullscreen_prev_bar_bottom: bool = false,

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

// Autostart fires once on first output. True if we've already run it,
// OR if we're restoring from --restore (autostart is a cold-start feature;
// hot-restart must not re-spawn clients that are still connected).
autostart_fired: bool = false,

// Previous workspace, for Mod+Escape toggle-last. Updated on every
// workspace switch.
prev_workspace: ?u8 = null,

// User-defined spawn chord commands. Each slot pairs with the
// spawn_0..spawn_31 action variants; the keybind table maps chords
// to those actions, this array resolves to the shell command.
// Populated from `[keybind]` config section entries of the form
// `Mod+Return = spawn:teru`.
spawn_table: [32][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 32,
spawn_table_len: [32]u16 = [_]u16{0} ** 32,

// MCP server for compositor control
wm_mcp: ?*WmMcpServer = null,

// Deferred layout/resize — set by mouse handlers, applied in frame callback
layout_dirty: bool = false,
resize_pending_id: ?u64 = null,
resize_pending_w: u32 = 0,
resize_pending_h: u32 = 0,

// Performance stats
perf: PerfStats = .{},

// Restart flag — set by MCP, executed in frame callback (after response is sent)
restart_pending: bool = false,

// ── Listeners ──────────────────────────────────────────────────

new_output: wlr.wl_listener = makeListener(Listeners.handleNewOutput),
new_input: wlr.wl_listener = makeListener(Input.handleNewInput),
new_xdg_toplevel: wlr.wl_listener = makeListener(Listeners.handleNewXdgToplevel),
cursor_motion: wlr.wl_listener = makeListener(Cursor.handleCursorMotion),
cursor_motion_absolute: wlr.wl_listener = makeListener(Cursor.handleCursorMotionAbsolute),
cursor_button: wlr.wl_listener = makeListener(Cursor.handleCursorButton),
cursor_axis: wlr.wl_listener = makeListener(Cursor.handleCursorAxis),
cursor_frame: wlr.wl_listener = makeListener(Cursor.handleCursorFrame),
request_set_cursor: wlr.wl_listener = makeListener(Cursor.handleRequestSetCursor),
new_xwayland_surface: wlr.wl_listener = makeListener(Listeners.handleNewXwaylandSurface),

// xdg_activation_v1 — clients asking for focus (v0.4.17).
xdg_activate: wlr.wl_listener = makeListener(Listeners.handleXdgActivation),
xdg_activation: ?*wlr.wlr_xdg_activation_v1 = null,

// xdg-decoration-v1 — for every new toplevel decoration we force the
// server-side mode (tiling WM: no wasted titlebar). Listener lives here;
// the manager itself has no long-lived state we need.
xdg_decoration_mgr: ?*wlr.wlr_xdg_decoration_manager_v1 = null,
new_xdg_decoration: wlr.wl_listener = makeListener(Listeners.handleNewXdgDecoration),

// idle-notify-v1 — swayidle/gammastep subscribers get activity pings
// on every real input event (keyboard, pointer motion/button/axis).
// Null = feature unavailable (should never happen; we own the global).
idle_notifier: ?*wlr.wlr_idle_notifier_v1 = null,

// wlr_idle_inhibit_v1 — mpv / browsers / video calls pin inhibitors
// to keep the screen awake. We count live inhibitors and flip the
// idle_notifier's inhibited flag accordingly.
idle_inhibit_mgr: ?*wlr.wlr_idle_inhibit_manager_v1 = null,
idle_inhibitor_count: u16 = 0,
new_inhibitor: wlr.wl_listener = makeListener(Listeners.handleNewInhibitor),
inhibitor_trackers: std.ArrayListUnmanaged(*Listeners.InhibitorTracker) = .empty,
shutting_down: bool = false,

// wlr_output_power_management_v1 — wlopm / swayidle dpms hook.
// Clients call set_mode with ON/OFF per output; we commit the
// corresponding wlr_output_state.enabled.
output_power_mgr: ?*wlr.wlr_output_power_manager_v1 = null,
output_power_set_mode: wlr.wl_listener = makeListener(Listeners.handleOutputPowerSetMode),

// wlr_virtual_keyboard_v1 / wlr_virtual_pointer_v1 — synthetic input
// for wtype / ydotool / wlrctl / accessibility. Each new object
// arrives embedding a wlr_keyboard / wlr_pointer we route through
// the normal input-device setup paths. Default-on; gate via config
// if you need to harden a shared host.
virtual_keyboard_mgr: ?*wlr.wlr_virtual_keyboard_manager_v1 = null,
virtual_pointer_mgr: ?*wlr.wlr_virtual_pointer_manager_v1 = null,
new_virtual_keyboard: wlr.wl_listener = makeListener(Listeners.handleNewVirtualKeyboard),
new_virtual_pointer: wlr.wl_listener = makeListener(Listeners.handleNewVirtualPointer),

// wlr_output_management_v1 — kanshi, wlr-randr, wdisplays.
// Clients post configurations; we apply/test and push current state
// back on any output add/remove/mode change.
output_manager: ?*wlr.wlr_output_manager_v1 = null,
output_manager_apply: wlr.wl_listener = makeListener(Listeners.handleOutputManagerApply),
output_manager_test: wlr.wl_listener = makeListener(Listeners.handleOutputManagerTest),

// wlr_foreign_toplevel_management_v1 — zwlr. waybar / nwg-panel /
// wlrctl list our mapped xdg toplevels and can activate/close them.
// One handle per XdgView, created in handleMap, destroyed in handleUnmap.
foreign_toplevel_mgr: ?*wlr.wlr_foreign_toplevel_manager_v1 = null,

// ── Types ─────────────────────────────────────────────────────

pub const PerfStats = struct {
    frame_count: u64 = 0,
    frame_time_sum_us: u64 = 0,
    frame_time_max_us: u64 = 0,
    frame_time_min_us: u64 = std.math.maxInt(u64),
    pty_reads: u64 = 0,
    pty_bytes: u64 = 0,

    pub fn recordFrame(self: *PerfStats, elapsed_us: u64) void {
        self.frame_count += 1;
        self.frame_time_sum_us += elapsed_us;
        if (elapsed_us > self.frame_time_max_us) self.frame_time_max_us = elapsed_us;
        if (elapsed_us < self.frame_time_min_us) self.frame_time_min_us = elapsed_us;
    }

    pub fn recordPtyRead(self: *PerfStats, bytes: usize) void {
        self.pty_reads += 1;
        self.pty_bytes += bytes;
    }

    pub fn avgFrameUs(self: *const PerfStats) u64 {
        if (self.frame_count == 0) return 0;
        return self.frame_time_sum_us / self.frame_count;
    }
};

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

    // zwlr_screencopy_manager_v1 — enables grim, slurp+grim, wf-recorder,
    // OBS screencopy, and any other screen-capture client. wlroots hooks
    // wlr_output.commit internally and samples the composited framebuffer
    // every vsync; no extra render pass. Owned by the wl_display, so no
    // cleanup needed (tears down on display_destroy).
    _ = wlr.wlr_screencopy_manager_v1_create(display);

    // xdg_activation_v1 — clients ask "please focus me." We route this
    // to the urgency bit (not focus-steal) so hidden apps visibly flag
    // themselves on their workspace pill in the bar.
    const xdg_act = wlr.wlr_xdg_activation_v1_create(display);

    // primary-selection-v1 — enables middle-click paste between Wayland
    // apps. wlroots owns the selection state; we only wire the global.
    _ = wlr.wlr_primary_selection_v1_device_manager_create(display);

    // xdg-decoration-v1 — every GTK/Qt app asks the compositor whether
    // to draw its own titlebar. We always say server-side (tiling =
    // no titlebar). Listener is registered in registerListeners once
    // Server has its heap address.
    const xdg_deco = wlr.wlr_xdg_decoration_manager_v1_create(display);

    // idle-notify-v1 — swayidle, gammastep, wlsunset, etc. Activity
    // pings go out from every real input event.
    const idle_notif = wlr.wlr_idle_notifier_v1_create(display);

    // Scene graph
    const scene = wlr.wlr_scene_create() orelse
        return error.SceneCreateFailed;

    // Note: background color is handled by wlr_renderer_clear in the
    // Output frame handler, not by a scene rect (avoids node type issues).

    // Output layout
    const output_layout = wlr.wlr_output_layout_create(display) orelse
        return error.OutputLayoutCreateFailed;
    _ = wlr.wlr_scene_attach_output_layout(scene, output_layout);

    // zxdg_output_manager_v1 — needs output_layout to exist. Without
    // this, grim / wlr-screencopy consumers fall back to guessing
    // output geometry and produce 0×0 PNGs (both on headless + real
    // DRM). Also a prerequisite for serious multi-output setups with
    // kanshi, wlr-randr, etc.
    _ = wlr.wlr_xdg_output_manager_v1_create(display, output_layout);

    // ── Chromium-engine requirement pack ──────────────────────
    //
    // wp_viewporter is the *smoking gun* for chromium-family browsers
    // (chromium, vivaldi, opera, brave, edge) stalling at their splash
    // on minimal wlroots compositors. Chromium's Viz/WebRender commits
    // page-content tiles as wl_subsurfaces clipped via viewporter;
    // absent this global the renderer can't commit those buffers and
    // the browser sits on its welcome screen forever. Firefox's
    // Gecko renderer is pure wl_shm and doesn't touch any of these.
    _ = wlr.wlr_viewporter_create(display);

    // zwp_linux_dmabuf_v1 — GPU process buffer transport. Chromium
    // falls back to wl_shm without this, which is slow and triggers
    // an FD-mode mismatch in some chromium versions.
    _ = wlr.wlr_linux_dmabuf_v1_create_with_renderer(display, 4, renderer);

    // wp_single_pixel_buffer_v1 — solid-color fills without allocating
    // a full-size wl_shm buffer. Chromium uses it for background fills.
    _ = wlr.wlr_single_pixel_buffer_manager_v1_create(display);

    // wp_fractional_scale_v1 — HiDPI at non-integer scales (1.25, 1.5).
    // Without it chromium falls back to integer scaling — blurry text
    // on HiDPI but renders.
    _ = wlr.wlr_fractional_scale_manager_v1_create(display, 1);

    // wp_presentation — accurate frame timing for VRR + smooth
    // animations. Falls back to wl_frame_callback; functional.
    _ = wlr.wlr_presentation_create(display);

    // wp_cursor_shape_v1 — preferred cursor path for chromium M111+,
    // foot, GTK4. Otherwise clients use client-side xcursor themes.
    _ = wlr.wlr_cursor_shape_manager_v1_create(display, 1);

    // ── Protocol pack #2 — clipboard + tearing + idle inhibit ─────
    //
    // wlr_data_control_v1: wl-clipboard (wl-copy/wl-paste), cliphist,
    // clipman — all the clipboard managers depend on this to read the
    // seat clipboard without owning keyboard focus. Fire-and-forget:
    // wlroots wires it into the seat we already created.
    _ = wlr.wlr_data_control_manager_v1_create(display);

    // wp_tearing_control_v1: games + emulators opt specific surfaces
    // into tearing presents (no vsync) to lower input latency.
    // wlroots reads the per-surface hint during output commit; no
    // listener required.
    _ = wlr.wlr_tearing_control_manager_v1_create(display, 1);

    // wlr_idle_inhibit_v1: mpv, browsers, video-call clients pin an
    // inhibitor while they need the screen awake. Track live inhibitor
    // count and flip the idle notifier's inhibited flag so any idle
    // subscribers (swayidle, gammastep, loginctl) stop firing during
    // playback. The manager pointer is stored below in the returned
    // struct literal.
    const idle_inhibit_mgr = wlr.wlr_idle_inhibit_v1_create(display);

    // wlr_output_power_management_v1: DPMS. Clients (wlopm, swayidle
    // `timeout N wlr-randr --output X --off`, wdisplays) toggle
    // individual outputs on/off. We commit the requested enabled
    // state on the output.
    const output_power_mgr = wlr.wlr_output_power_manager_v1_create(display);

    // wlr_virtual_keyboard_v1 / wlr_virtual_pointer_v1 — synthetic
    // input. wtype, ydotool, wlrctl, accessibility tools. Any client
    // binding these globals can inject keys / pointer events —
    // default-on; gate behind a config field if you need to harden a
    // kiosk / shared host. wlroots handles the ABI; route the new
    // object into the existing real-device setup path via
    // handleNewVirtual*.
    const virtual_keyboard_mgr = wlr.wlr_virtual_keyboard_manager_v1_create(display);
    const virtual_pointer_mgr = wlr.wlr_virtual_pointer_manager_v1_create(display);

    // wlr_output_management_v1 — kanshi & wlr-randr & wdisplays
    // speak this. Two-phase: clients always test_configuration
    // before apply_configuration; handling only apply hangs kanshi.
    const output_manager = wlr.wlr_output_manager_v1_create(display);

    // wlr_foreign_toplevel_management_v1 — taskbars + window lists.
    // XdgView.handleMap registers a handle, XdgView.handleUnmap
    // destroys it; request_close + request_activate listeners
    // route into closeNode / focusView.
    const foreign_toplevel_mgr = wlr.wlr_foreign_toplevel_manager_v1_create(display);

    // XDG shell
    const xdg_shell = wlr.wlr_xdg_shell_create(display, 3) orelse
        return error.XdgShellCreateFailed;

    // Cursor
    const cursor = wlr.wlr_cursor_create() orelse
        return error.CursorCreateFailed;
    wlr.wlr_cursor_attach_output_layout(cursor, output_layout);

    const cursor_mgr = wlr.wlr_xcursor_manager_create(null, WmConfig.default_cursor_size) orelse
        return error.CursorMgrCreateFailed;

    // Seat
    const seat = wlr.wlr_seat_create(display, "seat0") orelse
        return error.SeatCreateFailed;

    // XKB context for keyboards
    const xkb_ctx = wlr.xkb_context_new(0) orelse
        return error.XkbContextFailed;

    // Keybinds: initialized with defaults. applyConfig() will set mod_key
    // to Super and reload, so these initial Alt defaults get overwritten.
    var keybinds = KB{};
    keybinds.loadDefaults();

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
        .xdg_activation = xdg_act,
        .xdg_decoration_mgr = xdg_deco,
        .idle_notifier = idle_notif,
        .idle_inhibit_mgr = idle_inhibit_mgr,
        .output_power_mgr = output_power_mgr,
        .virtual_keyboard_mgr = virtual_keyboard_mgr,
        .virtual_pointer_mgr = virtual_pointer_mgr,
        .output_manager = output_manager,
        .foreign_toplevel_mgr = foreign_toplevel_mgr,
    };
}

/// Register wl_signal listeners. Must be called AFTER the Server has its
/// final heap address (listeners are stored by pointer in wlroots linked lists).
fn registerListeners(self: *Server) void {
    wlr.wl_signal_add(wlr.miozu_backend_new_output(self.backend), &self.new_output);
    wlr.wl_signal_add(wlr.miozu_backend_new_input(self.backend), &self.new_input);
    wlr.wl_signal_add(wlr.miozu_xdg_shell_new_toplevel(self.xdg_shell), &self.new_xdg_toplevel);

    // xdg_activation_v1 — request_activate fires when a client asks to
    // be focused (e.g. chromium background tab opening a new window).
    if (self.xdg_activation) |xa| {
        wlr.wl_signal_add(wlr.miozu_xdg_activation_request_activate(xa), &self.xdg_activate);
    }

    // xdg-decoration-v1 — new_toplevel_decoration fires once per toplevel
    // as it's mapped. Handler forces server-side mode and is fire-and-forget;
    // no per-decoration state to track afterwards.
    if (self.xdg_decoration_mgr) |m| {
        wlr.wl_signal_add(wlr.miozu_xdg_decoration_new_toplevel_decoration(m), &self.new_xdg_decoration);
    }

    // wlr_idle_inhibit_v1 — per-client inhibitor tracking.
    if (self.idle_inhibit_mgr) |m| {
        wlr.wl_signal_add(wlr.miozu_idle_inhibit_new_inhibitor(m), &self.new_inhibitor);
    }

    // wlr_output_power_management_v1 — DPMS set_mode requests.
    if (self.output_power_mgr) |m| {
        wlr.wl_signal_add(wlr.miozu_output_power_mgr_set_mode(m), &self.output_power_set_mode);
    }

    // wlr_virtual_keyboard_v1 + wlr_virtual_pointer_v1 — synthetic input.
    if (self.virtual_keyboard_mgr) |m| {
        wlr.wl_signal_add(wlr.miozu_virtual_keyboard_mgr_new(m), &self.new_virtual_keyboard);
    }
    if (self.virtual_pointer_mgr) |m| {
        wlr.wl_signal_add(wlr.miozu_virtual_pointer_mgr_new(m), &self.new_virtual_pointer);
    }

    // wlr_output_management_v1 — apply + test listeners.
    if (self.output_manager) |m| {
        wlr.wl_signal_add(wlr.miozu_output_manager_apply(m), &self.output_manager_apply);
        wlr.wl_signal_add(wlr.miozu_output_manager_test(m), &self.output_manager_test);
    }
    wlr.wl_signal_add(wlr.miozu_cursor_motion(self.cursor), &self.cursor_motion);
    wlr.wl_signal_add(wlr.miozu_cursor_motion_absolute(self.cursor), &self.cursor_motion_absolute);
    wlr.wl_signal_add(wlr.miozu_cursor_button(self.cursor), &self.cursor_button);
    wlr.wl_signal_add(wlr.miozu_cursor_axis(self.cursor), &self.cursor_axis);
    wlr.wl_signal_add(wlr.miozu_cursor_frame(self.cursor), &self.cursor_frame);
    wlr.wl_signal_add(wlr.miozu_seat_request_set_cursor(self.seat), &self.request_set_cursor);

    // XWayland (lazy start — only spawns Xwayland process when an X11 client connects)
    if (self.wlr_compositor) |comp| {
        if (wlr.wlr_xwayland_create(self.display, comp, true)) |xwl| {
            self.xwayland = xwl;
            wlr.wl_signal_add(wlr.miozu_xwayland_new_surface(xwl), &self.new_xwayland_surface);
            wlr.wlr_xwayland_set_seat(xwl, self.seat);

            // Set DISPLAY env var so X11 clients (xterm, emacs, ...) can connect.
            // The display socket is reserved immediately by wlr_xwayland_create
            // even in lazy mode; the Xwayland process only spawns on first connect.
            if (wlr.miozu_xwayland_display_name(xwl)) |dn| {
                _ = wlr.setenv("DISPLAY", dn, 1);
                std.debug.print("teruwm: XWayland enabled (DISPLAY={s})\n", .{dn});
            } else {
                std.debug.print("teruwm: XWayland enabled\n", .{});
            }
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

    // ── Keybinds: set mod to Super (compositor), load unified defaults + media ──
    self.keybinds.mod_key = Mods.SUPER;
    self.keybinds.loadDefaults(); // uses mod_key = Super for all $mod bindings
    self.keybinds.loadMediaDefaults(); // XF86 media keys (no modifier)
    // Apply user overrides from teru.conf on top
    // (config.keybinds were parsed with the old mod — we re-load with Super)

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

    // ── User-defined spawn chords from [keybind] section ────
    self.applyWmSpawnChords();
}

/// Resolve each `[keybind] chord = spawn:cmd` entry into a spawn_table
/// slot and install the binding in the keybinds table.
fn applyWmSpawnChords(self: *Server) void {
    var slot: u8 = 0;
    for (self.wm_config.spawn_chords[0..self.wm_config.spawn_chord_count]) |*entry| {
        if (slot >= self.spawn_table.len) break;

        // Parse the chord ("Mod+Return") via the shared trigger parser
        const trig = Keybinds.parseTriggerWithMod(entry.getChord(), self.keybinds.mod_key) orelse {
            std.debug.print("teruwm: skipping bad keybind chord '{s}'\n", .{entry.getChord()});
            continue;
        };

        // Store cmd in spawn_table[slot]
        const cmd = entry.getCmd();
        const n = @min(cmd.len, self.spawn_table[slot].len);
        @memcpy(self.spawn_table[slot][0..n], cmd[0..n]);
        self.spawn_table_len[slot] = @intCast(n);

        // Map to spawn_N action
        const first_tag: u8 = @intFromEnum(Keybinds.Action.spawn_0);
        const action: Keybinds.Action = @enumFromInt(first_tag + slot);

        // Install in normal mode (shared works too but normal is the daily path)
        _ = self.keybinds.add(.normal, trig.mods, trig.key, action);
        slot += 1;
    }
    if (slot > 0) {
        std.debug.print("teruwm: loaded {d} spawn chords\n", .{slot});
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

pub fn startMcp(self: *Server) void {
    self.wm_mcp = WmMcpServer.init(self);
}

/// Reload compositor config from disk and re-apply live.
/// Called by Mod+Shift+R keybind or teruwm_reload_config MCP tool.
pub fn reloadWmConfig(self: *Server) void {
    // Re-read config file (requires io — use a dummy Io for file access)
    // Use libc fopen/fread to reload config (no Io needed)
    self.wm_config = WmConfig.loadWithLibc();

    // Re-apply bar configuration — widget layout or thresholds may
    // have changed in ways the signature hash doesn't detect
    // (widgets.count alone can't express a widget's internal fmt).
    // Force a repaint.
    if (self.bar) |b| {
        b.configure(
            self.wm_config.bar_top_left,
            self.wm_config.bar_top_center,
            self.wm_config.bar_top_right,
            self.wm_config.bar_bottom_left,
            self.wm_config.bar_bottom_center,
            self.wm_config.bar_bottom_right,
        );
        b.dirty = true;
        b.render(self);
    }

    // Apply new background color to the scene rect
    if (self.bg_rect) |rect| {
        const col = self.wm_config.bg_color;
        const rgba: [4]f32 = .{
            @as(f32, @floatFromInt((col >> 16) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((col >> 8) & 0xFF)) / 255.0,
            @as(f32, @floatFromInt(col & 0xFF)) / 255.0,
            @as(f32, @floatFromInt((col >> 24) & 0xFF)) / 255.0,
        };
        wlr.wlr_scene_rect_set_color(rect, &rgba);
    }

    // Re-arrange all workspaces with new gap
    for (0..10) |wi| {
        const ws = &self.layout_engine.workspaces[wi];
        if (ws.node_ids.items.len > 0) {
            self.arrangeworkspace(@intCast(wi));
        }
    }

    // Re-apply keymap to *every* attached keyboard so [keyboard] edits
    // take effect without reconnecting devices. Laptops typically have
    // a built-in keyboard plus one external dock keyboard — refreshing
    // only the seat's active one (which is whichever key was last hit)
    // leaves the other stuck on the old layout.
    //
    // Build the keymap once and hand the same ref to each device. wlroots
    // retains its own ref in wlr_keyboard_set_keymap, so we unref once
    // at the end.
    const new_keymap = blk: {
        if (self.wm_config.hasXkbOverrides()) {
            const names = wlr.XkbRuleNames{
                .rules = self.wm_config.getXkbRules(),
                .model = self.wm_config.getXkbModel(),
                .layout = self.wm_config.getXkbLayout(),
                .variant = self.wm_config.getXkbVariant(),
                .options = self.wm_config.getXkbOptions(),
            };
            if (wlr.xkb_keymap_new_from_names(self.xkb_ctx, &names, 0)) |km| break :blk km;
            std.debug.print("teruwm: [keyboard] config invalid on reload, keeping previous keymap\n", .{});
            break :blk null;
        }
        break :blk wlr.xkb_keymap_new_from_names(self.xkb_ctx, null, 0);
    };
    if (new_keymap) |km| {
        defer wlr.xkb_keymap_unref(km);
        for (self.keyboards.items) |kb| {
            _ = wlr.wlr_keyboard_set_keymap(kb.wlr_keyboard, km);
        }
        // Refresh the bar widget from the seat's active keyboard (or any
        // keyboard if the seat has none yet — the name is identical after
        // a bulk reapply).
        const refresh_kb = wlr.miozu_seat_get_keyboard(self.seat) orelse
            (if (self.keyboards.items.len > 0) self.keyboards.items[0].wlr_keyboard else null);
        if (refresh_kb) |rkb| self.refreshActiveKeymap(rkb);
    }

    std.debug.print("teruwm: config reloaded (gap={d}, border={d}, bg=0x{x:0>8})\n", .{ self.wm_config.gap, self.wm_config.border_width, self.wm_config.bg_color });
}

/// Hot-restart entry point. Implementation lives in ServerRestart.zig
/// (serialize + execve + FD_CLOEXEC bookkeeping). Kept as a method on
/// Server for callers that already dispatch to self.execRestart().
pub fn execRestart(self: *Server) void {
    @import("ServerRestart.zig").execRestart(self);
}

pub fn deinit(self: *Server) void {
    // Flag before teardown so any destroy-signal handler that fires
    // during wl_display_destroy (idle-inhibit trackers, etc.) skips
    // the server deref path.
    self.shutting_down = true;

    // Free every InhibitorTracker before wl_display_destroy fires
    // inhibitor destroy signals on what would then be stale state.
    // Each tracker unhooks its own listener + drops itself.
    for (self.inhibitor_trackers.items) |tracker| {
        wlr.wl_list_remove(&tracker.destroy_listener.link);
        self.zig_allocator.destroy(tracker);
    }
    self.inhibitor_trackers.deinit(self.zig_allocator);

    if (self.wm_mcp) |mcp| mcp.deinit(self.zig_allocator);

    // Remove every Server-owned wl_listener. wlroots allocates each
    // listener's list node in-place inside the signal it's attached
    // to; leaking these means the signal keeps a dangling pointer
    // into freed Server memory on the next tick.
    //
    // Listeners without a live link (link.next == null) were never
    // registered (optional protocol paths: xwayland, xdg-activation,
    // xdg-decoration).
    safeRemoveListener(&self.new_output);
    safeRemoveListener(&self.new_input);
    safeRemoveListener(&self.new_xdg_toplevel);
    safeRemoveListener(&self.xdg_activate);
    safeRemoveListener(&self.new_xdg_decoration);
    safeRemoveListener(&self.cursor_motion);
    safeRemoveListener(&self.cursor_motion_absolute);
    safeRemoveListener(&self.cursor_button);
    safeRemoveListener(&self.cursor_axis);
    safeRemoveListener(&self.cursor_frame);
    safeRemoveListener(&self.request_set_cursor);
    safeRemoveListener(&self.new_xwayland_surface);
    safeRemoveListener(&self.new_inhibitor);
    safeRemoveListener(&self.output_power_set_mode);
    safeRemoveListener(&self.new_virtual_keyboard);
    safeRemoveListener(&self.new_virtual_pointer);
    safeRemoveListener(&self.output_manager_apply);
    safeRemoveListener(&self.output_manager_test);

    // Our ArrayListUnmanaged collections. The *Output / *Keyboard
    // items themselves are owned by wlroots' destroy-chain when the
    // wl_display tears down; we only free our pointer arrays here.
    self.outputs.deinit(self.zig_allocator);
    self.keyboards.deinit(self.zig_allocator);

    wlr.xkb_context_unref(self.xkb_ctx);
}

fn safeRemoveListener(listener: *wlr.wl_listener) void {
    if (listener.link.next != null) {
        wlr.wl_list_remove(&listener.link);
    }
}

// ── Signal handlers ────────────────────────────────────────────
//
// Output attach, xdg-shell, xdg-activation, xdg-decoration,
// idle-inhibit, output-power, virtual input, output-management
// and xwayland-surface handlers live in ServerListeners.zig; the
// field defaults above reference them through the Listeners alias.
// The input device + cursor + keyboard handlers stay in this file
// (pending the ServerInput / ServerCursor splits) because they
// call private helpers here.

/// Broadcast current output state. Thin delegator — see
/// ServerListeners.pushOutputManagerState for the real work.
pub fn pushOutputManagerState(self: *Server) void {
    Listeners.pushOutputManagerState(self);
}

/// Thin delegators so both WmMcpServer (which holds a *Server) and
/// ServerListeners's virtual-keyboard handler can keep calling these
/// as methods. Real logic lives in ServerInput.
pub inline fn notifyActivity(self: *Server) void {
    Input.notifyActivity(self);
}
pub fn setupKeyboard(self: *Server, device: *wlr.wlr_input_device) void {
    Input.setupKeyboard(self, device);
}
pub fn refreshActiveKeymap(self: *Server, keyboard: *wlr.wlr_keyboard) void {
    Input.refreshActiveKeymap(self, keyboard);
}
pub fn handleKey(self: *Server, keycode: u32, xkb_state_ptr: *wlr.xkb_state) bool {
    return Input.handleKey(self, keycode, xkb_state_ptr);
}
pub fn executeAction(self: *Server, action: KBAction) bool {
    return Input.executeAction(self, action);
}

// ── Cursor delegators ─────────────────────────────────────────
//
// processCursor{Motion,Button} are called by ServerMouse (synthetic
// mouse MCP tool) and cursor listener handlers; WmMcpServer reaches
// them through test tools too. Thin pub delegators here keep the
// external API stable.

pub fn processCursorMotion(self: *Server, time: u32) void {
    Cursor.processCursorMotion(self, time);
}

pub fn processCursorButton(self: *Server, button: u32, state: u32, time: u32, super_override: ?bool) void {
    Cursor.processCursorButton(self, button, state, time, super_override);
}

// ── Push widget helpers ─────────────────────────────────────────

/// Upsert a push widget. Returns false only if all slots are full AND
/// no existing slot has the given name. Updates are O(n≤32).
pub fn setPushWidget(self: *Server, name: []const u8, text: []const u8, class: teru.render.PushWidget.Class) bool {
    if (name.len == 0) return false;

    var empty_slot: ?*teru.render.PushWidget.PushWidget = null;
    for (&self.push_widgets) |*pw| {
        if (pw.used and std.mem.eql(u8, pw.name(), name)) {
            writeWidgetText(pw, text, class);
            self.scheduleRender();
            return true;
        }
        if (!pw.used and empty_slot == null) empty_slot = pw;
    }

    const slot = empty_slot orelse return false;
    const n_n = @min(name.len, slot.name_buf.len);
    @memcpy(slot.name_buf[0..n_n], name[0..n_n]);
    slot.name_len = @intCast(n_n);
    slot.used = true;
    writeWidgetText(slot, text, class);
    self.scheduleRender();
    return true;
}

fn writeWidgetText(slot: *teru.render.PushWidget.PushWidget, text: []const u8, class: teru.render.PushWidget.Class) void {
    const t_n = @min(text.len, slot.text_buf.len);
    @memcpy(slot.text_buf[0..t_n], text[0..t_n]);
    slot.text_len = @intCast(t_n);
    slot.class = class;
    slot.last_update_ns = @intCast(teru.compat.monotonicNow());
}

/// Remove a push widget by name. Returns true if found and removed.
pub fn deletePushWidget(self: *Server, name: []const u8) bool {
    for (&self.push_widgets) |*pw| {
        if (pw.used and std.mem.eql(u8, pw.name(), name)) {
            pw.used = false;
            pw.name_len = 0;
            pw.text_len = 0;
            self.scheduleRender();
            return true;
        }
    }
    return false;
}

/// Count currently-registered widgets. Used by teruwm_list_widgets.
pub fn countPushWidgets(self: *const Server) usize {
    var n: usize = 0;
    for (&self.push_widgets) |*pw| if (pw.used) { n += 1; };
    return n;
}

/// Ask wlroots to fire a frame callback on the primary output. Used after
/// any push-widget update so the bar paints the new value without waiting
/// for the next vsync on a dirty terminal pane.
/// Schedule a frame on every connected output. A pane on workspace K is
/// only visible on the output showing K, but with <=4 outputs in practice
/// iterating is trivial and avoids the "non-primary pane didn't repaint"
/// class (resize on a pane owned by output #2 otherwise waited for an
/// unrelated frame). Falls back to primary_output during the init window
/// before outputs[] populates.
pub fn scheduleRender(self: *Server) void {
    if (self.outputs.items.len > 0) {
        for (self.outputs.items) |o| {
            wlr.wlr_output_schedule_frame(o.wlr_output);
        }
    } else if (self.primary_output) |out| {
        wlr.wlr_output_schedule_frame(out);
    }
}


/// Un-float the focused node. Delegates to ServerLayout.zig.
pub fn sinkFocused(self: *Server) void {
    @import("ServerLayout.zig").sinkFocused(self);
}

/// Sink all floating nodes on the active workspace. Delegates.
pub fn sinkAllOnActiveWorkspace(self: *Server) void {
    @import("ServerLayout.zig").sinkAllOnActiveWorkspace(self);
}

// ── Tiling ─────────────────────────────────────────────────────

/// Arrange all nodes on a workspace according to its layout. Delegates.
pub fn arrangeworkspace(self: *Server, ws_index: u8) void {
    @import("ServerLayout.zig").arrangeWorkspace(self, ws_index);
}

/// Drag-feedback arrange — reposition scene buffers without grid
/// resize. Used during interactive resize drag. Delegates.
pub fn arrangeWorkspaceSmooth(self: *Server, ws_index: u8) void {
    @import("ServerLayout.zig").arrangeWorkspaceSmooth(self, ws_index);
}

/// Focus a view — activate its toplevel and send keyboard focus.
///
/// The keyboard-enter target surface matters more than you'd think:
/// Chromium (and all GTK/Qt toolkits that use subsurfaces for content)
/// only propagates keyboard focus to DOM / widget input elements when
/// the wl_keyboard.enter surface matches the surface the *pointer*
/// last entered. If we pass the xdg_toplevel's *root* surface, Chromium
/// dispatches the JS click event (so Doodle navigation works), but
/// `document.activeElement` stays on <body> — typing has nowhere to go.
/// That was the user-visible "can't interact with chrome" bug.
///
/// Fix: prefer the last pointer-entered leaf (captured by
/// processCursorMotion into `last_pointer_surface`). Fall back to the
/// xdg root only if the cached leaf belongs to a different client
/// (stale cache, or the pointer wandered onto a different window
/// between the click and now).
///
/// Keyboard-enter must also include live modifier state — else Chrome
/// sees keys with Shift/Ctrl marked up when they're physically held.
pub fn focusView(self: *Server, view: *XdgView) void {
    @import("ServerFocus.zig").focusView(self, view);
}

// ── Terminal pane management ───────────────────────────────────

/// Spawn an embedded terminal pane on the given workspace, sized to fill the output.
pub fn spawnTerminal(self: *Server, ws: u8) void {
    // Create at default size — arrangeworkspace will resize to fit the layout
    const tp = TerminalPane.create(self, ws, 24, 80) orelse {
        std.debug.print("teruwm: failed to spawn terminal pane\n", .{});
        return;
    };

    // Store in terminal_panes array FIRST (before arrangeworkspace)
    for (&self.terminal_panes) |*slot| {
        if (slot.* == null) {
            slot.* = tp;
            self.terminal_count += 1;
            break;
        }
    }

    // NOW arrange — all panes including the new one are findable
    self.arrangeworkspace(ws);

    // Focus the new terminal
    self.focused_terminal = tp;
    self.focused_view = null;

    // Re-render all panes (borders update for new focus)
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |t| t.render();
    }
    if (self.bar) |b| b.render(self);
}

// ── Clipboard (internal buffer for Ctrl+Shift+C/V) ───────────

/// Copy the cursor line from a terminal pane into the internal clipboard buffer.
/// Extracts the full line at the cursor row, trimming trailing whitespace.
pub fn clipboardCopyCursorLine(self: *Server, tp: *TerminalPane) void {
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
pub fn clipboardPaste(self: *Server, tp: *TerminalPane) void {
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

pub fn renderLauncherBar(self: *Server) void {
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
pub fn setWorkspaceVisibility(self: *Server, ws: u8, visible: bool) void {
    const ws_nodes = self.layout_engine.workspaces[ws].node_ids.items;
    for (ws_nodes) |nid| {
        // Terminal panes
        if (self.terminalPaneById(nid)) |tp| tp.setVisible(visible);
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
pub fn toggleFloat(self: *Server) void {
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
        const dims_c = self.activeOutputDims();
        const out_w: u32 = dims_c.w;
        const out_h: u32 = dims_c.h;
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

/// Toggle the focused node (terminal OR Wayland client) to fill the
/// entire output. Before v0.5.1 this bailed early for xdg views because
/// it only read `focused_terminal` — so Mod+F did nothing on Chrome /
/// Firefox / any native-Wayland client. Now resolves the target via
/// focused_terminal OR focused_view and expands either one.
pub fn toggleFullscreen(self: *Server) void {
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
    // Target = focused terminal OR focused xdg view. Either way we
    // expand its node to the full output.
    const target_id: u64 = if (self.focused_terminal) |tp|
        tp.node_id
    else if (self.focused_view) |v|
        v.node_id
    else
        return;

    self.fullscreen_node = target_id;

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

    // Hide everything except the fullscreened node. recomputeVisibility
    // now observes fullscreen_node as an override, so one O(N) pass
    // covers terminals + xdg views on every output — no double loop.
    self.recomputeVisibility();

    // Expand focused pane to fill entire output (no bar, no gaps).
    // For terminals we also resize the SW renderer framebuffer so the
    // cell grid expands to match; for xdg clients, applyRect sends the
    // xdg_toplevel_set_size configure.
    const dims_fs = self.activeOutputDims();
    const out_w: u32 = dims_fs.w;
    const out_h: u32 = dims_fs.h;
    if (self.focused_terminal) |tp| {
        tp.resize(out_w, out_h);
        tp.setPosition(0, 0);
    } else if (self.nodes.findById(target_id)) |slot| {
        self.nodes.applyRect(slot, 0, 0, out_w, out_h);
    }

    std.debug.print("teruwm: fullscreen on node={d}\n", .{target_id});
}

// ── Scratchpads (xmonad NamedScratchpad model) ────────────────
//
// A scratchpad is a regular pane with a stable string identity and
// floating placement. Its NodeRegistry slot's workspace toggles
// between NodeRegistry.HIDDEN_WS (parked, not rendered) and the
// currently-focused workspace (visible, floating on top). Zero
// parallel data structures — lookup is findByScratchpad(name).
//
// xmonad equivalent: NamedScratchpad with (name, spawn, query, hook).
//   name   → node's scratchpad_name
//   spawn  → a default shell today; future: WmConfig.scratchpads[name] cmd
//   query  → findByScratchpad(name) replaces class/title matching
//   hook   → per-scratchpad rect from WmConfig (future) or default 35×40% center

/// Toggle a named scratchpad. Delegates to ServerScratchpad.zig.
pub fn toggleScratchpadByName(self: *Server, name: []const u8, default_cmd: ?[]const u8) void {
    @import("ServerScratchpad.zig").toggleByName(self, name, default_cmd);
}

/// Numbered compatibility shim — N maps to named scratchpad padN+1.
pub fn toggleScratchpad(self: *Server, index: u8) void {
    @import("ServerScratchpad.zig").toggleNumbered(self, index);
}

// ── Terminal lifecycle ─────────────────────────────────────────

/// Handle terminal pane exit (shell process died).
/// Close a window (terminal pane or XDG view) by node_id.
/// Returns true if a window was closed.
/// Hit-test: return the node_id of the pane whose rect contains (x, y),
/// or null. Floating panes win over tiled because they render on top in
/// the scene graph. Linear scan — fine given the node count budget.
pub fn nodeAtPoint(self: *const Server, x: f64, y: f64) ?u64 {
    var best_floating: ?u64 = null;
    var best_tiled: ?u64 = null;
    const ix: i32 = @intFromFloat(x);
    const iy: i32 = @intFromFloat(y);
    const cur_ws = self.layout_engine.active_workspace;

    for (0..NodeRegistry.max_nodes) |slot| {
        if (self.nodes.kind[slot] == .empty) continue;
        if (self.nodes.workspace[slot] != cur_ws) continue;
        const px = self.nodes.pos_x[slot];
        const py = self.nodes.pos_y[slot];
        const pw: i32 = @intCast(self.nodes.width[slot]);
        const ph: i32 = @intCast(self.nodes.height[slot]);
        if (ix < px or ix >= px + pw) continue;
        if (iy < py or iy >= py + ph) continue;
        if (self.nodes.floating[slot]) {
            best_floating = self.nodes.node_id[slot];
        } else {
            best_tiled = self.nodes.node_id[slot];
        }
    }
    return best_floating orelse best_tiled;
}

/// Dimensions of the currently-focused output (or first connected if
/// no focus yet). Replaces miozu_output_layout_first_* which always
/// returned the first output in layout order — wrong under multi-head
/// for callers that mean "the output the user is looking at".
///
/// Returns 1920×1080 fallback when no outputs are connected (same as
/// the previous glue helper). Several callers do (w - x)/2 arithmetic
/// that would underflow u32 at w=0; 1920×1080 is the "drawing on a
/// virtual display" best guess.
pub fn activeOutputDims(self: *const Server) struct { w: u32, h: u32 } {
    const out: *wlr.wlr_output = if (self.focused_output) |o|
        o.wlr_output
    else if (self.outputs.items.len > 0)
        self.outputs.items[0].wlr_output
    else
        return .{ .w = 1920, .h = 1080 };
    return .{
        .w = @intCast(@max(1, wlr.miozu_output_width(out))),
        .h = @intCast(@max(1, wlr.miozu_output_height(out))),
    };
}

/// Find the TerminalPane with the given node_id. Still O(n) over the
/// fixed-size array, but keeps the lookup in one place — callers that
/// only need a node_id → *TerminalPane mapping shouldn't hand-roll the
/// nested slot/tp scan.
pub fn terminalPaneById(self: *const Server, node_id: u64) ?*TerminalPane {
    for (self.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            if (tp.node_id == node_id) return tp;
        }
    }
    return null;
}

/// Null every Server pointer that references the node being torn down.
/// Call BEFORE freeing the pane / view — a reentrant render or any code
/// that dereferences focused_terminal / focused_view touches freed memory
/// otherwise. `last_pointer_surface` is handled by the View's unmap/
/// destroy handlers since it's keyed on wlr_surface, not node_id.
pub fn clearFocusRefs(self: *Server, node_id: u64) void {
    @import("ServerFocus.zig").clearFocusRefs(self, node_id);
}

pub fn closeNode(self: *Server, node_id: u64) bool {
    // Try terminal pane first
    for (&self.terminal_panes, 0..) |*slot, i| {
        _ = i;
        if (slot.*) |tp| {
            if (tp.node_id == node_id) {
                const ws = if (self.nodes.findById(node_id)) |s| self.nodes.workspace[s] else self.layout_engine.active_workspace;
                self.layout_engine.workspaces[ws].removeNode(node_id);
                if (self.nodes.findById(node_id)) |_| _ = self.nodes.remove(node_id);

                self.clearFocusRefs(node_id);

                tp.deinit(self.zig_allocator);
                self.zig_allocator.destroy(tp);
                slot.* = null;
                self.terminal_count -|= 1;
                self.arrangeworkspace(ws);
                self.updateFocusedTerminal();
                if (self.bar) |b| b.render(self);
                return true;
            }
        }
    }

    // XDG view: find the view with matching node_id and send close request.
    // Defensive: the view may already be gone (the client crashed /
    // unmapped between the MCP caller's list_windows and this call);
    // dereferencing view.toplevel then feeds a dead wl_resource to
    // wl_resource_post_event, which aborts. Cross-check NodeRegistry
    // before touching the toplevel.
    if (self.focused_view) |view| {
        if (view.node_id == node_id and self.nodes.findById(node_id) != null) {
            self.clearFocusRefs(node_id);
            wlr.wlr_xdg_toplevel_send_close(view.toplevel);
            return true;
        }
    }
    // Search all XDG views for node_id match (walk the scene? no tracking, so
    // we need to iterate differently). For now, handle only focused_view —
    // MCP callers close by node_id through NodeRegistry instead.
    return false;
}

/// Close whatever window is currently focused (terminal pane or XDG view).
/// Bound to Win+X. No-op if nothing focused.
pub fn closeFocused(self: *Server) void {
    if (self.focused_view) |view| {
        self.clearFocusRefs(view.node_id);
        std.debug.print("teruwm: closeFocused → xdg view node={d}\n", .{view.node_id});
        wlr.wlr_xdg_toplevel_send_close(view.toplevel);
        return;
    }
    if (self.focused_terminal) |tp| {
        std.debug.print("teruwm: closeFocused → terminal node={d}\n", .{tp.node_id});
        _ = self.closeNode(tp.node_id);
        return;
    }
    // Neither focused_terminal nor focused_view — telemetry for the
    // "can't close last pane" symptom. Either focus is stale (action
    // dispatched before updateFocusedTerminal ran after the previous
    // close) or the workspace is legitimately empty. Print the state
    // so we can see which one it is in live logs.
    const ws = self.layout_engine.getActiveWorkspace();
    std.debug.print(
        "teruwm: closeFocused with no focus — ws={d} tiled_count={d} terminal_count={d}\n",
        .{ self.layout_engine.active_workspace, ws.node_ids.items.len, self.terminal_count },
    );
}

pub fn handleTerminalExit(self: *Server, tp: *TerminalPane) void {
    std.debug.print("teruwm: terminal exited node={d}\n", .{tp.node_id});

    self.clearFocusRefs(tp.node_id);

    // Remove from node registry and tiling engine
    _ = self.nodes.remove(tp.node_id);
    for (&self.layout_engine.workspaces) |*ws| {
        ws.removeNode(tp.node_id);
    }

    // DynamicProjects: if this empties any workspace, reset its
    // startup-fired flag so the next visit re-runs its startup hook.
    for (0..10) |ws_i| self.resetWorkspaceStartupIfEmpty(@intCast(ws_i));

    // Remove event source
    if (tp.event_source) |es| {
        _ = wlr.wl_event_source_remove(es);
        tp.event_source = null;
    }

    // Hide scene buffer
    if (wlr.miozu_scene_buffer_node(tp.scene_buffer)) |node| {
        wlr.wlr_scene_node_set_enabled(node, false);
    }

    // Remove from terminal_panes array. Scratchpads since v0.4.18 live
    // here too (they're regular panes with a scratchpad_name tag) —
    // single loop covers both cases.
    for (&self.terminal_panes) |*slot| {
        if (slot.* == tp) {
            slot.* = null;
            self.terminal_count -= 1;
            break;
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
///
/// Prefer `ws.active_node` over `getActiveNodeId()`: floating panes are
/// removed from `node_ids.items` (the tiled list) so `getActiveNodeId`
/// can't see them. `active_node` is the explicit authoritative focus
/// target set by `teruwm_focus_window` and friends — it works for both
/// tiled and floating panes.
pub fn updateFocusedTerminal(self: *Server) void {
    @import("ServerFocus.zig").updateFocusedTerminal(self);
}

// ── Multi-output: the 3-rule architecture (v0.4.20) ──────────
//
// R1: Node.workspace is identity (already in NodeRegistry).
// R2: Output.workspace is a viewport (stored per-Output).
// R3: Visibility is derived via recomputeVisibility().
//
// All workspace-level mutations go through focusWorkspace (viewport)
// or moveNodeToWorkspace (identity). Call recomputeVisibility after
// each mutation — it's O(max_nodes), sub-microsecond, no allocation.

/// Which workspace the focused output currently shows. Shim for
/// legacy call sites that read `layout_engine.active_workspace`.
pub fn activeWorkspace(self: *const Server) u8 {
    if (self.focused_output) |out| return out.workspace;
    return self.layout_engine.active_workspace;
}

/// Return the output currently showing `ws`, if any. Null means the
/// workspace is orphaned (nodes on it stay hidden until some output
/// takes it). Multi-output invariant: at most one output per ws.
pub fn outputShowing(self: *const Server, ws: u8) ?*Output {
    for (self.outputs.items) |out| {
        if (out.workspace == ws) return out;
    }
    return null;
}

/// **The only mutation path for Output.workspace.** Handles xmonad
/// pull-swap: if `target` is already visible on another output, that
/// output takes the focused output's previous workspace. All four
/// cases (identity, collision, no-op, first-show) live in one path.
pub fn focusWorkspace(self: *Server, target: u8) void {
    @import("ServerFocus.zig").focusWorkspace(self, target);
}

/// Move a node (pane or Wayland client) to a different workspace.
/// Orthogonal to Output.workspace: just flips Node.workspace, then
/// recomputes visibility and re-arranges affected outputs.
pub fn moveNodeToWorkspace(self: *Server, nid: u64, target: u8) void {
    if (target >= 10) return;
    const slot = self.nodes.findById(nid) orelse return;
    const from = self.nodes.workspace[slot];
    if (from == target) return;

    // If the node we're moving was the focused terminal and the target
    // workspace isn't visible anywhere, the pane becomes invisible —
    // we must drop focus so subsequent keystrokes don't silently feed
    // an off-screen PTY. updateFocusedTerminal (called below) picks a
    // new focus target on the now-visible workspace.
    const was_focused_nid = if (self.focused_terminal) |tp| tp.node_id else 0;
    const was_focused = (was_focused_nid == nid);

    // Update node identity. Workspace list bookkeeping: remove from old
    // node_ids (if it was tiled there), add to new.
    self.nodes.moveSlotToWorkspace(slot, target);
    self.layout_engine.workspaces[from].removeNode(nid);
    if (!self.nodes.floating[slot]) {
        self.layout_engine.workspaces[target].addNode(self.zig_allocator, nid) catch |e| {
            std.debug.print("teruwm: moveNodeToWorkspace addNode failed: {s}\n", .{@errorName(e)});
        };
    }

    // Re-arrange every output showing either ws (cheap: N ≤ 4).
    for (self.outputs.items) |out| {
        if (out.workspace == from or out.workspace == target) {
            self.arrangeworkspace(out.workspace);
        }
    }
    self.recomputeVisibility();

    if (was_focused) {
        // Focused pane moved. If target workspace isn't shown anywhere,
        // the pane is now invisible; refresh focus to whatever's on the
        // current workspace instead (or null if empty).
        if (self.outputShowing(target) == null) {
            self.focused_terminal = null;
            self.updateFocusedTerminal();
        }
    }
    self.emitMcpEventKind("node_moved", ",\"node_id\":{d},\"from\":{d},\"to\":{d}", .{ nid, from, target });
}

/// Rule 3: a node renders iff some output currently shows its
/// workspace. Called after any R1 or R2 mutation. Single-output
/// case: identical to the legacy setWorkspaceVisibility toggle.
pub fn recomputeVisibility(self: *Server) void {
    for (0..NodeRegistry.max_nodes) |i| {
        if (self.nodes.kind[i] == .empty) continue;
        const ws = self.nodes.workspace[i];
        if (ws == NodeRegistry.HIDDEN_WS) {
            self.setSlotVisible(@intCast(i), false);
            continue;
        }
        // Fullscreen takes precedence: every node but the fullscreened
        // one is hidden, regardless of which output shows its workspace.
        if (self.fullscreen_node) |fs_nid| {
            self.setSlotVisible(@intCast(i), self.nodes.node_id[i] == fs_nid);
            continue;
        }
        const visible = self.outputShowing(ws) != null;
        self.setSlotVisible(@intCast(i), visible);
    }
}

fn setSlotVisible(self: *Server, slot: u16, visible: bool) void {
    // Terminal panes: iterate terminal_panes array by node_id match.
    if (self.nodes.kind[slot] == .terminal) {
        const nid = self.nodes.node_id[slot];
        for (self.terminal_panes) |maybe_tp| {
            if (maybe_tp) |tp| {
                if (tp.node_id == nid) {
                    tp.setVisible(visible);
                    return;
                }
            }
        }
    }
    if (self.nodes.kind[slot] == .wayland_surface) {
        if (self.nodes.scene_tree[slot]) |tree| {
            if (wlr.miozu_scene_tree_node(tree)) |node| {
                wlr.wlr_scene_node_set_enabled(node, visible);
            }
        }
    }
}

/// Cycle focus to the next connected output (keybind action).
pub fn focusNextOutput(self: *Server) void {
    @import("ServerFocus.zig").focusNextOutput(self);
}

/// Move the focused node to the next output's current workspace.
pub fn moveFocusedToNextOutput(self: *Server) void {
    @import("ServerFocus.zig").moveFocusedToNextOutput(self);
}

// ── MCP event emission (v0.4.18) ─────────────────────────────
//
// Thin convenience forwarder — every call site uses the same pattern
// (has an event subscriber? push one JSON line). Keeping the shape
// centralized here means future events get one place to edit, not a
// dozen inlined writes.

pub fn emitMcpEventKind(self: *Server, kind: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (self.wm_mcp) |mcp| mcp.emitEventKind(kind, fmt, args);
}

/// DynamicProjects (v0.4.17). If the workspace we're switching into
/// is empty and has a `startup` command configured, spawn it. The
/// flag tracks "has fired at least once since the workspace last
/// became empty" so revisits during the same session don't re-spawn.
/// When the workspace empties (last pane closed), the flag resets so
/// a fresh visit re-fires (xmonad-ish).
pub fn maybeFireWorkspaceStartup(self: *Server, ws: u8) void {
    if (ws >= 10) return;
    const cmd = self.wm_config.workspace_startup[ws] orelse return;
    if (self.wm_config.workspace_startup_fired[ws]) return;
    if (self.nodes.countInWorkspace(ws) > 0) return;
    self.wm_config.workspace_startup_fired[ws] = true;
    self.spawnShell(cmd);
}

/// Reset the startup-fired flag for a workspace (call when its count
/// drops to zero) so the next visit re-runs the startup hook.
pub fn resetWorkspaceStartupIfEmpty(self: *Server, ws: u8) void {
    if (ws >= 10) return;
    if (self.nodes.countInWorkspace(ws) == 0) {
        self.wm_config.workspace_startup_fired[ws] = false;
    }
}

/// Apply wm_config.unfocused_opacity to every terminal pane's buffer.
/// Delegates to ServerFocus.zig.
pub fn applyFocusOpacity(self: *Server) void {
    @import("ServerFocus.zig").applyFocusOpacity(self);
}

// ── Process spawning ───────────────────────────────────────────

/// Spawn a shell command detached from the compositor (double-fork to avoid zombies).
/// Uses /bin/sh -c to handle commands with arguments and pipes. Inherits the
/// compositor's environment so children see WAYLAND_DISPLAY, DISPLAY (Xwayland),
/// HOME, etc.
pub fn spawnProcess(_: *Server, cmd: [*:0]const u8) void {
    const pid = std.os.linux.fork();
    if (pid == 0) {
        const pid2 = std.os.linux.fork();
        if (pid2 == 0) {
            // Grandchild: exec via shell to handle args/pipes
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            _ = std.posix.system.execve("/bin/sh", &argv, @ptrCast(envp));
            std.os.linux.exit(1);
        }
        std.os.linux.exit(0);
    }
    if (pid > 0) {
        _ = std.c.waitpid(@intCast(pid), null, 0);
    }
}

/// Same as `spawnProcess` but takes a non-nul-terminated slice. Copies into
/// a stack buffer and nul-terminates. Commands longer than 511 bytes are
/// truncated (matches the config parser's bound).
pub fn spawnShell(self: *Server, cmd: []const u8) void {
    var buf: [512:0]u8 = undefined;
    const n = @min(cmd.len, buf.len);
    @memcpy(buf[0..n], cmd[0..n]);
    buf[n] = 0;
    self.spawnProcess(@ptrCast(&buf));
}

/// Shell-spawn screenshot. Delegates to ServerScreenshot.zig.
pub fn takeScreenshot(self: *Server) void {
    @import("ServerScreenshot.zig").takeScreenshot(self);
}

/// Named-path screenshot. Public because WmMcpServer.teruwm_screenshot
/// calls it through self.server.takeScreenshotToPath. Delegates.
pub fn takeScreenshotToPath(self: *Server, path: []const u8) bool {
    return @import("ServerScreenshot.zig").takeScreenshotToPath(self, path);
}

// ── Helper ─────────────────────────────────────────────────────

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{
        .link = .{ .prev = null, .next = null },
        .notify = func,
    };
}
