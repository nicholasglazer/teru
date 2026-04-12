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
// Version comes from teru's McpServer which gets it from build_options
const version = "0.4.0";

const WmMcpServer = @This();

const max_request: usize = 65536;
const max_response: usize = 65536;
const socket_path_max: usize = 108;

socket_path: [socket_path_max]u8,
socket_path_len: usize,
socket_fd: posix.fd_t,
server: *Server,
event_source: ?*wlr.wl_event_source = null,

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
    }

    std.debug.print("teruwm: MCP server on {s}\n", .{path});
    return self;
}

pub fn deinit(self: *WmMcpServer, allocator: Allocator) void {
    if (self.event_source) |es| _ = wlr.wl_event_source_remove(es);
    _ = posix.system.close(self.socket_fd);

    var unlink_buf: [socket_path_max + 1]u8 = undefined;
    @memcpy(unlink_buf[0..self.socket_path_len], self.socket_path[0..self.socket_path_len]);
    unlink_buf[self.socket_path_len] = 0;
    _ = std.c.unlink(@ptrCast(&unlink_buf));

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

fn dispatch(self: *WmMcpServer, body: []const u8, resp_buf: []u8) []const u8 {
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
        \\{{"name":"teruwm_set_bar","description":"Set the enabled state of the top or bottom status bar explicitly.","inputSchema":{{"type":"object","properties":{{"which":{{"type":"string","enum":["top","bottom"]}},"enabled":{{"type":"boolean"}}}},"required":["which","enabled"]}}}}
        \\]}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn handleToolsCall(self: *WmMcpServer, body: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const params_body = extractJsonObject(body, "params") orelse
        return jsonRpcError(buf, id, -32602, "Missing params");
    // "name" is a sibling of "arguments" in params, not nested inside it
    const tool_name = extractJsonString(params_body, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing tool name");

    if (std.mem.eql(u8, tool_name, "teruwm_list_windows")) {
        return self.toolListWindows(buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_spawn_terminal")) {
        const ws = extractNestedJsonInt(params_body, "workspace") orelse 0;
        return self.toolSpawnTerminal(@intCast(ws), buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_close_window")) {
        const nid = extractNestedJsonInt(params_body, "node_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing node_id");
        return self.toolCloseWindow(@intCast(nid), buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_focus_window")) {
        const nid = extractNestedJsonInt(params_body, "node_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing node_id");
        return self.toolFocusWindow(@intCast(nid), buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_move_to_workspace")) {
        const nid = extractNestedJsonInt(params_body, "node_id") orelse
            return jsonRpcError(buf, id, -32602, "Missing node_id");
        const ws = extractNestedJsonInt(params_body, "workspace") orelse
            return jsonRpcError(buf, id, -32602, "Missing workspace");
        return self.toolMoveToWorkspace(@intCast(nid), @intCast(ws), buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_list_workspaces")) {
        return self.toolListWorkspaces(buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_switch_workspace")) {
        const ws = extractNestedJsonInt(params_body, "workspace") orelse
            return jsonRpcError(buf, id, -32602, "Missing workspace");
        return self.toolSwitchWorkspace(@intCast(ws), buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_set_layout")) {
        const layout_str = extractNestedJsonString(params_body, "layout") orelse
            return jsonRpcError(buf, id, -32602, "Missing layout");
        const ws = extractNestedJsonInt(params_body, "workspace") orelse 0;
        return self.toolSetLayout(@intCast(ws), layout_str, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_get_config")) {
        return self.toolGetConfig(buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_set_config")) {
        const key = extractNestedJsonString(params_body, "key") orelse
            return jsonRpcError(buf, id, -32602, "Missing key");
        const value = extractNestedJsonString(params_body, "value") orelse
            return jsonRpcError(buf, id, -32602, "Missing value");
        return self.toolSetConfig(key, value, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_screenshot")) {
        const path = extractNestedJsonString(params_body, "path") orelse "/tmp/teruwm-screenshot.png";
        return self.toolScreenshot(path, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_notify")) {
        const message = extractNestedJsonString(params_body, "message") orelse
            return jsonRpcError(buf, id, -32602, "Missing message");
        return self.toolNotify(message, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_reload_config")) {
        return self.toolReloadConfig(buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_screenshot_pane")) {
        const path = extractNestedJsonString(params_body, "path");
        return self.toolScreenshotPane(params_body, path, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_set_name")) {
        const new_name = extractNestedJsonString(params_body, "new_name") orelse
            return jsonRpcError(buf, id, -32602, "Missing new_name");
        return self.toolSetName(params_body, new_name, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_perf")) {
        return self.toolPerf(buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_restart")) {
        return self.toolRestart(buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_toggle_bar")) {
        const which = extractNestedJsonString(params_body, "which") orelse
            return jsonRpcError(buf, id, -32602, "Missing which (top|bottom)");
        return self.toolToggleBar(which, null, buf, id);
    } else if (std.mem.eql(u8, tool_name, "teruwm_set_bar")) {
        const which = extractNestedJsonString(params_body, "which") orelse
            return jsonRpcError(buf, id, -32602, "Missing which (top|bottom)");
        // Bool extraction: look for "enabled":true / "enabled":false
        const args = extractJsonObject(params_body, "arguments") orelse params_body;
        const enabled: bool = std.mem.indexOf(u8, args, "\"enabled\":true") != null;
        return self.toolToggleBar(which, enabled, buf, id);
    } else {
        return jsonRpcError(buf, id, -32602, "Unknown tool");
    }
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
    const srv = self.server;

    // Find and close terminal pane
    for (srv.terminal_panes, 0..) |maybe_tp, i| {
        if (maybe_tp) |tp| {
            if (tp.node_id == node_id) {
                // Remove from layout engine
                const ws = if (srv.nodes.findById(node_id)) |slot| srv.nodes.workspace[slot] else srv.layout_engine.active_workspace;
                srv.layout_engine.workspaces[ws].removeNode(node_id);
                if (srv.nodes.findById(node_id)) |_| _ = srv.nodes.remove(node_id);

                tp.deinit(srv.zig_allocator);
                srv.zig_allocator.destroy(tp);
                srv.terminal_panes[i] = null;
                srv.terminal_count -|= 1;
                srv.arrangeworkspace(ws);
                srv.updateFocusedTerminal();
                if (srv.bar) |b| b.render(srv);
                return std.fmt.bufPrint(buf,
                    \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"closed window {d}"}}]}},"id":{s}}}
                , .{ node_id, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
            }
        }
    }

    return jsonRpcError(buf, id, -32602, "Window not found");
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
    const srv = self.server;

    if (ws >= 10) return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    if (srv.nodes.findById(node_id)) |_| {
        const old_ws = srv.layout_engine.active_workspace;
        srv.layout_engine.moveNodeToWorkspace(node_id, ws) catch
            return jsonRpcError(buf, id, -32603, "Failed to move node");

        srv.arrangeworkspace(old_ws);
        srv.arrangeworkspace(ws);
        if (srv.bar) |b| b.render(srv);

        return std.fmt.bufPrint(buf,
            \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"moved window {d} to workspace {d}"}}]}},"id":{s}}}
        , .{ node_id, ws, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
    }

    return jsonRpcError(buf, id, -32602, "Window not found");
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
    const srv = self.server;
    if (ws >= 10) return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    const old_ws = srv.layout_engine.active_workspace;
    srv.layout_engine.switchWorkspace(ws);
    srv.setWorkspaceVisibility(old_ws, false);
    srv.setWorkspaceVisibility(ws, true);
    srv.arrangeworkspace(ws);
    srv.updateFocusedTerminal();
    if (srv.bar) |b| b.render(srv);

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

    const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(srv.output_layout)));
    const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(srv.output_layout)));

    const top_enabled = if (srv.bar) |b| b.top.enabled else false;
    const bot_enabled = if (srv.bar) |b| b.bottom.enabled else false;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"{{\"gap\":{d},\"border_width\":{d},\"bg_color\":\"0x{x:0>8}\",\"output_width\":{d},\"output_height\":{d},\"terminal_count\":{d},\"active_workspace\":{d},\"top_bar\":{any},\"bottom_bar\":{any}}}"}}]}},"id":{s}}}
    , .{ cfg.gap, cfg.border_width, cfg.bg_color, out_w, out_h, srv.terminal_count, srv.layout_engine.active_workspace, top_enabled, bot_enabled, id_str }) catch
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
        const out_w: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_width(self.server.output_layout)));
        const out_h: u32 = @intCast(@max(1, wlr.miozu_output_layout_first_height(self.server.output_layout)));
        return std.fmt.bufPrint(buf,
            \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"screenshot saved to {s} ({d}x{d})"}}]}},"id":{s}}}
        , .{ path, out_w, out_h, id_str }) catch jsonRpcError(buf, id, -32603, "Internal error");
    }

    return jsonRpcError(buf, id, -32603, "Screenshot failed");
}

fn toolNotify(_: *WmMcpServer, message: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    // TODO: wire up Notification overlay when integrated into Server
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

// ── JSON utilities (self-contained, no external deps) ─────────

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key":"value"
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = (std.mem.indexOf(u8, json, needle) orelse return null) + needle.len;
    const end = std.mem.indexOfPos(u8, json, start, "\"") orelse return null;
    return json[start..end];
}

fn extractJsonId(json: []const u8) ?[]const u8 {
    // Find "id": followed by a number or string
    const needle = "\"id\":";
    const start = (std.mem.indexOf(u8, json, needle) orelse return null) + needle.len;
    var i = start;
    while (i < json.len and json[i] == ' ') : (i += 1) {}
    if (i >= json.len) return null;

    if (json[i] == '"') {
        const end = std.mem.indexOfPos(u8, json, i + 1, "\"") orelse return null;
        return json[i .. end + 1];
    }
    // Numeric id
    const num_start = i;
    while (i < json.len and (json[i] >= '0' and json[i] <= '9')) : (i += 1) {}
    if (i == num_start) return null;
    return json[num_start..i];
}

fn extractJsonObject(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = (std.mem.indexOf(u8, json, needle) orelse return null) + needle.len;
    var i = start;
    while (i < json.len and json[i] == ' ') : (i += 1) {}
    if (i >= json.len or json[i] != '{') return null;
    var depth: u32 = 0;
    var j = i;
    while (j < json.len) : (j += 1) {
        if (json[j] == '{') depth += 1;
        if (json[j] == '}') {
            depth -= 1;
            if (depth == 0) return json[i .. j + 1];
        }
    }
    return null;
}

fn extractNestedJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Look inside "arguments":{...} first
    const args = extractJsonObject(json, "arguments") orelse json;
    return extractJsonString(args, key);
}

fn extractNestedJsonInt(json: []const u8, key: []const u8) ?i64 {
    const args = extractJsonObject(json, "arguments") orelse json;
    var search_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = (std.mem.indexOf(u8, args, needle) orelse return null) + needle.len;
    var i = start;
    while (i < args.len and args[i] == ' ') : (i += 1) {}
    if (i >= args.len) return null;
    var end = i;
    if (args[end] == '-') end += 1;
    while (end < args.len and args[end] >= '0' and args[end] <= '9') : (end += 1) {}
    return std.fmt.parseInt(i64, args[i..end], 10) catch null;
}

fn jsonRpcError(buf: []u8, id: ?[]const u8, code: i32, message: []const u8) []const u8 {
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","error":{{"code":{d},"message":"{s}"}},"id":{s}}}
    , .{ code, message, id_str }) catch
        \\{"jsonrpc":"2.0","error":{"code":-32603,"message":"Internal error"},"id":null}
    ;
}

fn jsonEscapeString(input: []const u8, output: []u8) []const u8 {
    var out_pos: usize = 0;
    for (input) |c| {
        if (out_pos + 2 > output.len) break;
        switch (c) {
            '"' => { output[out_pos] = '\\'; out_pos += 1; output[out_pos] = '"'; out_pos += 1; },
            '\\' => { output[out_pos] = '\\'; out_pos += 1; output[out_pos] = '\\'; out_pos += 1; },
            '\n' => { output[out_pos] = '\\'; out_pos += 1; output[out_pos] = 'n'; out_pos += 1; },
            '\r' => { output[out_pos] = '\\'; out_pos += 1; output[out_pos] = 'r'; out_pos += 1; },
            else => { if (c >= 0x20) { output[out_pos] = c; out_pos += 1; } },
        }
    }
    return output[0..out_pos];
}

fn findBody(data: []const u8) ?usize {
    const sep = "\r\n\r\n";
    if (std.mem.indexOf(u8, data, sep)) |pos| return pos + sep.len;
    return null;
}

fn parseContentLength(data: []const u8) ?usize {
    const needle = "Content-Length: ";
    const start = (std.mem.indexOf(u8, data, needle) orelse return null) + needle.len;
    const end = std.mem.indexOfPos(u8, data, start, "\r\n") orelse return null;
    return std.fmt.parseInt(usize, data[start..end], 10) catch null;
}
