//! MCP Server — exposes teru's process graph and pane state over a Unix domain socket.
//!
//! Implements a minimal HTTP JSON-RPC 2.0 server for the Model Context Protocol.
//! Listens on /run/user/$UID/teru-$PID.sock.
//!
//! Supported methods:
//!   tools/list  — returns tool definitions
//!   tools/call  — dispatches to a tool handler

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Multiplexer = @import("../core/Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Grid = @import("../core/Grid.zig");
const compat = @import("../compat.zig");
const ipc = @import("../server/ipc.zig");
const png = @import("../png.zig");
const tier = @import("../render/tier.zig");

const tools = @import("McpTools.zig");
const mcp_dispatch = @import("McpDispatch.zig");
const forward = @import("forward.zig");
const build_options = @import("build_options");
const impl = @import("McpServerTools.zig");
const McpServer = @This();

// TODO: Migrate to std.Io.net.UnixAddress.listen() once the Io.net API supports
// non-blocking accept (needed for single-threaded event loop integration).
// As of 0.16-dev.3039, Server.accept() either blocks or returns WouldBlock with
// no public API to set the socket to non-blocking mode.

const max_request: usize = 65536;
const max_response: usize = 65536;
const socket_path_max: usize = 108; // Unix domain socket sun_path limit

/// Invalid-fd sentinel. `posix.fd_t` is `c_int` on POSIX (−1 is the
/// conventional invalid value) and `*anyopaque` on Windows (HANDLE).
/// This module only runs on POSIX at runtime — Windows never reaches
/// the daemon path — but the field declarations must still type-check.
const invalid_fd: posix.fd_t = if (builtin.os.tag == .windows)
    @ptrFromInt(std.math.maxInt(usize))
else
    -1;

socket_path: [socket_path_max]u8,
socket_path_len: usize,
socket_fd: posix.fd_t,
multiplexer: *Multiplexer,
graph: *ProcessGraph,
allocator: Allocator,
running: bool,

/// Set from `$TERU_MCP_READONLY=1` at init. When true, the framework
/// rejects every tool listed in `write_tool_names` and filters them
/// out of `tools/list`. Defense-in-depth versus the bridge filter:
/// a client connecting directly to the socket can't bypass this.
read_only: bool = false,

// ── Event subscriber channel (v0.4.21) ────────────────────────
// Separate socket pushing newline-delimited JSON events for things
// that change *without* an explicit tool call — pane spawn/exit,
// agent lifecycle, command exec. Same shape as teruwm's event
// channel; `teru_subscribe_events` returns both paths so an agent
// can connect to teru + teruwm events with one handshake.
event_socket_path: [socket_path_max]u8 = undefined,
event_socket_path_len: usize = 0,
event_socket_fd: posix.fd_t = invalid_fd,
event_subscriber_fd: posix.fd_t = invalid_fd,
// Screen dimensions for PTY resize after pane creation
screen_width: u32 = 0,
screen_height: u32 = 0,
cell_width: u32 = 0,
cell_height: u32 = 0,
padding: u32 = 0,
status_bar_h: u32 = 0,
renderer: ?*tier.Renderer = null,

// ── Lifecycle ──────────────────────────────────────────────────

pub fn init(allocator: Allocator, mux: *Multiplexer, graph: *ProcessGraph) !McpServer {
    const pid = compat.getPid();

    // Build unique path: teru-mcp-{pid}
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return error.PathTooLong;
    var ipc_path_buf: [256]u8 = undefined;
    const path = ipc.buildPath(&ipc_path_buf, "mcp", pid_str) orelse return error.PathTooLong;
    const path_len = path.len;

    const ipc_server = ipc.listen(path) catch return error.SocketFailed;
    const sock = ipc_server.rawFd();

    const read_only = if (compat.getenv("TERU_MCP_READONLY")) |v|
        v.len > 0 and v[0] == '1'
    else
        false;

    var server = McpServer{
        .socket_path = undefined,
        .socket_path_len = path_len,
        .socket_fd = sock,
        .multiplexer = mux,
        .graph = graph,
        .allocator = allocator,
        .running = true,
        .read_only = read_only,
    };
    @memcpy(server.socket_path[0..path_len], path);

    // Companion events socket — best-effort push channel.
    var evt_path_buf: [256]u8 = undefined;
    if (ipc.buildPath(&evt_path_buf, "mcp-events", pid_str)) |evt_path| {
        if (ipc.listen(evt_path)) |evt_ipc| {
            const evt_sock = evt_ipc.rawFd();
            server.event_socket_fd = evt_sock;
            const n = @min(evt_path.len, server.event_socket_path.len);
            @memcpy(server.event_socket_path[0..n], evt_path[0..n]);
            server.event_socket_path_len = n;
        } else |_| {}
    }

    return server;
}

pub fn getSocketPath(self: *const McpServer) []const u8 {
    return self.socket_path[0..self.socket_path_len];
}

pub fn deinit(self: *McpServer) void {
    _ = posix.system.close(self.socket_fd);
    if (self.event_subscriber_fd != invalid_fd) _ = posix.system.close(self.event_subscriber_fd);
    if (self.event_socket_fd != invalid_fd) _ = posix.system.close(self.event_socket_fd);

    // Unlink socket files
    var unlink_buf: [socket_path_max + 1]u8 = undefined;
    @memcpy(unlink_buf[0..self.socket_path_len], self.socket_path[0..self.socket_path_len]);
    unlink_buf[self.socket_path_len] = 0;
    _ = std.c.unlink(@ptrCast(&unlink_buf));

    if (self.event_socket_path_len > 0) {
        @memcpy(unlink_buf[0..self.event_socket_path_len], self.event_socket_path[0..self.event_socket_path_len]);
        unlink_buf[self.event_socket_path_len] = 0;
        _ = std.c.unlink(@ptrCast(&unlink_buf));
    }

    self.running = false;
}

// ── Event loop integration ─────────────────────────────────────

/// Non-blocking accept + handle. Call from the main event loop.
pub fn poll(self: *McpServer) void {
    if (!self.running) return;

    // Accept on the events socket first — unlike the request socket,
    // this fd stays open (pushed JSON events flow here).
    // POSIX-only: fcntl is not in Windows libc; the daemon path never
    // runs on Windows anyway.
    if (builtin.os.tag != .windows and self.event_socket_fd != invalid_fd) {
        if (ipc.accept(ipc.IpcHandle.fromRaw(self.event_socket_fd))) |evt_client| {
            const fd = evt_client.rawFd();
            const F_GETFL: c_int = 3;
            const F_SETFL: c_int = 4;
            const O_NONBLOCK: c_int = 0o4000;
            const flags = std.c.fcntl(fd, F_GETFL);
            if (flags >= 0) _ = std.c.fcntl(fd, F_SETFL, flags | O_NONBLOCK);
            // Replace any prior subscriber.
            if (self.event_subscriber_fd != invalid_fd) _ = posix.system.close(self.event_subscriber_fd);
            self.event_subscriber_fd = fd;
        }
    }

    // Non-blocking accept on the main request socket
    const client = ipc.accept(ipc.IpcHandle.fromRaw(self.socket_fd)) orelse return;
    self.handleRequest(client.rawFd());
    client.close();
}

/// Push one JSON event to the current subscriber (if any). On write
/// failure the subscriber is dropped. Caller supplies a bare JSON
/// object; we append `\n` ourselves. O_NONBLOCK on the fd means slow
/// consumers drop events, never stall us.
pub fn emitEvent(self: *McpServer, json_line: []const u8) void {
    if (self.event_subscriber_fd == invalid_fd) return;
    var buf: [4096]u8 = undefined;
    const n = @min(json_line.len, buf.len - 1);
    @memcpy(buf[0..n], json_line[0..n]);
    buf[n] = '\n';
    const total = n + 1;
    const w = std.c.write(self.event_subscriber_fd, &buf, total);
    if (w <= 0) {
        _ = posix.system.close(self.event_subscriber_fd);
        self.event_subscriber_fd = invalid_fd;
    }
}

/// Helper: emit `{"event":"<kind>", ...rest...}` using format.
pub fn emitEventKind(self: *McpServer, kind: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (self.event_subscriber_fd == invalid_fd) return;
    var buf: [2048]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{{\"event\":\"{s}\"", .{kind}) catch return;
    const rest = std.fmt.bufPrint(buf[prefix.len..], fmt, args) catch return;
    const end = prefix.len + rest.len;
    if (end + 2 > buf.len) return;
    buf[end] = '}';
    self.emitEvent(buf[0 .. end + 1]);
}

// ── Line-JSON / JSON-RPC handling ──────────────────────────────
//
// Transport: each connection is one request/response pair in line-
// delimited JSON-RPC 2.0. Client writes `<json>\n`, server writes
// `<response-json>\n` and closes. No HTTP, no Content-Length. The
// newline delimiter is optional on the request side (bare JSON also
// works, since dispatch parses the body directly) but the server
// always terminates its reply with `\n` so stdio bridges can read
// line-at-a-time without buffering heuristics.

// ── MCP framework wiring ──────────────────────────────────────
//
// handleRequest, dispatch, method routing, initialize, tools/list,
// tools/call, prompts/list, notifications all live in
// teru.McpFramework now. This server supplies: line-JSON framing,
// tool_table (built from mcp_dispatch.tools × dispatch_table below),
// prompt handlers, the teruwm forward fallback.

const F = @import("McpFramework.zig").Framework(McpServer);

/// Comptime-built name → thunk map. Pairs every entry in
/// mcp_dispatch.tools (1:1 with dispatch_table by index) into a
/// StaticStringMap. Adding a tool: add a `Tool` in McpDispatch AND a
/// Handler in `dispatch_table` — a length mismatch is a compile error.
const tool_table = std.StaticStringMap(F.Thunk).initComptime(blk: {
    var entries: [mcp_dispatch.tools.len]struct { []const u8, F.Thunk } = undefined;
    for (mcp_dispatch.tools, 0..) |tool, i| entries[i] = .{ tool.name, dispatch_table[i] };
    break :blk entries;
});

const prompts_list_body: []const u8 =
    \\[{"name":"workspace_setup","description":"Set up teru workspaces with panes, layouts, and commands. Describe your desired workspace configuration in natural language.","arguments":[{"name":"description","description":"Natural language description of desired workspace setup (e.g. '4 workspaces, workspace 1 has 1 pane, workspace 2 has 2 panes, each running vim')","required":true}]}]
;

/// Tools that mutate state. Mirror of McpBridge.write_tool_names —
/// the bridge filters at the proxy boundary, the framework enforces
/// at the socket so a direct connection can't bypass either.
const write_tool_names = [_][]const u8{
    "teru_send_input",
    "teru_create_pane",
    "teru_broadcast",
    "teru_send_keys",
    "teru_close_pane",
    "teru_switch_workspace",
    "teru_set_layout",
    "teru_set_config",
    "teru_session_restore",
    "teru_focus_pane",
};

/// Snapshotted at server init from `$TERU_MCP_READONLY=1`.
/// Stored on the server struct rather than re-read per request because
/// env can't change after process start, and the framework gives us
/// `*McpServer` for free in its read-only callback.
fn isReadOnly(self: *McpServer) bool {
    return self.read_only;
}

pub const framework_config: F.Config = .{
    .server_name = "teru",
    .server_version = build_options.version,
    .framing = .line_json,
    .capabilities_json = "\"tools\":{},\"prompts\":{}",
    .tool_table = &tool_table,
    .tools_list_body = mcp_dispatch.tools_list_body,
    .prompts = .{
        .list_body = prompts_list_body,
        .get_fn = handlePromptsGet,
    },
    .forward = .{
        .prefix = "teruwm_",
        .fn_ = forward.forwardRequest,
        .unavailable_msg = "teruwm not running or socket unreachable",
    },
    .read_only = .{
        .is_active_fn = isReadOnly,
        .write_tool_names = &write_tool_names,
    },
};

fn handleRequest(self: *McpServer, conn_fd: posix.fd_t) void {
    F.handleRequestFd(self, conn_fd, &framework_config);
}

/// Route a JSON-RPC body through the framework. Public because the
/// OSC-9999 in-band path reaches dispatch without a socket — agents
/// inside a local pane call the server directly through their PTY.
pub fn dispatch(self: *McpServer, body: []const u8, resp_buf: []u8) []const u8 {
    return F.dispatch(self, body, resp_buf, &framework_config);
}

/// Minimal JSON string escape — replaces `"` and `\` so user-supplied
/// text embedded in a JSON string value can't break the structure.
fn jsonEscape(dst: []u8, src: []const u8) []const u8 {
    var pos: usize = 0;
    for (src) |ch| {
        if (pos + 2 > dst.len) break;
        if (ch == '"' or ch == '\\') {
            if (pos + 2 > dst.len) break;
            dst[pos] = '\\';
            dst[pos + 1] = ch;
            pos += 2;
        } else if (ch < 0x20) {
            // Drop control characters (would break JSON)
            continue;
        } else {
            dst[pos] = ch;
            pos += 1;
        }
    }
    return dst[0..pos];
}

// ── Prompts (only prompts/get is server-specific; prompts/list is static) ──

fn handlePromptsGet(self: *McpServer, body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = self;
    const id_str = id orelse "null";
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing params");
    const params_body = body[params_start..];
    const name = tools.extractNestedJsonString(params_body, "name") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing params.name");

    if (std.mem.eql(u8, name, "workspace_setup")) {
        const user_desc_raw = tools.extractNestedJsonString(params_body, "description") orelse "default setup";
        // JSON-escape the user description to prevent prompt injection
        // via embedded quotes or backslashes in the user-supplied text.
        var escaped_buf: [512]u8 = undefined;
        const user_desc = jsonEscape(&escaped_buf, user_desc_raw);
        return std.fmt.bufPrint(buf,
            \\{{"jsonrpc":"2.0","result":{{"messages":[
            \\{{"role":"user","content":{{"type":"text","text":"Set up teru workspaces as follows: {s}\n\nYou have these teru MCP tools:\n- teru_switch_workspace(workspace) — switch to workspace 0-9\n- teru_create_pane(workspace, direction) — spawn a new pane (starts user shell)\n- teru_send_input(pane_id, text) — type text into pane (omit \\n to leave command typed but not executed)\n- teru_send_keys(pane_id, keys) — send keystrokes like ['enter'], ['ctrl+c']\n- teru_set_layout(workspace, layout) — layouts: master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion\n- teru_set_config(key, value) — set appearance: font_size, opacity, theme, bg, fg, padding, cursor_shape\n- teru_focus_pane(pane_id) — focus a pane\n- teru_list_panes() — list all panes to get IDs\n\nWorkflow:\n1. For each workspace: switch to it, create panes, set layout\n2. To type a command without running it: teru_send_input(id, 'command') — no \\n\n3. To type and execute: teru_send_input(id, 'command') then teru_send_keys(id, ['enter'])\n4. After creating panes, call teru_list_panes() to get their IDs for send_input\n5. Workspace 0 already has 1 pane — create additional panes as needed"}}}}
            \\]}},"id":{s}}}
        , .{ user_desc, id_str }) catch
            tools.jsonRpcError(buf, id, -32603, "Internal error");
    } else {
        return tools.jsonRpcError(buf, id, -32602, "Unknown prompt");
    }
}

// ── Dispatch table ─────────────────────────────────────────────
// One adapter per tool. Each unpacks its args from params_body and
// delegates to the real handler below. Order MUST match McpDispatch.tools.
// A mismatch is a compile-time array-length error.

const Handler = *const fn (*McpServer, params_body: []const u8, buf: []u8, id: ?[]const u8) []const u8;

const dispatch_table: [mcp_dispatch.tools.len]Handler = .{
    impl.callListPanes,
    impl.callReadOutput,
    impl.callGetGraph,
    impl.callSendInput,
    impl.callCreatePane,
    impl.callBroadcast,
    impl.callSendKeys,
    impl.callGetState,
    impl.callFocusPane,
    impl.callClosePane,
    impl.callSwitchWorkspace,
    impl.callScroll,
    impl.callWaitFor,
    impl.callSetLayout,
    impl.callSetConfig,
    impl.callGetConfig,
    impl.callSessionSave,
    impl.callSessionRestore,
    impl.callScreenshot,
    impl.callSubscribeEvents,
};

