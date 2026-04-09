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
        return jsonRpcError(resp_buf, id, -32601, "Method not found");
    }
}

// ── MCP method handlers ────────────────────────────────────────

fn handleInitialize(self: *McpServer, buf: []u8, id: ?[]const u8) []const u8 {
    _ = self;
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"protocolVersion":"2025-03-26","capabilities":{{"tools":{{}},"prompts":{{}}}},"serverInfo":{{"name":"teru","version":"{s}"}}}},"id":{s}}}
    , .{ build_options.version, id_str }) catch
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
        \\{{"name":"teru_create_pane","description":"Spawn a new pane in a workspace","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer","default":0}},"direction":{{"type":"string","enum":["vertical","horizontal"],"default":"vertical"}},"command":{{"type":"string","description":"Command to run (default: user shell)"}},"cwd":{{"type":"string","description":"Working directory (default: active pane CWD)"}}}},"required":[]}}}},
        \\{{"name":"teru_broadcast","description":"Send text to all panes in a workspace","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer"}},"text":{{"type":"string"}}}},"required":["workspace","text"]}}}},
        \\{{"name":"teru_send_keys","description":"Send named keystrokes to a pane (e.g. enter, ctrl+c, up, f1)","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}},"keys":{{"type":"array","items":{{"type":"string"}}}}}},"required":["pane_id","keys"]}}}},
        \\{{"name":"teru_get_state","description":"Query terminal state for a pane (cursor, size, modes, title)","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}}}},"required":["pane_id"]}}}},
        \\{{"name":"teru_focus_pane","description":"Focus a specific pane by ID","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}}}},"required":["pane_id"]}}}},
        \\{{"name":"teru_close_pane","description":"Close a pane by ID","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}}}},"required":["pane_id"]}}}},
        \\{{"name":"teru_switch_workspace","description":"Switch the active workspace (0-9)","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer"}}}},"required":["workspace"]}}}},
        \\{{"name":"teru_scroll","description":"Scroll a pane's scrollback (up/down/bottom)","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}},"direction":{{"type":"string","enum":["up","down","bottom"]}},"lines":{{"type":"integer","default":10}}}},"required":["pane_id","direction"]}}}},
        \\{{"name":"teru_wait_for","description":"Check if text pattern exists in pane output (non-blocking)","inputSchema":{{"type":"object","properties":{{"pane_id":{{"type":"integer"}},"pattern":{{"type":"string"}},"lines":{{"type":"integer","default":20}}}},"required":["pane_id","pattern"]}}}},
        \\{{"name":"teru_set_layout","description":"Set the layout for a workspace. Layouts: master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion","inputSchema":{{"type":"object","properties":{{"workspace":{{"type":"integer","default":0}},"layout":{{"type":"string","enum":["master-stack","grid","monocle","dishes","spiral","three-col","columns","accordion"]}}}},"required":["layout"]}}}},
        \\{{"name":"teru_set_config","description":"Set a config value. Writes to teru.conf and triggers hot-reload. Keys: font_size, padding, opacity, theme, cursor_shape, cursor_blink, scroll_speed, bold_is_bright, bell, copy_on_select, bg, fg, cursor_color, attention_color","inputSchema":{{"type":"object","properties":{{"key":{{"type":"string"}},"value":{{"type":"string"}}}},"required":["key","value"]}}}},
        \\{{"name":"teru_get_config","description":"Get current live config values as JSON","inputSchema":{{"type":"object","properties":{{}},"required":[]}}}},
        \\{{"name":"teru_session_save","description":"Save current session state to a .tsess file. Captures workspaces, layouts, pane CWDs and commands.","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string","description":"Session name (saved to ~/.config/teru/sessions/NAME.tsess)"}}}},"required":["name"]}}}},
        \\{{"name":"teru_session_restore","description":"Restore a session from a .tsess file. Idempotent: panes matched by role are not duplicated.","inputSchema":{{"type":"object","properties":{{"name":{{"type":"string","description":"Session name to restore"}}}},"required":["name"]}}}},
        \\{{"name":"teru_screenshot","description":"Capture the terminal framebuffer as a PNG image file. Returns the file path and dimensions. Only works in windowed mode (X11/Wayland).","inputSchema":{{"type":"object","properties":{{"path":{{"type":"string","description":"Output file path (default: /tmp/teru-screenshot.png)"}}}},"required":[]}}}}
        \\]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
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
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn handlePromptsGet(self: *McpServer, body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = self;
    const id_str = id orelse "null";
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return jsonRpcError(buf, id, -32602, "Missing params");
    const params_body = body[params_start..];
    const name = extractNestedJsonString(params_body, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing params.name");

    if (std.mem.eql(u8, name, "workspace_setup")) {
        const user_desc = extractNestedJsonString(params_body, "description") orelse "default setup";
        return std.fmt.bufPrint(buf,
            \\{{"jsonrpc":"2.0","result":{{"messages":[
            \\{{"role":"user","content":{{"type":"text","text":"Set up teru workspaces as follows: {s}\n\nYou have these teru MCP tools:\n- teru_switch_workspace(workspace) — switch to workspace 0-9\n- teru_create_pane(workspace, direction) — spawn a new pane (starts user shell)\n- teru_send_input(pane_id, text) — type text into pane (omit \\n to leave command typed but not executed)\n- teru_send_keys(pane_id, keys) — send keystrokes like ['enter'], ['ctrl+c']\n- teru_set_layout(workspace, layout) — layouts: master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion\n- teru_set_config(key, value) — set appearance: font_size, opacity, theme, bg, fg, padding, cursor_shape\n- teru_focus_pane(pane_id) — focus a pane\n- teru_list_panes() — list all panes to get IDs\n\nWorkflow:\n1. For each workspace: switch to it, create panes, set layout\n2. To type a command without running it: teru_send_input(id, 'command') — no \\n\n3. To type and execute: teru_send_input(id, 'command') then teru_send_keys(id, ['enter'])\n4. After creating panes, call teru_list_panes() to get their IDs for send_input\n5. Workspace 0 already has 1 pane — create additional panes as needed"}}}}
            \\]}},"id":{s}}}
        , .{ user_desc, id_str }) catch
            jsonRpcError(buf, id, -32603, "Internal error");
    } else {
        return jsonRpcError(buf, id, -32602, "Unknown prompt");
    }
}

fn handleToolsCall(self: *McpServer, body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    // Extract params.name from the JSON body
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return jsonRpcError(buf, id, -32602, "Missing params");

    const params_body = body[params_start..];
    // Tool name is at params top level, NOT inside arguments.
    // Use extractJsonString (not extractNestedJsonString) to avoid
    // collision when an argument is also named "name".
    const tool_name = extractJsonString(params_body, "name") orelse
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
        const dir_str = extractNestedJsonString(params_body, "direction");
        const is_horizontal = if (dir_str) |d| std.mem.eql(u8, d, "horizontal") else false;
        const command = extractNestedJsonString(params_body, "command");
        const cwd = extractNestedJsonString(params_body, "cwd");
        return self.toolCreatePane(@intCast(workspace), is_horizontal, command, cwd, buf, id);
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
    } else if (std.mem.eql(u8, tool_name, "teru_set_layout")) {
        const layout_str = extractNestedJsonString(params_body, "layout") orelse
            return jsonRpcError(buf, id, -32602, "Missing layout");
        const workspace = extractNestedJsonInt(params_body, "workspace") orelse 0;
        return self.toolSetLayout(@intCast(workspace), layout_str, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_set_config")) {
        const key = extractNestedJsonString(params_body, "key") orelse
            return jsonRpcError(buf, id, -32602, "Missing key");
        const value = extractNestedJsonString(params_body, "value") orelse
            return jsonRpcError(buf, id, -32602, "Missing value");
        return self.toolSetConfig(key, value, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_get_config")) {
        return self.toolGetConfig(buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_session_save")) {
        const name = extractNestedJsonString(params_body, "name") orelse
            return jsonRpcError(buf, id, -32602, "Missing name");
        return self.toolSessionSave(name, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_session_restore")) {
        const name = extractNestedJsonString(params_body, "name") orelse
            return jsonRpcError(buf, id, -32602, "Missing name");
        return self.toolSessionRestore(name, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teru_screenshot")) {
        const path = extractNestedJsonString(params_body, "path") orelse "/tmp/teru-screenshot.png";
        return self.toolScreenshot(path, buf, id);
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
            \\{{\"id\":{d},\"workspace\":{d},\"name\":\"{s}\",\"status\":\"{s}\",\"rows\":{d},\"cols\":{d}}}
        , .{ pane.id, workspace, proc_name, status, pane.grid.rows, pane.grid.cols }) catch break;
        pos += entry.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "]\"}}]}},\"id\":{s}}}", .{id_str}) catch
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
            \\{{\"id\":{d},\"name\":\"{s}\",\"kind\":\"{s}\",\"state\":\"{s}\"
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

    // Unescape JSON string sequences before writing to PTY
    var unesc: [4096]u8 = undefined;
    const unesc_text = unescapeJson(text, &unesc);

    _ = pane.pty.write(unesc_text) catch
        return jsonRpcError(buf, id, -32603, "Write failed");

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolCreatePane(self: *McpServer, workspace: u8, horizontal: bool, command: ?[]const u8, cwd_param: ?[]const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    // Resolve CWD: explicit param > active pane's CWD > inherit
    var cwd_buf: [512]u8 = undefined;
    const cwd: ?[]const u8 = if (cwd_param) |c| c else blk: {
        // Read active pane's CWD from /proc/<pid>/cwd
        if (self.multiplexer.getActivePane()) |pane| {
            if (pane.pty.child_pid) |pid| {
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
        return jsonRpcError(buf, id, -32603, "Spawn failed");

    // Add to split tree if active
    const ws = &self.multiplexer.layout_engine.workspaces[workspace];
    const dir: @import("../tiling/LayoutEngine.zig").SplitDirection = if (horizontal) .horizontal else .vertical;
    ws.addNodeSplit(self.multiplexer.allocator, pane_id, dir) catch {};

    // Register in graph — non-fatal: pane works without graph tracking
    if (self.multiplexer.getPaneById(pane_id)) |pane| {
        _ = self.graph.spawn(.{
            .name = "shell",
            .kind = .shell,
            .pid = pane.pty.child_pid,
            .workspace = workspace,
        }) catch {};
    }

    // Resize all PTYs to match new layout
    if (self.screen_width > 0) {
        self.multiplexer.resizePanePtys(self.screen_width, self.screen_height, self.cell_width, self.cell_height, self.padding);
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
        return jsonRpcError(buf, id, -32603, "Internal error");

    // Escape for embedding inside JSON "text" string value
    var escaped_buf: [4096]u8 = undefined;
    const escaped = jsonEscapeString(inner_json, &escaped_buf);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{s}"}}]}},"id":{s}}}
    , .{ escaped, id_str }) catch
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

    if (workspace > 9)
        return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    self.multiplexer.switchWorkspace(workspace);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSetLayout(self: *McpServer, workspace: u8, layout_str: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const LayoutEngine = @import("../tiling/LayoutEngine.zig");

    if (workspace > 9)
        return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    const layout: LayoutEngine.Layout = if (std.mem.eql(u8, layout_str, "master-stack") or std.mem.eql(u8, layout_str, "master_stack"))
        .master_stack
    else if (std.mem.eql(u8, layout_str, "grid"))
        .grid
    else if (std.mem.eql(u8, layout_str, "monocle"))
        .monocle
    else if (std.mem.eql(u8, layout_str, "dishes"))
        .dishes
    else if (std.mem.eql(u8, layout_str, "accordion"))
        .accordion
    else if (std.mem.eql(u8, layout_str, "spiral"))
        .spiral
    else if (std.mem.eql(u8, layout_str, "three-col") or std.mem.eql(u8, layout_str, "three_col"))
        .three_col
    else if (std.mem.eql(u8, layout_str, "columns"))
        .columns
    else
        return jsonRpcError(buf, id, -32602, "Unknown layout");

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
        self.multiplexer.resizePanePtys(self.screen_width, self.screen_height, self.cell_width, self.cell_height, self.padding);
    }
    // Mark panes dirty for redraw
    for (self.multiplexer.panes.items) |*pane| pane.grid.dirty = true;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"ok"}}]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
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
        return jsonRpcError(buf, id, -32602, "Unknown config key");

    // Read existing config, update or append the key
    const home = compat.getenv("HOME") orelse
        return jsonRpcError(buf, id, -32603, "HOME not set");

    var path_buf: [512:0]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/teru/teru.conf", .{home}) catch
        return jsonRpcError(buf, id, -32603, "Path too long");
    path_buf[path.len] = 0;

    // Build the new line: "key = value\n"
    var line_buf: [256]u8 = undefined;
    const new_line = std.fmt.bufPrint(&line_buf, "{s} = {s}\n", .{ key, value }) catch
        return jsonRpcError(buf, id, -32603, "Value too long");

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
            return jsonRpcError(buf, id, -32603, "Cannot write config file");

        var replaced = false;
        var pos: usize = 0;
        while (pos < file_len) {
            // Find end of current line
            const line_end = std.mem.indexOfScalar(u8, file_buf[pos..file_len], '\n') orelse (file_len - pos);
            const line = file_buf[pos .. pos + line_end];

            // Check if this line starts with our key
            if (lineMatchesKey(line, key)) {
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

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"set {s} = {s}"}}]}},"id":{s}}}
    , .{ key, value, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn lineMatchesKey(line: []const u8, key: []const u8) bool {
    // Trim leading whitespace
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    const trimmed = line[start..];
    if (trimmed.len < key.len) return false;
    if (!std.mem.startsWith(u8, trimmed, key)) return false;
    // After key, expect whitespace or '='
    if (trimmed.len == key.len) return true;
    const next = trimmed[key.len];
    return next == ' ' or next == '=' or next == '\t';
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
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSessionSave(self: *McpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const SessionConfig = @import("../config/Session.zig");

    // Generate .tsess content from live state
    const content = SessionConfig.saveFromLive(self.allocator, self.multiplexer, self.graph) catch
        return jsonRpcError(buf, id, -32603, "Failed to snapshot session");
    defer self.allocator.free(content);

    // Build path: ~/.config/teru/sessions/NAME.tsess
    const path = SessionConfig.getSessionPath(self.allocator, name) catch
        return jsonRpcError(buf, id, -32603, "Failed to build session path");
    defer self.allocator.free(path);

    // Write to file (using C fopen/fwrite since we don't have io here)
    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return jsonRpcError(buf, id, -32603, "Path too long");
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    // Ensure parent directory exists
    ensureParentDirC(path);

    const f = std.c.fopen(@ptrCast(path_z[0..path.len :0]), "w");
    if (f == null) return jsonRpcError(buf, id, -32603, "Cannot write session file");
    _ = std.c.fwrite(content.ptr, 1, content.len, f.?);
    _ = std.c.fclose(f.?);

    // JSON-escape the path for the response
    var escaped_path: [1024]u8 = undefined;
    const epath = jsonEscapeString(path, &escaped_path);

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"saved to {s}"}}]}},"id":{s}}}
    , .{ epath, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolSessionRestore(self: *McpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const SessionConfig = @import("../config/Session.zig");

    // Build path and read file
    const path = SessionConfig.getSessionPath(self.allocator, name) catch
        return jsonRpcError(buf, id, -32603, "Failed to build session path");
    defer self.allocator.free(path);

    // Read file using C fopen/fread
    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return jsonRpcError(buf, id, -32603, "Path too long");
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var file_buf: [SessionConfig.max_file_size]u8 = undefined;
    var file_len: usize = 0;
    {
        const f = std.c.fopen(@ptrCast(path_z[0..path.len :0]), "r");
        if (f == null) return jsonRpcError(buf, id, -32602, "Session file not found");
        file_len = std.c.fread(&file_buf, 1, file_buf.len, f.?);
        _ = std.c.fclose(f.?);
    }

    if (file_len == 0) return jsonRpcError(buf, id, -32602, "Session file empty");

    // Parse
    var def = SessionConfig.parse(self.allocator, file_buf[0..file_len]) catch
        return jsonRpcError(buf, id, -32603, "Failed to parse session file");
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
                self.multiplexer.resizePanePtys(self.screen_width, self.screen_height, self.cell_width, self.cell_height, self.padding);
            }
        }
        self.multiplexer.switchWorkspace(prev_ws);
    }

    // Mark all panes dirty
    for (self.multiplexer.panes.items) |*pane| pane.grid.dirty = true;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"restored session {s} ({d} workspaces)"}}]}},"id":{s}}}
    , .{ name, def.workspace_count, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn toolScreenshot(self: *McpServer, path: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";

    const r = self.renderer orelse
        return jsonRpcError(buf, id, -32603, "No renderer (TTY mode has no framebuffer)");

    const pixels = r.getFramebuffer() orelse
        return jsonRpcError(buf, id, -32603, "No framebuffer available");

    const width: u32 = switch (r.*) {
        .cpu => |cpu| cpu.width,
        .tty => return jsonRpcError(buf, id, -32603, "No framebuffer in TTY mode"),
    };
    const height: u32 = switch (r.*) {
        .cpu => |cpu| cpu.height,
        .tty => return jsonRpcError(buf, id, -32603, "No framebuffer in TTY mode"),
    };

    // Null-terminate path for C fopen
    var path_z: [512:0]u8 = undefined;
    if (path.len >= path_z.len) return jsonRpcError(buf, id, -32602, "Path too long");
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    png.write(self.allocator, @ptrCast(path_z[0..path.len :0]), pixels, width, height) catch |err| {
        return switch (err) {
            error.FileOpenFailed => jsonRpcError(buf, id, -32603, "Failed to open output file"),
            error.OutOfMemory => jsonRpcError(buf, id, -32603, "Out of memory"),
        };
    };

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"screenshot saved to {s} ({d}x{d})"}}]}},"id":{s}}}
    , .{ path, width, height, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

/// Ensure parent directory exists using C mkdir.
fn ensureParentDirC(path: []const u8) void {
    // Find last '/' to get parent dir
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (last_slash == 0) return;

    // Walk path components and create each one
    var path_z: [512:0]u8 = undefined;
    var i: usize = 1;
    while (i <= last_slash and i < path_z.len) : (i += 1) {
        if (path[i] == '/' or i == last_slash) {
            @memcpy(path_z[0..i], path[0..i]);
            path_z[i] = 0;
            _ = std.c.mkdir(@ptrCast(path_z[0..i :0]), 0o755);
        }
    }
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
                \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"matched\":true,\"line\":\"{s}\"}}"}}]}},"id":{s}}}
            , .{ escaped[0..elen], id_str }) catch
                jsonRpcError(buf, id, -32603, "Internal error");
            }
        }

        // Not found this attempt — sleep 50ms and retry
        compat.sleepNs(50_000_000); // 50ms
    }

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"matched\":false}}"}}]}},"id":{s}}}
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

/// Unescape JSON string escape sequences: \n \r \t \\ \"
fn unescapeJson(src: []const u8, dst: []u8) []const u8 {
    var di: usize = 0;
    var si: usize = 0;
    while (si < src.len and di < dst.len) {
        if (src[si] == '\\' and si + 1 < src.len) {
            switch (src[si + 1]) {
                'n' => { dst[di] = '\n'; di += 1; si += 2; },
                'r' => { dst[di] = '\r'; di += 1; si += 2; },
                't' => { dst[di] = '\t'; di += 1; si += 2; },
                '\\' => { dst[di] = '\\'; di += 1; si += 2; },
                '"' => { dst[di] = '"'; di += 1; si += 2; },
                else => { dst[di] = src[si]; di += 1; si += 1; },
            }
        } else {
            dst[di] = src[si];
            di += 1;
            si += 1;
        }
    }
    return dst[0..di];
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

test "jsonEscapeString quotes and backslash" {
    var buf: [256]u8 = undefined;
    const result = jsonEscapeString("hello \"world\"", &buf);
    try t.expectEqualStrings("hello \\\"world\\\"", result);

    const result2 = jsonEscapeString("path\\to\\file", &buf);
    try t.expectEqualStrings("path\\\\to\\\\file", result2);

    const result3 = jsonEscapeString("{\"key\":\"val\"}", &buf);
    try t.expectEqualStrings("{\\\"key\\\":\\\"val\\\"}", result3);
}
