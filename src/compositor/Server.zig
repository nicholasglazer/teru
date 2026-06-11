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
const LeaderKey = @import("LeaderKey.zig");
const Bar = @import("Bar.zig");
const WmConfig = @import("WmConfig.zig");
const WmMcpServer = @import("WmMcpServer.zig");
const NodeRegistry = @import("Node.zig");
const Listeners = @import("ServerListeners.zig");
const Input = @import("ServerInput.zig");
const Cursor = @import("ServerCursor.zig");
const ServerClipboard = @import("ServerClipboard.zig");
const Focus = @import("ServerFocus.zig");
const Layout = @import("ServerLayout.zig");
const Scratchpad = @import("ServerScratchpad.zig");
const Restart = @import("ServerRestart.zig");
const Screenshot = @import("ServerScreenshot.zig");
const Process = @import("ServerProcess.zig");
const Repeat = @import("ServerRepeat.zig");
const Config = @import("ServerConfig.zig");
const Window = @import("ServerWindow.zig");
const teru = @import("teru");
const LayoutEngine = teru.LayoutEngine;
const Keybinds = teru.Keybinds;
const Mods = Keybinds.Mods;
const KB = Keybinds.Keybinds;
const KBAction = Keybinds.Action;
const KBMods = Keybinds.Mods;

const Server = @This();

pub const CursorMode = enum { normal, move, resize, border_drag, area_select };

/// A desktop notification forwarded in from a freedesktop.org D-Bus helper
/// (see tools/teruwm-notify-daemon) via the `teruwm_notify` MCP tool, or
/// pushed directly by any MCP client. teruwm owns the presentation: the
/// `{notify}` bar widget marquee-scrolls the text while one is active.
///
/// Zero-alloc fixed buffers — mirrors PushWidget's storage policy. At most
/// one notification shows at a time (newest wins); a richer stack can come
/// later. `received_ns` is a monotonic stamp; `timeout_ms == 0` means "use
/// the renderer default" (treated as 5000 ms by the expiry check).
pub const Notification = struct {
    pub const Urgency = enum(u8) { low, normal, critical };

    app_buf: [32]u8 = undefined,
    app_len: u8 = 0,
    summary_buf: [96]u8 = undefined,
    summary_len: u8 = 0,
    body_buf: [160]u8 = undefined,
    body_len: u8 = 0,
    urgency: Urgency = .normal,
    received_ns: i64 = 0,
    timeout_ms: u32 = 0,

    pub fn app(self: *const Notification) []const u8 {
        return self.app_buf[0..self.app_len];
    }
    pub fn summary(self: *const Notification) []const u8 {
        return self.summary_buf[0..self.summary_len];
    }
    pub fn body(self: *const Notification) []const u8 {
        return self.body_buf[0..self.body_len];
    }

    /// Effective lifetime in nanoseconds. A 0/critical timeout is clamped
    /// to a sane default so a notification can never wedge the bar's fast
    /// tick on permanently (which would be a CPU-drain regression).
    pub fn lifetimeNs(self: *const Notification) i64 {
        const ms: i64 = if (self.timeout_ms == 0) 5000 else @min(self.timeout_ms, 60_000);
        return ms * std.time.ns_per_ms;
    }

    pub fn expired(self: *const Notification, now_ns: i64) bool {
        return now_ns -| self.received_ns >= self.lifetimeNs();
    }

    pub fn urgencyFromString(s: []const u8) Urgency {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "critical")) return .critical;
        return .normal; // default + "normal"
    }
};

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
font_size: u16 = 16, // live font size — mutated by Alt+scroll zoom (ServerFont)
font_size_base: u16 = 16, // config font size — the `.reset` zoom target
// Terminal-rendering settings fed from teru.conf (populated in
// ServerConfig.applyConfig). Native panes used to render with libteru struct
// defaults (Miozu palette, block cursor, 10000-line scrollback) regardless of
// the user's teru.conf; these carry the configured values into every
// TerminalPane. color_scheme is value-only (safe to copy); spawn_config's
// shell/term slices point into the process-lifetime Config (main.zig:47).
color_scheme: teru.Config.ColorScheme = .{},
spawn_config: teru.Pane.SpawnConfig = .{},
// Visual margin between a pane's edge and its text — config.padding, default
// 8px, same key + meaning as windowed teru. Applied via renderer.padding (the
// pane buffer is the full tile rect, so there's room); margins fill with the
// terminal bg, identical to the windowed path.
terminal_padding: u32 = 8,
// Optional bold/italic font variants (config.font_{bold,italic,bold_italic}).
// Owned here for the process lifetime; null → that weight falls back to the
// regular atlas. Their `.data` is handed to each pane renderer.
font_variant_bold: ?teru.render.FontAtlas.VariantAtlas = null,
font_variant_italic: ?teru.render.FontAtlas.VariantAtlas = null,
font_variant_bold_italic: ?teru.render.FontAtlas.VariantAtlas = null,
next_node_id: u64 = 1,
focused_view: ?*XdgView = null,
focused_terminal: ?*TerminalPane = null,
// Last xcursor name we pushed to wlr_cursor. Tracks whether the next
// motion event actually needs a wlr_cursor_set_xcursor call. Without
// this cache, hovering over a teruwm-native terminal pane calls
// set_xcursor("default") on every motion packet — wlroots then
// re-configures the cursor image + re-damages the output at mouse
// rate, which on real hardware shows as visible flicker near the
// cursor position. "" means "not yet set".
last_xcursor_name: []const u8 = "",

// Terminal pane currently being drag-selected (mouse_down over a
// native terminal). Cleared on release. Non-null while a drag is in
// progress so motion events continue updating the pane's Selection
// even if the cursor wanders outside the pane bounds.
drag_terminal: ?*TerminalPane = null,
// XWayland (Emacs, Steam, GIMP) focus target. Lives alongside
// focused_view because an xwayland_surface isn't an XdgView and we
// don't want to fake one just to fit the existing XOR invariant.
// Exactly one of focused_terminal, focused_view, focused_xwayland is
// non-null at any time — focus helpers null the other two.
focused_xwayland: ?*wlr.wlr_xwayland_surface = null,
terminal_panes: [NodeRegistry.max_nodes]?*TerminalPane = @splat(null),
terminal_count: u16 = 0,
/// node_id → *TerminalPane index. Rebuilt by spawn/close; read by
/// terminalPaneById + setSlotVisible so visibility recomputation
/// doesn't scan 256 slots per node. Empty pane_index entries are
/// fine — ghostly stale entries are prevented by every close path
/// routing through the unset path here.
pane_index: std.AutoHashMapUnmanaged(u64, *TerminalPane) = .empty,
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

outputs: std.ArrayList(*Output) = .empty,
focused_output: ?*Output = null,
workspace_trees: [10]?*wlr.wlr_scene_tree = @splat(null),

// Active XKB layout name (for the {keymap} bar widget).
// Stored as a static buffer because the xkb string can outlive
// the keymap it came from between reads.
active_keymap_name_buf: [64]u8 = @splat(0),
active_keymap_name: []const u8 = "",

// Every keyboard device seen via setupKeyboard. Append-only while the
// compositor runs — used to re-apply keymaps to *every* attached device
// on config reload (laptop + external dock is the common case). We
// don't remove on unplug today because Keyboard never frees itself;
// stale entries would dereference a dead `wlr_keyboard`. Wiring device-
// destroy listeners + removal is the next step if/when unplug matters.
keyboards: std.ArrayList(*Input.Keyboard) = .empty,

// Diagnostic only — tracks the last surface pointer notify_enter was
// called with, so motion logging can print only on transitions instead
// of every motion event. Not authoritative.
last_pointer_surface: ?*wlr.wlr_surface = null,

/// FixedBufferAllocator-backed scratch for layout_engine.calculate.
/// LayoutEngine allocates a []Rect per call (masterStackN / grid /
/// etc. all end with a `try self.allocator.alloc(Rect, count)`). On
/// border-drag that's 60 heap allocs/sec; during Mod+drag float it's
/// more. With a 16 KiB FBA we cover up to 1024 panes of Rect and
/// arrangeworkspace's outer ArrayList still falls back to
/// the general allocator for tree layouts / edge cases.
arrange_scratch_buf: [16 * 1024]u8 = undefined,

/// Push widgets registered via MCP. Referenced by bar format strings
/// with `{widget:name}`. Fixed-size array; slot 0..N with `.used=false`
/// are empty. No heap allocation. Not persisted across hot-restart.
push_widgets: [teru.render.PushWidget.max_widgets]teru.render.PushWidget.PushWidget = @splat(.{}),
/// Count of `push_widgets[i].used == true`. Maintained incrementally
/// by setPushWidget / deletePushWidget so barSignature and
/// countPushWidgets are O(1).
push_widget_count: u8 = 0,

/// Currently-shown desktop notification (null = none). Filled by
/// setNotification (driven by the `teruwm_notify` MCP tool, which the
/// freedesktop.org D-Bus helper forwards into). The `{notify}` bar
/// widget reads this and marquee-scrolls it; barTick clears it on expiry
/// and reverts the fast tick. Not persisted across hot-restart.
current_notification: ?Notification = null,
/// Marquee scroll offset (in cells) for the active notification. Advanced
/// by barTick while a notification is live; reset to 0 on each new one.
notify_scroll: u32 = 0,

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
/// Accumulated touchpad axis delta for Alt+scroll font zoom. A touchpad
/// gesture fires dozens of small axis events; stepping the font on each one
/// made zoom wildly over-sensitive. We accumulate here and step once per
/// `zoom_units_per_step` of travel (wheel notches bypass this — one step each).
zoom_accum: f64 = 0,

// Native area-select (mod+ctrl+w): drag a box over the composited output,
// crop on release. area_rect is the live translucent overlay scene node.
area_dragging: bool = false,
area_anchor_x: f64 = 0,
area_anchor_y: f64 = 0,
area_rect: ?*wlr.wlr_scene_rect = null,
// Four edge rects (top, bottom, left, right) forming a crisp border frame
// around area_rect's translucent fill — the Figma-style selection look.
// Created/destroyed alongside area_rect.
area_border: [4]?*wlr.wlr_scene_rect = .{ null, null, null, null },

// Internal clipboard buffer (Ctrl+Shift+C/V between terminal panes).
// Sized to match the seat-published selection (Selection.getText's 64 KiB
// cap) so a native-pane self-paste delivers the SAME bytes a foreign app
// pasting the same selection would get — the old 8 KiB mirror silently
// truncated self-pastes, possibly mid-UTF-8.
clipboard_buf: [65536]u8 = undefined,
clipboard_len: usize = 0,

// In-flight async paste from a foreign data source (ServerClipboard):
// pipe read end watched on the event loop, accumulated until EOF, then
// delivered to the pane identified by paste_target_node. Drained in
// deinit via ServerClipboard.cancelInflight.
paste_event_source: ?*wlr.wl_event_source = null,
paste_fd: c_int = -1,
paste_target_node: u64 = 0,
paste_len: usize = 0,
paste_buf: [65536]u8 = undefined,

// Phase-2 timer of the restore-repaint jiggle (ServerRestart): fires once
// ~60 ms after restore to re-assert true PTY winsizes. Self-removing in
// its callback; deliberately NOT touched in deinit (it lives only in the
// first 60 ms after process start, and deinit runs after the event loop
// is freed — removing it there would be the UAF this codebase avoids).
jiggle_timer_src: ?*wlr.wl_event_source = null,

// Built-in launcher
launcher: Launcher = .{},
leader: LeaderKey = .{},

// teruwm-specific config (~/.config/teruwm/config)
wm_config: WmConfig = .{},

// Autostart fires once on first output. True if we've already run it,
// OR if we're restoring from --restore (autostart is a cold-start feature;
// hot-restart must not re-spawn clients that are still connected).
autostart_fired: bool = false,

// Previous workspace, for Mod+Escape toggle-last. Updated on every
// workspace switch.
prev_workspace: ?u8 = null,

// The node that held focus immediately before a scratchpad was raised
// (A1). Captured in ServerScratchpad.focusScratchpad, consumed in hide()
// to restore the exact pre-scratchpad window — terminal, XDG or XWayland,
// tiled or floating. null when nothing meaningful was focused. Mirrors the
// prev_workspace single-slot pattern (toggle is synchronous).
scratchpad_prev_focus: ?u64 = null,

// User-defined spawn chord commands. Each slot pairs with the
// spawn_0..spawn_31 action variants; the keybind table maps chords
// to those actions, this array resolves to the shell command.
// Populated from `[keybind]` config section entries of the form
// `Mod+Return = spawn:teru`.
spawn_table: [32][256]u8 = @splat(@splat(0)),
spawn_table_len: [32]u16 = @splat(0),

// User-defined scratchpad chord names. Paired with scratchpad_0..7
// Action variants. Populated from `[keybind]` entries of the form
// `Super+T = scratchpad:term`. Also pre-seeded with sensible
// defaults (term / term2 / htop / help) bound to Super+T,
// Super+Shift+T, Super+H, Super+Shift+H — see applyDefaultScratchpads
// below.
scratchpad_table: [8][32]u8 = @splat(@splat(0)),
scratchpad_table_len: [8]u8 = @splat(0),

// Permanently-disabled scene tree used to park scratchpad nodes when
// toggled off. See getOrCreateHiddenTree() for rationale — we can't
// rely on wlr_scene_node_set_enabled(false) alone because the scene →
// output damage propagation sometimes loses the disable transition,
// leaving DRM stuck on the last frame. Reparenting into a disabled
// tree changes scene topology, which always damages correctly.
hidden_tree: ?*wlr.wlr_scene_tree = null,

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

// Keybind repeat state. Wayland delivers one key-press event per press,
// so holding Mod+L — which in xmonad-land grows the master area one
// tick per repeat — does nothing unless we implement repeat ourselves.
// We arm `keybind_repeat_src` on press of a matched keybind, fire the
// same action every `keybind_repeat_rate_ms`, and disarm on release /
// modifier change / different key. Rate + delay defaults borrowed from
// sway (25 Hz after a 400 ms delay); libinput-reported rates override
// when a keyboard surfaces them.
keybind_repeat_src: ?*wlr.wl_event_source = null,
keybind_repeat_keycode: u32 = 0,
keybind_repeat_action: ?KBAction = null,
keybind_repeat_rate_ms: c_int = 40,
keybind_repeat_delay_ms: c_int = 400,
event_loop: ?*wlr.wl_event_loop = null,

// Terminal-input repeat state (v0.6.4). Same rationale as
// keybind_repeat_src but for raw key bytes routed to focused_terminal.
// Wayland clients (Chromium, Emacs, ...) handle repeat themselves via
// the `repeat_info` hint we publish on the seat, but teru-native panes
// read directly from PTY — no client to implement repeat. Symptom
// before fix: hold Backspace → one character deleted, not a whole line.
terminal_repeat_src: ?*wlr.wl_event_source = null,
terminal_repeat_keycode: u32 = 0,
terminal_repeat_bytes: [32]u8 = undefined,
terminal_repeat_len: u8 = 0,

// Bar reactivity tick (v0.6.6). Idle compositor never schedules a
// frame — no PTY output, no input, no client damage — which means
// `Bar.render` (driven from the frame callback) never re-evaluates
// its widgets. Symptom: clock + CPU% + battery froze for minutes
// at a time on an idle desktop. We fire `barTick` at 1 Hz: it
// refreshes the sysfs/proc cache (TTL-gated, near-zero cost), and
// only schedules a frame when the bar's signature actually changed
// — so a truly-idle bar still produces no GPU work.
bar_tick_src: ?*wlr.wl_event_source = null,
bar_tick_last_sig: u64 = 0,

// Frames since the last PTY write from input (key, paste, mouse). Used by
// Output.handleFrame's edge-trigger fallback poll: poll every vsync for
// the first few frames after input (catches shell echo stragglers), then
// drop to a 16-frame safety net (~270 ms at 60 Hz). Without this gate the
// fallback issues N×60 non-blocking reads/sec for every idle terminal.
frames_since_pty_input: u32 = std.math.maxInt(u32),

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
// Clipboard: relay client copy requests to the seat (regular + primary
// selection). Without these, nothing a client copies can be pasted elsewhere.
request_set_selection: wlr.wl_listener = makeListener(Listeners.handleRequestSetSelection),
request_set_primary_selection: wlr.wl_listener = makeListener(Listeners.handleRequestSetPrimarySelection),
// wp_cursor_shape_v1 — Chromium M111+, GTK 4.14+, modern Qt. Without
// this listener hover state (pointer / text / grab / resize) is frozen
// on the default arrow over browsers.
cursor_shape_mgr: ?*wlr.wlr_cursor_shape_manager_v1 = null,
request_set_shape: wlr.wl_listener = makeListener(Cursor.handleRequestSetShape),
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
inhibitor_trackers: std.ArrayList(*Listeners.InhibitorTracker) = .empty,
shutting_down: bool = false,

// Deferred scene-node destroy queue (#11). TerminalPane.deinit runs
// mid-dispatch (PTY-fd / keybind / MCP callback); destroying the pane's
// wlr_scene_buffer node synchronously there crashed at teardown (a
// buffer-internal signal fired after the pane memory was freed). deinit
// detaches the node + enqueues it here; drainSceneDestroy — a one-shot
// wl_event_loop_add_idle — destroys it once the loop goes idle (after the
// current dispatch unwinds). Holds raw wlroots pointers only, never a
// *TerminalPane (the pane struct is freed immediately after deinit).
pending_scene_destroy: std.ArrayList(SceneDestroyRecord) = .empty,
pending_scene_destroy_armed: bool = false,

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
    // Frame-phase profiling: gap between consecutive frame callbacks (the
    // effective frame PERIOD) and the time spent inside wlr_scene_output_commit.
    // With frame_time_sum (total handleFrame work) these split each frame into
    // work / commit / inter-frame-wait — to localize a low-fps-but-low-CPU cap.
    frame_interval_sum_us: u64 = 0,
    commit_time_sum_us: u64 = 0,
    // i64 (not i128): an i128 field would raise Server's alignment to 16 and
    // break the @fieldParentPtr listener recovery (parent assumes 8). Monotonic
    // ns since boot fits in i64 (~292 years) with room to spare.
    prev_frame_start_ns: i64 = 0,

    pub fn recordFrame(self: *PerfStats, elapsed_us: u64) void {
        self.frame_count += 1;
        self.frame_time_sum_us += elapsed_us;
        if (elapsed_us > self.frame_time_max_us) self.frame_time_max_us = elapsed_us;
        if (elapsed_us < self.frame_time_min_us) self.frame_time_min_us = elapsed_us;
    }

    /// Accumulate the gap since the previous frame callback (effective period).
    pub fn recordInterval(self: *PerfStats, frame_start_ns: i128) void {
        const now: i64 = @intCast(frame_start_ns); // monotonic ns fits in i64
        if (self.prev_frame_start_ns != 0) {
            const gap_ns = now - self.prev_frame_start_ns;
            if (gap_ns > 0) self.frame_interval_sum_us += @intCast(@divTrunc(gap_ns, 1000));
        }
        self.prev_frame_start_ns = now;
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
    const cursor_shape_mgr = wlr.wlr_cursor_shape_manager_v1_create(display, 1);

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
    // input. wtype, ydotool, wlrctl, accessibility tools. Gated by
    // wm_config.allow_virtual_input (default true). Disable on shared
    // or kiosk hosts to prevent input-layer compromise.
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
        .cursor_shape_mgr = cursor_shape_mgr,
        .event_loop = event_loop,
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
    wlr.wl_signal_add(wlr.miozu_seat_request_set_selection(self.seat), &self.request_set_selection);
    wlr.wl_signal_add(wlr.miozu_seat_request_set_primary_selection(self.seat), &self.request_set_primary_selection);
    if (self.cursor_shape_mgr) |mgr| {
        wlr.wl_signal_add(wlr.miozu_cursor_shape_request_set_shape(mgr), &self.request_set_shape);
    }

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
                std.log.scoped(.compositor).info("XWayland enabled (DISPLAY={s})", .{dn});
            } else {
                std.log.scoped(.compositor).info("XWayland enabled", .{});
            }
        } else {
            std.log.scoped(.compositor).err("XWayland init failed (X11 apps won't work)", .{});
        }
    }
}

/// Apply loaded config to server state: font, colors, keybinds,
/// workspace layouts, bars. Implementation in ServerConfig.zig.
pub fn applyConfig(self: *Server, config: *const teru.Config, allocator: std.mem.Allocator, io: std.Io) void {
    Config.applyConfig(self, config, allocator, io);
}

/// Scene graph root — the parent tree of every mapped node (terminals,
/// XDG surfaces, XWayland surfaces, scene_rect borders, bars). Cached
/// accessor so callers don't have to know about the wlr glue function.
pub fn sceneRoot(self: *const Server) ?*wlr.wlr_scene_tree {
    return wlr.miozu_scene_tree(self.scene);
}

/// Return (lazily creating on first call) a permanently-disabled
/// scene tree that lives as a sibling of the scene root. Scratchpads
/// park their scene buffer node in here when toggled off. The tree is
/// disabled so nothing in it ever paints; reparenting into/out of it
/// damages both the old and new AABBs, which is what wlr_scene → output
/// commit needs to flip the DRM. set_enabled alone is not enough —
/// see hidden_tree field docstring.
pub fn getOrCreateHiddenTree(self: *Server) ?*wlr.wlr_scene_tree {
    if (self.hidden_tree) |t| return t;
    const root = self.sceneRoot() orelse return null;
    const tree = wlr.wlr_scene_tree_create(root) orelse return null;
    if (wlr.miozu_scene_tree_node(tree)) |node| {
        wlr.wlr_scene_node_set_enabled(node, false);
    }
    self.hidden_tree = tree;
    return tree;
}

/// Look up per-name scratchpad rule. Implementation in ServerConfig.zig.
pub fn scratchpadRuleFor(self: *const Server, name: []const u8) ?*const WmConfig.ScratchpadRule {
    return Config.scratchpadRuleFor(self, name);
}

/// Scratchpad name for action `a` (scratchpad_0..7). Impl in ServerConfig.zig.
pub fn scratchpadNameFor(self: *const Server, a: Keybinds.Action) []const u8 {
    return Config.scratchpadNameFor(self, a);
}

/// Apply teruwm bar config to the bar instance. Impl in ServerConfig.zig.
pub fn applyWmBar(self: *Server) void {
    Config.applyWmBar(self);
}

pub fn startMcp(self: *Server) void {
    self.wm_mcp = WmMcpServer.init(self);
}

/// Reload compositor config from disk and re-apply live (Mod+Shift+R /
/// teruwm_reload_config MCP tool). Implementation in ServerConfig.zig.
pub fn reloadWmConfig(self: *Server) void {
    Config.reloadWmConfig(self);
}

/// Hot-restart entry point. Implementation lives in ServerRestart.zig
/// (serialize + execve + FD_CLOEXEC bookkeeping). Kept as a method on
/// Server for callers that already dispatch to self.execRestart().
pub fn execRestart(self: *Server) void {
    Restart.execRestart(self);
}

// A detached pane scene node awaiting deferred destruction (#11). Both
// pointers are wlroots-owned and outlive the *TerminalPane that enqueued them.
pub const SceneDestroyRecord = struct {
    node: *wlr.wlr_scene_node,
    buffer: *wlr.wlr_buffer,
};

/// Enqueue a detached scene node (+ its backing buffer) for destruction once
/// the event loop is next idle, and arm a one-shot idle drain if not already
/// armed. Returns false if the work couldn't be queued (no event loop, or OOM)
/// — the caller must then fall back to its own safe handling. The node MUST
/// already be detached (wlr_scene_buffer_set_buffer(.., null)) by the caller.
pub fn queueSceneDestroy(self: *Server, node: *wlr.wlr_scene_node, buffer: *wlr.wlr_buffer) bool {
    if (self.shutting_down) return false;
    const loop = self.event_loop orelse return false;
    self.pending_scene_destroy.append(self.zig_allocator, .{ .node = node, .buffer = buffer }) catch return false;
    if (!self.pending_scene_destroy_armed) {
        if (wlr.wl_event_loop_add_idle(loop, drainSceneDestroy, self) == null) {
            // Couldn't arm the idle — pop the record back off so the caller's
            // fallback owns it (avoids a node that's queued but never drained).
            _ = self.pending_scene_destroy.pop();
            return false;
        }
        self.pending_scene_destroy_armed = true;
    }
    return true;
}

/// One-shot idle callback: destroy every queued scene node now that the loop
/// is idle (the enqueueing dispatch has fully unwound, so no buffer-internal
/// signal can fire against freed pane memory). The idle source auto-removes
/// after this returns — do not remove it here.
fn drainSceneDestroy(data: ?*anyopaque) callconv(.c) void {
    const self: *Server = @ptrCast(@alignCast(data orelse return));
    self.pending_scene_destroy_armed = false;
    if (self.shutting_down) {
        // wl_display_destroy will reclaim the scene; don't double-destroy.
        self.pending_scene_destroy.clearRetainingCapacity();
        return;
    }
    // Safe to iterate items directly: wlr_scene_node_destroy + wlr_buffer_drop
    // do not re-enter teruwm (no teruwm listeners on these scene nodes /
    // pixel buffers — the buffer_release listener was already removed by the
    // set_buffer(null) in deinit), so nothing calls queueSceneDestroy mid-loop
    // to realloc the backing store. If a future change adds such a listener,
    // snapshot the slice into a temp before this loop.
    for (self.pending_scene_destroy.items) |rec| {
        wlr.wlr_scene_node_destroy(rec.node);
        wlr.wlr_buffer_drop(rec.buffer);
    }
    self.pending_scene_destroy.clearRetainingCapacity();
}

pub fn deinit(self: *Server) void {
    // Flag before teardown so any destroy-signal handler that fires
    // during wl_display_destroy (idle-inhibit trackers, etc.) skips
    // the server deref path.
    self.shutting_down = true;

    // Tear down timers first so a late tick can't fire against
    // torn-down Server state.
    if (self.keybind_repeat_src) |src| {
        _ = wlr.wl_event_source_remove(src);
        self.keybind_repeat_src = null;
    }
    if (self.bar_tick_src) |src| {
        _ = wlr.wl_event_source_remove(src);
        self.bar_tick_src = null;
    }
    // terminal_repeat_src is created lazily by armTerminalRepeat and is
    // only *disarmed* (not removed) by cancelTerminalRepeat, so it can
    // still be live here. terminalRepeatTick does not check shutting_down —
    // a tick firing during wl_display_destroy would deref a freed pane.
    if (self.terminal_repeat_src) |src| {
        _ = wlr.wl_event_source_remove(src);
        self.terminal_repeat_src = null;
    }

    // Drain in-flight bar exec widgets — removes their pipe event
    // sources so execReadable can't fire against a torn-down loop.
    if (self.bar) |b| b.deinitExecs();
    // NOTE: the clipboard paste watcher is NOT drained here — deinit runs
    // after wl_display_destroy (main.zig defer order), so removing event
    // sources at this point would be a UAF on the freed event loop. Its
    // cancel runs from main.zig's own defer, before display destroy.

    // Free every InhibitorTracker before wl_display_destroy fires
    // inhibitor destroy signals on what would then be stale state.
    // Each tracker unhooks its own listener + drops itself.
    for (self.inhibitor_trackers.items) |tracker| {
        wlr.wl_list_remove(&tracker.destroy_listener.link);
        self.zig_allocator.destroy(tracker);
    }
    self.inhibitor_trackers.deinit(self.zig_allocator);

    // Free the deferred scene-destroy queue's backing array. Do NOT destroy
    // its node pointers: wl_display_destroy ran before this (main.zig defer
    // order) and already reclaimed the whole scene, so they're dangling. The
    // backing buffers leak harmlessly here (process is exiting) rather than
    // risk a drop after display-destroy.
    self.pending_scene_destroy.deinit(self.zig_allocator);

    if (self.wm_mcp) |mcp| mcp.deinit(self.zig_allocator);

    // Remove every Server-owned wl_listener. wlroots allocates each
    // listener's list node in-place inside the signal it's attached
    // to; leaking these means the signal keeps a dangling pointer
    // into freed Server memory on the next tick.
    //
    // Listeners without a live link (link.next == null) were never
    // registered (optional protocol paths: xwayland, xdg-activation,
    // xdg-decoration).
    // new_output / new_input listen on the *backend's* signals, which
    // releaseSeat() destroyed before deinit ran (main.zig defer order:
    // releaseSeat → wl_display_destroy → deinit). Removing them here would
    // walk an already-freed wl_signal list → use-after-free. releaseSeat
    // detaches them itself, immediately before wlr_backend_destroy.
    safeRemoveListener(&self.new_xdg_toplevel);
    safeRemoveListener(&self.xdg_activate);
    safeRemoveListener(&self.new_xdg_decoration);
    safeRemoveListener(&self.cursor_motion);
    safeRemoveListener(&self.cursor_motion_absolute);
    safeRemoveListener(&self.cursor_button);
    safeRemoveListener(&self.cursor_axis);
    safeRemoveListener(&self.cursor_frame);
    safeRemoveListener(&self.request_set_cursor);
    safeRemoveListener(&self.request_set_shape);
    safeRemoveListener(&self.new_xwayland_surface);
    safeRemoveListener(&self.new_inhibitor);
    safeRemoveListener(&self.output_power_set_mode);
    safeRemoveListener(&self.new_virtual_keyboard);
    safeRemoveListener(&self.new_virtual_pointer);
    safeRemoveListener(&self.output_manager_apply);
    safeRemoveListener(&self.output_manager_test);

    // Our ArrayList collections. The *Output / *Keyboard
    // items themselves are owned by wlroots' destroy-chain when the
    // wl_display tears down; we only free our pointer arrays here.
    self.outputs.deinit(self.zig_allocator);
    self.keyboards.deinit(self.zig_allocator);
    self.pane_index.deinit(self.zig_allocator);
    self.nodes.deinitIndex(self.zig_allocator);

    wlr.xkb_context_unref(self.xkb_ctx);
}

fn safeRemoveListener(listener: *wlr.wl_listener) void {
    if (listener.link.next != null) {
        wlr.wl_list_remove(&listener.link);
    }
}

/// Tear down XWayland: kills the Xwayland process and unlinks its display
/// lock + socket (/tmp/.X{N}-lock, /tmp/.X11-unix/X{N}). No-op if XWayland was
/// never started. MUST run before wl_display_destroy_clients so Xwayland's own
/// wayland-connection teardown doesn't race the wrapper free (matches sway /
/// tinywl ordering). Shared by the quit path (main.zig defers) and the
/// hot-restart path (ServerRestart) so both reclaim :0 cleanly.
pub fn destroyXwayland(self: *Server) void {
    if (self.xwayland) |xwl| {
        wlr.wlr_xwayland_destroy(xwl);
        self.xwayland = null;
    }
}

/// Release the DRM / logind seat IN-PROCESS. On a bare TTY wlr_backend_autocreate
/// took libseat control, the DRM master, and every input device; neither exit()
/// nor execve() runs wlroots destructors, so without this the VT is left in
/// graphics mode displaying teruwm's last frame with the keyboard in raw mode —
/// indistinguishable from a hang, recoverable only by reboot. (This is why
/// Mod+Shift+' / Mod+Shift+Q "froze" the machine; headless/X11 backends have no
/// seat, so it never surfaced in tests.)
///
/// Order is load-bearing:
///   1. Detach new_output / new_input — they listen on the backend's signals,
///      which step 4 frees; leaving them attached would dangle into freed memory
///      when deinit later walks them.
///   2. Drop the seat keyboard + remove per-keyboard listeners. wlr_keyboard_finish
///      (fired inside backend destroy) sends a final release-all key notify; if the
///      keyboard is still the seat's active keyboard with our key_listener attached,
///      that notify routes into a half-freed seat/grab → SIGSEGV. Detaching first
///      makes the teardown inert.
///   3. wlr_backend_destroy — closes the DRM + input fds THROUGH the still-live
///      session.
///   4. wlr_session_destroy — its close releases libseat control (logind
///      ReleaseControl), which restores the VT to text mode. This is the step that
///      actually un-freezes the console on exit.
///
/// Call EXACTLY ONCE per process (not idempotent — a second call double-removes
/// listeners + double-destroys the backend): the quit path calls it via a
/// main.zig defer (before wl_display_destroy); the restart path calls it directly
/// before execve. Those paths are mutually exclusive (restart execve/exits, so
/// its defers never run). deinit() must run AFTER this and must NOT re-remove
/// new_output / new_input.
pub fn releaseSeat(self: *Server) void {
    safeRemoveListener(&self.new_output);
    safeRemoveListener(&self.new_input);

    wlr.wlr_seat_set_keyboard(self.seat, null);
    for (self.keyboards.items) |kb| {
        wlr.wl_list_remove(&kb.key_listener.link);
        wlr.wl_list_remove(&kb.modifiers_listener.link);
        wlr.wl_list_remove(&kb.destroy_listener.link);
    }

    wlr.wlr_backend_destroy(self.backend);
    if (self.session) |sess| {
        wlr.wlr_session_destroy(sess);
        self.session = null;
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
/// as methods. Real logic lives in ServerInput (except for this one —
/// it's a single wlr call, no module needed).
pub inline fn notifyActivity(self: *Server) void {
    if (self.idle_notifier) |n| wlr.wlr_idle_notifier_v1_notify_activity(n, self.seat);
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
    self.push_widget_count += 1;
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
            self.push_widget_count -|= 1;
            self.scheduleRender();
            return true;
        }
    }
    return false;
}

/// Count currently-registered widgets. O(1) via the maintained counter.
pub fn countPushWidgets(self: *const Server) usize {
    return self.push_widget_count;
}

// ── Desktop notification ────────────────────────────────────────

/// Set the active desktop notification (newest wins). Truncates each
/// field into the fixed buffers, stamps the monotonic receive time, resets
/// the marquee offset, re-arms the bar tick at ~33 ms so the marquee
/// scrolls, and schedules a frame. Called from the `teruwm_notify` MCP
/// tool, which the D-Bus helper forwards into. `urgency`/`timeout_ms`
/// default sensibly when the caller omits them.
pub fn setNotification(
    self: *Server,
    app: []const u8,
    summary: []const u8,
    body: []const u8,
    urgency: Notification.Urgency,
    timeout_ms: u32,
) void {
    var n: Notification = .{};
    const an = @min(app.len, n.app_buf.len);
    @memcpy(n.app_buf[0..an], app[0..an]);
    n.app_len = @intCast(an);
    const sn = @min(summary.len, n.summary_buf.len);
    @memcpy(n.summary_buf[0..sn], summary[0..sn]);
    n.summary_len = @intCast(sn);
    const bn = @min(body.len, n.body_buf.len);
    @memcpy(n.body_buf[0..bn], body[0..bn]);
    n.body_len = @intCast(bn);
    n.urgency = urgency;
    n.timeout_ms = timeout_ms;
    n.received_ns = @intCast(teru.compat.monotonicNow());

    self.current_notification = n;
    self.notify_scroll = 0;
    self.armNotifyTick();
    self.scheduleRender();
}

/// Re-arm the bar tick at the fast (~33 ms) cadence so the `{notify}`
/// marquee advances smoothly. No-op if the timer doesn't exist yet.
/// barTick reverts to 1 Hz once the notification expires — see barTick.
fn armNotifyTick(self: *Server) void {
    if (self.bar_tick_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, notify_tick_ms);
    }
}

/// Fast bar-tick cadence while a notification is on screen (~30 fps).
pub const notify_tick_ms: c_int = 33;

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

/// Frame-callback hook: advance a held drag-select that has run past a pane
/// edge (auto-scroll). No-op unless a native-terminal drag is in progress.
pub fn tickDragAutoScroll(self: *Server) void {
    Cursor.tickDragAutoScroll(self);
}

/// Frame-callback hook: ease smooth-scroll animations toward their target.
/// No-op unless a pane is mid-scroll-animation.
pub fn tickScrollAnim(self: *Server) void {
    Cursor.tickScrollAnim(self);
}


// ── Layout facade ──────────────────────────────────────────────
// Thin forwarders so external callers (Session, Output, WmMcpServer,
// Xwayland/XdgView) keep a stable Server surface even though the real
// implementations live in ServerLayout. See that file for the gap
// math, drag-feedback path, and float-sink semantics.

pub fn sinkFocused(self: *Server) void { Layout.sinkFocused(self); }
pub fn sinkAllOnActiveWorkspace(self: *Server) void { Layout.sinkAllOnActiveWorkspace(self); }
pub fn arrangeworkspace(self: *Server, ws_index: u8) void { Layout.arrangeWorkspace(self, ws_index); }
pub fn arrangeWorkspaceSmooth(self: *Server, ws_index: u8) void { Layout.arrangeWorkspaceSmooth(self, ws_index); }

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
    Focus.focusView(self, view);
}

// ── Terminal pane management ───────────────────────────────────

/// Spawn an embedded terminal pane on the given workspace, sized to fill the output.
pub fn spawnTerminal(self: *Server, ws: u8) void {
    // Create at default size — arrangeworkspace will resize to fit the layout
    const tp = TerminalPane.create(self, ws, 24, 80) orelse {
        std.log.scoped(.compositor).err("failed to spawn terminal pane", .{});
        return;
    };

    // Store in terminal_panes array FIRST (before arrangeworkspace).
    // pane_index was already populated by TerminalPane.init.
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
    if (self.bar) |b| _ = b.render(self);
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

    self.clipboard_len = pos;
    std.log.scoped(.compositor).debug("clipboard copy ({d} bytes)", .{self.clipboard_len});
}

/// Drop any in-flight clipboard paste pipe watcher. Thin forwarder for
/// main.zig's shutdown defer — must run BEFORE wl_display_destroy (see
/// ServerClipboard.cancelInflight for the UAF rationale).
pub fn cancelClipboardPaste(self: *Server) void {
    ServerClipboard.cancelInflight(self);
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
            _ = b.render(self); // restore normal bar
        }
    }
}

/// Repaint the bar after a leader-mode change. Bar.render owns the branch
/// (renders the which-key hint into the BOTTOM bar while leader.active, else
/// the normal stats). Force a repaint so both entering (show hint) and exiting
/// (restore stats — the bar signature may be unchanged) take effect now.
pub fn renderLeaderHint(self: *Server) void {
    if (self.bar) |b| {
        b.dirty = true;
        _ = b.render(self);
    }
}

// ── Window & workspace lifecycle (ServerWindow.zig) ────────────
// Thin re-exports; node lookup, close paths, float/fullscreen,
// workspace placement, visibility recompute, multi-output focus.
pub const setWorkspaceVisibility = Window.setWorkspaceVisibility;
pub const toggleFloat = Window.toggleFloat;
pub const toggleFullscreen = Window.toggleFullscreen;
pub const nodeAtPoint = Window.nodeAtPoint;
pub const activeOutputDims = Window.activeOutputDims;
pub const terminalPaneById = Window.terminalPaneById;
pub const clearFocusRefs = Window.clearFocusRefs;
pub const closeNode = Window.closeNode;
pub const closeFocused = Window.closeFocused;
pub const handleTerminalExit = Window.handleTerminalExit;
pub const updateFocusedTerminal = Window.updateFocusedTerminal;
pub const activeWorkspace = Window.activeWorkspace;
pub const outputShowing = Window.outputShowing;
pub const focusWorkspace = Window.focusWorkspace;
pub const moveNodeToWorkspace = Window.moveNodeToWorkspace;
pub const recomputeVisibility = Window.recomputeVisibility;
pub const focusNextOutput = Window.focusNextOutput;
pub const cycleFocusAll = Window.cycleFocusAll;
pub const focusXwaylandSurface = Window.focusXwaylandSurface;

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
pub fn toggleScratchpadByName(self: *Server, name: []const u8) void {
    Scratchpad.toggleByName(self, name);
}

/// Numbered compatibility shim — N maps to named scratchpad padN+1.
pub fn toggleScratchpad(self: *Server, index: u8) void {
    Scratchpad.toggleNumbered(self, index);
}

/// Arm the keybind-action repeat timer for `keycode`. See ServerRepeat.zig.
pub fn armKeybindRepeat(self: *Server, action: KBAction, keycode: u32) void {
    Repeat.armKeybindRepeat(self, action, keycode);
}

/// Disarm the keybind repeat timer.
pub fn cancelKeybindRepeat(self: *Server) void {
    Repeat.cancelKeybindRepeat(self);
}

/// Arm the terminal-input repeat timer. See ServerRepeat.zig.
pub fn armTerminalRepeat(self: *Server, keycode: u32, bytes: []const u8) void {
    Repeat.armTerminalRepeat(self, keycode, bytes);
}

/// Disarm the terminal-input repeat timer.
pub fn cancelTerminalRepeat(self: *Server) void {
    Repeat.cancelTerminalRepeat(self);
}

// ── Bar reactivity tick (v0.6.6) ─────────────────────────────
//
// Idle compositor scenario: no PTY output, no input, no client damage
// → wlroots schedules zero frames → handleFrame never fires → Bar.render
// never re-evaluates its widgets → clock and CPU% sit frozen for
// minutes (verified empirically with snapshots 5 min apart returning
// byte-identical bar pixels). Frame-driven reactivity is correct for
// terminal panes (output drives damage) but wrong for time/sysfs
// widgets that have no event source of their own.
//
// Fix: a 1-Hz wlroots timer that calls Bar.render directly. Bar.render
// already does TTL-gated /proc reads and a signature short-circuit, so
// when nothing actually changed the tick costs only the /proc syscalls
// (a few µs) and a u64 hash. We only call scheduleRender when the bar
// reports it actually re-painted — so a truly-idle bar produces zero
// extra GPU/scene-commit work. 1 Hz is the floor because the CPU%
// widget's cache TTL is 1 s; longer TTL widgets (battery, watts) are
// already gated inside refreshCachedData and won't burn extra reads.

fn barTick(data: ?*anyopaque) callconv(.c) c_int {
    const self: *Server = @ptrCast(@alignCast(data orelse return 0));
    // DPMS gate: when every output is asleep (lid closed, swayidle blanked,
    // monitor off), skip the /proc reads + signature hash and re-arm at 5 s
    // instead of 1 s. ~5× wakeup reduction on a closed-lid laptop.
    var any_enabled = false;
    for (self.outputs.items) |out| {
        if (wlr.miozu_output_enabled(out.wlr_output) != 0) {
            any_enabled = true;
            break;
        }
    }
    // Notification lifecycle. While one is live we run the fast (~33 ms)
    // marquee cadence; on expiry we clear it and fall back to 1 Hz. This
    // is the only thing that keeps the fast tick alive, so a truly-idle
    // bar always reverts to 1 Hz (no power-drain regression — see
    // .claude/rules/cpu-performance.md). The fast path runs only when a
    // notification exists.
    var notify_active = false;
    if (self.current_notification) |*n| {
        const now_ns: i64 = @intCast(teru.compat.monotonicNow());
        if (n.expired(now_ns)) {
            self.current_notification = null;
            self.notify_scroll = 0;
            // Re-render once so the bar reverts to its empty center.
            if (self.bar) |b| b.dirty = true;
        } else {
            notify_active = true;
            // Advance the marquee one cell per fast tick (~30 cells/s).
            self.notify_scroll +%= 1;
        }
    }

    var next_ms: c_int = if (notify_active) notify_tick_ms else 1000;
    if (!self.shutting_down and any_enabled) {
        if (self.bar) |b| {
            const repainted = b.render(self);
            if (repainted) self.scheduleRender();
        }
    } else if (!notify_active) {
        next_ms = 5000;
    }
    if (self.bar_tick_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, next_ms);
    }
    return 0;
}

/// Start the 1-Hz bar reactivity tick. Idempotent — safe to call
/// multiple times. Called from Output.attach once a bar exists; the
/// timer is torn down in deinit.
pub fn startBarTick(self: *Server) void {
    if (self.bar_tick_src != null) return;
    const loop = self.event_loop orelse return;
    self.bar_tick_src = wlr.wl_event_loop_add_timer(loop, barTick, @ptrCast(self));
    if (self.bar_tick_src) |src| {
        _ = wlr.wl_event_source_timer_update(src, 1000);
    }
}

/// Move the focused node to the next output's current workspace.
pub fn moveFocusedToNextOutput(self: *Server) void {
    Focus.moveFocusedToNextOutput(self);
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
    Focus.applyFocusOpacity(self);
}

// ── Process spawning ───────────────────────────────────────────

/// Spawn a shell command detached from the compositor. See ServerProcess.zig.
pub fn spawnProcess(_: *Server, cmd: [*:0]const u8) void {
    Process.spawnProcess(cmd);
}

/// Spawn a shell command from a non-nul-terminated slice. See ServerProcess.zig.
pub fn spawnShell(_: *Server, cmd: []const u8) void {
    Process.spawnShell(cmd);
}

/// Shell-spawn screenshot. Delegates to ServerScreenshot.zig.
pub fn takeScreenshot(self: *Server) void {
    Screenshot.takeScreenshot(self);
}

/// Named-path screenshot. Public because WmMcpServer.teruwm_screenshot
/// calls it through self.server.takeScreenshotToPath. Delegates.
pub fn takeScreenshotToPath(self: *Server, path: []const u8) bool {
    return Screenshot.takeScreenshotToPath(self, path);
}

/// Crop a region of the composited output to a PNG. Delegates.
pub fn takeAreaScreenshot(self: *Server, rx: i32, ry: i32, rw: u32, rh: u32) bool {
    return Screenshot.takeAreaScreenshot(self, rx, ry, rw, rh);
}

/// Enter / cancel native area-select (drag-to-capture). Delegate to Cursor.
pub fn beginAreaSelect(self: *Server) void {
    Cursor.beginAreaSelect(self);
}
pub fn cancelAreaSelect(self: *Server) void {
    Cursor.cancelAreaSelect(self);
}

// ── Helper ─────────────────────────────────────────────────────

fn makeListener(comptime func: *const fn (*wlr.wl_listener, ?*anyopaque) callconv(.c) void) wlr.wl_listener {
    return .{
        .link = .{ .prev = null, .next = null },
        .notify = func,
    };
}
