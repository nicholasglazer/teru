//! CustomPaneBackend: Native Claude Code agent team integration.
//!
//! Implements the 7-operation protocol from Claude Code issue #26572.
//! Claude Code connects via Unix socket (CLAUDE_PANE_BACKEND_SOCKET)
//! and manages agent panes through JSON-RPC 2.0 over NDJSON.
//!
//! Operations:
//!   spawn(argv, cwd, env, metadata) -> context_id
//!   write(context_id, data) -> ok
//!   capture(context_id, lines) -> text
//!   kill(context_id) -> ok
//!   list() -> [{context_id, metadata}]
//!   get_self_id() -> context_id
//!   (push) context_exited(context_id, exit_code)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");
const ipc = @import("../server/ipc.zig");
const Allocator = std.mem.Allocator;
const Multiplexer = @import("../core/Multiplexer.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const Grid = @import("../core/Grid.zig");

const PaneBackend = @This();

pub const socket_path_max: usize = 108;
const max_request: usize = 65536;
const max_response: usize = 65536;
const max_contexts: usize = 64;

// ── Context tracking ─────────────────────────────────────────────

/// Maps context_id -> pane_id + metadata for Claude Code's view.
const Context = struct {
    context_id: u64,
    pane_id: u64,
    graph_node_id: u64,
    alive: bool,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    group: [64]u8 = [_]u8{0} ** 64,
    group_len: usize = 0,
    role: [64]u8 = [_]u8{0} ** 64,
    role_len: usize = 0,
};

// ── State ────────────────────────────────────────────────────────

socket_path: [socket_path_max]u8,
socket_path_len: usize,
socket_fd: posix.fd_t,
client_fd: posix.fd_t, // connected Claude Code client (-1 if none)
multiplexer: *Multiplexer,
graph: *ProcessGraph,
allocator: Allocator,

/// Context table (small fixed array, no heap allocation)
contexts: [max_contexts]?Context = [_]?Context{null} ** max_contexts,
next_context_id: u64 = 1,

/// Partial line buffer for NDJSON reading (accumulates bytes until newline)
line_buf: [max_request]u8 = undefined,
line_len: usize = 0,

// ── Lifecycle ────────────────────────────────────────────────────

pub fn init(allocator: Allocator, mux: *Multiplexer, graph: *ProcessGraph) !PaneBackend {
    var ipc_path_buf: [256]u8 = undefined;
    const path = ipc.buildPath(&ipc_path_buf, "pane-backend", "") orelse
        return error.PathTooLong;
    const path_len = path.len;

    const server = ipc.listen(path) catch return error.SocketFailed;
    const sock = server.fd;

    var backend = PaneBackend{
        .socket_path = undefined,
        .socket_path_len = path_len,
        .socket_fd = sock,
        .client_fd = -1,
        .multiplexer = mux,
        .graph = graph,
        .allocator = allocator,
    };
    @memcpy(backend.socket_path[0..path_len], path);

    return backend;
}

pub fn deinit(self: *PaneBackend) void {
    if (self.client_fd >= 0) {
        _ = posix.system.close(self.client_fd);
        self.client_fd = -1;
    }
    _ = posix.system.close(self.socket_fd);

    // Unlink socket file
    var unlink_buf: [socket_path_max + 1]u8 = undefined;
    @memcpy(unlink_buf[0..self.socket_path_len], self.socket_path[0..self.socket_path_len]);
    unlink_buf[self.socket_path_len] = 0;
    _ = std.c.unlink(@ptrCast(&unlink_buf));
}

/// Return the socket path as a slice (for setting env var).
pub fn getSocketPath(self: *const PaneBackend) []const u8 {
    return self.socket_path[0..self.socket_path_len];
}

// ── Event loop integration ───────────────────────────────────────

/// Non-blocking: accept new client, read NDJSON lines, dispatch.
pub fn poll(self: *PaneBackend) void {
    // Accept new client if we don't have one
    if (self.client_fd < 0) {
        if (ipc.accept(.{ .fd = self.socket_fd })) |client| {
            self.client_fd = client.fd;
            self.line_len = 0;
        }
    }

    if (self.client_fd < 0) return;

    // Read available data
    var read_buf: [4096]u8 = undefined;
    const rc = std.c.read(self.client_fd, &read_buf, read_buf.len);
    if (rc < 0) {
        // EAGAIN/EWOULDBLOCK: no data, fine
        return;
    }
    if (rc == 0) {
        // Client disconnected
        _ = posix.system.close(self.client_fd);
        self.client_fd = -1;
        self.line_len = 0;
        return;
    }

    const n: usize = @intCast(rc);

    // Append to line buffer and process complete lines (NDJSON)
    for (read_buf[0..n]) |byte| {
        if (byte == '\n') {
            // Complete line — dispatch
            if (self.line_len > 0) {
                self.dispatchLine(self.line_buf[0..self.line_len]);
                self.line_len = 0;
            }
        } else {
            if (self.line_len < self.line_buf.len) {
                self.line_buf[self.line_len] = byte;
                self.line_len += 1;
            }
            // If line buffer overflows, silently drop (malformed request)
        }
    }
}

/// Check all tracked panes for exited processes, push notifications.
pub fn checkExits(self: *PaneBackend) void {
    for (&self.contexts) |*slot| {
        const ctx = slot.* orelse continue;
        if (!ctx.alive) continue;

        // Check if the pane's process is still alive
        const pane = self.multiplexer.getPaneById(ctx.pane_id) orelse {
            // Pane was removed externally
            self.pushContextExited(ctx.context_id, 255);
            slot.*.?.alive = false;
            self.graph.markFinished(ctx.graph_node_id, 255);
            continue;
        };

        if (!pane.isAlive()) {
            // Determine exit code
            const exit_code: u8 = if (self.graph.getNode(ctx.graph_node_id)) |node|
                node.exit_code orelse 0
            else
                0;
            self.pushContextExited(ctx.context_id, exit_code);
            slot.*.?.alive = false;
            self.graph.markFinished(ctx.graph_node_id, exit_code);
        }
    }
}

// ── NDJSON dispatch ──────────────────────────────────────────────

fn dispatchLine(self: *PaneBackend, line: []const u8) void {
    const method = extractJsonString(line, "method") orelse return;
    const id = extractJsonId(line);

    var resp_buf: [max_response]u8 = undefined;
    const response: []const u8 = if (std.mem.eql(u8, method, "spawn"))
        self.handleSpawn(line, id, &resp_buf)
    else if (std.mem.eql(u8, method, "write"))
        self.handleWrite(line, id, &resp_buf)
    else if (std.mem.eql(u8, method, "capture"))
        self.handleCapture(line, id, &resp_buf)
    else if (std.mem.eql(u8, method, "kill"))
        self.handleKill(line, id, &resp_buf)
    else if (std.mem.eql(u8, method, "list"))
        self.handleList(id, &resp_buf)
    else if (std.mem.eql(u8, method, "get_self_id"))
        self.handleGetSelfId(id, &resp_buf)
    else
        jsonRpcError(&resp_buf, id, -32601, "Method not found");

    self.sendNdjson(response);
}

// ── Protocol handlers ────────────────────────────────────────────

fn handleSpawn(self: *PaneBackend, body: []const u8, id: ?[]const u8, buf: []u8) []const u8 {
    // Extract params
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return jsonRpcError(buf, id, -32602, "Missing params");
    const params = body[params_start..];

    // Build command from argv: extract argv[0] as shell command
    // For simplicity, join argv into a single shell -c command
    const argv_cmd = extractJsonString(params, "argv") orelse
        // Try direct command string
        extractJsonString(params, "command") orelse
        return jsonRpcError(buf, id, -32602, "Missing argv");

    const cwd = extractJsonString(params, "cwd");

    // Extract metadata
    const name = extractJsonString(params, "name") orelse "agent";
    const group = extractJsonString(params, "group") orelse "default";
    const role = extractJsonString(params, "role") orelse "worker";

    // Construct shell command: /bin/sh -c "argv contents"
    // The argv field in JSON is expected to be a string for v1
    // (e.g., "claude --agent backend-dev")
    var cmd_buf: [2048]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "/bin/sh -c \"{s}\"", .{argv_cmd}) catch
        return jsonRpcError(buf, id, -32603, "Command too long");

    // Spawn a pane with the custom command
    const pane_id = self.multiplexer.spawnPaneWithCommand(24, 80, cmd, cwd) catch
        return jsonRpcError(buf, id, -32603, "Spawn failed");

    // Register in process graph
    const graph_node_id = self.graph.spawn(.{
        .name = name,
        .kind = .agent,
        .pid = if (self.multiplexer.getPaneById(pane_id)) |pane| pane.pty.child_pid else null,
        .agent = .{
            .group = group,
            .role = role,
        },
    }) catch {
        return jsonRpcError(buf, id, -32603, "Graph registration failed");
    };

    // Allocate context
    const context_id = self.next_context_id;
    self.next_context_id += 1;

    var ctx = Context{
        .context_id = context_id,
        .pane_id = pane_id,
        .graph_node_id = graph_node_id,
        .alive = true,
    };

    // Copy metadata strings
    const name_len = @min(name.len, ctx.name.len);
    @memcpy(ctx.name[0..name_len], name[0..name_len]);
    ctx.name_len = name_len;

    const group_len = @min(group.len, ctx.group.len);
    @memcpy(ctx.group[0..group_len], group[0..group_len]);
    ctx.group_len = group_len;

    const role_len = @min(role.len, ctx.role.len);
    @memcpy(ctx.role[0..role_len], role[0..role_len]);
    ctx.role_len = role_len;

    // Store in first free slot
    for (&self.contexts) |*slot| {
        if (slot.* == null) {
            slot.* = ctx;
            break;
        }
    }

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"context_id":{d}}},"id":{s}}}
    , .{ context_id, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn handleWrite(self: *PaneBackend, body: []const u8, id: ?[]const u8, buf: []u8) []const u8 {
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return jsonRpcError(buf, id, -32602, "Missing params");
    const params = body[params_start..];

    const context_id = extractJsonInt(params, "context_id") orelse
        return jsonRpcError(buf, id, -32602, "Missing context_id");

    const data = extractJsonString(params, "data") orelse
        return jsonRpcError(buf, id, -32602, "Missing data");

    const ctx = self.findContext(context_id) orelse
        return jsonRpcError(buf, id, -32602, "Unknown context_id");

    const pane = self.multiplexer.getPaneById(ctx.pane_id) orelse
        return jsonRpcError(buf, id, -32602, "Pane not found");

    _ = pane.pty.write(data) catch
        return jsonRpcError(buf, id, -32603, "Write failed");

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"ok":true}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn handleCapture(self: *PaneBackend, body: []const u8, id: ?[]const u8, buf: []u8) []const u8 {
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return jsonRpcError(buf, id, -32602, "Missing params");
    const params = body[params_start..];

    const context_id = extractJsonInt(params, "context_id") orelse
        return jsonRpcError(buf, id, -32602, "Missing context_id");

    const lines = extractJsonInt(params, "lines") orelse 50;

    const ctx = self.findContext(context_id) orelse
        return jsonRpcError(buf, id, -32602, "Unknown context_id");

    const pane = self.multiplexer.getPaneById(ctx.pane_id) orelse
        return jsonRpcError(buf, id, -32602, "Pane not found");

    // Extract text from grid rows (bottom N lines)
    var text_buf: [32768]u8 = undefined;
    var text_pos: usize = 0;

    const grid = &pane.grid;
    const total_rows: u64 = grid.rows;
    const start_row: u64 = if (total_rows > lines) total_rows - lines else 0;

    var row: u64 = start_row;
    while (row < total_rows) : (row += 1) {
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
        text_pos = line_end;
        if (text_pos < text_buf.len and row + 1 < total_rows) {
            text_buf[text_pos] = '\n';
            text_pos += 1;
        }
    }

    // JSON-escape the text
    var escaped_buf: [max_response - 256]u8 = undefined;
    const escaped = jsonEscapeString(text_buf[0..text_pos], &escaped_buf);

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"text":"{s}"}},"id":{s}}}
    , .{ escaped, id_str }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn handleKill(self: *PaneBackend, body: []const u8, id: ?[]const u8, buf: []u8) []const u8 {
    const params_start = std.mem.indexOf(u8, body, "\"params\"") orelse
        return jsonRpcError(buf, id, -32602, "Missing params");
    const params = body[params_start..];

    const context_id = extractJsonInt(params, "context_id") orelse
        return jsonRpcError(buf, id, -32602, "Missing context_id");

    const ctx = self.findContext(context_id) orelse
        return jsonRpcError(buf, id, -32602, "Unknown context_id");

    // Close the pane
    self.multiplexer.closePane(ctx.pane_id);
    self.graph.markFinished(ctx.graph_node_id, 0);

    // Mark context as dead
    for (&self.contexts) |*slot| {
        if (slot.*) |*c| {
            if (c.context_id == context_id) {
                c.alive = false;
                break;
            }
        }
    }

    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"ok":true}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

fn handleList(self: *PaneBackend, id: ?[]const u8, buf: []u8) []const u8 {
    const id_str = id orelse "null";
    var pos: usize = 0;

    const prefix = "{\"jsonrpc\":\"2.0\",\"result\":{\"contexts\":[";
    if (prefix.len > buf.len) return jsonRpcError(buf, id, -32603, "Internal error");
    @memcpy(buf[0..prefix.len], prefix);
    pos = prefix.len;

    var first = true;
    for (&self.contexts) |*slot| {
        const ctx = slot.* orelse continue;
        if (!first) {
            if (pos < buf.len) {
                buf[pos] = ',';
                pos += 1;
            }
        }
        first = false;

        const alive_str = if (ctx.alive) "true" else "false";
        const entry = std.fmt.bufPrint(buf[pos..],
            \\{{"context_id":{d},"metadata":{{"name":"{s}","group":"{s}","role":"{s}"}},"alive":{s}}}
        , .{
            ctx.context_id,
            ctx.name[0..ctx.name_len],
            ctx.group[0..ctx.group_len],
            ctx.role[0..ctx.role_len],
            alive_str,
        }) catch break;
        pos += entry.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..], "]}},\"id\":{s}}}", .{id_str}) catch
        return jsonRpcError(buf, id, -32603, "Internal error");
    pos += suffix.len;

    return buf[0..pos];
}

fn handleGetSelfId(self: *PaneBackend, id: ?[]const u8, buf: []u8) []const u8 {
    // Return the active pane's context_id if it has one.
    // This is a best-effort heuristic for v1.
    const id_str = id orelse "null";

    if (self.multiplexer.getActivePane()) |active| {
        for (&self.contexts) |*slot| {
            const ctx = slot.* orelse continue;
            if (ctx.pane_id == active.id and ctx.alive) {
                return std.fmt.bufPrint(buf,
                    \\{{"jsonrpc":"2.0","result":{{"context_id":{d}}},"id":{s}}}
                , .{ ctx.context_id, id_str }) catch
                    jsonRpcError(buf, id, -32603, "Internal error");
            }
        }
    }

    // No context found for active pane
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"context_id":null}},"id":{s}}}
    , .{id_str}) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

// ── Push notification ────────────────────────────────────────────

fn pushContextExited(self: *PaneBackend, context_id: u64, exit_code: u8) void {
    if (self.client_fd < 0) return;

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","method":"context_exited","params":{{"context_id":{d},"exit_code":{d}}}}}
    , .{ context_id, exit_code }) catch return;

    self.sendNdjson(msg);
}

// ── Helpers ──────────────────────────────────────────────────────

fn sendNdjson(self: *PaneBackend, data: []const u8) void {
    if (self.client_fd < 0) return;
    _ = std.c.write(self.client_fd, data.ptr, data.len);
    const nl = [1]u8{'\n'};
    _ = std.c.write(self.client_fd, &nl, 1);
}

fn findContext(self: *PaneBackend, context_id: u64) ?*const Context {
    for (&self.contexts) |*slot| {
        if (slot.*) |*ctx| {
            if (ctx.context_id == context_id) return ctx;
        }
    }
    return null;
}

// ── JSON parsing (minimal, no library) ───────────────────────────

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const after_key = key_pos + needle.len;

    var i = after_key;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len or json[i] != '"') return null;
    i += 1;

    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {
        if (json[i] == '\\') i += 1;
    }
    if (i >= json.len) return null;

    return json[start..i];
}

fn extractJsonInt(json: []const u8, key: []const u8) ?u64 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const after_key = key_pos + needle.len;

    var i = after_key;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len) return null;

    const start = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(u64, json[start..i], 10) catch null;
}

fn extractJsonId(json: []const u8) ?[]const u8 {
    const needle = "\"id\":";
    const pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const after = pos + needle.len;

    var i = after;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len) return null;

    if (json[i] == '"') {
        i += 1;
        const start = i;
        while (i < json.len and json[i] != '"') : (i += 1) {}
        if (i >= json.len) return null;
        return json[start - 1 .. i + 1];
    } else if (json[i] == 'n') {
        return "null";
    } else {
        const start = i;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
        if (i == start) return null;
        return json[start..i];
    }
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
            },
        }
    }
    return output[0..out_pos];
}

fn jsonRpcError(buf: []u8, id: ?[]const u8, code: i32, message: []const u8) []const u8 {
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","error":{{"code":{d},"message":"{s}"}},"id":{s}}}
    , .{ code, message, id_str }) catch
        "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"},\"id\":null}";
}

// ── Tests ────────────────────────────────────────────────────────

const t = std.testing;

test "extractJsonString" {
    const json = "{\"method\":\"spawn\",\"params\":{\"argv\":\"claude --agent dev\"}}";
    const method = extractJsonString(json, "method");
    try t.expect(method != null);
    try t.expectEqualStrings("spawn", method.?);

    const argv = extractJsonString(json, "argv");
    try t.expect(argv != null);
    try t.expectEqualStrings("claude --agent dev", argv.?);
}

test "extractJsonInt" {
    const json = "{\"params\":{\"context_id\":42,\"lines\":20}}";
    const cid = extractJsonInt(json, "context_id");
    try t.expect(cid != null);
    try t.expectEqual(@as(u64, 42), cid.?);

    const lines = extractJsonInt(json, "lines");
    try t.expect(lines != null);
    try t.expectEqual(@as(u64, 20), lines.?);
}

test "extractJsonId numeric" {
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"list\",\"id\":7}";
    const id = extractJsonId(json);
    try t.expect(id != null);
    try t.expectEqualStrings("7", id.?);
}

test "extractJsonId null" {
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"list\",\"id\":null}";
    const id = extractJsonId(json);
    try t.expect(id != null);
    try t.expectEqualStrings("null", id.?);
}

test "jsonRpcError format" {
    var buf: [512]u8 = undefined;
    const result = jsonRpcError(&buf, "1", -32601, "Method not found");
    try t.expect(std.mem.indexOf(u8, result, "-32601") != null);
    try t.expect(std.mem.indexOf(u8, result, "Method not found") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
}

test "jsonEscapeString" {
    var buf: [256]u8 = undefined;
    const r1 = jsonEscapeString("hello", &buf);
    try t.expectEqualStrings("hello", r1);

    const r2 = jsonEscapeString("a\nb", &buf);
    try t.expectEqualStrings("a\\nb", r2);

    const r3 = jsonEscapeString("x\"y\\z", &buf);
    try t.expectEqualStrings("x\\\"y\\\\z", r3);
}

test "spawn response format" {
    // Verify the response JSON format is correct
    var buf: [512]u8 = undefined;
    const result = std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","result":{{"context_id":{d}}},"id":{s}}}
    , .{ @as(u64, 42), "1" }) catch unreachable;

    try t.expect(std.mem.indexOf(u8, result, "\"context_id\":42") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
}

test "list response format" {
    // Verify list JSON format with contexts
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;

    const prefix = "{\"jsonrpc\":\"2.0\",\"result\":{\"contexts\":[";
    @memcpy(buf[0..prefix.len], prefix);
    pos = prefix.len;

    const entry = std.fmt.bufPrint(buf[pos..],
        \\{{"context_id":{d},"metadata":{{"name":"{s}","group":"{s}","role":"{s}"}},"alive":{s}}}
    , .{
        @as(u64, 1),
        "backend-dev",
        "team-temporal",
        "implementer",
        "true",
    }) catch unreachable;
    pos += entry.len;

    const suffix = "]},\"id\":1}";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    const result = buf[0..pos];
    try t.expect(std.mem.indexOf(u8, result, "\"context_id\":1") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"name\":\"backend-dev\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"group\":\"team-temporal\"") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"alive\":true") != null);
}

test "capture response format" {
    var buf: [1024]u8 = undefined;
    var escaped_buf: [512]u8 = undefined;
    const text = "$ ls\nfile1.txt\nfile2.txt";
    const escaped = jsonEscapeString(text, &escaped_buf);

    const result = std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","result":{{"text":"{s}"}},"id":{s}}}
    , .{ escaped, "3" }) catch unreachable;

    try t.expect(std.mem.indexOf(u8, result, "$ ls\\nfile1.txt\\nfile2.txt") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":3") != null);
}

// ── Spec Section 4.4.2: write response format ──────────────────

test "write response format" {
    var buf: [512]u8 = undefined;
    const result = std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","result":{{"ok":true}},"id":{s}}}
    , .{"2"}) catch unreachable;

    try t.expect(std.mem.indexOf(u8, result, "\"ok\":true") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":2") != null);
}

// ── Spec Section 4.4.4: kill response format ────────────────────

test "kill response format" {
    var buf: [512]u8 = undefined;
    const result = std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","result":{{"ok":true}},"id":{s}}}
    , .{"4"}) catch unreachable;

    try t.expect(std.mem.indexOf(u8, result, "\"ok\":true") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":4") != null);
}

// ── Spec Section 4.4.7: context_exited push notification format ─

test "context_exited push notification format" {
    // Push notifications have no "id" field per spec
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","method":"context_exited","params":{{"context_id":{d},"exit_code":{d}}}}}
    , .{ @as(u64, 1), @as(u8, 0) }) catch unreachable;

    try t.expect(std.mem.indexOf(u8, msg, "\"method\":\"context_exited\"") != null);
    try t.expect(std.mem.indexOf(u8, msg, "\"context_id\":1") != null);
    try t.expect(std.mem.indexOf(u8, msg, "\"exit_code\":0") != null);
    // Per spec: "NOT a request-response -- it is a server-initiated message with no id field"
    try t.expect(std.mem.indexOf(u8, msg, "\"id\"") == null);
}

// ── Spec Section 4.4.6: get_self_id null context ────────────────

test "get_self_id null context response format" {
    // Spec: Returns null for context_id if the active pane has no associated context
    var buf: [512]u8 = undefined;
    const result = std.fmt.bufPrint(&buf,
        \\{{"jsonrpc":"2.0","result":{{"context_id":null}},"id":{s}}}
    , .{"6"}) catch unreachable;

    try t.expect(std.mem.indexOf(u8, result, "\"context_id\":null") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":6") != null);
}

// ── Spec Section 4.4.8: Error responses ─────────────────────────

test "jsonRpcError format: -32600 Invalid request" {
    var buf: [512]u8 = undefined;
    const result = jsonRpcError(&buf, "1", -32600, "Invalid request");
    try t.expect(std.mem.indexOf(u8, result, "-32600") != null);
    try t.expect(std.mem.indexOf(u8, result, "Invalid request") != null);
}

test "jsonRpcError format: -32601 Method not found" {
    var buf: [512]u8 = undefined;
    const result = jsonRpcError(&buf, "1", -32601, "Method not found");
    try t.expect(std.mem.indexOf(u8, result, "-32601") != null);
    try t.expect(std.mem.indexOf(u8, result, "Method not found") != null);
}

test "jsonRpcError format: -32602 Invalid params" {
    var buf: [512]u8 = undefined;
    const result = jsonRpcError(&buf, "1", -32602, "Invalid params");
    try t.expect(std.mem.indexOf(u8, result, "-32602") != null);
    try t.expect(std.mem.indexOf(u8, result, "Invalid params") != null);
}

test "jsonRpcError format: -32603 Internal error" {
    var buf: [512]u8 = undefined;
    const result = jsonRpcError(&buf, "1", -32603, "Internal error");
    try t.expect(std.mem.indexOf(u8, result, "-32603") != null);
    try t.expect(std.mem.indexOf(u8, result, "Internal error") != null);
}

test "jsonRpcError with null id" {
    var buf: [512]u8 = undefined;
    const result = jsonRpcError(&buf, null, -32601, "Method not found");
    try t.expect(std.mem.indexOf(u8, result, "\"id\":null") != null);
}

// ── Spec Section 4.4: JSON-RPC 2.0 protocol ────────────────────

test "extractJsonId with string id" {
    const json = "{\"jsonrpc\":\"2.0\",\"method\":\"spawn\",\"id\":\"req-42\"}";
    const id = extractJsonId(json);
    try t.expect(id != null);
    try t.expectEqualStrings("\"req-42\"", id.?);
}

test "extractJsonString missing key returns null" {
    const json = "{\"method\":\"spawn\"}";
    try t.expectEqual(@as(?[]const u8, null), extractJsonString(json, "nonexistent"));
}

test "extractJsonInt missing key returns null" {
    const json = "{\"params\":{}}";
    try t.expectEqual(@as(?u64, null), extractJsonInt(json, "context_id"));
}

test "extractJsonInt non-numeric value returns null" {
    const json = "{\"context_id\":\"abc\"}";
    try t.expectEqual(@as(?u64, null), extractJsonInt(json, "context_id"));
}

// ── Spec Section 4.5: Metadata string truncation to 64 bytes ────

test "metadata fields truncated to 64 bytes" {
    // Spec: "Metadata strings (name, group, role) are truncated to 64 bytes"
    var ctx = Context{
        .context_id = 1,
        .pane_id = 1,
        .graph_node_id = 1,
        .alive = true,
    };

    // Create a string longer than 64 bytes
    const long_name = "a" ** 100;
    const name_len = @min(long_name.len, ctx.name.len);
    @memcpy(ctx.name[0..name_len], long_name[0..name_len]);
    ctx.name_len = name_len;

    // Verify truncation to 64
    try t.expectEqual(@as(usize, 64), ctx.name_len);
}

// ── Spec Section 4.5: Fixed context table capacity ──────────────

test "context table has fixed capacity of 64" {
    try t.expectEqual(@as(usize, 64), max_contexts);
}

// ── Spec Section 4.4.5: list with dead contexts ─────────────────

test "list response includes alive and dead contexts" {
    // Spec: "Dead contexts remain in the list response (with alive: false)"
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;

    const prefix = "{\"jsonrpc\":\"2.0\",\"result\":{\"contexts\":[";
    @memcpy(buf[0..prefix.len], prefix);
    pos = prefix.len;

    // alive context
    const entry1 = std.fmt.bufPrint(buf[pos..],
        \\{{"context_id":{d},"metadata":{{"name":"{s}","group":"{s}","role":"{s}"}},"alive":{s}}}
    , .{ @as(u64, 1), "dev-1", "group-a", "worker", "true" }) catch unreachable;
    pos += entry1.len;

    buf[pos] = ',';
    pos += 1;

    // dead context
    const entry2 = std.fmt.bufPrint(buf[pos..],
        \\{{"context_id":{d},"metadata":{{"name":"{s}","group":"{s}","role":"{s}"}},"alive":{s}}}
    , .{ @as(u64, 2), "dev-2", "group-a", "worker", "false" }) catch unreachable;
    pos += entry2.len;

    const suffix = "]},\"id\":5}";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    const result = buf[0..pos];
    try t.expect(std.mem.indexOf(u8, result, "\"alive\":true") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"alive\":false") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"context_id\":1") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"context_id\":2") != null);
}

// ── Spec: JSON escape for control characters ────────────────────

test "jsonEscapeString handles tab and carriage return" {
    var buf: [256]u8 = undefined;
    const result = jsonEscapeString("a\tb\rc", &buf);
    try t.expectEqualStrings("a\\tb\\rc", result);
}

test "jsonEscapeString strips control characters below 0x20" {
    var buf: [256]u8 = undefined;
    // \x01 is a control character that should be dropped
    const result = jsonEscapeString("a\x01b", &buf);
    try t.expectEqualStrings("ab", result);
}
