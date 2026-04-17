//! MCP server framework — comptime-generic over the impl type.
//!
//! Both teru's McpServer and teruwm's WmMcpServer used to open-code
//! the same JSON-RPC machinery: socket read, framing, method routing,
//! initialize + tools/list + tools/call response shapes. This module
//! owns that machinery once; each server supplies a `Config` struct
//! and a `StaticStringMap` of tool thunks.
//!
//! Usage pattern:
//!
//!     const F = McpFramework.Framework(Self);
//!     const tool_table = std.StaticStringMap(F.Thunk).initComptime(.{
//!         .{ "server_do_thing", thunkDoThing },
//!         ...
//!     });
//!     const config: F.Config = .{
//!         .server_name = "myserver",
//!         .server_version = "0.5.0",
//!         .framing = .http,                 // or .line_json
//!         .capabilities_json = "\"tools\":{}",
//!         .tool_table = &tool_table,
//!         .tools_list_body = tools_list_body_comptime,
//!     };
//!     pub fn handleRequest(self: *Self, fd: posix.fd_t) void {
//!         F.handleRequestFd(self, fd, &config);
//!     }
//!     pub fn dispatch(self: *Self, body, resp) []const u8 {
//!         return F.dispatch(self, body, resp, &config);
//!     }
//!
//! Comptime-generic means there's no runtime overhead, no anyopaque
//! ptr-cast, and the tool-thunk signature is fully typed — each
//! thunk's first param is `*Impl`, not an erased pointer.
//!
//! Out of scope (deliberate): wl_event_loop / socket setup /
//! McpEventChannel. Those are server-specific and have their own
//! layering. The framework only owns the request/response path.

const std = @import("std");
const posix = std.posix;
const tools = @import("McpTools.zig");

/// Framing of request/response bytes on the wire.
pub const Framing = enum {
    /// Each message is terminated by a single '\n'. Used by teru's
    /// stdio proxy + in-band OSC path.
    line_json,
    /// HTTP/1.1 with Content-Length header + CRLF body separator.
    /// Used by the compositor, which ships over a Unix socket that
    /// MCP clients commonly treat as HTTP.
    http,
};

pub const max_request: usize = 65536;
pub const max_response: usize = 65536;

pub fn Framework(comptime Impl: type) type {
    return struct {
        pub const Thunk = *const fn (
            impl: *Impl,
            params_body: []const u8,
            buf: []u8,
            id: ?[]const u8,
        ) []const u8;

        /// Optional: prompts/list + prompts/get. Absent = "method not found".
        pub const Prompts = struct {
            /// Pre-serialized JSON array content — just the
            /// `[{...},{...}]` body, no outer `"prompts":` key.
            /// Framework wraps it in the jsonrpc envelope.
            list_body: []const u8,
            get_fn: *const fn (impl: *Impl, body: []const u8, buf: []u8, id: ?[]const u8) []const u8,
        };

        /// Optional: cross-MCP forwarding fallback. When an unknown
        /// tool is called and its name starts with `prefix`, the
        /// framework calls `fn_` to forward the whole request. Used
        /// by teru's McpServer to send `teruwm_*` tools to teruwm.
        pub const Forward = struct {
            prefix: []const u8,
            fn_: *const fn (body: []const u8, buf: []u8) ?[]const u8,
            unavailable_msg: []const u8,
        };

        pub const Config = struct {
            server_name: []const u8,
            server_version: []const u8,
            protocol_version: []const u8 = "2025-03-26",
            framing: Framing,
            /// Inner capabilities object contents — e.g.
            /// `"tools":{}` or `"tools":{},"prompts":{}`.
            capabilities_json: []const u8,
            tool_table: *const std.StaticStringMap(Thunk),
            /// Pre-serialized `[{name, description, inputSchema}, ...]`.
            /// Comptime string so no per-request work.
            tools_list_body: []const u8,
            prompts: ?Prompts = null,
            forward: ?Forward = null,
        };

        /// Route a JSON-RPC body through method dispatch. Public because
        /// in-band OSC 9999 path reaches here without a socket fd.
        pub fn dispatch(impl: *Impl, body: []const u8, resp: []u8, config: *const Config) []const u8 {
            const method = tools.extractJsonString(body, "method") orelse
                return tools.jsonRpcError(resp, null, -32600, "Invalid Request: missing method");
            const id = tools.extractJsonId(body);

            if (std.mem.eql(u8, method, "initialize")) return handleInitialize(resp, id, config);
            if (std.mem.eql(u8, method, "tools/list")) return handleToolsList(resp, id, config);
            if (std.mem.eql(u8, method, "tools/call")) return handleToolsCall(impl, body, resp, id, config);
            if (std.mem.startsWith(u8, method, "notifications/")) {
                // MCP notifications (initialized, progress, cancelled)
                // — acknowledge with an empty result.
                const id_str = id orelse "null";
                return std.fmt.bufPrint(resp,
                    \\{{"jsonrpc":"2.0","result":{{}},"id":{s}}}
                , .{id_str}) catch "{}";
            }
            if (config.prompts) |p| {
                if (std.mem.eql(u8, method, "prompts/list")) {
                    const id_str = id orelse "null";
                    return std.fmt.bufPrint(resp,
                        \\{{"jsonrpc":"2.0","result":{{"prompts":{s}}},"id":{s}}}
                    , .{ p.list_body, id_str }) catch
                        tools.jsonRpcError(resp, id, -32603, "Internal error");
                }
                if (std.mem.eql(u8, method, "prompts/get")) return p.get_fn(impl, body, resp, id);
            }
            return tools.jsonRpcError(resp, id, -32601, "Method not found");
        }

        /// Read an entire request off `conn_fd`, dispatch it, and write
        /// the framed response back. Framing decided by `config.framing`.
        /// Silent partial-write is fine here — clients retry on a fresh
        /// connection (this is a single-request socket protocol).
        pub fn handleRequestFd(impl: *Impl, conn_fd: posix.fd_t, config: *const Config) void {
            var req_buf: [max_request]u8 = undefined;
            var total: usize = 0;

            while (total < req_buf.len) {
                const rc = std.c.read(conn_fd, req_buf[total..].ptr, req_buf.len - total);
                if (rc <= 0) break;
                total += @intCast(rc);

                // Framing-specific termination check.
                switch (config.framing) {
                    .http => {
                        if (tools.findHttpBody(req_buf[0..total])) |body_start| {
                            if (tools.parseHttpContentLength(req_buf[0..total])) |cl| {
                                if (total >= body_start + cl) break;
                            } else break; // malformed; stop reading
                        }
                    },
                    .line_json => {
                        if (std.mem.indexOfScalar(u8, req_buf[0..total], '\n') != null) break;
                    },
                }
            }
            if (total == 0) return;

            switch (config.framing) {
                .http => {
                    const body = if (tools.findHttpBody(req_buf[0..total])) |s|
                        req_buf[s..total]
                    else
                        req_buf[0..total];
                    var resp_buf: [max_response]u8 = undefined;
                    const json_response = dispatch(impl, body, &resp_buf, config);

                    var header: [256]u8 = undefined;
                    const h = std.fmt.bufPrint(&header,
                        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
                        .{json_response.len},
                    ) catch return;
                    _ = std.c.write(conn_fd, h.ptr, h.len);
                    _ = std.c.write(conn_fd, json_response.ptr, json_response.len);
                },
                .line_json => {
                    var body_len = total;
                    if (body_len > 0 and req_buf[body_len - 1] == '\n') body_len -= 1;
                    if (body_len > 0 and req_buf[body_len - 1] == '\r') body_len -= 1;

                    // +1 slot for the trailing newline so line-oriented
                    // readers (the stdio bridge, socat, agents) split
                    // on '\n' without heuristics.
                    var resp_buf: [max_response + 1]u8 = undefined;
                    const json_response = dispatch(impl, req_buf[0..body_len], resp_buf[0..max_response], config);
                    const end = json_response.len;
                    if (end < resp_buf.len) {
                        resp_buf[end] = '\n';
                        _ = std.c.write(conn_fd, &resp_buf, end + 1);
                    } else {
                        _ = std.c.write(conn_fd, json_response.ptr, json_response.len);
                    }
                },
            }
        }

        fn handleInitialize(resp: []u8, id: ?[]const u8, config: *const Config) []const u8 {
            const id_str = id orelse "null";
            return std.fmt.bufPrint(resp,
                \\{{"jsonrpc":"2.0","result":{{"protocolVersion":"{s}","capabilities":{{{s}}},"serverInfo":{{"name":"{s}","version":"{s}"}}}},"id":{s}}}
            , .{ config.protocol_version, config.capabilities_json, config.server_name, config.server_version, id_str }) catch
                tools.jsonRpcError(resp, id, -32603, "Internal error");
        }

        fn handleToolsList(resp: []u8, id: ?[]const u8, config: *const Config) []const u8 {
            const id_str = id orelse "null";
            return std.fmt.bufPrint(resp,
                \\{{"jsonrpc":"2.0","result":{{"tools":{s}}},"id":{s}}}
            , .{ config.tools_list_body, id_str }) catch
                tools.jsonRpcError(resp, id, -32603, "Internal error");
        }

        fn handleToolsCall(
            impl: *Impl,
            body: []const u8,
            resp: []u8,
            id: ?[]const u8,
            config: *const Config,
        ) []const u8 {
            const params_body = tools.extractJsonObject(body, "params") orelse
                return tools.jsonRpcError(resp, id, -32602, "Missing params");
            const tool_name = tools.extractJsonString(params_body, "name") orelse
                return tools.jsonRpcError(resp, id, -32602, "Missing params.name");

            if (config.tool_table.get(tool_name)) |thunk| return thunk(impl, params_body, resp, id);

            if (config.forward) |fwd| {
                if (std.mem.startsWith(u8, tool_name, fwd.prefix)) {
                    if (fwd.fn_(body, resp)) |r| return r;
                    return tools.jsonRpcError(resp, id, -32002, fwd.unavailable_msg);
                }
            }
            return tools.jsonRpcError(resp, id, -32602, "Unknown tool");
        }
    };
}
