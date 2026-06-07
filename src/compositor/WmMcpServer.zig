//! Compositor MCP Server — exposes teruwm window manager controls over a Unix domain socket.
//!
//! Separate from the terminal MCP (which controls panes within a teru instance).
//! This controls the compositor itself: windows, workspaces, layouts, screenshots.
//!
//! Listens on /run/user/$UID/teruwm-mcp-$PID.sock.
//! Protocol: HTTP/1.1 + JSON-RPC 2.0 (same as teru terminal MCP).

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const teru = @import("teru");
const compat = teru.compat;
const ipc = teru.ipc;
const png = teru.png;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");
const ServerFont = @import("ServerFont.zig");
const NodeRegistry = @import("Node.zig");
const WmMcpTools = @import("WmMcpTools.zig");
const tools = teru.McpTools;
const version = teru.build_options.version;

// ── JSON helper aliases ───────────────────────────────────────
//
// The canonical implementations live in src/agent/McpTools.zig;
// we alias the ones this server calls frequently so the call sites
// below stay short. Signed coordinates flow through the i64 variant;
// ids / workspace indexes use the u64 one.
const extractJsonString = tools.extractJsonString;
const extractJsonId = tools.extractJsonId;
const extractJsonObject = tools.extractJsonObject;
const extractNestedJsonString = tools.extractNestedJsonString;
const extractNestedJsonInt = tools.extractNestedJsonIntSigned; // i64
const jsonRpcError = tools.jsonRpcError;
const jsonEscapeString = tools.jsonEscapeString;
const findBody = tools.findHttpBody;
const parseContentLength = tools.parseHttpContentLength;

const WmMcpServer = @This();

const max_request: usize = 65536;
const max_response: usize = 65536;
const socket_path_max: usize = 108;

socket_path: [socket_path_max]u8,
socket_path_len: usize,
socket_fd: posix.fd_t,
server: *Server,
event_source: ?*wlr.wl_event_source = null,

// ── Event subscriber channel (v0.4.18) ────────────────────────
// Separate socket for pushed JSON events (`urgent`, `focus_changed`,
// `workspace_switched`, `window_mapped`). Protocol: one connected
// subscriber at a time; each emitEvent writes `<json>\n` to the fd.
// On write failure the subscriber is dropped. Clients obtain the
// path via the `teruwm_subscribe_events` MCP tool, then connect
// with a plain Unix-socket client — no HTTP, no JSON-RPC handshake.
// A new subscriber replaces the previous one (socket is single-seat).
event_socket_path: [socket_path_max]u8 = undefined,
event_socket_path_len: usize = 0,
event_socket_fd: posix.fd_t = -1,
event_subscriber_fd: posix.fd_t = -1,
event_source_evt: ?*wlr.wl_event_source = null,

// ── Lifecycle ──────────────────────────────────────────────────

pub fn init(server: *Server) ?*WmMcpServer {
    const pid = compat.getPid();

    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return null;

    // Path: /run/user/$UID/teruwm-mcp-$PID.sock  (renamed from
    // teru-wmmcp-$PID.sock at v0.6.4 — `teruwm-` matches the binary
    // name, and separating the family prefix from `mcp` makes it read
    // as "teruwm / mcp / PID" instead of the mashed-together "wmmcp".)
    var ipc_path_buf: [256]u8 = undefined;
    const path = ipc.buildPathFamily(&ipc_path_buf, "teruwm", "mcp", pid_str) orelse return null;

    const ipc_server = ipc.listen(path) catch return null;
    const sock = ipc_server.rawFd();

    const self = server.zig_allocator.create(WmMcpServer) catch return null;
    self.* = .{
        .socket_path = undefined,
        .socket_path_len = path.len,
        .socket_fd = sock,
        .server = server,
    };
    @memcpy(self.socket_path[0..path.len], path);

    // Register with wlroots event loop for async accept
    if (wlr.wl_display_get_event_loop(server.display)) |event_loop| {
        self.event_source = wlr.wl_event_loop_add_fd(
            event_loop,
            sock,
            wlr.WL_EVENT_READABLE,
            onSocketReadable,
            @ptrCast(self),
        );

        // Companion events socket — best-effort push channel.
        var evt_path_buf: [256]u8 = undefined;
        if (ipc.buildPathFamily(&evt_path_buf, "teruwm", "mcp-events", pid_str)) |evt_path| {
            if (ipc.listen(evt_path)) |evt_ipc| {
                const evt_sock = evt_ipc.rawFd();
                self.event_socket_fd = evt_sock;
                const n = @min(evt_path.len, self.event_socket_path.len);
                @memcpy(self.event_socket_path[0..n], evt_path[0..n]);
                self.event_socket_path_len = n;
                self.event_source_evt = wlr.wl_event_loop_add_fd(
                    event_loop,
                    evt_sock,
                    wlr.WL_EVENT_READABLE,
                    onEventSocketReadable,
                    @ptrCast(self),
                );
                std.log.scoped(.mcp).info("event socket on {s}", .{evt_path});
            } else |_| {}
        }
    }

    std.log.scoped(.mcp).info("server on {s}", .{path});
    return self;
}

pub fn deinit(self: *WmMcpServer, allocator: Allocator) void {
    if (self.event_source) |es| _ = wlr.wl_event_source_remove(es);
    if (self.event_source_evt) |es| _ = wlr.wl_event_source_remove(es);
    _ = posix.system.close(self.socket_fd);
    if (self.event_subscriber_fd != -1) _ = posix.system.close(self.event_subscriber_fd);
    if (self.event_socket_fd != -1) _ = posix.system.close(self.event_socket_fd);

    var unlink_buf: [socket_path_max + 1]u8 = undefined;
    @memcpy(unlink_buf[0..self.socket_path_len], self.socket_path[0..self.socket_path_len]);
    unlink_buf[self.socket_path_len] = 0;
    _ = std.c.unlink(@ptrCast(&unlink_buf));

    if (self.event_socket_path_len > 0) {
        @memcpy(unlink_buf[0..self.event_socket_path_len], self.event_socket_path[0..self.event_socket_path_len]);
        unlink_buf[self.event_socket_path_len] = 0;
        _ = std.c.unlink(@ptrCast(&unlink_buf));
    }

    allocator.destroy(self);
}

// ── Event loop callback ───────────────────────────────────────

fn onSocketReadable(_: c_int, _: u32, data: ?*anyopaque) callconv(.c) c_int {
    const self: *WmMcpServer = @ptrCast(@alignCast(data orelse return 0));
    self.poll();
    return 0;
}

fn poll(self: *WmMcpServer) void {
    const client = ipc.accept(ipc.IpcHandle.fromRaw(self.socket_fd)) orelse return;
    self.handleRequest(client.rawFd());
    client.close();
}

// ── Event subscriber (v0.4.18) ────────────────────────────────

fn onEventSocketReadable(_: c_int, _: u32, data: ?*anyopaque) callconv(.c) c_int {
    const self: *WmMcpServer = @ptrCast(@alignCast(data orelse return 0));
    self.acceptEventSubscriber();
    return 0;
}

/// Accept a new event subscriber, replacing any previous one. Only one
/// subscriber at a time (the last to connect wins). We set O_NONBLOCK
/// so emitEvent never blocks the compositor event loop if the subscriber
/// is slow — slow subscribers just drop events (best-effort telemetry).
fn acceptEventSubscriber(self: *WmMcpServer) void {
    const client = ipc.accept(ipc.IpcHandle.fromRaw(self.event_socket_fd)) orelse return;
    const fd = client.rawFd();

    // O_NONBLOCK so we never stall.
    const F_GETFL: c_int = 3;
    const F_SETFL: c_int = 4;
    const O_NONBLOCK: c_int = 0o4000;
    const flags = std.c.fcntl(fd, F_GETFL);
    if (flags >= 0) {
        _ = std.c.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    // Replace previous subscriber.
    if (self.event_subscriber_fd != -1) _ = posix.system.close(self.event_subscriber_fd);
    self.event_subscriber_fd = fd;
    std.log.scoped(.mcp).info("events subscriber connected (fd={d})", .{fd});
}

/// Emit one JSON event line to the current subscriber. No subscriber,
/// no cost — single fd check. On write failure (subscriber gone) we
/// drop them. Callers pass a bare JSON object *without* the trailing
/// newline; we append it here.
pub fn emitEvent(self: *WmMcpServer, json_line: []const u8) void {
    if (self.event_subscriber_fd == -1) return;
    // Two writes are fine (subscriber reads until \n), but keep it one
    // syscall for efficiency.
    var buf: [4096]u8 = undefined;
    const line_len = @min(json_line.len, buf.len - 1);
    @memcpy(buf[0..line_len], json_line[0..line_len]);
    buf[line_len] = '\n';
    const total = line_len + 1;
    const n = std.c.write(self.event_subscriber_fd, &buf, total);
    // EAGAIN on a non-blocking socket means the kernel buffer is full;
    // drop this event but keep the subscriber. Only close on real
    // terminal errors (EPIPE, EBADF, etc). Before v0.4.22 this branch
    // treated EAGAIN as "subscriber gone" and silently closed it, so
    // the first event went through and the rest were black-holed.
    const EAGAIN: i32 = 11;
    if (n < 0) {
        const errno = std.c._errno().*;
        if (errno == EAGAIN) return; // keep subscriber, drop event
        _ = posix.system.close(self.event_subscriber_fd);
        self.event_subscriber_fd = -1;
    } else if (n == 0) {
        // 0 isn't normal for stream sockets — treat as closed.
        _ = posix.system.close(self.event_subscriber_fd);
        self.event_subscriber_fd = -1;
    }
}

/// Convenience for the common shape: `{"event":"<kind>", ...}` built
/// by a caller-supplied body printer. `body_fn` writes the JSON
/// field(s) after `"event":"<kind>"`. Returns iff emitted.
pub fn emitEventKind(self: *WmMcpServer, kind: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (self.event_subscriber_fd == -1) return;
    var buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{{\"event\":\"{s}\"", .{kind}) catch return;
    const rest = std.fmt.bufPrint(buf[prefix.len..], fmt, args) catch return;
    const end = prefix.len + rest.len;
    if (end + 2 > buf.len) return;
    buf[end] = '}';
    buf[end + 1] = 0;
    self.emitEvent(buf[0 .. end + 1]);
}

// ── MCP framework wiring ──────────────────────────────────────
//
// handleRequest, dispatch, initialize / tools_list / tools_call, and
// the notifications ack all live in teru.McpFramework now. This
// server supplies: framing choice, tool_table, tools_list_body,
// server identity. Everything else is the framework's job.

const F = teru.McpFramework.Framework(WmMcpServer);

/// Array body of tools/list — comptime string that the framework
/// wraps in the jsonrpc envelope. Adding a new tool: entry here +
/// entry in tool_table + the thunk further down.
const tools_list_body: []const u8 =
    \\[
    \\{"name":"teruwm_list_windows","description":"List all managed windows (terminals + external apps) with node ID, workspace, kind, title, position, size","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"teruwm_spawn_terminal","description":"Spawn a new terminal pane on a workspace","inputSchema":{"type":"object","properties":{"workspace":{"type":"integer","default":0}},"required":[]}},
    \\{"name":"teruwm_close_window","description":"Close a window by node ID","inputSchema":{"type":"object","properties":{"node_id":{"type":"integer"}},"required":["node_id"]}},
    \\{"name":"teruwm_focus_window","description":"Focus a window by node ID","inputSchema":{"type":"object","properties":{"node_id":{"type":"integer"}},"required":["node_id"]}},
    \\{"name":"teruwm_move_to_workspace","description":"Move a window to a different workspace","inputSchema":{"type":"object","properties":{"node_id":{"type":"integer"},"workspace":{"type":"integer"}},"required":["node_id","workspace"]}},
    \\{"name":"teruwm_list_workspaces","description":"List workspaces with layout, window count, active status","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"teruwm_switch_workspace","description":"Switch active workspace (0-9)","inputSchema":{"type":"object","properties":{"workspace":{"type":"integer"}},"required":["workspace"]}},
    \\{"name":"teruwm_set_layout","description":"Set layout for a workspace","inputSchema":{"type":"object","properties":{"workspace":{"type":"integer","default":0},"layout":{"type":"string","enum":["master-stack","grid","monocle","dishes","spiral","three-col","columns","accordion"]}},"required":["layout"]}},
    \\{"name":"teruwm_zoom","description":"Font zoom for the whole compositor — re-rasterizes the shared font atlas and re-fonts every terminal pane + bar. 'in'/'out' step the font size by one pixel; 'reset' restores the configured size.","inputSchema":{"type":"object","properties":{"direction":{"type":"string","enum":["in","out","reset"]}},"required":["direction"]}},
    \\{"name":"teruwm_zoom_focused","description":"Per-pane font zoom for the FOCUSED terminal only — same effect as Alt+scroll-wheel over a pane. 'in'/'out' step the pane's font size by one pixel; 'reset' returns it to the configured size. Bars and other panes are untouched.","inputSchema":{"type":"object","properties":{"direction":{"type":"string","enum":["in","out","reset"]}},"required":["direction"]}},
    \\{"name":"teruwm_get_config","description":"Get compositor config (gap, border_width, bar settings)","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"teruwm_set_config","description":"Set a compositor config value live. Keys: gap (int), border_width (int), bg_color (hex #rrggbb or 0xaarrggbb).","inputSchema":{"type":"object","properties":{"key":{"type":"string","enum":["gap","border_width","bg_color"]},"value":{"type":"string"}},"required":["key","value"]}},
    \\{"name":"teruwm_screenshot","description":"Capture the full compositor output as PNG. Uses grim if available, otherwise returns error.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Output path (default: /tmp/teruwm-screenshot.png)"}},"required":[]}},
    \\{"name":"teruwm_notify","description":"Show a notification overlay on the compositor","inputSchema":{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}},
    \\{"name":"teruwm_reload_config","description":"Reload compositor config from ~/.config/teruwm/config. Re-applies gap, border, bar settings live.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"teruwm_screenshot_pane","description":"Capture a single pane as PNG by name or node_id. Works for terminal panes.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Pane name (e.g. term-0-1, editor)"},"node_id":{"type":"integer"},"path":{"type":"string","description":"Output path (default: /tmp/teruwm-pane-NAME.png)"}},"required":[]}},
    \\{"name":"teruwm_set_name","description":"Assign a human-readable name to a window/pane.","inputSchema":{"type":"object","properties":{"node_id":{"type":"integer"},"name":{"type":"string"},"new_name":{"type":"string"}},"required":["new_name"]}},
    \\{"name":"teruwm_perf","description":"Get compositor performance stats: frame timing (avg/max us), PTY throughput, terminal count","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"teruwm_restart","description":"Hot-restart the compositor: serializes PTY state, exec()s new binary. Terminal sessions survive. Use after rebuild.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"teruwm_quit","description":"Terminate the compositor cleanly. Same effect as Mod+Shift+Q. Destructive — every managed client loses its display server and any unsaved state. Prefer teruwm_restart if you're reloading after a rebuild.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"teruwm_toggle_bar","description":"Toggle top or bottom status bar visibility. Triggers a re-arrange of all workspaces.","inputSchema":{"type":"object","properties":{"which":{"type":"string","enum":["top","bottom"]}},"required":["which"]}},
    \\{"name":"teruwm_set_bar","description":"Set the enabled state of the top or bottom status bar explicitly.","inputSchema":{"type":"object","properties":{"which":{"type":"string","enum":["top","bottom"]},"enabled":{"type":"boolean"}},"required":["which","enabled"]}},
    \\{"name":"teruwm_set_widget","description":"Register or update a push widget shown in a bar via {widget:name}. Upsert semantics — idempotent.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"widget name, ≤32 chars"},"text":{"type":"string","description":"text to display, ≤128 chars"},"class":{"type":"string","enum":["none","muted","info","success","warning","critical","accent"],"description":"semantic color class (defaults to fg)"}},"required":["name","text"]}},
    \\{"name":"teruwm_delete_widget","description":"Remove a push widget by name.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}},
    \\{"name":"teruwm_list_widgets","description":"List registered push widgets with their current text, class, and last update timestamp.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"teruwm_test_drag","description":"TEST ONLY: synthesize a pointer drag from (from_x,from_y) to (to_x,to_y). Optional super=true simulates Mod-held drag (tiling → floating). Used by E2E suites; not normally invoked by users.","inputSchema":{"type":"object","properties":{"from_x":{"type":"integer"},"from_y":{"type":"integer"},"to_x":{"type":"integer"},"to_y":{"type":"integer"},"super":{"type":"boolean"},"button":{"type":"integer","description":"linux input-event code; 272=left (default), 273=right"}},"required":["from_x","from_y","to_x","to_y"]}},
    \\{"name":"teruwm_click","description":"AI-first physical click. Warps the cursor to (x, y) and synthesizes a real left-click at the compositor seat (same wlroots path as a touchpad click). Use this to drive any Wayland client (Chromium, Firefox, GIMP, …) from an agent. Output: {cx,cy,hit:node_id|null,kind:'wayland'|'terminal'|'none'}.","inputSchema":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"string","enum":["left","right","middle"],"description":"default left"}},"required":["x","y"]}},
    \\{"name":"teruwm_type","description":"AI-first physical typing. Sends key press+release events for each character of the text through the compositor seat (same wlroots path as a real keyboard). ASCII-only today (US QWERTY); maps each char to evdev keycode + Shift modifier as needed. Use after teruwm_click on a focusable element to type into it.","inputSchema":{"type":"object","properties":{"text":{"type":"string","description":"text to type — ASCII printable + space; non-ASCII is silently dropped"}},"required":["text"]}},
    \\{"name":"teruwm_press","description":"AI-first single key press. Useful for special keys like Enter, Tab, Escape, Backspace, ArrowDown that teruwm_type doesn't cover. Mods supported: ctrl, shift, alt, super.","inputSchema":{"type":"object","properties":{"key":{"type":"string","description":"key name: 'Return', 'Tab', 'Escape', 'BackSpace', 'Up', 'Down', 'Left', 'Right', 'Home', 'End', 'PageUp', 'PageDown', or single ASCII char"},"ctrl":{"type":"boolean"},"shift":{"type":"boolean"},"alt":{"type":"boolean"},"super":{"type":"boolean"}},"required":["key"]}},
    \\{"name":"teruwm_scroll","description":"AI-first scroll wheel. Synthesizes a vertical scroll axis event at (x, y) on the focused surface (or whatever's under the cursor at that point).","inputSchema":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"dy":{"type":"number","description":"positive scrolls down, negative scrolls up; magnitude in libinput axis units (15 ≈ one detent)"}},"required":["x","y","dy"]}},
    \\{"name":"teruwm_test_key","description":"TEST ONLY: dispatch a keybind action by name, bypassing xkb. Use for E2E tests of keybind-triggered compositor actions.","inputSchema":{"type":"object","properties":{"action":{"type":"string","description":"action name e.g. 'layout_cycle', 'bar_toggle_top'"}},"required":["action"]}},
    \\{"name":"teruwm_test_move","description":"TEST ONLY: warp the cursor to (x, y) and fire a motion event, no button. Useful for tests that verify hover focus, scroll mode, etc.","inputSchema":{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"}},"required":["x","y"]}},
    \\{"name":"teruwm_mouse_path","description":"Move the cursor from (from_x, from_y) to (to_x, to_y) along a smooth humanised path (Bezier + tremor + ease-in-out) over duration_ms milliseconds. Optional button is pressed partway through and released at the end — the synthetic click looks like a real person moved the mouse. Use this instead of teruwm_test_drag when driving client apps that care about bot-like straight-line warps (anti-bot browsing automation, UI smoke tests against protected pages).","inputSchema":{"type":"object","properties":{"from_x":{"type":"integer"},"from_y":{"type":"integer"},"to_x":{"type":"integer"},"to_y":{"type":"integer"},"duration_ms":{"type":"integer","description":"wall-clock path duration; default from wm_config.mouse_path_default_ms (250)"},"humanize":{"type":"boolean","description":"if false, teleport (skip Bezier/tremor). Default: honour wm_config.mouse_humanize"},"button":{"type":"integer","description":"linux input-event code; 272=left, 273=right. Omit for pointer-move only"},"super":{"type":"boolean","description":"simulate Mod-held drag (tiling → floating)"}},"required":["from_x","from_y","to_x","to_y"]}},
    \\{"name":"teruwm_toggle_scratchpad","description":"Toggle numbered scratchpad N (0..8). Compat shim since v0.4.18 — delegates to teruwm_scratchpad name=padN+1. Prefer teruwm_scratchpad for new code.","inputSchema":{"type":"object","properties":{"index":{"type":"integer","description":"scratchpad index 0..8"}},"required":["index"]}},
    \\{"name":"teruwm_scratchpad","description":"Toggle a named scratchpad (xmonad NamedScratchpad model). First call spawns a floating terminal tagged with the given name; subsequent calls toggle its visibility on the focused workspace. Scratchpads live in the node registry with a hidden-workspace sentinel when parked — visible via teruwm_list_windows.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"scratchpad identifier (e.g. 'term', 'music'). Max 15 chars."},"cmd":{"type":"string","description":"Reserved for future per-scratchpad spawn commands; ignored today — scratchpads spawn the user shell."}},"required":["name"]}},
    \\{"name":"teruwm_subscribe_events","description":"Get the Unix-socket path for the event push channel. Connect a raw client to that path to read newline-delimited JSON events: urgent, focus_changed, workspace_switched, window_mapped. One subscriber at a time (last-connect wins); best-effort (slow subscribers drop events).","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"teruwm_session_save","description":"Snapshot the compositor's live state to ~/.config/teru/sessions/<name>.tsess. Captures workspace layouts, master ratios, pane roles, and per-pane cwd + running cmd (from /proc). Scope: tiled terminal panes only — no XDG clients, no floats, no scratchpads, no scrollback.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"session name (default: 'default')"}},"required":[]}},
    \\{"name":"teruwm_session_restore","description":"Restore a .tsess file into the compositor. Idempotent by role: panes whose role matches an existing pane are not duplicated. Each spawned pane resumes in its saved cwd running its saved cmd. Layouts and master_ratio are restored.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"session name (default: 'default')"}},"required":[]}}
    \\]
;

const framework_config: F.Config = .{
    .server_name = "teruwm",
    .server_version = version,
    .framing = .http,
    .capabilities_json = "\"tools\":{}",
    .tool_table = &tool_table,
    .tools_list_body = tools_list_body,
};

fn handleRequest(self: *WmMcpServer, conn_fd: posix.fd_t) void {
    F.handleRequestFd(self, conn_fd, &framework_config);
}

/// Route a JSON-RPC body through the framework. Public so the
/// in-band OSC 9999 path (teru side) can reach the compositor
/// without constructing a socket connection.
pub fn dispatch(self: *WmMcpServer, body: []const u8, resp_buf: []u8) []const u8 {
    return F.dispatch(self, body, resp_buf, &framework_config);
}

// ── Tool dispatch table ────────────────────────────────────────
//
// Each entry owns its arg-extraction — the thunks unpack
// `params_body` (already stripped to the RPC "params" object) and
// call the underlying tool method. The framework routes by name
// via StaticStringMap hash; no edits to the framework when adding
// a tool — just an entry here plus the thunk further down.
const tool_table = std.StaticStringMap(F.Thunk).initComptime(.{
    .{ "teruwm_list_windows", WmMcpTools.thunkListWindows },
    .{ "teruwm_spawn_terminal", WmMcpTools.thunkSpawnTerminal },
    .{ "teruwm_close_window", WmMcpTools.thunkCloseWindow },
    .{ "teruwm_focus_window", WmMcpTools.thunkFocusWindow },
    .{ "teruwm_move_to_workspace", WmMcpTools.thunkMoveToWorkspace },
    .{ "teruwm_list_workspaces", WmMcpTools.thunkListWorkspaces },
    .{ "teruwm_switch_workspace", WmMcpTools.thunkSwitchWorkspace },
    .{ "teruwm_set_layout", WmMcpTools.thunkSetLayout },
    .{ "teruwm_zoom", WmMcpTools.thunkZoom },
    .{ "teruwm_zoom_focused", WmMcpTools.thunkZoomFocused },
    .{ "teruwm_get_config", WmMcpTools.thunkGetConfig },
    .{ "teruwm_set_config", WmMcpTools.thunkSetConfig },
    .{ "teruwm_screenshot", WmMcpTools.thunkScreenshot },
    .{ "teruwm_notify", WmMcpTools.thunkNotify },
    .{ "teruwm_reload_config", WmMcpTools.thunkReloadConfig },
    .{ "teruwm_screenshot_pane", WmMcpTools.thunkScreenshotPane },
    .{ "teruwm_set_name", WmMcpTools.thunkSetName },
    .{ "teruwm_perf", WmMcpTools.thunkPerf },
    .{ "teruwm_restart", WmMcpTools.thunkRestart },
    .{ "teruwm_quit", WmMcpTools.thunkQuit },
    .{ "teruwm_toggle_bar", WmMcpTools.thunkToggleBar },
    .{ "teruwm_set_bar", WmMcpTools.thunkSetBar },
    .{ "teruwm_set_widget", WmMcpTools.thunkSetWidget },
    .{ "teruwm_delete_widget", WmMcpTools.thunkDeleteWidget },
    .{ "teruwm_list_widgets", WmMcpTools.thunkListWidgets },
    .{ "teruwm_test_drag", WmMcpTools.thunkTestDrag },
    .{ "teruwm_test_key", WmMcpTools.thunkTestKey },
    .{ "teruwm_test_move", WmMcpTools.thunkTestMove },
    .{ "teruwm_mouse_path", WmMcpTools.thunkMousePath },
    .{ "teruwm_click", WmMcpTools.thunkClick },
    .{ "teruwm_type", WmMcpTools.thunkType },
    .{ "teruwm_press", WmMcpTools.thunkPress },
    .{ "teruwm_scroll", WmMcpTools.thunkScroll },
    .{ "teruwm_toggle_scratchpad", WmMcpTools.thunkToggleScratchpad },
    .{ "teruwm_scratchpad", WmMcpTools.thunkScratchpad },
    .{ "teruwm_subscribe_events", WmMcpTools.thunkSubscribeEvents },
    .{ "teruwm_session_save", WmMcpTools.thunkSessionSave },
    .{ "teruwm_session_restore", WmMcpTools.thunkSessionRestore },
});
