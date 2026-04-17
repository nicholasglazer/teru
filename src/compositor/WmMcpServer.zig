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
const NodeRegistry = @import("Node.zig");
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

    // Path: /run/user/$UID/teru-wmmcp-$PID.sock
    var ipc_path_buf: [256]u8 = undefined;
    const path = ipc.buildPath(&ipc_path_buf, "wmmcp", pid_str) orelse return null;

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
        if (ipc.buildPath(&evt_path_buf, "wmmcp-events", pid_str)) |evt_path| {
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
                std.debug.print("teruwm: MCP event socket on {s}\n", .{evt_path});
            } else |_| {}
        }
    }

    std.debug.print("teruwm: MCP server on {s}\n", .{path});
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
    std.debug.print("teruwm: MCP events subscriber connected (fd={d})\n", .{fd});
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

// ── HTTP / JSON-RPC handling ──────────────────────────────────

fn handleRequest(self: *WmMcpServer, conn_fd: posix.fd_t) void {
    var req_buf: [max_request]u8 = undefined;
    var total: usize = 0;

    while (total < req_buf.len) {
        const rc = std.c.read(conn_fd, req_buf[total..].ptr, req_buf.len - total);
        if (rc <= 0) break;
        total += @intCast(rc);

        if (findBody(req_buf[0..total])) |body_start| {
            if (parseContentLength(req_buf[0..total])) |content_len| {
                if (total >= body_start + content_len) break;
            } else break;
        }
    }

    if (total == 0) return;

    const body = if (findBody(req_buf[0..total])) |start|
        req_buf[start..total]
    else
        req_buf[0..total];

    var resp_buf: [max_response]u8 = undefined;
    const json_response = self.dispatch(body, &resp_buf);

    var http_header: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&http_header, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{json_response.len}) catch return;

    _ = std.c.write(conn_fd, header.ptr, header.len);
    _ = std.c.write(conn_fd, json_response.ptr, json_response.len);
}

/// Route a JSON-RPC body through the method/tool dispatch. Public for
/// symmetry with McpServer.dispatch (teru side) — any transport
/// (HTTP socket, future line-JSON, future in-band forwarding) can
/// share this one path without re-implementing framing + routing.
pub fn dispatch(self: *WmMcpServer, body: []const u8, resp_buf: []u8) []const u8 {
    const method = extractJsonString(body, "method") orelse
        return jsonRpcError(resp_buf, null, -32600, "Invalid Request");
    const id = extractJsonId(body);

    if (std.mem.eql(u8, method, "initialize")) {
        return self.handleInitialize(resp_buf, id);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return self.handleToolsList(resp_buf, id);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        return self.handleToolsCall(body, resp_buf, id);
    } else if (std.mem.startsWith(u8, method, "notifications/")) {
        return std.fmt.bufPrint(resp_buf,
            \\{{"jsonrpc":"2.0","result":{{}},"id":{s}}}
        , .{id orelse "null"}) catch "{}";
    } else {
        return jsonRpcError(resp_buf, id, -32601, "Method not found");
    }
}

// ── MCP handlers ──────────────────────────────────────────────

fn handleInitialize(_: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"protocolVersion":"2025-03-26","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"teruwm","version":"{s}"}}}},"id":{s}}}
    , .{ version, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn handleToolsList(_: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"tools":[
        \\{{"name":"teruwm_list_windows","description":"List all managed windows (terminals + external apps) with node ID, workspace, kind, title, position, size","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teruwm_spawn_terminal","description":"Spawn a new terminal pane on a workspace","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer","default":0}}}},"required":[]}}}},
        \\{{"name":"teruwm_close_window","description":"Close a window by node ID","inputSchema":{{"type":"object","properties":{{"node_id":{{"type":"integer"}}}},"required":["node_id"]}}}},
        \\{{"name":"teruwm_focus_window","description":"Focus a window by node ID","inputSchema":{{"type":"object","properties":{{"node_id":{{"type":"integer"}}}},"required":["node_id"]}}}},
        \\{{"name":"teruwm_move_to_workspace","description":"Move a window to a different workspace","inputSchema":{{"type":"object","properties":{{"node_id":{{"type":"integer"}},"workspace":{{"type":"integer"}}}},"required":["node_id","workspace"]}}}},
        \\{{"name":"teruwm_list_workspaces","description":"List workspaces with layout, window count, active status","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teruwm_switch_workspace","description":"Switch active workspace (0-9)","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer"}}}},"required":["workspace"]}}}},
        \\{{"name":"teruwm_set_layout","description":"Set layout for a workspace","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer","default":0}},"layout":{{"type":"string","enum":["master-stack","grid","monocle","dishes","spiral","three-col","columns","accordion"]}}}},"required":["layout"]}}}},
        \\{{"name":"teruwm_get_config","description":"Get compositor config (gap, border_width, bar settings)","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teruwm_set_config","description":"Set a compositor config value live. Keys: gap (int), border_width (int), bg_color (hex #rrggbb or 0xaarrggbb).","inputSchema":{{"type":"object","properties":{{"key":{{"type":"string","enum":["gap","border_width","bg_color"]}},"value":{{"type":"string"}}}},"required":["key","value"]}}}},
        \\{{"name":"teruwm_screenshot","description":"Capture the full compositor output as PNG. Uses grim if available, otherwise returns error.","inputSchema":{{"type":"object","properties":{{"path":{{"type":"string","description":"Output path (default: /tmp/teruwm-screenshot.png)"}}}},"required":[]}}}},
        \\{{"name":"teruwm_notify","description":"Show a notification overlay on the compositor","inputSchema":{{"type":"object","properties":{{"message":{{"type":"string"}}}},"required":["message"]}}}},
        \\{{"name":"teruwm_reload_config","description":"Reload compositor config from ~/.config/teruwm/config. Re-applies gap, border, bar settings live.","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teruwm_screenshot_pane","description":"Capture a single pane as PNG by name or node_id. Works for terminal panes.","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string","description":"Pane name (e.g. term-0-1, editor)"}},"node_id":{{"type":"integer"}},"path":{{"type":"string","description":"Output path (default: /tmp/teruwm-pane-NAME.png)"}}}},"required":[]}}}},
        \\{{"name":"teruwm_set_name","description":"Assign a human-readable name to a window/pane.","inputSchema":{{"type":"object","properties":{{"node_id":{{"type":"integer"}},"name":{{"type":"string"}},"new_name":{{"type":"string"}}}},"required":["new_name"]}}}},
        \\{{"name":"teruwm_perf","description":"Get compositor performance stats: frame timing (avg/max us), PTY throughput, terminal count","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teruwm_restart","description":"Hot-restart the compositor: serializes PTY state, exec()s new binary. Terminal sessions survive. Use after rebuild.","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teruwm_toggle_bar","description":"Toggle top or bottom status bar visibility. Triggers a re-arrange of all workspaces.","inputSchema":{{"type":"object","properties":{{"which":{{"type":"string","enum":["top","bottom"]}}}},"required":["which"]}}}},
        \\{{"name":"teruwm_set_bar","description":"Set the enabled state of the top or bottom status bar explicitly.","inputSchema":{{"type":"object","properties":{{"which":{{"type":"string","enum":["top","bottom"]}},"enabled":{{"type":"boolean"}}}},"required":["which","enabled"]}}}},
        \\{{"name":"teruwm_set_widget","description":"Register or update a push widget shown in a bar via {{widget:name}}. Upsert semantics — idempotent.","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string","description":"widget name, ≤32 chars"}},"text":{{"type":"string","description":"text to display, ≤128 chars"}},"class":{{"type":"string","enum":["none","muted","info","success","warning","critical","accent"],"description":"semantic color class (defaults to fg)"}}}},"required":["name","text"]}}}},
        \\{{"name":"teruwm_delete_widget","description":"Remove a push widget by name.","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string"}}}},"required":["name"]}}}},
        \\{{"name":"teruwm_list_widgets","description":"List registered push widgets with their current text, class, and last update timestamp.","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teruwm_test_drag","description":"TEST ONLY: synthesize a pointer drag from (from_x,from_y) to (to_x,to_y). Optional super=true simulates Mod-held drag (tiling → floating). Used by E2E suites; not normally invoked by users.","inputSchema":{{"type":"object","properties":{{"from_x":{{"type":"integer"}},"from_y":{{"type":"integer"}},"to_x":{{"type":"integer"}},"to_y":{{"type":"integer"}},"super":{{"type":"boolean"}},"button":{{"type":"integer","description":"linux input-event code; 272=left (default), 274=right"}}}},"required":["from_x","from_y","to_x","to_y"]}}}},
        \\{{"name":"teruwm_click","description":"AI-first physical click. Warps the cursor to (x, y) and synthesizes a real left-click at the compositor seat (same wlroots path as a touchpad click). Use this to drive any Wayland client (Chromium, Firefox, GIMP, …) from an agent. Output: {{cx,cy,hit:node_id|null,kind:'wayland'|'terminal'|'none'}}.","inputSchema":{{"type":"object","properties":{{"x":{{"type":"integer"}},"y":{{"type":"integer"}},"button":{{"type":"string","enum":["left","right","middle"],"description":"default left"}}}},"required":["x","y"]}}}},
        \\{{"name":"teruwm_type","description":"AI-first physical typing. Sends key press+release events for each character of the text through the compositor seat (same wlroots path as a real keyboard). ASCII-only today (US QWERTY); maps each char to evdev keycode + Shift modifier as needed. Use after teruwm_click on a focusable element to type into it.","inputSchema":{{"type":"object","properties":{{"text":{{"type":"string","description":"text to type — ASCII printable + space; non-ASCII is silently dropped"}}}},"required":["text"]}}}},
        \\{{"name":"teruwm_press","description":"AI-first single key press. Useful for special keys like Enter, Tab, Escape, Backspace, ArrowDown that teruwm_type doesn't cover. Mods supported: ctrl, shift, alt, super.","inputSchema":{{"type":"object","properties":{{"key":{{"type":"string","description":"key name: 'Return', 'Tab', 'Escape', 'BackSpace', 'Up', 'Down', 'Left', 'Right', 'Home', 'End', 'PageUp', 'PageDown', or single ASCII char"}},"ctrl":{{"type":"boolean"}},"shift":{{"type":"boolean"}},"alt":{{"type":"boolean"}},"super":{{"type":"boolean"}}}},"required":["key"]}}}},
        \\{{"name":"teruwm_scroll","description":"AI-first scroll wheel. Synthesizes a vertical scroll axis event at (x, y) on the focused surface (or whatever's under the cursor at that point).","inputSchema":{{"type":"object","properties":{{"x":{{"type":"integer"}},"y":{{"type":"integer"}},"dy":{{"type":"number","description":"positive scrolls down, negative scrolls up; magnitude in libinput axis units (15 ≈ one detent)"}}}},"required":["x","y","dy"]}}}},
        \\{{"name":"teruwm_test_key","description":"TEST ONLY: dispatch a keybind action by name, bypassing xkb. Use for E2E tests of keybind-triggered compositor actions.","inputSchema":{{"type":"object","properties":{{"action":{{"type":"string","description":"action name e.g. 'layout_cycle', 'bar_toggle_top'"}}}},"required":["action"]}}}},
        \\{{"name":"teruwm_test_move","description":"TEST ONLY: warp the cursor to (x, y) and fire a motion event, no button. Useful for tests that verify hover focus, scroll mode, etc.","inputSchema":{{"type":"object","properties":{{"x":{{"type":"integer"}},"y":{{"type":"integer"}}}},"required":["x","y"]}}}},
        \\{{"name":"teruwm_mouse_path","description":"Move the cursor from (from_x, from_y) to (to_x, to_y) along a smooth humanised path (Bezier + tremor + ease-in-out) over duration_ms milliseconds. Optional button is pressed partway through and released at the end — the synthetic click looks like a real person moved the mouse. Use this instead of teruwm_test_drag when driving client apps that care about bot-like straight-line warps (anti-bot browsing automation, UI smoke tests against protected pages).","inputSchema":{{"type":"object","properties":{{"from_x":{{"type":"integer"}},"from_y":{{"type":"integer"}},"to_x":{{"type":"integer"}},"to_y":{{"type":"integer"}},"duration_ms":{{"type":"integer","description":"wall-clock path duration; default from wm_config.mouse_path_default_ms (250)"}},"humanize":{{"type":"boolean","description":"if false, teleport (skip Bezier/tremor). Default: honour wm_config.mouse_humanize"}},"button":{{"type":"integer","description":"linux input-event code; 272=left, 274=right. Omit for pointer-move only"}},"super":{{"type":"boolean","description":"simulate Mod-held drag (tiling → floating)"}}}},"required":["from_x","from_y","to_x","to_y"]}}}},
        \\{{"name":"teruwm_toggle_scratchpad","description":"Toggle numbered scratchpad N (0..8). Compat shim since v0.4.18 — delegates to teruwm_scratchpad name=padN+1. Prefer teruwm_scratchpad for new code.","inputSchema":{{"type":"object","properties":{{"index":{{"type":"integer","description":"scratchpad index 0..8"}}}},"required":["index"]}}}},
        \\{{"name":"teruwm_scratchpad","description":"Toggle a named scratchpad (xmonad NamedScratchpad model). First call spawns a floating terminal tagged with the given name; subsequent calls toggle its visibility on the focused workspace. Scratchpads live in the node registry with a hidden-workspace sentinel when parked — visible via teruwm_list_windows.","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string","description":"scratchpad identifier (e.g. 'term', 'music'). Max 15 chars."}},"cmd":{{"type":"string","description":"Reserved for future per-scratchpad spawn commands; ignored today — scratchpads spawn the user shell."}}}},"required":["name"]}}}},
        \\{{"name":"teruwm_subscribe_events","description":"Get the Unix-socket path for the event push channel. Connect a raw client to that path to read newline-delimited JSON events: urgent, focus_changed, workspace_switched, window_mapped. One subscriber at a time (last-connect wins); best-effort (slow subscribers drop events).","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teruwm_session_save","description":"Snapshot the compositor's live state to ~/.config/teru/sessions/<name>.tsess. Captures workspace layouts, master ratios, pane roles, and per-pane cwd + running cmd (from /proc). Scope: tiled terminal panes only — no XDG clients, no floats, no scratchpads, no scrollback.","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string","description":"session name (default: 'default')"}}}},"required":[]}}}},
        \\{{"name":"teruwm_session_restore","description":"Restore a .tsess file into the compositor. Idempotent by role: panes whose role matches an existing pane are not duplicated. Each spawned pane resumes in its saved cwd running its saved cmd. Layouts and master_ratio are restored.","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string","description":"session name (default: 'default')"}}}},"required":[]}}}}
        \\]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

// ── Tool dispatch table ────────────────────────────────────────
//
// Each entry owns its arg-extraction — the thunks unpack
// `params_body` (already stripped to the RPC "params" object) and
// call the underlying tool method. StaticStringMap gives O(1)
// hashed lookup instead of a 28-way std.mem.eql chain; adding a
// tool is one map entry + one thunk, no edits to the dispatcher.
const ToolThunk = *const fn (*WmMcpServer, []const u8, []u8, ?[]const u8) []const u8;

const tool_table = std.StaticStringMap(ToolThunk).initComptime(.{
    .{ "teruwm_list_windows", thunkListWindows },
    .{ "teruwm_spawn_terminal", thunkSpawnTerminal },
    .{ "teruwm_close_window", thunkCloseWindow },
    .{ "teruwm_focus_window", thunkFocusWindow },
    .{ "teruwm_move_to_workspace", thunkMoveToWorkspace },
    .{ "teruwm_list_workspaces", thunkListWorkspaces },
    .{ "teruwm_switch_workspace", thunkSwitchWorkspace },
    .{ "teruwm_set_layout", thunkSetLayout },
    .{ "teruwm_get_config", thunkGetConfig },
    .{ "teruwm_set_config", thunkSetConfig },
    .{ "teruwm_screenshot", thunkScreenshot },
    .{ "teruwm_notify", thunkNotify },
    .{ "teruwm_reload_config", thunkReloadConfig },
    .{ "teruwm_screenshot_pane", thunkScreenshotPane },
    .{ "teruwm_set_name", thunkSetName },
    .{ "teruwm_perf", thunkPerf },
    .{ "teruwm_restart", thunkRestart },
    .{ "teruwm_toggle_bar", thunkToggleBar },
    .{ "teruwm_set_bar", thunkSetBar },
    .{ "teruwm_set_widget", thunkSetWidget },
    .{ "teruwm_delete_widget", thunkDeleteWidget },
    .{ "teruwm_list_widgets", thunkListWidgets },
    .{ "teruwm_test_drag", thunkTestDrag },
    .{ "teruwm_test_key", thunkTestKey },
    .{ "teruwm_test_move", thunkTestMove },
    .{ "teruwm_mouse_path", thunkMousePath },
    .{ "teruwm_click", thunkClick },
    .{ "teruwm_type", thunkType },
    .{ "teruwm_press", thunkPress },
    .{ "teruwm_scroll", thunkScroll },
    .{ "teruwm_toggle_scratchpad", thunkToggleScratchpad },
    .{ "teruwm_scratchpad", thunkScratchpad },
    .{ "teruwm_subscribe_events", thunkSubscribeEvents },
    .{ "teruwm_session_save", thunkSessionSave },
    .{ "teruwm_session_restore", thunkSessionRestore },
});

fn handleToolsCall(self: *WmMcpServer, body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const params_body = extractJsonObject(body, "params") orelse
        return jsonRpcError(buf, id, -32602, "Missing params");
    const tool_name = extractJsonString(params_body, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing tool name");
    if (tool_table.get(tool_name)) |thunk| return thunk(self, params_body, buf, id);
    return jsonRpcError(buf, id, -32602, "Unknown tool");
}

// ── Thunks (arg unpacking; uniform signature) ──────────────────

fn thunkListWindows(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return self.toolListWindows(buf, id);
}

fn thunkSpawnTerminal(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const ws = extractNestedJsonInt(p, "workspace") orelse 0;
    return self.toolSpawnTerminal(@intCast(ws), buf, id);
}

fn thunkCloseWindow(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const nid = extractNestedJsonInt(p, "node_id") orelse
        return jsonRpcError(buf, id, -32602, "Missing node_id");
    return self.toolCloseWindow(@intCast(nid), buf, id);
}

fn thunkFocusWindow(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const nid = extractNestedJsonInt(p, "node_id") orelse
        return jsonRpcError(buf, id, -32602, "Missing node_id");
    return self.toolFocusWindow(@intCast(nid), buf, id);
}

fn thunkMoveToWorkspace(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const nid = extractNestedJsonInt(p, "node_id") orelse
        return jsonRpcError(buf, id, -32602, "Missing node_id");
    const ws = extractNestedJsonInt(p, "workspace") orelse
        return jsonRpcError(buf, id, -32602, "Missing workspace");
    return self.toolMoveToWorkspace(@intCast(nid), @intCast(ws), buf, id);
}

fn thunkListWorkspaces(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return self.toolListWorkspaces(buf, id);
}

fn thunkSwitchWorkspace(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const ws = extractNestedJsonInt(p, "workspace") orelse
        return jsonRpcError(buf, id, -32602, "Missing workspace");
    return self.toolSwitchWorkspace(@intCast(ws), buf, id);
}

fn thunkSetLayout(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const layout_str = extractNestedJsonString(p, "layout") orelse
        return jsonRpcError(buf, id, -32602, "Missing layout");
    const ws = extractNestedJsonInt(p, "workspace") orelse 0;
    return self.toolSetLayout(@intCast(ws), layout_str, buf, id);
}

fn thunkGetConfig(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return self.toolGetConfig(buf, id);
}

fn thunkSetConfig(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const key = extractNestedJsonString(p, "key") orelse
        return jsonRpcError(buf, id, -32602, "Missing key");
    const value = extractNestedJsonString(p, "value") orelse
        return jsonRpcError(buf, id, -32602, "Missing value");
    return self.toolSetConfig(key, value, buf, id);
}

fn thunkScreenshot(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const path = extractNestedJsonString(p, "path") orelse "/tmp/teruwm-screenshot.png";
    return self.toolScreenshot(path, buf, id);
}

fn thunkNotify(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const message = extractNestedJsonString(p, "message") orelse
        return jsonRpcError(buf, id, -32602, "Missing message");
    return self.toolNotify(message, buf, id);
}

fn thunkReloadConfig(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return self.toolReloadConfig(buf, id);
}

fn thunkScreenshotPane(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const path = extractNestedJsonString(p, "path");
    return self.toolScreenshotPane(p, path, buf, id);
}

fn thunkSetName(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const new_name = extractNestedJsonString(p, "new_name") orelse
        return jsonRpcError(buf, id, -32602, "Missing new_name");
    return self.toolSetName(p, new_name, buf, id);
}

fn thunkPerf(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return self.toolPerf(buf, id);
}

fn thunkRestart(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return self.toolRestart(buf, id);
}

fn thunkToggleBar(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const which = extractNestedJsonString(p, "which") orelse
        return jsonRpcError(buf, id, -32602, "Missing which (top|bottom)");
    return self.toolToggleBar(which, null, buf, id);
}

fn thunkSetBar(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const which = extractNestedJsonString(p, "which") orelse
        return jsonRpcError(buf, id, -32602, "Missing which (top|bottom)");
    const args = extractJsonObject(p, "arguments") orelse p;
    const enabled: bool = std.mem.indexOf(u8, args, "\"enabled\":true") != null;
    return self.toolToggleBar(which, enabled, buf, id);
}

fn thunkSetWidget(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const w_name = extractNestedJsonString(p, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing name");
    const w_text = extractNestedJsonString(p, "text") orelse
        return jsonRpcError(buf, id, -32602, "Missing text");
    const w_class = extractNestedJsonString(p, "class") orelse "";
    return self.toolSetWidget(w_name, w_text, w_class, buf, id);
}

fn thunkDeleteWidget(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const w_name = extractNestedJsonString(p, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing name");
    return self.toolDeleteWidget(w_name, buf, id);
}

fn thunkListWidgets(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return self.toolListWidgets(buf, id);
}

fn thunkTestDrag(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const fx = extractNestedJsonInt(p, "from_x") orelse
        return jsonRpcError(buf, id, -32602, "Missing from_x");
    const fy = extractNestedJsonInt(p, "from_y") orelse
        return jsonRpcError(buf, id, -32602, "Missing from_y");
    const tx = extractNestedJsonInt(p, "to_x") orelse
        return jsonRpcError(buf, id, -32602, "Missing to_x");
    const ty = extractNestedJsonInt(p, "to_y") orelse
        return jsonRpcError(buf, id, -32602, "Missing to_y");
    const args = extractJsonObject(p, "arguments") orelse p;
    const super_held = std.mem.indexOf(u8, args, "\"super\":true") != null;
    const button: u32 = blk: {
        const b = extractNestedJsonInt(p, "button") orelse break :blk 272;
        break :blk @intCast(b);
    };
    return self.toolTestDrag(@intCast(fx), @intCast(fy), @intCast(tx), @intCast(ty), super_held, button, buf, id);
}

fn thunkTestKey(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const action = extractNestedJsonString(p, "action") orelse
        return jsonRpcError(buf, id, -32602, "Missing action");
    return self.toolTestKey(action, buf, id);
}

fn thunkTestMove(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const x = extractNestedJsonInt(p, "x") orelse
        return jsonRpcError(buf, id, -32602, "Missing x");
    const y = extractNestedJsonInt(p, "y") orelse
        return jsonRpcError(buf, id, -32602, "Missing y");
    return self.toolTestMove(@intCast(x), @intCast(y), buf, id);
}

fn thunkMousePath(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const fx = extractNestedJsonInt(p, "from_x") orelse
        return jsonRpcError(buf, id, -32602, "Missing from_x");
    const fy = extractNestedJsonInt(p, "from_y") orelse
        return jsonRpcError(buf, id, -32602, "Missing from_y");
    const tx = extractNestedJsonInt(p, "to_x") orelse
        return jsonRpcError(buf, id, -32602, "Missing to_x");
    const ty = extractNestedJsonInt(p, "to_y") orelse
        return jsonRpcError(buf, id, -32602, "Missing to_y");
    const dur_raw = extractNestedJsonInt(p, "duration_ms");
    const dur: u32 = if (dur_raw) |d| @intCast(@max(0, d)) else self.server.wm_config.mouse_path_default_ms;
    const humanize_true = std.mem.indexOf(u8, p, "\"humanize\":true") != null;
    const humanize_false = std.mem.indexOf(u8, p, "\"humanize\":false") != null;
    const humanize: bool = if (humanize_true) true else if (humanize_false) false else self.server.wm_config.mouse_humanize;
    const btn_raw = extractNestedJsonInt(p, "button");
    const btn: ?u32 = if (btn_raw) |b| @intCast(@max(0, b)) else null;
    const super_held = std.mem.indexOf(u8, p, "\"super\":true") != null;
    return self.toolMousePath(@intCast(fx), @intCast(fy), @intCast(tx), @intCast(ty), dur, humanize, btn, super_held, buf, id);
}

fn thunkClick(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const x = extractNestedJsonInt(p, "x") orelse
        return jsonRpcError(buf, id, -32602, "Missing x");
    const y = extractNestedJsonInt(p, "y") orelse
        return jsonRpcError(buf, id, -32602, "Missing y");
    const args_obj = extractJsonObject(p, "arguments") orelse p;
    const button_str = extractJsonString(args_obj, "button") orelse "left";
    const button: u32 = if (std.mem.eql(u8, button_str, "right")) 274 else if (std.mem.eql(u8, button_str, "middle")) 273 else 272;
    return self.toolClick(@intCast(x), @intCast(y), button, buf, id);
}

fn thunkType(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const text = extractNestedJsonString(p, "text") orelse
        return jsonRpcError(buf, id, -32602, "Missing text");
    return self.toolType(text, buf, id);
}

fn thunkPress(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const key = extractNestedJsonString(p, "key") orelse
        return jsonRpcError(buf, id, -32602, "Missing key");
    const args_obj = extractJsonObject(p, "arguments") orelse p;
    const ctrl = std.mem.indexOf(u8, args_obj, "\"ctrl\":true") != null;
    const shift = std.mem.indexOf(u8, args_obj, "\"shift\":true") != null;
    const alt = std.mem.indexOf(u8, args_obj, "\"alt\":true") != null;
    const sup = std.mem.indexOf(u8, args_obj, "\"super\":true") != null;
    return self.toolPress(key, ctrl, shift, alt, sup, buf, id);
}

fn thunkScroll(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const x = extractNestedJsonInt(p, "x") orelse
        return jsonRpcError(buf, id, -32602, "Missing x");
    const y = extractNestedJsonInt(p, "y") orelse
        return jsonRpcError(buf, id, -32602, "Missing y");
    const dy = extractNestedJsonInt(p, "dy") orelse 15;
    return self.toolScroll(@intCast(x), @intCast(y), @intCast(dy), buf, id);
}

fn thunkToggleScratchpad(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const idx = extractNestedJsonInt(p, "index") orelse
        return jsonRpcError(buf, id, -32602, "Missing index");
    if (idx < 0 or idx > 8) return jsonRpcError(buf, id, -32602, "index must be 0..8");
    return self.toolToggleScratchpad(@intCast(idx), buf, id);
}

fn thunkScratchpad(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const name = extractNestedJsonString(p, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing name");
    const cmd = extractNestedJsonString(p, "cmd");
    return self.toolScratchpad(name, cmd, buf, id);
}

fn thunkSubscribeEvents(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return self.toolSubscribeEvents(buf, id);
}

fn thunkSessionSave(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const name = extractNestedJsonString(p, "name") orelse "default";
    return self.toolSessionSave(name, buf, id);
}

fn thunkSessionRestore(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const name = extractNestedJsonString(p, "name") orelse "default";
    return self.toolSessionRestore(name, buf, id);
}

fn toolSessionSave(self: *WmMcpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const Session = @import("Session.zig");
    Session.save(self.server, name) catch |err| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "session save failed: {}", .{err}) catch "session save failed";
        return jsonRpcError(buf, id, -32603, msg);
    };
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"saved session '{s}'"}}]}},"id":{s}}}
    , .{ name, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSessionRestore(self: *WmMcpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const Session = @import("Session.zig");
    Session.restore(self.server, name) catch |err| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "session restore failed: {}", .{err}) catch "session restore failed";
        return jsonRpcError(buf, id, -32603, msg);
    };
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"restored session '{s}'"}}]}},"id":{s}}}
    , .{ name, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSubscribeEvents(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const path = self.event_socket_path[0..self.event_socket_path_len];
    // Path contains `/` and maybe other chars; safe as a JSON string (no
    // need to escape — socket paths don't have quote/backslash/control).
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"socket\":\"{s}\"}}"}}]}},"id":{s}}}
    , .{ path, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

// ── Name resolution ───────────────────────────────────────────

/// Resolve a node from MCP params: tries "name" first, then "node_id".
fn resolveNode(self: *WmMcpServer, params_body: []const u8) ?u16 {
    if (extractNestedJsonString(params_body, "name")) |name| {
        return self.server.nodes.findByName(name, null);
    }
    if (extractNestedJsonInt(params_body, "node_id")) |nid| {
        return self.server.nodes.findById(@intCast(nid));
    }
    return null;
}

// ── Tool implementations ──────────────────────────────────────

fn toolListWindows(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..],
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"[
    , .{}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += prefix.len;

    var first = true;
    for (0..NodeRegistry.max_nodes) |slot| {
        if (srv.nodes.kind[slot] != .empty) {
            if (!first) {
                if (pos < buf.len) { buf[pos] = ','; pos += 1; }
            }
            first = false;

            const nid = srv.nodes.node_id[slot];
            const ws = srv.nodes.workspace[slot];
            const kind_str = switch (srv.nodes.kind[slot]) {
                .terminal => "terminal",
                .wayland_surface => "wayland",
                .empty => unreachable,
            };

            // Get title for terminal panes
            var title: []const u8 = "";
            for (srv.terminal_panes) |maybe_tp| {
                if (maybe_tp) |tp| {
                    if (tp.node_id == nid) {
                        if (tp.pane.vt.title_len > 0) {
                            title = tp.pane.vt.title[0..tp.pane.vt.title_len];
                        } else {
                            title = "shell";
                        }
                        break;
                    }
                }
            }

            var title_esc: [256]u8 = undefined;
            const safe_title = jsonEscapeString(title, &title_esc);

            const node_name = srv.nodes.getName(@intCast(slot));
            var name_esc: [64]u8 = undefined;
            const safe_name = jsonEscapeString(node_name, &name_esc);

            const entry = std.fmt.bufPrint(buf[pos..],
                \\{{\\\"id\\\":{d},\\\"name\\\":\\\"{s}\\\",\\\"workspace\\\":{d},\\\"kind\\\":\\\"{s}\\\",\\\"title\\\":\\\"{s}\\\",\\\"x\\\":{d},\\\"y\\\":{d},\\\"w\\\":{d},\\\"h\\\":{d}}}
            , .{
                nid, safe_name, ws, kind_str, safe_title,
                srv.nodes.pos_x[slot], srv.nodes.pos_y[slot],
                srv.nodes.width[slot], srv.nodes.height[slot],
            }) catch break;
            pos += entry.len;
        }
    }

    const suffix = std.fmt.bufPrint(buf[pos..],
        \\]"}}]}},"id":{s}}}
    , .{id_str}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += suffix.len;
    return buf[0..pos];
}

fn toolSpawnTerminal(self: *WmMcpServer, ws: u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;

    srv.spawnTerminal(ws);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"spawned terminal on workspace {d}"}}]}},"id":{s}}}
    , .{ ws, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolCloseWindow(self: *WmMcpServer, node_id: u64, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    if (!self.server.closeNode(node_id)) {
        return jsonRpcError(buf, id, -32602, "Window not found");
    }
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"closed window {d}"}}]}},"id":{s}}}
    , .{ node_id, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolFocusWindow(self: *WmMcpServer, node_id: u64, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;

    // Set as active in workspace, then update focus
    if (srv.nodes.findById(node_id)) |slot| {
        const ws_idx = srv.nodes.workspace[slot];
        const workspace = &srv.layout_engine.workspaces[ws_idx];
        // Find node in the workspace list and set active_index
        for (workspace.node_ids.items, 0..) |nid, idx| {
            if (nid == node_id) { workspace.active_index = idx; break; }
        }
        workspace.active_node = node_id;
        srv.updateFocusedTerminal();
        if (srv.bar) |b| b.render(srv);
        return std.fmt.bufPrint(buf,
            \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"focused window {d}"}}]}},"id":{s}}}
        , .{ node_id, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
    }

    return jsonRpcError(buf, id, -32602, "Window not found");
}

fn toolMoveToWorkspace(self: *WmMcpServer, node_id: u64, ws: u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    if (ws >= 10) return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    if (self.server.nodes.findById(node_id) == null)
        return jsonRpcError(buf, id, -32602, "Window not found");

    // Route through the single node-identity mutation chokepoint — it
    // handles floating vs tiled, re-arranges affected outputs, calls
    // recomputeVisibility, re-derives focus if the moved node was
    // focused and the target workspace is invisible, and emits
    // `node_moved`. Pre-v0.4.22 this called layout_engine directly
    // and never emitted the event.
    self.server.moveNodeToWorkspace(node_id, ws);
    if (self.server.bar) |b| b.render(self.server);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"moved window {d} to workspace {d}"}}]}},"id":{s}}}
    , .{ node_id, ws, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolListWorkspaces(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..],
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"[
    , .{}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += prefix.len;

    for (0..10) |wi| {
        if (wi > 0) {
            if (pos < buf.len) { buf[pos] = ','; pos += 1; }
        }
        const ws = &srv.layout_engine.workspaces[wi];
        const layout_str = switch (ws.layout) {
            .master_stack => "master-stack",
            .grid => "grid",
            .monocle => "monocle",
            .dishes => "dishes",
            .accordion => "accordion",
            .spiral => "spiral",
            .three_col => "three-col",
            .columns => "columns",
        };
        const active = if (wi == srv.layout_engine.active_workspace) "true" else "false";
        const count = ws.node_ids.items.len;

        const entry = std.fmt.bufPrint(buf[pos..],
            \\{{\\\"id\\\":{d},\\\"layout\\\":\\\"{s}\\\",\\\"windows\\\":{d},\\\"active\\\":{s}}}
        , .{ wi, layout_str, count, active }) catch break;
        pos += entry.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..],
        \\]"}}]}},"id":{s}}}
    , .{id_str}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += suffix.len;
    return buf[0..pos];
}

fn toolSwitchWorkspace(self: *WmMcpServer, ws: u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    if (ws >= 10) return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    // Route through the single workspace-mutation chokepoint so the
    // xmonad pull-swap semantics, recomputeVisibility, and event
    // emission (workspace_switched) all happen. Pre-v0.4.22 this path
    // drove layout_engine directly, bypassing focusWorkspace — which
    // silently swallowed workspace_switched events for every MCP-
    // triggered switch.
    self.server.focusWorkspace(ws);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"switched to workspace {d}"}}]}},"id":{s}}}
    , .{ ws, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSetLayout(self: *WmMcpServer, ws: u8, layout_str: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;
    if (ws >= 10) return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    const layout = teru.LayoutEngine.Layout.parse(layout_str) orelse
        return jsonRpcError(buf, id, -32602, "Unknown layout");

    srv.layout_engine.workspaces[ws].layout = layout;
    srv.arrangeworkspace(ws);
    if (srv.bar) |b| b.render(srv);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolGetConfig(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const cfg = &self.server.wm_config;
    const srv = self.server;

    const dims = srv.activeOutputDims();
    const out_w: u32 = dims.w;
    const out_h: u32 = dims.h;

    const top_enabled = if (srv.bar) |b| b.top.enabled else false;
    const bot_enabled = if (srv.bar) |b| b.bottom.enabled else false;
    // Font cell dimensions and bar height — derived at runtime from the
    // loaded font atlas. Useful for external tools computing grid layouts,
    // measuring gaps, or debugging. cell_h=16 default, bar_h = cell_h+4.
    const cell_w: u32 = if (srv.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (srv.font_atlas) |fa| fa.cell_height else 16;
    const bar_h: u32 = if (srv.bar) |b| b.bar_height else 0;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"gap\":{d},\"border_width\":{d},\"bg_color\":\"0x{x:0>8}\",\"output_width\":{d},\"output_height\":{d},\"cell_width\":{d},\"cell_height\":{d},\"bar_height\":{d},\"terminal_count\":{d},\"active_workspace\":{d},\"top_bar\":{any},\"bottom_bar\":{any}}}"}}]}},"id":{s}}}
    , .{ cfg.gap, cfg.border_width, cfg.bg_color, out_w, out_h, cell_w, cell_h, bar_h, srv.terminal_count, srv.layout_engine.active_workspace, top_enabled, bot_enabled, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSetConfig(self: *WmMcpServer, key: []const u8, value: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const cfg = &self.server.wm_config;

    if (std.mem.eql(u8, key, "gap")) {
        cfg.gap = std.fmt.parseInt(u16, value, 10) catch
            return jsonRpcError(buf, id, -32602, "Invalid gap value");
        // Re-arrange all workspaces to apply new gap
        for (0..self.server.layout_engine.workspaces.len) |ws| {
            self.server.arrangeworkspace(@intCast(ws));
        }
    } else if (std.mem.eql(u8, key, "border_width")) {
        cfg.border_width = std.fmt.parseInt(u16, value, 10) catch
            return jsonRpcError(buf, id, -32602, "Invalid border_width value");
    } else if (std.mem.eql(u8, key, "bg_color") or std.mem.eql(u8, key, "bg")) {
        var v = value;
        if (v.len > 0 and v[0] == '#') v = v[1..];
        if (v.len > 2 and v[0] == '0' and (v[1] == 'x' or v[1] == 'X')) v = v[2..];
        const parsed = std.fmt.parseInt(u32, v, 16) catch
            return jsonRpcError(buf, id, -32602, "Invalid bg_color (hex: #rrggbb or 0xaarrggbb)");
        cfg.bg_color = if (v.len <= 6) 0xFF000000 | parsed else parsed;
        if (self.server.bg_rect) |rect| {
            const col = cfg.bg_color;
            const rgba: [4]f32 = .{
                @as(f32, @floatFromInt((col >> 16) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt((col >> 8) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt(col & 0xFF)) / 255.0,
                @as(f32, @floatFromInt((col >> 24) & 0xFF)) / 255.0,
            };
            wlr.wlr_scene_rect_set_color(rect, &rgba);
        }
    } else {
        return jsonRpcError(buf, id, -32602, "Unknown config key (gap, border_width, bg_color)");
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"set {s} = {s}"}}]}},"id":{s}}}
    , .{ key, value, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolScreenshot(self: *WmMcpServer, path: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    if (self.server.takeScreenshotToPath(path)) {
        const dims = self.server.activeOutputDims();
        const out_w: u32 = dims.w;
        const out_h: u32 = dims.h;
        return std.fmt.bufPrint(buf,
            \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"screenshot saved to {s} ({d}x{d})"}}]}},"id":{s}}}
        , .{ path, out_w, out_h, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
    }

    return jsonRpcError(buf, id, -32603, "Screenshot failed");
}

fn toolNotify(_: *WmMcpServer, message: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    // No overlay surface in teruwm yet — the notification goes to stderr
    // so any tail -F of the compositor log sees it. A proper on-screen
    // toast would need a scene_rect + a libteru text renderer anchored
    // to the focused output; worth doing when session_lock_v1 lands
    // (shared scene-tree plumbing).
    std.debug.print("teruwm: notify: {s}\n", .{message});
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"notification logged"}}]}},"id":{s}}}
    , .{id_str}) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolReloadConfig(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    self.server.reloadWmConfig();
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"config reloaded (gap={d}, border={d})"}}]}},"id":{s}}}
    , .{ self.server.wm_config.gap, self.server.wm_config.border_width, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolScreenshotPane(self: *WmMcpServer, params_body: []const u8, path_opt: ?[]const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;

    const slot = self.resolveNode(params_body) orelse
        return jsonRpcError(buf, id, -32602, "Pane not found (provide name or node_id)");

    if (srv.nodes.kind[slot] != .terminal)
        return jsonRpcError(buf, id, -32602, "Only terminal pane screenshots are supported");

    const nid = srv.nodes.node_id[slot];
    const pane_name = srv.nodes.getName(slot);

    // Find the TerminalPane
    for (srv.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            if (tp.node_id == nid) {
                // Ensure grid is rendered
                tp.render();

                // Build path
                var path_buf: [512:0]u8 = undefined;
                const path = if (path_opt) |p| p else blk: {
                    const p = std.fmt.bufPrint(&path_buf, "/tmp/teruwm-pane-{s}.png", .{
                        if (pane_name.len > 0) pane_name else "unknown",
                    }) catch return jsonRpcError(buf, id, -32603, "Path error");
                    break :blk p;
                };

                // Null-terminate
                var path_z: [512:0]u8 = undefined;
                if (path.len >= path_z.len) return jsonRpcError(buf, id, -32602, "Path too long");
                @memcpy(path_z[0..path.len], path);
                path_z[path.len] = 0;

                png.write(srv.zig_allocator, @ptrCast(path_z[0..path.len :0]), tp.renderer.framebuffer, tp.renderer.width, tp.renderer.height) catch |err| {
                    return switch (err) {
                        error.FileOpenFailed => jsonRpcError(buf, id, -32603, "Failed to open output file"),
                        error.OutOfMemory => jsonRpcError(buf, id, -32603, "Out of memory"),
                    };
                };

                return std.fmt.bufPrint(buf,
                    \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"pane screenshot saved to {s} ({d}x{d})"}}]}},"id":{s}}}
                , .{ path, tp.renderer.width, tp.renderer.height, id_str }) catch
                    jsonRpcError(buf, id, -32603, "Internal error");
            }
        }
    }

    return jsonRpcError(buf, id, -32603, "Terminal pane not found in pane list");
}

fn toolSetName(self: *WmMcpServer, params_body: []const u8, new_name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const slot = self.resolveNode(params_body) orelse
        return jsonRpcError(buf, id, -32602, "Node not found (provide name or node_id)");

    self.server.nodes.setName(slot, new_name);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"renamed node {d} to {s}"}}]}},"id":{s}}}
    , .{ self.server.nodes.node_id[slot], new_name, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolRestart(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    // Schedule restart after response is sent (via deferred flag)
    self.server.restart_pending = true;
    if (self.server.primary_output) |output| wlr.wlr_output_schedule_frame(output);
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"restart scheduled — compositor will exec() on next frame"}}]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolPerf(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const perf = &self.server.perf;
    const max_us = if (perf.frame_time_max_us == std.math.maxInt(u64)) @as(u64, 0) else perf.frame_time_max_us;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"frames: {d}, avg: {d}us, max: {d}us, min: {d}us, pty_reads: {d}, pty_bytes: {d}, terminals: {d}"}}]}},"id":{s}}}
    , .{
        perf.frame_count,
        perf.avgFrameUs(),
        max_us,
        if (perf.frame_time_min_us == std.math.maxInt(u64)) @as(u64, 0) else perf.frame_time_min_us,
        perf.pty_reads,
        perf.pty_bytes,
        self.server.terminal_count,
        id_str,
    }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

/// Toggle (explicit=null) or set (explicit=true/false) a bar's enabled state.
fn toolToggleBar(self: *WmMcpServer, which: []const u8, explicit: ?bool, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const bar = self.server.bar orelse
        return jsonRpcError(buf, id, -32603, "bar not initialized");

    const is_top = std.mem.eql(u8, which, "top");
    const is_bot = std.mem.eql(u8, which, "bottom");
    if (!is_top and !is_bot)
        return jsonRpcError(buf, id, -32602, "which must be 'top' or 'bottom'");

    const bar_instance = if (is_top) &bar.top else &bar.bottom;
    const new_val = explicit orelse !bar_instance.enabled;
    bar_instance.enabled = new_val;

    // Hide/show the bar's scene node so it doesn't occupy pixels when disabled
    bar.updateVisibility();

    // Re-arrange every workspace — layout area changes when bar toggles
    for (0..self.server.layout_engine.workspaces.len) |ws| {
        self.server.arrangeworkspace(@intCast(ws));
    }
    if (new_val) bar.render(self.server);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{s} bar {s}"}}]}},"id":{s}}}
    , .{ which, if (new_val) "enabled" else "disabled", id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

// ── Push widget tools ──────────────────────────────────────────

fn toolSetWidget(self: *WmMcpServer, name: []const u8, text: []const u8, class_str: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    if (name.len == 0) return jsonRpcError(buf, id, -32602, "Empty name");
    if (name.len > teru.render.PushWidget.max_name)
        return jsonRpcError(buf, id, -32602, "Name too long (max 32)");
    if (text.len > teru.render.PushWidget.max_text)
        return jsonRpcError(buf, id, -32602, "Text too long (max 128)");

    const class = teru.render.PushWidget.Class.fromString(class_str);
    const ok = self.server.setPushWidget(name, text, class);
    if (!ok) return jsonRpcError(buf, id, -32603, "Out of widget slots (max 32)");

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"widget '{s}' set"}}]}},"id":{s}}}
    , .{ name, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolDeleteWidget(self: *WmMcpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    if (name.len == 0) return jsonRpcError(buf, id, -32602, "Empty name");
    const removed = self.server.deletePushWidget(name);
    const id_str = id orelse "null";
    const msg = if (removed) "deleted" else "not found";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"widget '{s}' {s}"}}]}},"id":{s}}}
    , .{ name, msg, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolListWidgets(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..],
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"[
    , .{}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += prefix.len;

    var first = true;
    const now_ns: i64 = @intCast(teru.compat.monotonicNow());
    for (&srv.push_widgets) |*pw| {
        if (!pw.used) continue;
        if (!first) {
            if (pos < buf.len) { buf[pos] = ','; pos += 1; }
        }
        first = false;

        const age_ms: u64 = blk: {
            if (pw.last_update_ns == 0) break :blk 0;
            const diff: i64 = now_ns -| pw.last_update_ns;
            if (diff < 0) break :blk 0;
            break :blk @intCast(@divTrunc(diff, std.time.ns_per_ms));
        };
        const class_name = @tagName(pw.class);

        var text_esc_buf: [256]u8 = undefined;
        const safe_text = jsonEscapeString(pw.text(), &text_esc_buf);
        var name_esc_buf: [64]u8 = undefined;
        const safe_name = jsonEscapeString(pw.name(), &name_esc_buf);

        const entry = std.fmt.bufPrint(buf[pos..],
            \\{{\\\"name\\\":\\\"{s}\\\",\\\"text\\\":\\\"{s}\\\",\\\"class\\\":\\\"{s}\\\",\\\"age_ms\\\":{d}}}
        , .{ safe_name, safe_text, class_name, age_ms }) catch break;
        pos += entry.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..],
        \\]"}}]}},"id":{s}}}
    , .{id_str}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += suffix.len;
    return buf[0..pos];
}

// ── E2E test tools (internal) ──────────────────────────────────

fn toolTestDrag(self: *WmMcpServer, from_x: i32, from_y: i32, to_x: i32, to_y: i32, super_held: bool, button: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;

    // Real monotonic timestamps (ms) for each phase — chromium / GTK
    // compute click-vs-drag by checking the delta between press and
    // release time. When both are time=0 (epoch), some input pipelines
    // drop the click as "too old". Use a monotonic source with a small
    // non-zero offset between phases.
    const ns_per_ms: i128 = 1_000_000;
    const t0_ns: i128 = @import("teru").compat.monotonicNow();
    const t0: u32 = @intCast(@mod(@divTrunc(t0_ns, ns_per_ms), 0xFFFFFFFF));

    // Phase 1: warp cursor to start, fire motion so focus follows
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(from_x), @floatFromInt(from_y));
    srv.processCursorMotion(t0);

    // Phase 2: button press. Brief sleep so release carries a different
    // timestamp — many toolkits distinguish "click" vs "drag-without-
    // motion" by duration, and same-time press+release can be treated
    // as noise.
    srv.processCursorButton(button, 1, t0, super_held);

    // Phase 3: warp cursor to destination, fire motion so drag tracks
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(to_x), @floatFromInt(to_y));
    srv.processCursorMotion(t0 + 10);

    // Phase 4: button release at t0 + 20ms — gives chromium's click
    // dispatcher a realistic down-up interval.
    srv.processCursorButton(button, 0, t0 + 20, super_held);

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"drag ({d},{d})->({d},{d}) super={any} button={d}"}}]}},"id":{s}}}
    , .{ from_x, from_y, to_x, to_y, super_held, button, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolTestMove(self: *WmMcpServer, x: i32, y: i32, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(x), @floatFromInt(y));
    srv.processCursorMotion(0);
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"cursor at ({d},{d})"}}]}},"id":{s}}}
    , .{ x, y, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolMousePath(
    self: *WmMcpServer,
    from_x: i32, from_y: i32, to_x: i32, to_y: i32,
    duration_ms: u32, humanize: bool, button: ?u32, super_held: bool,
    buf: []u8, id: ?[]const u8,
) []const u8 {
    @import("ServerMouse.zig").pathMove(
        self.server,
        from_x, from_y, to_x, to_y,
        duration_ms, humanize, button, super_held,
    );
    const id_str = id orelse "null";
    const btn_val: i32 = if (button) |b| @intCast(b) else -1;
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"path ({d},{d})->({d},{d}) {d}ms humanize={any} button={d}"}}]}},"id":{s}}}
    , .{ from_x, from_y, to_x, to_y, duration_ms, humanize, btn_val, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolToggleScratchpad(self: *WmMcpServer, index: u8, buf: []u8, id: ?[]const u8) []const u8 {
    // Compat shim: numbered index delegates to named pad<N+1>. Report
    // the toggle result by reading the new state from the NodeRegistry.
    var name_buf: [8]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "pad{d}", .{index + 1}) catch return jsonRpcError(buf, id, -32603, "bad index");
    self.server.toggleScratchpadByName(name, null);

    const id_str = id orelse "null";
    const slot = self.server.nodes.findByScratchpad(name);
    const created = slot != null;
    const visible = if (slot) |s| !self.server.nodes.isHidden(s) else false;
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"scratchpad {d} name={s} visible={any} created={any}"}}]}},"id":{s}}}
    , .{ index, name, visible, created, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolScratchpad(self: *WmMcpServer, name: []const u8, cmd: ?[]const u8, buf: []u8, id: ?[]const u8) []const u8 {
    if (name.len == 0) return jsonRpcError(buf, id, -32602, "scratchpad name required");
    self.server.toggleScratchpadByName(name, cmd);

    const id_str = id orelse "null";
    const slot = self.server.nodes.findByScratchpad(name);
    const created = slot != null;
    const visible = if (slot) |s| !self.server.nodes.isHidden(s) else false;
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"scratchpad name={s} visible={any} created={any}"}}]}},"id":{s}}}
    , .{ name, visible, created, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolTestKey(self: *WmMcpServer, action_name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const Action = teru.Keybinds.Action;
    // Parse action from string (exhaustive — unknown → error)
    const action: Action = blk: {
        inline for (@typeInfo(Action).@"enum".fields) |f| {
            if (std.mem.eql(u8, f.name, action_name)) {
                break :blk @enumFromInt(f.value);
            }
        }
        return jsonRpcError(buf, id, -32602, "Unknown action name");
    };

    const handled = self.server.executeAction(action);
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"action '{s}' handled={any}"}}]}},"id":{s}}}
    , .{ action_name, handled, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

// ── AI-first physical input MCP tools ──────────────────────────
//
// teruwm is an AI-first WM. These tools let an agent drive the same
// pointer/keyboard pipeline a real touchpad/keyboard would, through
// the wlroots seat — clients (Chromium, Firefox, GIMP, …) cannot
// distinguish synthetic events from physical ones.

fn toolClick(self: *WmMcpServer, x: i32, y: i32, button: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    const ms_now = monotonicMs();

    // Warp cursor + motion (sets pointer focus on the surface under
    // the new cursor position).
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(x), @floatFromInt(y));
    srv.processCursorMotion(ms_now);

    // Identify what we landed on for the response (so the agent can
    // verify the click went where it intended).
    const hit_id = srv.nodeAtPoint(@floatFromInt(x), @floatFromInt(y));
    var kind_str: []const u8 = "none";
    if (hit_id) |h| {
        if (srv.nodes.findById(h)) |slot| {
            kind_str = switch (srv.nodes.kind[slot]) {
                .terminal => "terminal",
                .wayland_surface => "wayland",
                .empty => "none",
            };
        }
    }

    // Press, brief delta, release. Real touchpads have ~10-30ms hold;
    // we use 15ms which Chromium / GTK treat as a click.
    srv.processCursorButton(button, 1, ms_now, false);
    srv.processCursorButton(button, 0, ms_now + 15, false);

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"cx\":{d},\"cy\":{d},\"hit\":{?d},\"kind\":\"{s}\"}}"}}]}},"id":{s}}}
    , .{ x, y, hit_id, kind_str, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolType(self: *WmMcpServer, text: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    var ms = monotonicMs();
    var sent: u32 = 0;
    var dropped: u32 = 0;

    for (text) |c| {
        const map = asciiToKeycode(c) orelse {
            dropped += 1;
            continue;
        };
        if (map.shift) {
            sendKey(srv, KEY_LEFTSHIFT, true, ms);
            ms += 1;
        }
        sendKey(srv, map.keycode, true, ms);
        ms += 5;
        sendKey(srv, map.keycode, false, ms);
        ms += 1;
        if (map.shift) {
            sendKey(srv, KEY_LEFTSHIFT, false, ms);
            ms += 1;
        }
        sent += 1;
    }

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"sent\":{d},\"dropped\":{d}}}"}}]}},"id":{s}}}
    , .{ sent, dropped, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolPress(self: *WmMcpServer, key: []const u8, ctrl: bool, shift: bool, alt: bool, sup: bool, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    var ms = monotonicMs();

    const keycode = nameToKeycode(key) orelse return jsonRpcError(buf, id, -32602, "Unknown key name");

    // Modifier presses
    if (ctrl) { sendKey(srv, KEY_LEFTCTRL, true, ms); ms += 1; }
    if (shift) { sendKey(srv, KEY_LEFTSHIFT, true, ms); ms += 1; }
    if (alt) { sendKey(srv, KEY_LEFTALT, true, ms); ms += 1; }
    if (sup) { sendKey(srv, KEY_LEFTMETA, true, ms); ms += 1; }

    sendKey(srv, keycode, true, ms);
    ms += 10;
    sendKey(srv, keycode, false, ms);
    ms += 1;

    if (sup) { sendKey(srv, KEY_LEFTMETA, false, ms); ms += 1; }
    if (alt) { sendKey(srv, KEY_LEFTALT, false, ms); ms += 1; }
    if (shift) { sendKey(srv, KEY_LEFTSHIFT, false, ms); ms += 1; }
    if (ctrl) { sendKey(srv, KEY_LEFTCTRL, false, ms); ms += 1; }

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"key\":\"{s}\",\"keycode\":{d}}}"}}]}},"id":{s}}}
    , .{ key, keycode, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolScroll(self: *WmMcpServer, x: i32, y: i32, dy: i32, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    const ms_now = monotonicMs();

    // Position cursor + sync pointer focus
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(x), @floatFromInt(y));
    srv.processCursorMotion(ms_now);

    // Send axis event. wlroots: orientation 0 = vertical, source 0 = wheel.
    wlr.wlr_seat_pointer_notify_axis(
        srv.seat,
        ms_now,
        0, // WL_POINTER_AXIS_VERTICAL_SCROLL
        @floatFromInt(dy),
        if (dy > 0) 1 else -1,
        0, // WL_POINTER_AXIS_SOURCE_WHEEL
        0, // WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL
    );
    wlr.wlr_seat_pointer_notify_frame(srv.seat);

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"x\":{d},\"y\":{d},\"dy\":{d}}}"}}]}},"id":{s}}}
    , .{ x, y, dy, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

// ── Keyboard helpers ──────────────────────────────────────────

/// evdev keycodes (from include/uapi/linux/input-event-codes.h). These
/// are what wlr_seat_keyboard_notify_key takes. xkb adds 8 internally.
const KEY_ESC: u32 = 1;
const KEY_BACKSPACE: u32 = 14;
const KEY_TAB: u32 = 15;
const KEY_ENTER: u32 = 28;
const KEY_LEFTCTRL: u32 = 29;
const KEY_LEFTSHIFT: u32 = 42;
const KEY_LEFTALT: u32 = 56;
const KEY_LEFTMETA: u32 = 125;
const KEY_SPACE: u32 = 57;
const KEY_UP: u32 = 103;
const KEY_LEFT: u32 = 105;
const KEY_RIGHT: u32 = 106;
const KEY_DOWN: u32 = 108;
const KEY_HOME: u32 = 102;
const KEY_END: u32 = 107;
const KEY_PAGEUP: u32 = 104;
const KEY_PAGEDOWN: u32 = 109;

const AsciiMap = struct { keycode: u32, shift: bool };

/// US QWERTY ASCII → evdev keycode + shift. Not locale-aware; assumes
/// the user / agent target a US layout. Non-US users will see swapped
/// punctuation. Future: read xkb_keymap and reverse-look up properly.
fn asciiToKeycode(c: u8) ?AsciiMap {
    return switch (c) {
        ' ' => .{ .keycode = KEY_SPACE, .shift = false },
        'a' => .{ .keycode = 30, .shift = false },
        'b' => .{ .keycode = 48, .shift = false },
        'c' => .{ .keycode = 46, .shift = false },
        'd' => .{ .keycode = 32, .shift = false },
        'e' => .{ .keycode = 18, .shift = false },
        'f' => .{ .keycode = 33, .shift = false },
        'g' => .{ .keycode = 34, .shift = false },
        'h' => .{ .keycode = 35, .shift = false },
        'i' => .{ .keycode = 23, .shift = false },
        'j' => .{ .keycode = 36, .shift = false },
        'k' => .{ .keycode = 37, .shift = false },
        'l' => .{ .keycode = 38, .shift = false },
        'm' => .{ .keycode = 50, .shift = false },
        'n' => .{ .keycode = 49, .shift = false },
        'o' => .{ .keycode = 24, .shift = false },
        'p' => .{ .keycode = 25, .shift = false },
        'q' => .{ .keycode = 16, .shift = false },
        'r' => .{ .keycode = 19, .shift = false },
        's' => .{ .keycode = 31, .shift = false },
        't' => .{ .keycode = 20, .shift = false },
        'u' => .{ .keycode = 22, .shift = false },
        'v' => .{ .keycode = 47, .shift = false },
        'w' => .{ .keycode = 17, .shift = false },
        'x' => .{ .keycode = 45, .shift = false },
        'y' => .{ .keycode = 21, .shift = false },
        'z' => .{ .keycode = 44, .shift = false },
        'A'...'Z' => |u| .{ .keycode = (asciiToKeycode(u + 32) orelse return null).keycode, .shift = true },
        '0' => .{ .keycode = 11, .shift = false },
        '1'...'9' => |d| .{ .keycode = @as(u32, d - '1' + 2), .shift = false },
        '!' => .{ .keycode = 2, .shift = true },
        '@' => .{ .keycode = 3, .shift = true },
        '#' => .{ .keycode = 4, .shift = true },
        '$' => .{ .keycode = 5, .shift = true },
        '%' => .{ .keycode = 6, .shift = true },
        '^' => .{ .keycode = 7, .shift = true },
        '&' => .{ .keycode = 8, .shift = true },
        '*' => .{ .keycode = 9, .shift = true },
        '(' => .{ .keycode = 10, .shift = true },
        ')' => .{ .keycode = 11, .shift = true },
        '-' => .{ .keycode = 12, .shift = false },
        '_' => .{ .keycode = 12, .shift = true },
        '=' => .{ .keycode = 13, .shift = false },
        '+' => .{ .keycode = 13, .shift = true },
        '[' => .{ .keycode = 26, .shift = false },
        '{' => .{ .keycode = 26, .shift = true },
        ']' => .{ .keycode = 27, .shift = false },
        '}' => .{ .keycode = 27, .shift = true },
        '\\' => .{ .keycode = 43, .shift = false },
        '|' => .{ .keycode = 43, .shift = true },
        ';' => .{ .keycode = 39, .shift = false },
        ':' => .{ .keycode = 39, .shift = true },
        '\'' => .{ .keycode = 40, .shift = false },
        '"' => .{ .keycode = 40, .shift = true },
        ',' => .{ .keycode = 51, .shift = false },
        '<' => .{ .keycode = 51, .shift = true },
        '.' => .{ .keycode = 52, .shift = false },
        '>' => .{ .keycode = 52, .shift = true },
        '/' => .{ .keycode = 53, .shift = false },
        '?' => .{ .keycode = 53, .shift = true },
        '`' => .{ .keycode = 41, .shift = false },
        '~' => .{ .keycode = 41, .shift = true },
        '\n' => .{ .keycode = KEY_ENTER, .shift = false },
        '\t' => .{ .keycode = KEY_TAB, .shift = false },
        else => null,
    };
}

fn nameToKeycode(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Return")) return KEY_ENTER;
    if (std.mem.eql(u8, name, "Enter")) return KEY_ENTER;
    if (std.mem.eql(u8, name, "Tab")) return KEY_TAB;
    if (std.mem.eql(u8, name, "Escape")) return KEY_ESC;
    if (std.mem.eql(u8, name, "Esc")) return KEY_ESC;
    if (std.mem.eql(u8, name, "BackSpace")) return KEY_BACKSPACE;
    if (std.mem.eql(u8, name, "Backspace")) return KEY_BACKSPACE;
    if (std.mem.eql(u8, name, "Up")) return KEY_UP;
    if (std.mem.eql(u8, name, "Down")) return KEY_DOWN;
    if (std.mem.eql(u8, name, "Left")) return KEY_LEFT;
    if (std.mem.eql(u8, name, "Right")) return KEY_RIGHT;
    if (std.mem.eql(u8, name, "Home")) return KEY_HOME;
    if (std.mem.eql(u8, name, "End")) return KEY_END;
    if (std.mem.eql(u8, name, "PageUp")) return KEY_PAGEUP;
    if (std.mem.eql(u8, name, "PageDown")) return KEY_PAGEDOWN;
    if (std.mem.eql(u8, name, "Space")) return KEY_SPACE;
    if (name.len == 1) {
        if (asciiToKeycode(name[0])) |m| return m.keycode;
    }
    return null;
}

fn sendKey(srv: *Server, evdev_keycode: u32, pressed: bool, time_ms: u32) void {
    const state: u32 = if (pressed) 1 else 0;
    wlr.wlr_seat_keyboard_notify_key(srv.seat, time_ms, evdev_keycode, state);
}

fn monotonicMs() u32 {
    const ns_per_ms: i128 = 1_000_000;
    const t_ns: i128 = teru.compat.monotonicNow();
    return @intCast(@mod(@divTrunc(t_ns, ns_per_ms), 0xFFFFFFFF));
}
