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
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Multiplexer = @import("../core/Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Grid = @import("../core/Grid.zig");

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

// ── Lifecycle ──────────────────────────────────────────────────

pub fn init(allocator: Allocator, mux: *Multiplexer, graph: *ProcessGraph) !McpServer {
    const uid = linux.getuid();
    const pid = linux.getpid();

    var path_buf: [socket_path_max]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/run/user/{d}/teru-{d}.sock", .{ uid, pid }) catch
        return error.PathTooLong;
    const path_len = path.len;

    // Remove stale socket if it exists
    var unlink_buf: [socket_path_max + 1]u8 = undefined;
    @memcpy(unlink_buf[0..path_len], path);
    unlink_buf[path_len] = 0;
    _ = std.c.unlink(@ptrCast(&unlink_buf));

    // Create socket
    const sock = std.c.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (sock < 0) return error.SocketFailed;
    errdefer _ = posix.system.close(sock);

    // Set non-blocking for event-loop polling (accept returns EAGAIN when idle)
    const flags = std.c.fcntl(sock, posix.F.GETFL);
    if (flags < 0) return error.FcntlFailed;
    const O_NONBLOCK = 0x800; // linux/fcntl.h
    _ = std.c.fcntl(sock, posix.F.SETFL, flags | O_NONBLOCK);

    // Bind to path
    var addr: posix.sockaddr.un = std.mem.zeroes(posix.sockaddr.un);
    addr.family = posix.AF.UNIX;
    @memcpy(addr.path[0..path_len], path);

    const addr_ptr: *const posix.sockaddr = @ptrCast(&addr);
    if (std.c.bind(sock, addr_ptr, @sizeOf(posix.sockaddr.un)) != 0)
        return error.BindFailed;

    // Allow owner + group read/write so same-user processes can connect
    _ = std.c.chmod(@ptrCast(&unlink_buf), 0o660);

    if (std.c.listen(sock, 5) != 0)
        return error.ListenFailed;

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
    const conn = std.c.accept(self.socket_fd, null, null);
    if (conn < 0) return; // EAGAIN / no connection

    self.handleRequest(conn);
    _ = posix.system.close(conn);
}

// ── HTTP / JSON-RPC handling ───────────────────────────────────

fn handleRequest(self: *McpServer, conn_fd: posix.fd_t) void {
    var req_buf: [max_request]u8 = undefined;
    var total: usize = 0;

    // Read until we have the full HTTP request (Content-Length based)
    while (total < req_buf.len) {
        const rc = std.c.read(conn_fd, req_buf[total..].ptr, req_buf.len - total);
        if (rc <= 0) break;
        total += @intCast(rc);

        // Check if we've received the full body
        if (findBody(req_buf[0..total])) |body_start| {
            if (parseContentLength(req_buf[0..total])) |content_len| {
                if (total >= body_start + content_len) break;
            } else {
                // No Content-Length header — use what we have
                break;
            }
        }
    }

    if (total == 0) return;

    // Extract JSON body from HTTP request
    const body = if (findBody(req_buf[0..total])) |start|
        req_buf[start..total]
    else
        req_buf[0..total]; // Bare JSON (no HTTP framing)

    // Dispatch JSON-RPC
    var resp_buf: [max_response]u8 = undefined;
    const json_response = self.dispatch(body, &resp_buf);

    // Write HTTP response
    var http_header: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&http_header, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{json_response.len}) catch return;

    _ = std.c.write(conn_fd, header.ptr, header.len);
    _ = std.c.write(conn_fd, json_response.ptr, json_response.len);
}

fn dispatch(self: *McpServer, body: []const u8, resp_buf: []u8) []const u8 {
    // Parse JSON-RPC request manually (no JSON library)
    const method = extractJsonString(body, "method") orelse {
        return jsonRpcError(resp_buf, null, -32600, "Invalid Request: missing method");
    };
    const id = extractJsonId(body);

    if (std.mem.eql(u8, method, "tools/list")) {
        return self.handleToolsList(resp_buf, id);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        return self.handleToolsCall(body, resp_buf, id);
    } else if (std.mem.eql(u8, method, "initialize")) {
        return self.handleInitialize(resp_buf, id);
    } else if (std.mem.startsWith(u8, method, "notifications/")) {
        // MCP notifications (initialized, progress, cancelled) — acknowledge silently
        return std.fmt.bufPrint(resp_buf,
            \\{{"jsonrpc":"2.0","result":{{}},"id":{s}}}
        , .{id orelse "null"}) catch "{}";
    } else {
        return jsonRpcError(resp_buf, id, -32601, "Method not found");
    }
}

// ── MCP method handlers ────────────────────────────────────────

fn handleInitialize(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    _ = self;
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"protocolVersion":"2025-03-26","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"teru","version":"0.1.15"}}}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn handleToolsList(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    _ = self;
    const id_str = id orelse "null";

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"tools":[
        \\{{"name":"teru_list_panes","description":"List all panes with id, workspace, agent name, status","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teru_read_output","description":"Get recent N lines from a pane scrollback","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}},"lines":{{"type":"integer","default":50}}}},"required":["pane_id"]}}}},
        \\{{"name":"teru_get_graph","description":"Get the process graph as JSON","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teru_send_input","description":"Write text to a pane PTY stdin","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}},"text":{{"type":"string"}}}},"required":["pane_id","text"]}}}},
        \\{{"name":"teru_create_pane","description":"Spawn a new pane in a workspace","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer","default":0}}}},"required":[]}}}},
        \\{{"name":"teru_broadcast","description":"Send text to all panes in a workspace","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer"}},"text":{{"type":"string"}}}},"required":["workspace","text"]}}}},
        \\{{"name":"teru_send_keys","description":"Send named keystrokes to a pane (e.g. enter, ctrl+c, up, f1)","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}},"keys":{{"type":"array","items":{{"type":"string"}}}}}},"required":["pane_id","keys"]}}}},
        \\{{"name":"teru_get_state","description":"Query terminal state for a pane (cursor, size, modes, title)","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}}}},"required":["pane_id"]}}}},
        \\{{"name":"teru_focus_pane","description":"Focus a specific pane by ID","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}}}},"required":["pane_id"]}}}},
        \\{{"name":"teru_close_pane","description":"Close a pane by ID","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}}}},"required":["pane_id"]}}}},
        \\{{"name":"teru_switch_workspace","description":"Switch the active workspace (0-8)","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer"}}}},"required":["workspace"]}}}},
        \\{{"name":"teru_scroll","description":"Scroll a pane's scrollback (up/down/bottom)","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}},"direction":{{"type":"string","enum":["up","down","bottom"]}},"lines":{{"type":"integer","default":10}}}},"required":["pane_id","direction"]}}}},
        \\{{"name":"teru_wait_for","description":"Check if text pattern exists in pane output (non-blocking)","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}},"pattern":{{"type":"string"}},"lines":{{"type":"integer","default":20}}}},"required":["pane_id","pattern"]}}}}
        \\]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn handleToolsCall(self: *McpServer, body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    // Extract params.name from the JSON body
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return jsonRpcError(buf, id, -32602, "Missing params");

    const params_body = body[params_start..];
    const tool_name = extractNestedJsonString(params_body, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing params.name");

    if (std.mem.eql(u8, tool_name, "teru_list_panes")) {
        return self.toolListPanes(buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_read_output")) {
        const pane_id = extractNestedJsonInt(params_body, "pane_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing pane_id");
        const lines = extractNestedJsonInt(params_body, "lines") orelse 50;
        return self.toolReadOutput(pane_id, @intCast(lines), buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_get_graph")) {
        return self.toolGetGraph(buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_send_input")) {
        const pane_id = extractNestedJsonInt(params_body, "pane_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing pane_id");
        const text = extractNestedJsonString(params_body, "text") orelse
            return jsonRpcError(buf, id, -32602, "Missing text");
        return self.toolSendInput(pane_id, text, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_create_pane")) {
        const workspace = extractNestedJsonInt(params_body, "workspace") orelse 0;
        return self.toolCreatePane(@intCast(workspace), buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_broadcast")) {
        const workspace = extractNestedJsonInt(params_body, "workspace") orelse
            return jsonRpcError(buf, id, -32602, "Missing workspace");
        const text = extractNestedJsonString(params_body, "text") orelse
            return jsonRpcError(buf, id, -32602, "Missing text");
        return self.toolBroadcast(@intCast(workspace), text, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_send_keys")) {
        const pane_id = extractNestedJsonInt(params_body, "pane_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing pane_id");
        return self.toolSendKeys(pane_id, params_body, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_get_state")) {
        const pane_id = extractNestedJsonInt(params_body, "pane_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing pane_id");
        return self.toolGetState(pane_id, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_focus_pane")) {
        const pane_id = extractNestedJsonInt(params_body, "pane_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing pane_id");
        return self.toolFocusPane(pane_id, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_close_pane")) {
        const pane_id = extractNestedJsonInt(params_body, "pane_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing pane_id");
        return self.toolClosePane(pane_id, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_switch_workspace")) {
        const workspace = extractNestedJsonInt(params_body, "workspace") orelse
            return jsonRpcError(buf, id, -32602, "Missing workspace");
        return self.toolSwitchWorkspace(@intCast(workspace), buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_scroll")) {
        const pane_id = extractNestedJsonInt(params_body, "pane_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing pane_id");
        const direction = extractNestedJsonString(params_body, "direction") orelse "up";
        const lines = extractNestedJsonInt(params_body, "lines") orelse 10;
        return self.toolScroll(@intCast(pane_id), direction, @intCast(lines), buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_wait_for")) {
        const pane_id = extractNestedJsonInt(params_body, "pane_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing pane_id");
        const pattern = extractNestedJsonString(params_body, "pattern") orelse
            return jsonRpcError(buf, id, -32602, "Missing pattern");
        const lines = extractNestedJsonInt(params_body, "lines") orelse 20;
        return self.toolWaitFor(@intCast(pane_id), pattern, @intCast(lines), buf, id);
    } else {
        return jsonRpcError(buf, id, -32602, "Unknown tool");
    }
}

// ── Tool implementations ───────────────────────────────────────

fn toolListPanes(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    var pos: usize = 0;

    // Build JSON array of panes
    const prefix = std.fmt.bufPrint(buf[pos..], "{s}{s}", .{
        "{\"jsonrpc\":\"2.0\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[",
        "",
    }) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += prefix.len;

    for (self.multiplexer.panes.items, 0..) |*pane, i| {
        if (i > 0) {
            if (pos < buf.len) {
                buf[pos] = ',';
                pos += 1;
            }
        }
        // Find process name from graph
        const proc_name = self.findPaneName(pane.id);
        const status = if (pane.isAlive()) "running" else "exited";
        const workspace = self.findPaneWorkspace(pane.id);

        const entry = std.fmt.bufPrint(buf[pos..],
            \\{{"id":{d},"workspace":{d},"name":\"{s}\","status":\"{s}\","rows":{d},"cols":{d}}}
        , .{ pane.id, workspace, proc_name, status, pane.grid.rows, pane.grid.cols }) catch break;
        pos += entry.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "]\"}}}},\"id\":{s}}}", .{id_str}) catch
        return jsonRpcError(buf, id, -32603, "Internal error");
    pos += suffix.len;

    return buf[0..pos];
}

fn toolReadOutput(self: *McpServer, pane_id: u64, lines: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return jsonRpcError(buf, id, -32602, "Pane not found");

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
    const escaped = jsonEscapeString(text_buf[0..text_pos], &escaped_buf);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{s}"}}]}},"id":{s}}}
    , .{ escaped, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolGetGraph(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    var pos: usize = 0;

    const prefix = "{\"jsonrpc\":\"2.0\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"nodes\\\":[";
    if (pos + prefix.len > buf.len) return jsonRpcError(buf, id, -32603, "Internal error");
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

        const entry_json = std.fmt.bufPrint(buf[pos..],
            \\{{\\"id\\":{d},\\"name\\":\\"{s}\\",\\"kind\\":\\"{s}\\",\\"state\\":\\"{s}\\"
        , .{ node.id, node.name, kind_str, state_str }) catch break;
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
    if (pos + suffix_str.len + id_str.len + 1 > buf.len) return jsonRpcError(buf, id, -32603, "Internal error");
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
        return jsonRpcError(buf, id, -32602, "Pane not found");

    _ = pane.pty.write(text) catch
        return jsonRpcError(buf, id, -32603, "Write failed");

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolCreatePane(self: *McpServer, workspace: u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    // Save current workspace, switch, spawn, restore
    const prev_workspace = self.multiplexer.active_workspace;
    if (workspace != prev_workspace) {
        self.multiplexer.switchWorkspace(workspace);
    }

    // Use default grid size (24x80)
    const pane_id = self.multiplexer.spawnPane(24, 80) catch
        return jsonRpcError(buf, id, -32603, "Spawn failed");

    // Register in graph — non-fatal: pane works without graph tracking
    if (self.multiplexer.getPaneById(pane_id)) |pane| {
        _ = self.graph.spawn(.{
            .name = "shell",
            .kind = .shell,
            .pid = pane.pty.child_pid,
            .workspace = workspace,
        }) catch {};
    }

    // Restore workspace
    if (workspace != prev_workspace) {
        self.multiplexer.switchWorkspace(prev_workspace);
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{d}"}}]}},"id":{s}}}
    , .{ pane_id, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolBroadcast(self: *McpServer, workspace: u8, text: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    // Get pane IDs in the workspace from the layout engine
    const ws = &self.multiplexer.layout_engine.workspaces[workspace];
    var sent: u32 = 0;

    for (ws.node_ids.items) |node_id| {
        if (self.multiplexer.getPaneById(node_id)) |pane| {
            _ = pane.pty.write(text) catch continue;
            sent += 1;
        }
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"sent to {d} panes"}}]}},"id":{s}}}
    , .{ sent, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSendKeys(self: *McpServer, pane_id: u64, params_body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return jsonRpcError(buf, id, -32602, "Pane not found");

    const app_cursor = pane.vt.app_cursor_keys;

    // Find the "keys" array in the arguments
    const keys_json = extractNestedJsonArray(params_body, "keys") orelse
        return jsonRpcError(buf, id, -32602, "Missing keys array");

    // Iterate over string elements in the JSON array
    var sent: u32 = 0;
    var iter = JsonArrayIterator.init(keys_json);
    while (iter.next()) |key_name| {
        const seq = resolveKey(key_name, app_cursor);
        _ = pane.pty.write(seq) catch continue;
        sent += 1;
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"sent {d} keys"}}]}},"id":{s}}}
    , .{ sent, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolGetState(self: *McpServer, pane_id: u64, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return jsonRpcError(buf, id, -32602, "Pane not found");

    const grid = &pane.grid;
    const vt = &pane.vt;

    // JSON-escape the title
    var title_escaped_buf: [512]u8 = undefined;
    const title_escaped = jsonEscapeString(vt.title[0..vt.title_len], &title_escaped_buf);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{"cursor_row":{d},"cursor_col":{d},"cursor_visible":{s},"rows":{d},"cols":{d},"alt_screen":{s},"bracketed_paste":{s},"app_cursor_keys":{s},"title":\"{s}\","scroll_top":{d},"scroll_bottom":{d}}}"}}]}},"id":{s}}}
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
        id_str,
    }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
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
                    jsonRpcError(buf, id, -32603, "Internal error");
            }
        }
    }

    return jsonRpcError(buf, id, -32602, "Pane not found");
}

fn toolClosePane(self: *McpServer, pane_id: u64, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    // Verify pane exists before closing
    if (self.multiplexer.getPaneById(pane_id) == null)
        return jsonRpcError(buf, id, -32602, "Pane not found");

    self.multiplexer.closePane(pane_id);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSwitchWorkspace(self: *McpServer, workspace: u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    if (workspace > 8)
        return jsonRpcError(buf, id, -32602, "Workspace must be 0-8");

    self.multiplexer.switchWorkspace(workspace);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolScroll(self: *McpServer, pane_id: u64, direction: []const u8, lines: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return jsonRpcError(buf, id, -32602, "Pane not found");

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
        return jsonRpcError(buf, id, -32602, "direction must be up/down/bottom");
    }

    pane.grid.dirty = true;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"scroll_offset={d}"}}]}},"id":{s}}}
    , .{ pane.scroll_offset, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolWaitFor(self: *McpServer, pane_id: u64, pattern: []const u8, lines: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const pane = self.multiplexer.getPaneById(pane_id) orelse
        return jsonRpcError(buf, id, -32602, "Pane not found");

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
                \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{"matched\":true,\"line\":\"{s}\"}}"}}]}},"id":{s}}}
            , .{ escaped[0..elen], id_str }) catch
                jsonRpcError(buf, id, -32603, "Internal error");
            }
        }

        // Not found this attempt — sleep 50ms and retry
        var ts = std.os.linux.timespec{ .sec = 0, .nsec = 50_000_000 };
        _ = std.os.linux.nanosleep(&ts, null);
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{"matched\":false}}"}}]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
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

fn findBody(data: []const u8) ?usize {
    // Find \r\n\r\n separator between HTTP headers and body
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |pos| {
        return pos + 4;
    }
    return null;
}

fn parseContentLength(data: []const u8) ?usize {
    const needle = "Content-Length: ";
    const pos = std.mem.indexOf(u8, data, needle) orelse
        // Try lowercase
        std.mem.indexOf(u8, data, "content-length: ") orelse
        return null;

    const start = pos + needle.len;
    const end = std.mem.indexOfScalar(u8, data[start..], '\r') orelse return null;
    return std.fmt.parseInt(usize, data[start .. start + end], 10) catch null;
}

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key":"value" pattern
    // Build the search pattern "key":"
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const after_key = key_pos + needle.len;

    // Skip whitespace
    var i = after_key;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len or json[i] != '"') return null;
    i += 1; // skip opening quote

    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {
        if (json[i] == '\\') i += 1; // skip escaped char
    }
    if (i >= json.len) return null;

    return json[start..i];
}

fn extractNestedJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Same as extractJsonString but searches for the key within "arguments" or at top level
    // First try within "arguments" block
    if (std.mem.indexOf(u8, json, "\"arguments\"")) |args_pos| {
        if (extractJsonString(json[args_pos..], key)) |val| return val;
    }
    return extractJsonString(json, key);
}

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

fn extractNestedJsonInt(json: []const u8, key: []const u8) ?u64 {
    // Find "key":N pattern (number value)
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    // Search in "arguments" first, then top-level
    const search_start = if (std.mem.indexOf(u8, json, "\"arguments\"")) |ap| ap else 0;
    const key_pos = std.mem.indexOf(u8, json[search_start..], needle) orelse
        std.mem.indexOf(u8, json, needle) orelse return null;

    const after_key = search_start + key_pos + needle.len;

    var i = after_key;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len) return null;

    // Could be a number
    const start = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(u64, json[start..i], 10) catch null;
}

fn jsonEscapeString(input: []const u8, output: []u8) []const u8 {
    var out_pos: usize = 0;
    for (input) |c| {
        if (out_pos + 2 > output.len) break;
        switch (c) {
            '"' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = '"';
                out_pos += 1;
            },
            '\\' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = '\\';
                out_pos += 1;
            },
            '\n' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = 'n';
                out_pos += 1;
            },
            '\r' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = 'r';
                out_pos += 1;
            },
            '\t' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = 't';
                out_pos += 1;
            },
            else => {
                if (c >= 0x20) {
                    output[out_pos] = c;
                    out_pos += 1;
                }
                // Skip control chars
            },
        }
    }
    return output[0..out_pos];
}

fn jsonRpcError(buf: []u8, id: ?[]const u8, code: i32, message: []const u8) []const u8 {
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","error":{{"code":{d},"message":"{s}"}},"id":{s}}}
    , .{ code, message, id_str }) catch "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"},\"id\":null}";
}

// ── Tests ──────────────────────────────────────────────────────

const t = std.testing;

test "extractJsonString basic" {
    const json = "{\"method\":\"tools/list\",\"id\":1}";
    const method = extractJsonString(json, "method");
    try t.expect(method != null);
    try t.expectEqualStrings("tools/list", method.?);
}

test "extractJsonString with spaces" {
    const json = "{\"method\": \"tools/call\", \"id\": 2}";
    const method = extractJsonString(json, "method");
    try t.expect(method != null);
    try t.expectEqualStrings("tools/call", method.?);
}

test "extractJsonString missing key" {
    const json = "{\"method\":\"tools/list\"}";
    try t.expectEqual(@as(?[]const u8, null), extractJsonString(json, "missing"));
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
    const pane_id = extractNestedJsonInt(json, "pane_id");
    try t.expect(pane_id != null);
    try t.expectEqual(@as(u64, 3), pane_id.?);

    const lines = extractNestedJsonInt(json, "lines");
    try t.expect(lines != null);
    try t.expectEqual(@as(u64, 20), lines.?);
}

test "extractNestedJsonString" {
    const json = "{\"params\":{\"name\":\"teru_send_input\",\"arguments\":{\"pane_id\":1,\"text\":\"hello\"}}}";
    const text = extractNestedJsonString(json, "text");
    try t.expect(text != null);
    try t.expectEqualStrings("hello", text.?);

    const name = extractNestedJsonString(json, "name");
    try t.expect(name != null);
    try t.expectEqualStrings("teru_send_input", name.?);
}

test "jsonEscapeString" {
    var buf: [256]u8 = undefined;

    const result1 = jsonEscapeString("hello world", &buf);
    try t.expectEqualStrings("hello world", result1);

    const result2 = jsonEscapeString("line1\nline2", &buf);
    try t.expectEqualStrings("line1\\nline2", result2);

    const result3 = jsonEscapeString("a\"b\\c", &buf);
    try t.expectEqualStrings("a\\\"b\\\\c", result3);
}

test "jsonRpcError" {
    var buf: [512]u8 = undefined;
    const result = jsonRpcError(&buf, "1", -32601, "Method not found");
    try t.expect(std.mem.indexOf(u8, result, "-32601") != null);
    try t.expect(std.mem.indexOf(u8, result, "Method not found") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
}

test "findBody" {
    const http = "POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const body_start = findBody(http);
    try t.expect(body_start != null);
    try t.expectEqualStrings("hello", http[body_start.?..]);
}

test "parseContentLength" {
    const http = "POST /mcp HTTP/1.1\r\nContent-Length: 42\r\n\r\n";
    const cl = parseContentLength(http);
    try t.expect(cl != null);
    try t.expectEqual(@as(usize, 42), cl.?);
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
