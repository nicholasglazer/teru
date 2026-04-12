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
const build_options = @import("build_options");
const McpServer = @This();

// TODO: Migrate to std.Io.net.UnixAddress.listen() once the Io.net API supports
// non-blocking accept (needed for single-threaded event loop integration).
// As of 0.16-dev.3039, Server.accept() either blocks or returns WouldBlock with
// no public API to set the socket to non-blocking mode.

const max_request: usize = 65536;
const max_response: usize = 65536;
const socket_path_max: usize = 108; // Unix domain socket sun_path limit

socket_path: [socket_path_max]u8,
socket_path_len: usize,
socket_fd: posix.fd_t,
multiplexer: *Multiplexer,
graph: *ProcessGraph,
allocator: Allocator,
running: bool,
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

    var server = McpServer{
        .socket_path = undefined,
        .socket_path_len = path_len,
        .socket_fd = sock,
        .multiplexer = mux,
        .graph = graph,
        .allocator = allocator,
        .running = true,
    };
    @memcpy(server.socket_path[0..path_len], path);

    return server;
}

pub fn getSocketPath(self: *const McpServer) []const u8 {
    return self.socket_path[0..self.socket_path_len];
}

pub fn deinit(self: *McpServer) void {
    _ = posix.system.close(self.socket_fd);

    // Unlink socket file
    var unlink_buf: [socket_path_max + 1]u8 = undefined;
    @memcpy(unlink_buf[0..self.socket_path_len], self.socket_path[0..self.socket_path_len]);
    unlink_buf[self.socket_path_len] = 0;
    _ = std.c.unlink(@ptrCast(&unlink_buf));

    self.running = false;
}

// ── Event loop integration ─────────────────────────────────────

/// Non-blocking accept + handle. Call from the main event loop.
pub fn poll(self: *McpServer) void {
    if (!self.running) return;

    // Non-blocking accept
    const client = ipc.accept(ipc.IpcHandle.fromRaw(self.socket_fd)) orelse return;

    self.handleRequest(client.rawFd());
    client.close();
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

fn handleRequest(self: *McpServer, conn_fd: posix.fd_t) void {
    var req_buf: [max_request]u8 = undefined;
    var total: usize = 0;

    // Read until newline or EOF or buffer full.
    while (total < req_buf.len) {
        const rc = std.c.read(conn_fd, req_buf[total..].ptr, req_buf.len - total);
        if (rc <= 0) break;
        total += @intCast(rc);
        if (std.mem.indexOfScalar(u8, req_buf[0..total], '\n') != null) break;
    }
    if (total == 0) return;

    // Trim a single trailing newline (and optional \r) if present.
    var body_len = total;
    if (body_len > 0 and req_buf[body_len - 1] == '\n') body_len -= 1;
    if (body_len > 0 and req_buf[body_len - 1] == '\r') body_len -= 1;

    var resp_buf: [max_response + 1]u8 = undefined;
    const json_response = self.dispatch(req_buf[0..body_len], resp_buf[0..max_response]);
    // Append newline so line-oriented readers (the bridge, socat, etc.)
    // can split without heuristics.
    const resp_end = json_response.len;
    if (resp_end < resp_buf.len) {
        resp_buf[resp_end] = '\n';
        _ = std.c.write(conn_fd, &resp_buf, resp_end + 1);
    } else {
        _ = std.c.write(conn_fd, json_response.ptr, json_response.len);
    }
}

/// Route a JSON-RPC body through the method/tool dispatch table and
/// write the response into `resp_buf`. Transport-agnostic — used by
/// the socket server, the stdio proxy, and the OSC in-band path.
pub fn dispatch(self: *McpServer, body: []const u8, resp_buf: []u8) []const u8 {
    // Parse JSON-RPC request manually (no JSON library)
    const method = tools.extractJsonString(body, "method") orelse {
        return tools.jsonRpcError(resp_buf, null, -32600, "Invalid Request: missing method");
    };
    const id = extractJsonId(body);

    if (std.mem.eql(u8, method, "tools/list")) {
        return self.handleToolsList(resp_buf, id);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        return self.handleToolsCall(body, resp_buf, id);
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        return self.handlePromptsList(resp_buf, id);
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        return self.handlePromptsGet(body, resp_buf, id);
    } else if (std.mem.eql(u8, method, "initialize")) {
        return self.handleInitialize(resp_buf, id);
    } else if (std.mem.startsWith(u8, method, "notifications/")) {
        // MCP notifications (initialized, progress, cancelled) — acknowledge silently
        return std.fmt.bufPrint(resp_buf,
            \\{{"jsonrpc":"2.0","result":{{}},"id":{s}}}
        , .{id orelse "null"}) catch "{}";
    } else {
        return tools.jsonRpcError(resp_buf, id, -32601, "Method not found");
    }
}

// ── MCP method handlers ────────────────────────────────────────

fn handleInitialize(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    _ = self;
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"protocolVersion":"2025-03-26","capabilities":{{"tools":{{}},"prompts":{{}}}},"serverInfo":{{"name":"teru","version":"{s}"}}}},"id":{s}}}
    , .{ build_options.version, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn handleToolsList(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    _ = self;
    const id_str = id orelse "null";
    // Schemas are assembled once at comptime in McpDispatch — this call
    // is a single bufPrint, no per-request concatenation.
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"tools":[{s}]}},"id":{s}}}
    , .{ mcp_dispatch.tools_list_body, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

// ── MCP Prompts ───────────────────────────────────────────────

fn handlePromptsList(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    _ = self;
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"prompts":[
        \\{{"name":"workspace_setup","description":"Set up teru workspaces with panes, layouts, and commands. Describe your desired workspace configuration in natural language.","arguments":[{{"name":"description","description":"Natural language description of desired workspace setup (e.g. '4 workspaces, workspace 1 has 1 pane, workspace 2 has 2 panes, each running vim')","required":true}}]}}
        \\]}},"id":{s}}}
    , .{id_str}) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn handlePromptsGet(self: *McpServer, body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = self;
    const id_str = id orelse "null";
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing params");
    const params_body = body[params_start..];
    const name = tools.extractNestedJsonString(params_body, "name") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing params.name");

    if (std.mem.eql(u8, name, "workspace_setup")) {
        const user_desc = tools.extractNestedJsonString(params_body, "description") orelse "default setup";
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

fn handleToolsCall(self: *McpServer, body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing params");
    const params_body = body[params_start..];

    // Tool name is at params top level, NOT inside arguments — use
    // extractJsonString (flat) to avoid collision with an `arguments.name`.
    const tool_name = tools.extractJsonString(params_body, "name") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing params.name");

    const idx = mcp_dispatch.tool_index.get(tool_name) orelse
        return tools.jsonRpcError(buf, id, -32602, "Unknown tool");
    return dispatch_table[idx](self, params_body, buf, id);
}

// ── Dispatch table ─────────────────────────────────────────────
// One adapter per tool. Each unpacks its args from params_body and
// delegates to the real handler below. Order MUST match McpDispatch.tools.
// A mismatch is a compile-time array-length error.

const Handler = *const fn (*McpServer, params_body: []const u8, buf: []u8, id: ?[]const u8) []const u8;

const dispatch_table: [mcp_dispatch.tools.len]Handler = .{
    callListPanes,
    callReadOutput,
    callGetGraph,
    callSendInput,
    callCreatePane,
    callBroadcast,
    callSendKeys,
    callGetState,
    callFocusPane,
    callClosePane,
    callSwitchWorkspace,
    callScroll,
    callWaitFor,
    callSetLayout,
    callSetConfig,
    callGetConfig,
    callSessionSave,
    callSessionRestore,
    callScreenshot,
};

fn callListPanes(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = params;
    return self.toolListPanes(buf, id);
}
fn callReadOutput(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const pane_id = tools.extractNestedJsonInt(params, "pane_id") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing pane_id");
    const lines = tools.extractNestedJsonInt(params, "lines") orelse 50;
    return self.toolReadOutput(pane_id, @intCast(lines), buf, id);
}
fn callGetGraph(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = params;
    return self.toolGetGraph(buf, id);
}
fn callSendInput(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const pane_id = tools.extractNestedJsonInt(params, "pane_id") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing pane_id");
    const text = tools.extractNestedJsonString(params, "text") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing text");
    return self.toolSendInput(pane_id, text, buf, id);
}
fn callCreatePane(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const workspace = tools.extractNestedJsonInt(params, "workspace") orelse 0;
    const dir_str = tools.extractNestedJsonString(params, "direction");
    const is_horizontal = if (dir_str) |d| std.mem.eql(u8, d, "horizontal") else false;
    const command = tools.extractNestedJsonString(params, "command");
    const cwd = tools.extractNestedJsonString(params, "cwd");
    return self.toolCreatePane(@intCast(workspace), is_horizontal, command, cwd, buf, id);
}
fn callBroadcast(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const workspace = tools.extractNestedJsonInt(params, "workspace") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing workspace");
    const text = tools.extractNestedJsonString(params, "text") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing text");
    return self.toolBroadcast(@intCast(workspace), text, buf, id);
}
fn callSendKeys(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const pane_id = tools.extractNestedJsonInt(params, "pane_id") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing pane_id");
    return self.toolSendKeys(pane_id, params, buf, id);
}
fn callGetState(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const pane_id = tools.extractNestedJsonInt(params, "pane_id") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing pane_id");
    return self.toolGetState(pane_id, buf, id);
}
fn callFocusPane(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const pane_id = tools.extractNestedJsonInt(params, "pane_id") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing pane_id");
    return self.toolFocusPane(pane_id, buf, id);
}
fn callClosePane(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const pane_id = tools.extractNestedJsonInt(params, "pane_id") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing pane_id");
    return self.toolClosePane(pane_id, buf, id);
}
fn callSwitchWorkspace(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const workspace = tools.extractNestedJsonInt(params, "workspace") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing workspace");
    return self.toolSwitchWorkspace(@intCast(workspace), buf, id);
}
fn callScroll(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const pane_id = tools.extractNestedJsonInt(params, "pane_id") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing pane_id");
    const direction = tools.extractNestedJsonString(params, "direction") orelse "up";
    const lines = tools.extractNestedJsonInt(params, "lines") orelse 10;
    return self.toolScroll(@intCast(pane_id), direction, @intCast(lines), buf, id);
}
fn callWaitFor(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const pane_id = tools.extractNestedJsonInt(params, "pane_id") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing pane_id");
    const pattern = tools.extractNestedJsonString(params, "pattern") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing pattern");
    const lines = tools.extractNestedJsonInt(params, "lines") orelse 20;
    return self.toolWaitFor(@intCast(pane_id), pattern, @intCast(lines), buf, id);
}
fn callSetLayout(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const layout_str = tools.extractNestedJsonString(params, "layout") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing layout");
    const workspace = tools.extractNestedJsonInt(params, "workspace") orelse 0;
    return self.toolSetLayout(@intCast(workspace), layout_str, buf, id);
}
fn callSetConfig(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const key = tools.extractNestedJsonString(params, "key") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing key");
    const value = tools.extractNestedJsonString(params, "value") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing value");
    return self.toolSetConfig(key, value, buf, id);
}
fn callGetConfig(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = params;
    return self.toolGetConfig(buf, id);
}
fn callSessionSave(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const name = tools.extractNestedJsonString(params, "name") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing name");
    return self.toolSessionSave(name, buf, id);
}
fn callSessionRestore(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const name = tools.extractNestedJsonString(params, "name") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing name");
    return self.toolSessionRestore(name, buf, id);
}
fn callScreenshot(self: *McpServer, params: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const path = tools.extractNestedJsonString(params, "path") orelse "/tmp/teru-screenshot.png";
    return self.toolScreenshot(path, buf, id);
}

// ── Tool implementations ───────────────────────────────────────

fn toolListPanes(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    var pos: usize = 0;

    // Build JSON array of panes
    const prefix = std.fmt.bufPrint(buf[pos..], "{s}{s}", .{
        "{\"jsonrpc\":\"2.0\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[",
        "",
    }) catch return tools.jsonRpcError(buf, id, -32603, "Internal error");
    pos += prefix.len;

    for (self.multiplexer.panes.items, 0..) |*pane, i| {
        if (i > 0) {
            if (pos < buf.len) {
                buf[pos] = ',';
                pos += 1;
            }
        }
        // Find process name from graph (escape for JSON safety)
        const proc_name = self.findPaneName(pane.id);
        var proc_esc: [256]u8 = undefined;
        const proc_safe = tools.jsonEscapeString(proc_name, &proc_esc);
        const status = if (pane.isAlive()) "running" else "exited";
        const workspace = self.findPaneWorkspace(pane.id);

        const entry = std.fmt.bufPrint(buf[pos..],
            \\{{\"id\":{d},\"workspace\":{d},\"name\":\"{s}\",\"status\":\"{s}\",\"rows\":{d},\"cols\":{d}}}
        , .{ pane.id, workspace, proc_safe, status, pane.grid.rows, pane.grid.cols }) catch break;
        pos += entry.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "]\"}}]}},\"id\":{s}}}", .{id_str}) catch
        return tools.jsonRpcError(buf, id, -32603, "Internal error");
    pos += suffix.len;

    return buf[0..pos];
}

fn toolReadOutput(self: *McpServer, pane_id: u64, lines: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return tools.jsonRpcError(buf, id, -32602, "Pane not found");

    // Extract text from grid rows (bottom N lines, walking upward)
    var text_buf: [32768]u8 = undefined;
    var text_pos: usize = 0;

    const grid = &pane.grid;
    const total_rows: u32 = grid.rows;
    const start_row: u32 = if (total_rows > lines) total_rows - lines else 0;

    var row: u32 = start_row;
    while (row < total_rows) : (row += 1) {
        // Extract line text
        var line_end: usize = 0;
        for (0..grid.cols) |col| {
            const cell = grid.cellAtConst(@intCast(row), @intCast(col));
            const cp = cell.char;
            if (cp >= 32 and cp < 127) {
                if (text_pos < text_buf.len) {
                    text_buf[text_pos] = @intCast(cp);
                    text_pos += 1;
                    line_end = text_pos;
                }
            } else if (cp == 0 or cp == ' ') {
                if (text_pos < text_buf.len) {
                    text_buf[text_pos] = ' ';
                    text_pos += 1;
                }
            }
        }
        // Trim trailing spaces on this line
        text_pos = line_end;
        // Add newline
        if (text_pos < text_buf.len and row + 1 < total_rows) {
            text_buf[text_pos] = '\n';
            text_pos += 1;
        }
    }

    // JSON-escape the text and build response
    var escaped_buf: [max_response - 256]u8 = undefined;
    const escaped = tools.jsonEscapeString(text_buf[0..text_pos], &escaped_buf);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{s}"}}]}},"id":{s}}}
    , .{ escaped, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolGetGraph(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    var pos: usize = 0;

    const prefix = "{\"jsonrpc\":\"2.0\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"nodes\\\":[";
    if (pos + prefix.len > buf.len) return tools.jsonRpcError(buf, id, -32603, "Internal error");
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    var it = self.graph.nodes.iterator();
    var first = true;
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (!first) {
            if (pos < buf.len) {
                buf[pos] = ',';
                pos += 1;
            }
        }
        first = false;

        const kind_str = @tagName(node.kind);
        const state_str = @tagName(node.state);
        var name_esc: [256]u8 = undefined;
        const name_safe = tools.jsonEscapeString(node.name, &name_esc);

        const entry_json = std.fmt.bufPrint(buf[pos..],
            \\{{\"id\":{d},\"name\":\"{s}\",\"kind\":\"{s}\",\"state\":\"{s}\"
        , .{ node.id, name_safe, kind_str, state_str }) catch break;
        pos += entry_json.len;

        // Optional fields
        if (node.pid) |pid| {
            const pid_json = std.fmt.bufPrint(buf[pos..], ",\\\"pid\\\":{d}", .{pid}) catch break;
            pos += pid_json.len;
        }
        if (node.parent) |parent| {
            const parent_json = std.fmt.bufPrint(buf[pos..], ",\\\"parent\\\":{d}", .{parent}) catch break;
            pos += parent_json.len;
        }
        if (node.exit_code) |ec| {
            const ec_json = std.fmt.bufPrint(buf[pos..], ",\\\"exit_code\\\":{d}", .{ec}) catch break;
            pos += ec_json.len;
        }

        const workspace_json = std.fmt.bufPrint(buf[pos..], ",\\\"workspace\\\":{d}}}", .{node.workspace}) catch break;
        pos += workspace_json.len;
    }

    const suffix_str = "]}\"}]},\"id\":";
    if (pos + suffix_str.len + id_str.len + 1 > buf.len) return tools.jsonRpcError(buf, id, -32603, "Internal error");
    @memcpy(buf[pos..][0..suffix_str.len], suffix_str);
    pos += suffix_str.len;
    @memcpy(buf[pos..][0..id_str.len], id_str);
    pos += id_str.len;
    buf[pos] = '}';
    pos += 1;

    return buf[0..pos];
}

fn toolSendInput(self: *McpServer, pane_id: u64, text: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return tools.jsonRpcError(buf, id, -32602, "Pane not found");

    // Unescape JSON string sequences before writing to PTY
    var unesc: [4096]u8 = undefined;
    const unesc_text = tools.unescapeJson(text, &unesc);

    _ = pane.ptyWrite(unesc_text) catch
        return tools.jsonRpcError(buf, id, -32603, "Write failed");

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolCreatePane(self: *McpServer, workspace: u8, horizontal: bool, command: ?[]const u8, cwd_param: ?[]const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    // Resolve CWD: explicit param > active pane's CWD > inherit
    var cwd_buf: [512]u8 = undefined;
    const cwd: ?[]const u8 = if (cwd_param) |c| c else blk: {
        // Read active pane's CWD from /proc/<pid>/cwd
        if (self.multiplexer.getActivePane()) |pane| {
            if (pane.childPid()) |pid| {
                if (builtin.os.tag == .windows) break :blk null;
                var path_z: [64:0]u8 = undefined;
                const proc_path = std.fmt.bufPrint(&path_z, "/proc/{d}/cwd", .{pid}) catch break :blk null;
                path_z[proc_path.len] = 0;
                const rc = std.c.readlink(@ptrCast(&path_z), &cwd_buf, cwd_buf.len);
                if (rc > 0) {
                    break :blk cwd_buf[0..@intCast(rc)];
                }
            }
        }
        break :blk null;
    };

    // Save current workspace, switch, spawn, restore
    const prev_workspace = self.multiplexer.active_workspace;
    if (workspace != prev_workspace) {
        self.multiplexer.switchWorkspace(workspace);
    }

    // spawnPaneWithCommand handles both custom commands and CWD.
    // When command is null, pass the default shell explicitly.
    const shell = command orelse compat.getenv("SHELL") orelse "/bin/sh";
    const pane_id = self.multiplexer.spawnPaneWithCommand(24, 80, shell, cwd) catch
        return tools.jsonRpcError(buf, id, -32603, "Spawn failed");

    // Add to split tree if active
    const ws = &self.multiplexer.layout_engine.workspaces[workspace];
    const dir: @import("../tiling/LayoutEngine.zig").SplitDirection = if (horizontal) .horizontal else .vertical;
    ws.addNodeSplit(self.multiplexer.allocator, pane_id, dir) catch {};

    // Register in graph — non-fatal: pane works without graph tracking
    if (self.multiplexer.getPaneById(pane_id)) |pane| {
        _ = self.graph.spawn(.{
            .name = "shell",
            .kind = .shell,
            .pid = pane.childPid(),
            .workspace = workspace,
        }) catch {};
    }

    // Resize all PTYs to match new layout
    if (self.screen_width > 0) {
        self.multiplexer.resizePanePtys(self.screen_width, self.screen_height, self.cell_width, self.cell_height, self.padding, self.status_bar_h);
    }

    // Restore workspace
    if (workspace != prev_workspace) {
        self.multiplexer.switchWorkspace(prev_workspace);
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{d}"}}]}},"id":{s}}}
    , .{ pane_id, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolBroadcast(self: *McpServer, workspace: u8, text: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    // Get pane IDs in the workspace from the layout engine
    const ws = &self.multiplexer.layout_engine.workspaces[workspace];
    var sent: u32 = 0;

    for (ws.node_ids.items) |node_id| {
        if (self.multiplexer.getPaneById(node_id)) |pane| {
            _ = pane.ptyWrite(text) catch continue;
            sent += 1;
        }
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"sent to {d} panes"}}]}},"id":{s}}}
    , .{ sent, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSendKeys(self: *McpServer, pane_id: u64, params_body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return tools.jsonRpcError(buf, id, -32602, "Pane not found");

    const app_cursor = pane.vt.app_cursor_keys;

    // Find the "keys" array in the arguments
    const keys_json = extractNestedJsonArray(params_body, "keys") orelse
        return tools.jsonRpcError(buf, id, -32602, "Missing keys array");

    // Iterate over string elements in the JSON array
    var sent: u32 = 0;
    var iter = JsonArrayIterator.init(keys_json);
    while (iter.next()) |key_name| {
        const seq = resolveKey(key_name, app_cursor);
        _ = pane.ptyWrite(seq) catch continue;
        sent += 1;
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"sent {d} keys"}}]}},"id":{s}}}
    , .{ sent, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolGetState(self: *McpServer, pane_id: u64, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return tools.jsonRpcError(buf, id, -32602, "Pane not found");

    const grid = &pane.grid;
    const vt = &pane.vt;

    // JSON-escape the title
    var title_escaped_buf: [512]u8 = undefined;
    const title_escaped = tools.jsonEscapeString(vt.title[0..vt.title_len], &title_escaped_buf);

    // Build inner JSON in temp buffer, then escape for embedding in text field
    var inner_buf: [2048]u8 = undefined;
    const inner_json = std.fmt.bufPrint(&inner_buf,
        \\{{"cursor_row":{d},"cursor_col":{d},"cursor_visible":{s},"rows":{d},"cols":{d},"alt_screen":{s},"bracketed_paste":{s},"app_cursor_keys":{s},"title":"{s}","scroll_top":{d},"scroll_bottom":{d}}}
    , .{
        grid.cursor_row,
        grid.cursor_col,
        if (vt.cursor_visible) "true" else "false",
        grid.rows,
        grid.cols,
        if (vt.alt_screen) "true" else "false",
        if (vt.bracketed_paste) "true" else "false",
        if (vt.app_cursor_keys) "true" else "false",
        title_escaped,
        grid.scroll_top,
        grid.scroll_bottom,
    }) catch
        return tools.jsonRpcError(buf, id, -32603, "Internal error");

    // Escape for embedding inside JSON "text" string value
    var escaped_buf: [4096]u8 = undefined;
    const escaped = tools.jsonEscapeString(inner_json, &escaped_buf);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{s}"}}]}},"id":{s}}}
    , .{ escaped, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolFocusPane(self: *McpServer, pane_id: u64, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    // Search all workspaces for the pane
    for (&self.multiplexer.layout_engine.workspaces, 0..) |*ws, ws_idx| {
        for (ws.node_ids.items, 0..) |node_id, node_idx| {
            if (node_id == pane_id) {
                ws.active_index = node_idx;
                self.multiplexer.active_workspace = @intCast(ws_idx);
                return std.fmt.bufPrint(buf,
                    \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
                , .{id_str}) catch
                    tools.jsonRpcError(buf, id, -32603, "Internal error");
            }
        }
    }

    return tools.jsonRpcError(buf, id, -32602, "Pane not found");
}

fn toolClosePane(self: *McpServer, pane_id: u64, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    // Verify pane exists before closing
    if (self.multiplexer.getPaneById(pane_id) == null)
        return tools.jsonRpcError(buf, id, -32602, "Pane not found");

    self.multiplexer.closePane(pane_id);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSwitchWorkspace(self: *McpServer, workspace: u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    if (workspace > 9)
        return tools.jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    self.multiplexer.switchWorkspace(workspace);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSetLayout(self: *McpServer, workspace: u8, layout_str: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const LayoutEngine = @import("../tiling/LayoutEngine.zig");

    if (workspace > 9)
        return tools.jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    const layout: LayoutEngine.Layout = LayoutEngine.parseLayout(layout_str) orelse
        return tools.jsonRpcError(buf, id, -32602, "Unknown layout");

    const ws = &self.multiplexer.layout_engine.workspaces[workspace];
    ws.layout = layout;
    // Clear split tree so the flat layout algorithm takes effect.
    // Panes remain in ws.node_ids (the flat list) which all layouts use.
    ws.split_root = null;
    ws.split_node_count = 0;
    // Sync active_node to flat list active
    if (ws.node_ids.items.len > 0) {
        ws.active_node = null;
    }

    // Resize PTYs to match new layout
    if (self.screen_width > 0 and self.cell_width > 0) {
        self.multiplexer.resizePanePtys(self.screen_width, self.screen_height, self.cell_width, self.cell_height, self.padding, self.status_bar_h);
    }
    // Mark panes dirty for redraw
    for (self.multiplexer.panes.items) |*pane| pane.grid.dirty = true;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSetConfig(_: *McpServer, key: []const u8, value: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    // Validate key is a known config option
    const valid_keys = [_][]const u8{
        "font_size", "padding", "opacity", "theme", "cursor_shape", "cursor_blink",
        "scroll_speed", "bold_is_bright", "bell", "copy_on_select", "bg", "fg",
        "cursor_color", "selection_bg", "border_active", "border_inactive",
        "attention_color", "scrollback_lines", "mouse_hide_when_typing",
        "show_status_bar", "alt_workspace_switch",
    };
    var is_valid = false;
    for (valid_keys) |vk| {
        if (std.mem.eql(u8, key, vk)) {
            is_valid = true;
            break;
        }
    }
    if (!is_valid)
        return tools.jsonRpcError(buf, id, -32602, "Unknown config key");

    // Read existing config, update or append the key
    const home = compat.getenv("HOME") orelse
        return tools.jsonRpcError(buf, id, -32603, "HOME not set");

    var path_buf: [512:0]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/teru/teru.conf", .{home}) catch
        return tools.jsonRpcError(buf, id, -32603, "Path too long");
    path_buf[path.len] = 0;

    // Build the new line: "key = value\n"
    var line_buf: [256]u8 = undefined;
    const new_line = std.fmt.bufPrint(&line_buf, "{s} = {s}\n", .{ key, value }) catch
        return tools.jsonRpcError(buf, id, -32603, "Value too long");

    // Read existing file content
    var file_buf: [16384]u8 = undefined;
    var file_len: usize = 0;
    {
        const f = std.c.fopen(@ptrCast(path_buf[0..path.len :0]), "r");
        if (f != null) {
            file_len = std.c.fread(&file_buf, 1, file_buf.len, f.?);
            _ = std.c.fclose(f.?);
        }
    }

    // Write back: replace existing key or append
    {
        const f = std.c.fopen(@ptrCast(path_buf[0..path.len :0]), "w");
        if (f == null)
            return tools.jsonRpcError(buf, id, -32603, "Cannot write config file");

        var replaced = false;
        var pos: usize = 0;
        while (pos < file_len) {
            // Find end of current line
            const line_end = std.mem.indexOfScalar(u8, file_buf[pos..file_len], '\n') orelse (file_len - pos);
            const line = file_buf[pos .. pos + line_end];

            // Check if this line starts with our key
            if (tools.lineMatchesKey(line, key)) {
                _ = std.c.fwrite(new_line.ptr, 1, new_line.len, f.?);
                replaced = true;
            } else {
                _ = std.c.fwrite(file_buf[pos..].ptr, 1, line_end, f.?);
                _ = std.c.fwrite("\n", 1, 1, f.?);
            }
            pos += line_end + 1;
        }

        if (!replaced) {
            _ = std.c.fwrite(new_line.ptr, 1, new_line.len, f.?);
        }
        _ = std.c.fclose(f.?);
    }

    var key_esc: [128]u8 = undefined;
    var val_esc: [256]u8 = undefined;
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"set {s} = {s}"}}]}},"id":{s}}}
    , .{ tools.jsonEscapeString(key, &key_esc), tools.jsonEscapeString(value, &val_esc), id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolGetConfig(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const mux = self.multiplexer;
    const ws = &mux.layout_engine.workspaces[mux.active_workspace];

    // Build JSON snapshot of current live config values
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"active_workspace\":{d},\"layout\":\"{s}\",\"master_ratio\":{d},\"pane_count\":{d},\"screen_width\":{d},\"screen_height\":{d},\"cell_width\":{d},\"cell_height\":{d},\"padding\":{d}}}"}}]}},"id":{s}}}
    , .{
        mux.active_workspace,
        @tagName(ws.layout),
        @as(u32, @intFromFloat(ws.master_ratio * 100)),
        mux.panes.items.len,
        self.screen_width,
        self.screen_height,
        self.cell_width,
        self.cell_height,
        self.padding,
        id_str,
    }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSessionSave(self: *McpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const SessionConfig = @import("../config/Session.zig");

    // Generate .tsess content from live state
    const content = SessionConfig.saveFromLive(self.allocator, self.multiplexer, self.graph) catch
        return tools.jsonRpcError(buf, id, -32603, "Failed to snapshot session");
    defer self.allocator.free(content);

    // Build path: ~/.config/teru/sessions/NAME.tsess
    const path = SessionConfig.getSessionPath(self.allocator, name) catch
        return tools.jsonRpcError(buf, id, -32603, "Failed to build session path");
    defer self.allocator.free(path);

    // Write to file (using C fopen/fwrite since we don't have io here)
    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return tools.jsonRpcError(buf, id, -32603, "Path too long");
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    // Ensure parent directory exists
    tools.ensureParentDirC(path);

    const f = std.c.fopen(@ptrCast(path_z[0..path.len :0]), "w");
    if (f == null) return tools.jsonRpcError(buf, id, -32603, "Cannot write session file");
    _ = std.c.fwrite(content.ptr, 1, content.len, f.?);
    _ = std.c.fclose(f.?);

    // JSON-escape the path for the response
    var escaped_path: [1024]u8 = undefined;
    const epath = tools.jsonEscapeString(path, &escaped_path);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"saved to {s}"}}]}},"id":{s}}}
    , .{ epath, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSessionRestore(self: *McpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const SessionConfig = @import("../config/Session.zig");

    // Build path and read file
    const path = SessionConfig.getSessionPath(self.allocator, name) catch
        return tools.jsonRpcError(buf, id, -32603, "Failed to build session path");
    defer self.allocator.free(path);

    // Read file using C fopen/fread
    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return tools.jsonRpcError(buf, id, -32603, "Path too long");
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var file_buf: [SessionConfig.max_file_size]u8 = undefined;
    var file_len: usize = 0;
    {
        const f = std.c.fopen(@ptrCast(path_z[0..path.len :0]), "r");
        if (f == null) return tools.jsonRpcError(buf, id, -32602, "Session file not found");
        file_len = std.c.fread(&file_buf, 1, file_buf.len, f.?);
        _ = std.c.fclose(f.?);
    }

    if (file_len == 0) return tools.jsonRpcError(buf, id, -32602, "Session file empty");

    // Parse
    var def = SessionConfig.parse(self.allocator, file_buf[0..file_len]) catch
        return tools.jsonRpcError(buf, id, -32603, "Failed to parse session file");
    defer def.deinit();

    // Restore — determine default rows/cols from active pane or fallback
    var rows: u16 = 24;
    var cols: u16 = 80;
    if (self.multiplexer.getActivePane()) |pane| {
        rows = pane.grid.rows;
        cols = pane.grid.cols;
    }

    SessionConfig.restore(&def, self.multiplexer, self.graph, rows, cols);

    // Resize PTYs after restore
    if (self.screen_width > 0 and self.cell_width > 0) {
        // Resize all workspaces that have panes
        const prev_ws = self.multiplexer.active_workspace;
        for (0..SessionConfig.max_workspaces) |wi| {
            const ws = &self.multiplexer.layout_engine.workspaces[wi];
            if (ws.node_ids.items.len > 0) {
                self.multiplexer.switchWorkspace(@intCast(wi));
                self.multiplexer.resizePanePtys(self.screen_width, self.screen_height, self.cell_width, self.cell_height, self.padding, self.status_bar_h);
            }
        }
        self.multiplexer.switchWorkspace(prev_ws);
    }

    // Mark all panes dirty
    for (self.multiplexer.panes.items) |*pane| pane.grid.dirty = true;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"restored session {s} ({d} workspaces)"}}]}},"id":{s}}}
    , .{ name, def.workspace_count, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolScreenshot(self: *McpServer, path: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const r = self.renderer orelse
        return tools.jsonRpcError(buf, id, -32603, "No renderer (TTY mode has no framebuffer)");

    const pixels = r.getFramebuffer() orelse
        return tools.jsonRpcError(buf, id, -32603, "No framebuffer available");

    const width: u32 = switch (r.*) {
        .cpu => |cpu| cpu.width,
        .tty => return tools.jsonRpcError(buf, id, -32603, "No framebuffer in TTY mode"),
    };
    const height: u32 = switch (r.*) {
        .cpu => |cpu| cpu.height,
        .tty => return tools.jsonRpcError(buf, id, -32603, "No framebuffer in TTY mode"),
    };

    // Null-terminate path for C fopen
    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return tools.jsonRpcError(buf, id, -32602, "Path too long");
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    png.write(self.allocator, @ptrCast(path_z[0..path.len :0]), pixels, width, height) catch |err| {
        return switch (err) {
            error.FileOpenFailed => tools.jsonRpcError(buf, id, -32603, "Failed to open output file"),
            error.OutOfMemory => tools.jsonRpcError(buf, id, -32603, "Out of memory"),
        };
    };

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"screenshot saved to {s} ({d}x{d})"}}]}},"id":{s}}}
    , .{ path, width, height, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

/// Ensure parent directory exists using C mkdir.

fn toolScroll(self: *McpServer, pane_id: u64, direction: []const u8, lines: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return tools.jsonRpcError(buf, id, -32602, "Pane not found");

    if (std.mem.eql(u8, direction, "up")) {
        const max_offset: u32 = if (pane.grid.scrollback) |sb|
            @as(u32, @intCast(sb.lineCount()))
        else
            0;
        pane.scroll_offset = @min(pane.scroll_offset + lines, max_offset);
    } else if (std.mem.eql(u8, direction, "down")) {
        pane.scroll_offset -|= lines;
    } else if (std.mem.eql(u8, direction, "bottom")) {
        pane.scroll_offset = 0;
    } else {
        return tools.jsonRpcError(buf, id, -32602, "direction must be up/down/bottom");
    }

    pane.grid.dirty = true;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"scroll_offset={d}"}}]}},"id":{s}}}
    , .{ pane.scroll_offset, id_str }) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolWaitFor(self: *McpServer, pane_id: u64, pattern: []const u8, lines: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return tools.jsonRpcError(buf, id, -32602, "Pane not found");

    const grid = &pane.grid;

    // Retry up to 10 times with 50ms sleeps (500ms total) to let PTY output arrive
    var attempt: u32 = 0;
    while (attempt < 10) : (attempt += 1) {
        // Force a PTY read so the grid is up-to-date
        var pty_buf: [8192]u8 = undefined;
        _ = pane.readAndProcess(&pty_buf) catch 0;

        const cells = grid.cells; // grid is never modified by scroll — always real content
        const check_rows = @min(lines, grid.rows);
        const start_row = grid.rows - check_rows;

        var row: u16 = start_row;
        while (row < grid.rows) : (row += 1) {
            var line_buf: [512]u8 = undefined;
            var col: u16 = 0;
            var len: usize = 0;
            while (col < grid.cols and len < line_buf.len) : (col += 1) {
                const cell_idx = @as(usize, row) * @as(usize, grid.cols) + col;
                const ch = if (cell_idx < cells.len) cells[cell_idx].char else @as(u21, ' ');
                if (ch < 128) {
                    line_buf[len] = @intCast(ch);
                    len += 1;
                }
            }
            while (len > 0 and line_buf[len - 1] == ' ') len -= 1;

            if (len > 0 and std.mem.indexOf(u8, line_buf[0..len], pattern) != null) {
            // Found — return the matching line
            // JSON-escape the line content
            var escaped: [1024]u8 = undefined;
            var elen: usize = 0;
            for (line_buf[0..len]) |c| {
                if (elen + 2 > escaped.len) break;
                if (c == '"' or c == '\\') {
                    escaped[elen] = '\\';
                    elen += 1;
                }
                escaped[elen] = c;
                elen += 1;
            }
            return std.fmt.bufPrint(buf,
                \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"matched\":true,\"line\":\"{s}\"}}"}}]}},"id":{s}}}
            , .{ escaped[0..elen], id_str }) catch
                tools.jsonRpcError(buf, id, -32603, "Internal error");
            }
        }

        // Not found this attempt — sleep 50ms and retry
        compat.sleepNs(50_000_000); // 50ms
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"matched\":false}}"}}]}},"id":{s}}}
    , .{id_str}) catch
        tools.jsonRpcError(buf, id, -32603, "Internal error");
}

// ── Key mapping for teru_send_keys ────────────────────────────

const KeyMapping = struct {
    name: []const u8,
    /// Normal mode sequence
    seq: []const u8,
    /// App cursor mode sequence (null = same as normal)
    app_seq: ?[]const u8 = null,
};

const key_mappings = [_]KeyMapping{
    .{ .name = "enter", .seq = "\r" },
    .{ .name = "tab", .seq = "\t" },
    .{ .name = "escape", .seq = "\x1b" },
    .{ .name = "backspace", .seq = "\x7f" },
    .{ .name = "delete", .seq = "\x1b[3~" },
    .{ .name = "up", .seq = "\x1b[A", .app_seq = "\x1bOA" },
    .{ .name = "down", .seq = "\x1b[B", .app_seq = "\x1bOB" },
    .{ .name = "right", .seq = "\x1b[C", .app_seq = "\x1bOC" },
    .{ .name = "left", .seq = "\x1b[D", .app_seq = "\x1bOD" },
    .{ .name = "home", .seq = "\x1b[H" },
    .{ .name = "end", .seq = "\x1b[F" },
    .{ .name = "pageup", .seq = "\x1b[5~" },
    .{ .name = "pagedown", .seq = "\x1b[6~" },
    .{ .name = "insert", .seq = "\x1b[2~" },
    .{ .name = "f1", .seq = "\x1bOP" },
    .{ .name = "f2", .seq = "\x1bOQ" },
    .{ .name = "f3", .seq = "\x1bOR" },
    .{ .name = "f4", .seq = "\x1bOS" },
    .{ .name = "f5", .seq = "\x1b[15~" },
    .{ .name = "f6", .seq = "\x1b[17~" },
    .{ .name = "f7", .seq = "\x1b[18~" },
    .{ .name = "f8", .seq = "\x1b[19~" },
    .{ .name = "f9", .seq = "\x1b[20~" },
    .{ .name = "f10", .seq = "\x1b[21~" },
    .{ .name = "f11", .seq = "\x1b[23~" },
    .{ .name = "f12", .seq = "\x1b[24~" },
};

/// Resolve a key name to its escape sequence.
/// Handles named keys, ctrl+letter combinations, and literal pass-through.
fn resolveKey(name: []const u8, app_cursor: bool) []const u8 {
    // Check named key mappings
    for (&key_mappings) |*km| {
        if (std.mem.eql(u8, name, km.name)) {
            if (app_cursor) {
                return km.app_seq orelse km.seq;
            }
            return km.seq;
        }
    }

    // Check ctrl+letter pattern
    if (name.len >= 6 and std.mem.eql(u8, name[0..5], "ctrl+")) {
        const letter = name[5];
        if (letter >= 'a' and letter <= 'z') {
            return &ctrl_byte_table[letter - 'a'];
        }
    }

    // Fallback: pass through as literal bytes
    return name;
}

/// Comptime table: ctrl_byte_table['a'-'a'] = 0x01, ..., ctrl_byte_table['z'-'a'] = 0x1a
const ctrl_byte_table = blk: {
    var table: [26][1]u8 = undefined;
    for (0..26) |i| {
        table[i] = .{@intCast(i + 1)};
    }
    break :blk table;
};

// ── JSON array helpers ────────────────────────────────────────

/// Extract the raw content of a JSON array value for a given key within "arguments".
/// Returns the slice between [ and ] (exclusive of brackets).
fn extractNestedJsonArray(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    // Search in "arguments" first, then top-level
    const search_start = if (std.mem.indexOf(u8, json, "\"arguments\"")) |ap| ap else 0;
    const key_pos = std.mem.indexOf(u8, json[search_start..], needle) orelse
        std.mem.indexOf(u8, json, needle) orelse return null;

    const after_key = search_start + key_pos + needle.len;

    var i = after_key;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len or json[i] != '[') return null;
    i += 1; // skip '['

    const start = i;
    // Find matching ']' (handles nested brackets)
    var depth: u32 = 1;
    while (i < json.len and depth > 0) : (i += 1) {
        switch (json[i]) {
            '[' => depth += 1,
            ']' => depth -= 1,
            '"' => {
                // Skip string contents
                i += 1;
                while (i < json.len and json[i] != '"') : (i += 1) {
                    if (json[i] == '\\') i += 1;
                }
            },
            else => {},
        }
    }
    if (depth != 0) return null;
    // i is now one past the closing ']'
    return json[start .. i - 1];
}

/// Iterator over string elements in a JSON array body (content between [ and ]).
const JsonArrayIterator = struct {
    data: []const u8,
    pos: usize = 0,

    fn init(data: []const u8) JsonArrayIterator {
        return .{ .data = data };
    }

    fn next(self: *JsonArrayIterator) ?[]const u8 {
        // Skip to next opening quote
        while (self.pos < self.data.len and self.data[self.pos] != '"') : (self.pos += 1) {}
        if (self.pos >= self.data.len) return null;
        self.pos += 1; // skip opening quote

        const start = self.pos;
        while (self.pos < self.data.len and self.data[self.pos] != '"') : (self.pos += 1) {
            if (self.data[self.pos] == '\\') self.pos += 1;
        }
        if (self.pos >= self.data.len) return null;

        const result = self.data[start..self.pos];
        self.pos += 1; // skip closing quote
        return result;
    }
};

// ── Helpers ────────────────────────────────────────────────────

fn findPaneName(self: *McpServer, pane_id: u64) []const u8 {
    // Search graph for a node associated with this pane
    // Heuristic: look for nodes whose children or pid might match
    var it = self.graph.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        // Match by checking if pane_id correlates to node_id
        // Since pane IDs and node IDs are both auto-incrementing from 1,
        // they often correspond. Use node_id == pane_id as heuristic.
        if (node.id == pane_id) return node.name;
    }
    return "shell";
}

fn findPaneWorkspace(self: *McpServer, pane_id: u64) u8 {
    // Check which workspace this pane belongs to via layout engine
    for (self.multiplexer.layout_engine.workspaces, 0..) |ws, i| {
        for (ws.node_ids.items) |node_id| {
            if (node_id == pane_id) return @intCast(i);
        }
    }
    return self.multiplexer.active_workspace;
}

// ── Minimal JSON parsing (no library) ──────────────────────────

fn extractJsonId(json: []const u8) ?[]const u8 {
    // Extract the "id" field value (could be number or string)
    const needle = "\"id\":";
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const after = pos + needle.len;

    var i = after;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len) return null;

    if (json[i] == '"') {
        // String id
        i += 1;
        const start = i;
        while (i < json.len and json[i] != '"') : (i += 1) {}
        if (i >= json.len) return null;
        // Return with quotes for JSON embedding
        return json[start - 1 .. i + 1];
    } else if (json[i] == 'n') {
        // null
        return "null";
    } else {
        // Numeric id
        const start = i;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
        if (i == start) return null;
        return json[start..i];
    }
}




// ── Tests ──────────────────────────────────────────────────────

const t = std.testing;

test "extractJsonString basic" {
    const json = "{\"method\":\"tools/list\",\"id\":1}";
    const method = tools.extractJsonString(json, "method");
    try t.expect(method != null);
    try t.expectEqualStrings("tools/list", method.?);
}

test "extractJsonString with spaces" {
    const json = "{\"method\": \"tools/call\", \"id\": 2}";
    const method = tools.extractJsonString(json, "method");
    try t.expect(method != null);
    try t.expectEqualStrings("tools/call", method.?);
}

test "extractJsonString missing key" {
    const json = "{\"method\":\"tools/list\"}";
    try t.expectEqual(@as(?[]const u8, null), tools.extractJsonString(json, "missing"));
}

test "extractJsonId numeric" {
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":42}";
    const id = extractJsonId(json);
    try t.expect(id != null);
    try t.expectEqualStrings("42", id.?);
}

test "extractJsonId null" {
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":null}";
    const id = extractJsonId(json);
    try t.expect(id != null);
    try t.expectEqualStrings("null", id.?);
}

test "extractNestedJsonInt" {
    const json = "{\"params\":{\"name\":\"teru_read_output\",\"arguments\":{\"pane_id\":3,\"lines\":20}}}";
    const pane_id = tools.extractNestedJsonInt(json, "pane_id");
    try t.expect(pane_id != null);
    try t.expectEqual(@as(u64, 3), pane_id.?);

    const lines = tools.extractNestedJsonInt(json, "lines");
    try t.expect(lines != null);
    try t.expectEqual(@as(u64, 20), lines.?);
}

test "extractNestedJsonString" {
    const json = "{\"params\":{\"name\":\"teru_send_input\",\"arguments\":{\"pane_id\":1,\"text\":\"hello\"}}}";
    const text = tools.extractNestedJsonString(json, "text");
    try t.expect(text != null);
    try t.expectEqualStrings("hello", text.?);

    const name = tools.extractNestedJsonString(json, "name");
    try t.expect(name != null);
    try t.expectEqualStrings("teru_send_input", name.?);
}

test "jsonEscapeString" {
    var buf: [256]u8 = undefined;

    const result1 = tools.jsonEscapeString("hello world", &buf);
    try t.expectEqualStrings("hello world", result1);

    const result2 = tools.jsonEscapeString("line1\nline2", &buf);
    try t.expectEqualStrings("line1\\nline2", result2);

    const result3 = tools.jsonEscapeString("a\"b\\c", &buf);
    try t.expectEqualStrings("a\\\"b\\\\c", result3);
}

test "jsonRpcError" {
    var buf: [512]u8 = undefined;
    const result = tools.jsonRpcError(&buf, "1", -32601, "Method not found");
    try t.expect(std.mem.indexOf(u8, result, "-32601") != null);
    try t.expect(std.mem.indexOf(u8, result, "Method not found") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
}

test "handleInitialize returns valid JSON" {
    var buf: [max_response]u8 = undefined;
    const result = McpServer.handleInitialize(undefined, &buf, "1");
    try t.expect(std.mem.indexOf(u8, result, "protocolVersion") != null);
    try t.expect(std.mem.indexOf(u8, result, "teru") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
}

test "resolveKey named keys" {
    try t.expectEqualStrings("\r", resolveKey("enter", false));
    try t.expectEqualStrings("\t", resolveKey("tab", false));
    try t.expectEqualStrings("\x1b", resolveKey("escape", false));
    try t.expectEqualStrings("\x7f", resolveKey("backspace", false));
    try t.expectEqualStrings("\x1b[3~", resolveKey("delete", false));
    try t.expectEqualStrings("\x1b[H", resolveKey("home", false));
    try t.expectEqualStrings("\x1b[F", resolveKey("end", false));
    try t.expectEqualStrings("\x1b[5~", resolveKey("pageup", false));
    try t.expectEqualStrings("\x1b[6~", resolveKey("pagedown", false));
    try t.expectEqualStrings("\x1b[2~", resolveKey("insert", false));
}

test "resolveKey arrow keys normal vs app cursor" {
    // Normal mode
    try t.expectEqualStrings("\x1b[A", resolveKey("up", false));
    try t.expectEqualStrings("\x1b[B", resolveKey("down", false));
    try t.expectEqualStrings("\x1b[C", resolveKey("right", false));
    try t.expectEqualStrings("\x1b[D", resolveKey("left", false));

    // App cursor mode
    try t.expectEqualStrings("\x1bOA", resolveKey("up", true));
    try t.expectEqualStrings("\x1bOB", resolveKey("down", true));
    try t.expectEqualStrings("\x1bOC", resolveKey("right", true));
    try t.expectEqualStrings("\x1bOD", resolveKey("left", true));
}

test "resolveKey function keys" {
    try t.expectEqualStrings("\x1bOP", resolveKey("f1", false));
    try t.expectEqualStrings("\x1bOQ", resolveKey("f2", false));
    try t.expectEqualStrings("\x1bOR", resolveKey("f3", false));
    try t.expectEqualStrings("\x1bOS", resolveKey("f4", false));
    try t.expectEqualStrings("\x1b[15~", resolveKey("f5", false));
    try t.expectEqualStrings("\x1b[17~", resolveKey("f6", false));
    try t.expectEqualStrings("\x1b[18~", resolveKey("f7", false));
    try t.expectEqualStrings("\x1b[19~", resolveKey("f8", false));
    try t.expectEqualStrings("\x1b[20~", resolveKey("f9", false));
    try t.expectEqualStrings("\x1b[21~", resolveKey("f10", false));
    try t.expectEqualStrings("\x1b[23~", resolveKey("f11", false));
    try t.expectEqualStrings("\x1b[24~", resolveKey("f12", false));
}

test "resolveKey ctrl+letter" {
    try t.expectEqualStrings("\x01", resolveKey("ctrl+a", false));
    try t.expectEqualStrings("\x03", resolveKey("ctrl+c", false));
    try t.expectEqualStrings("\x04", resolveKey("ctrl+d", false));
    try t.expectEqualStrings("\x0c", resolveKey("ctrl+l", false));
    try t.expectEqualStrings("\x1a", resolveKey("ctrl+z", false));
}

test "resolveKey literal fallback" {
    try t.expectEqualStrings("hello", resolveKey("hello", false));
    try t.expectEqualStrings("x", resolveKey("x", false));
}

test "extractNestedJsonArray" {
    const json = "{\"params\":{\"name\":\"teru_send_keys\",\"arguments\":{\"pane_id\":1,\"keys\":[\"ctrl+c\",\"enter\"]}}}";
    const arr = extractNestedJsonArray(json, "keys");
    try t.expect(arr != null);
    try t.expectEqualStrings("\"ctrl+c\",\"enter\"", arr.?);
}

test "extractNestedJsonArray empty" {
    const json = "{\"params\":{\"name\":\"test\",\"arguments\":{\"keys\":[]}}}";
    const arr = extractNestedJsonArray(json, "keys");
    try t.expect(arr != null);
    try t.expectEqualStrings("", arr.?);
}

test "JsonArrayIterator" {
    const data = "\"ctrl+c\",\"enter\",\"up\"";
    var iter = JsonArrayIterator.init(data);

    const k1 = iter.next();
    try t.expect(k1 != null);
    try t.expectEqualStrings("ctrl+c", k1.?);

    const k2 = iter.next();
    try t.expect(k2 != null);
    try t.expectEqualStrings("enter", k2.?);

    const k3 = iter.next();
    try t.expect(k3 != null);
    try t.expectEqualStrings("up", k3.?);

    try t.expectEqual(@as(?[]const u8, null), iter.next());
}

test "JsonArrayIterator empty" {
    var iter = JsonArrayIterator.init("");
    try t.expectEqual(@as(?[]const u8, null), iter.next());
}

test "jsonEscapeString quotes and backslash" {
    var buf: [256]u8 = undefined;
    const result = tools.jsonEscapeString("hello \"world\"", &buf);
    try t.expectEqualStrings("hello \\\"world\\\"", result);

    const result2 = tools.jsonEscapeString("path\\to\\file", &buf);
    try t.expectEqualStrings("path\\\\to\\\\file", result2);

    const result3 = tools.jsonEscapeString("{\"key\":\"val\"}", &buf);
    try t.expectEqualStrings("{\\\"key\\\":\\\"val\\\"}", result3);
}
