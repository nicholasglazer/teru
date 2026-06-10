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
const builtin = @import("builtin");
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
            /// Tools (full names) that are SAFE to forward while read-only is
            /// active — i.e. the read-only subset of the forwarded surface.
            /// teru's own `write_tool_names` can't enumerate another binary's
            /// tools, so under read-only we block every forwarded tool NOT in
            /// this allowlist. Fail-safe: a newly-added forwarded tool is
            /// blocked until it's explicitly listed here. Empty = block ALL
            /// forwarded tools under read-only.
            read_only_allow: []const []const u8 = &.{},
        };

        /// Server-side read-only enforcement. Mirror of the bridge-level
        /// `TERU_MCP_READONLY` filter, but applied here so a client that
        /// connects directly to the socket (bypassing the bridge) still
        /// can't invoke a write tool.
        ///
        /// `is_active_fn` is checked per-request; null = always off.
        /// `write_tool_names` is the comptime allowlist of tools to
        /// reject + filter from `tools/list`. Empty = no-op.
        pub const ReadOnly = struct {
            is_active_fn: *const fn (impl: *Impl) bool,
            /// Blocklist: tools rejected + filtered when read-only is active.
            /// Use for a server whose tools are MOSTLY reads (teru).
            write_tool_names: []const []const u8 = &.{},
            /// Allowlist: when set, ONLY these tools are permitted under
            /// read-only; everything else is rejected + filtered. Use for a
            /// server whose tools are MOSTLY writes (teruwm). Fail-safe — a
            /// newly-added tool is blocked until listed. Takes precedence over
            /// write_tool_names when non-null.
            read_allowlist: ?[]const []const u8 = null,
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
            read_only: ?ReadOnly = null,
        };

        /// Route a JSON-RPC body through method dispatch. Public because
        /// in-band OSC 9999 path reaches here without a socket fd.
        /// Clip a body for the trace log so a 64 KiB request/response stays
        /// readable in `TERU_LOG=debug` output.
        fn logClip(s: []const u8) []const u8 {
            return if (s.len > 800) s[0..800] else s;
        }

        /// Trace wrapper: logs the request + response at `mcp` debug level
        /// (gated by TERU_LOG=debug). Covers every MCP path — the teru socket,
        /// the teruwm socket, and the OSC-9999 in-band channel all call this.
        pub fn dispatch(impl: *Impl, body: []const u8, resp: []u8, config: *const Config) []const u8 {
            std.log.scoped(.mcp).debug("→ {s}", .{logClip(body)});
            const out = dispatchInner(impl, body, resp, config);
            std.log.scoped(.mcp).debug("← {s}", .{logClip(out)});
            return out;
        }

        fn dispatchInner(impl: *Impl, body: []const u8, resp: []u8, config: *const Config) []const u8 {
            const method = tools.extractJsonString(body, "method") orelse
                return tools.jsonRpcError(resp, null, -32600, "Invalid Request: missing method");
            const id = tools.extractJsonId(body);

            if (std.mem.eql(u8, method, "initialize")) return handleInitialize(resp, id, config);
            if (std.mem.eql(u8, method, "tools/list")) return handleToolsList(impl, resp, id, config);
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
            const poll_in: i16 = 0x001; // POLLIN
            var req_buf: [max_request]u8 = undefined;
            var total: usize = 0;
            var stalls: u8 = 0;

            while (total < req_buf.len) {
                const rc = std.c.read(conn_fd, req_buf[total..].ptr, req_buf.len - total);
                if (rc < 0) {
                    // The accepted fd is non-blocking (ipc.acceptPosix) and
                    // the event loop wakes us as soon as the *connection*
                    // is pending — which can precede the client's separate
                    // send() of the request. A bare read() then hits
                    // EAGAIN; bailing here silently drops the request
                    // ~1-in-N under that connect/send race. Wait for the
                    // bytes instead, bounded so a wedged client can't pin
                    // the event loop.
                    stalls += 1;
                    if (stalls > 8) break;
                    // POSIX-only readability wait. posix.pollfd is absent on
                    // Windows (ws2_32.pollfd) and the MCP Unix-socket servers
                    // are POSIX-only, so comptime-exclude the poll there.
                    if (builtin.os.tag == .windows) break;
                    var pfd = [_]posix.pollfd{.{ .fd = conn_fd, .events = poll_in, .revents = 0 }};
                    const ready = posix.poll(&pfd, 250) catch 0;
                    if (ready == 0 or (pfd[0].revents & poll_in) == 0) break;
                    continue;
                }
                if (rc == 0) break; // peer closed
                stalls = 0;
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
                        if (std.mem.findScalar(u8, req_buf[0..total], '\n') != null) break;
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

        fn handleToolsList(impl: *Impl, resp: []u8, id: ?[]const u8, config: *const Config) []const u8 {
            const id_str = id orelse "null";

            // Read-only: filter write tools out of the listed schema so
            // downstream clients that don't enforce a separate filter
            // never see disabled tools advertised.
            if (config.read_only) |ro| {
                if (ro.is_active_fn(impl)) {
                    var filter_buf: [max_response]u8 = undefined;
                    const names = ro.read_allowlist orelse ro.write_tool_names;
                    const invert = ro.read_allowlist != null;
                    if (filterToolsList(config.tools_list_body, &filter_buf, names, invert)) |body| {
                        return std.fmt.bufPrint(resp,
                            \\{{"jsonrpc":"2.0","result":{{"tools":{s}}},"id":{s}}}
                        , .{ body, id_str }) catch
                            tools.jsonRpcError(resp, id, -32603, "Internal error");
                    }
                }
            }

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

            // Server-side read-only enforcement. Mirrors the bridge
            // filter; gives defense-in-depth for clients that connect
            // directly to the socket.
            if (config.read_only) |ro| {
                if (ro.is_active_fn(impl)) {
                    const blocked = if (ro.read_allowlist) |allow| blk: {
                        // allowlist mode: blocked unless explicitly allowed
                        for (allow) |a| {
                            if (std.mem.eql(u8, tool_name, a)) break :blk false;
                        }
                        break :blk true;
                    } else blk: {
                        // blocklist mode: blocked only if a named write tool
                        for (ro.write_tool_names) |w| {
                            if (std.mem.eql(u8, tool_name, w)) break :blk true;
                        }
                        break :blk false;
                    };
                    if (blocked)
                        return tools.jsonRpcError(resp, id, -32601, "Read-only mode: write tools are disabled");
                }
            }

            if (config.tool_table.get(tool_name)) |thunk| return thunk(impl, params_body, resp, id);

            if (config.forward) |fwd| {
                if (std.mem.startsWith(u8, tool_name, fwd.prefix)) {
                    // Read-only enforcement for FORWARDED tools (teruwm_*).
                    // The gate above only checks this server's own
                    // write_tool_names, which can't list another binary's
                    // tools — so a read-only teru would otherwise relay
                    // teruwm_quit/restart/spawn unchecked. Block any forwarded
                    // tool not in the explicit read-only allowlist.
                    if (config.read_only) |ro| {
                        if (ro.is_active_fn(impl)) {
                            var allowed = false;
                            for (fwd.read_only_allow) |a| {
                                if (std.mem.eql(u8, tool_name, a)) {
                                    allowed = true;
                                    break;
                                }
                            }
                            if (!allowed)
                                return tools.jsonRpcError(resp, id, -32601, "Read-only mode: write tools are disabled");
                        }
                    }
                    if (fwd.fn_(body, resp)) |r| return r;
                    return tools.jsonRpcError(resp, id, -32002, fwd.unavailable_msg);
                }
            }
            return tools.jsonRpcError(resp, id, -32602, "Unknown tool");
        }

        /// Strip every tool object whose `"name":"..."` matches an entry
        /// in `write_names` from a pre-serialized tools/list array body.
        /// Returns null on any parse error so the caller can fall back
        /// to the unfiltered body.
        /// Filter a pre-serialized tools array. `invert=false` DROPS tools whose
        /// name is in `names` (blocklist — teru's write tools). `invert=true`
        /// KEEPS only tools whose name is in `names` (allowlist — teruwm's
        /// read-only set). Either way the disabled tools never appear in the
        /// advertised `tools/list` under read-only.
        fn filterToolsList(src: []const u8, out: []u8, names: []const []const u8, invert: bool) ?[]const u8 {
            if (src.len < 2 or src[0] != '[' or src[src.len - 1] != ']') return null;
            var pos: usize = 0;
            if (pos >= out.len) return null;
            out[pos] = '[';
            pos += 1;

            const body = src[1 .. src.len - 1];
            var i: usize = 0;
            var first = true;
            while (i < body.len) {
                // Skip separators AND whitespace. tools_list_body is built from
                // Zig multiline-string segments, which are joined with '\n', so
                // objects are separated by `,\n` — not just `,` or space.
                while (i < body.len and (body[i] == ',' or body[i] == ' ' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t')) i += 1;
                if (i >= body.len) break;
                if (body[i] != '{') return null;

                var depth: i32 = 0;
                var j = i;
                while (j < body.len) : (j += 1) {
                    if (body[j] == '{') depth += 1 else if (body[j] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                }
                if (j >= body.len) return null;
                const obj = body[i .. j + 1];

                var in_list = false;
                for (names) |w| {
                    var name_buf: [128]u8 = undefined;
                    const needle = std.fmt.bufPrint(&name_buf, "\"name\":\"{s}\"", .{w}) catch continue;
                    if (std.mem.find(u8, obj, needle) != null) {
                        in_list = true;
                        break;
                    }
                }

                // blocklist (invert=false): keep tools NOT in `names`.
                // allowlist (invert=true): keep tools IN `names`.
                const keep = if (invert) in_list else !in_list;
                if (keep) {
                    if (!first) {
                        if (pos >= out.len) return null;
                        out[pos] = ',';
                        pos += 1;
                    }
                    if (pos + obj.len > out.len) return null;
                    @memcpy(out[pos..][0..obj.len], obj);
                    pos += obj.len;
                    first = false;
                }

                i = j + 1;
            }

            if (pos >= out.len) return null;
            out[pos] = ']';
            pos += 1;
            return out[0..pos];
        }
    };
}

// ── Inline tests ─────────────────────────────────────────────────

test "read-only mode rejects write tools" {
    const Dummy = struct {
        active: bool,
        fn isActive(self: *@This()) bool {
            return self.active;
        }
        fn dispatchEcho(_: *@This(), _: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
            const id_str = id orelse "null";
            return std.fmt.bufPrint(buf,
                \\{{"jsonrpc":"2.0","result":"ok","id":{s}}}
            , .{id_str}) catch "{}";
        }
    };
    const FW = Framework(Dummy);
    const dispatch_table = std.StaticStringMap(FW.Thunk).initComptime(.{
        .{ "test_read", Dummy.dispatchEcho },
        .{ "test_write", Dummy.dispatchEcho },
    });
    const config: FW.Config = .{
        .server_name = "t",
        .server_version = "0",
        .framing = .line_json,
        .capabilities_json = "\"tools\":{}",
        .tool_table = &dispatch_table,
        .tools_list_body =
            \\[{"name":"test_read","description":"r","inputSchema":{}},{"name":"test_write","description":"w","inputSchema":{}}]
        ,
        .read_only = .{
            .is_active_fn = Dummy.isActive,
            .write_tool_names = &[_][]const u8{"test_write"},
        },
    };

    var impl = Dummy{ .active = true };
    var resp_buf: [2048]u8 = undefined;

    // Read tools call succeeds
    const read_call = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"test_read\"},\"id\":1}";
    const r1 = FW.dispatch(&impl, read_call, &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, r1, "\"result\"") != null);

    // Write tools call rejected
    const write_call = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"test_write\"},\"id\":2}";
    const r2 = FW.dispatch(&impl, write_call, &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, r2, "Read-only") != null);

    // tools/list excludes test_write
    const list_call = "{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":3}";
    const r3 = FW.dispatch(&impl, list_call, &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, r3, "test_read") != null);
    try std.testing.expect(std.mem.find(u8, r3, "test_write") == null);

    // Disabling the gate restores write access + listing
    impl.active = false;
    const r4 = FW.dispatch(&impl, write_call, &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, r4, "\"result\"") != null);
    const r5 = FW.dispatch(&impl, list_call, &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, r5, "test_write") != null);
}

test "read-only allowlist mode (teruwm): blocks all but the read allowlist" {
    const Dummy = struct {
        active: bool,
        fn isActive(self: *@This()) bool {
            return self.active;
        }
        fn echo(_: *@This(), _: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
            const id_str = id orelse "null";
            return std.fmt.bufPrint(buf, "{{\"jsonrpc\":\"2.0\",\"result\":\"ok\",\"id\":{s}}}", .{id_str}) catch "{}";
        }
    };
    const FW = Framework(Dummy);
    const dispatch_table = std.StaticStringMap(FW.Thunk).initComptime(.{
        .{ "wm_list", Dummy.echo },
        .{ "wm_quit", Dummy.echo },
    });
    const config: FW.Config = .{
        .server_name = "t",
        .server_version = "0",
        .framing = .http,
        .capabilities_json = "\"tools\":{}",
        .tool_table = &dispatch_table,
        // Newline between objects (as real multiline-string bodies have) —
        // guards the filter's whitespace-skip between tool objects.
        .tools_list_body = "[{\"name\":\"wm_list\",\"description\":\"r\",\"inputSchema\":{}},\n{\"name\":\"wm_quit\",\"description\":\"w\",\"inputSchema\":{}}]",
        .read_only = .{
            .is_active_fn = Dummy.isActive,
            .read_allowlist = &[_][]const u8{"wm_list"},
        },
    };
    var impl = Dummy{ .active = true };
    var resp_buf: [2048]u8 = undefined;

    // Allowlisted read tool passes; everything else blocked (fail-safe).
    const r1 = FW.dispatch(&impl, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"wm_list\"},\"id\":1}", &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, r1, "\"result\"") != null);
    const r2 = FW.dispatch(&impl, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"wm_quit\"},\"id\":2}", &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, r2, "Read-only") != null);

    // tools/list keeps ONLY the allowlisted tool.
    const r3 = FW.dispatch(&impl, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/list\",\"id\":3}", &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, r3, "wm_list") != null);
    try std.testing.expect(std.mem.find(u8, r3, "wm_quit") == null);
}

test "read-only forward gate: only allowlisted forwarded tools relay" {
    const Dummy = struct {
        active: bool,
        fn isActive(self: *@This()) bool {
            return self.active;
        }
        fn fwd(_: []const u8, buf: []u8) ?[]const u8 {
            return std.fmt.bufPrint(buf, "{{\"jsonrpc\":\"2.0\",\"result\":\"forwarded\",\"id\":1}}", .{}) catch null;
        }
    };
    const FW = Framework(Dummy);
    const empty = std.StaticStringMap(FW.Thunk).initComptime(.{});
    const config: FW.Config = .{
        .server_name = "t",
        .server_version = "0",
        .framing = .line_json,
        .capabilities_json = "\"tools\":{}",
        .tool_table = &empty,
        .tools_list_body = "[]",
        .forward = .{
            .prefix = "wm_",
            .fn_ = Dummy.fwd,
            .unavailable_msg = "down",
            .read_only_allow = &[_][]const u8{"wm_list"},
        },
        .read_only = .{ .is_active_fn = Dummy.isActive },
    };
    var impl = Dummy{ .active = true };
    var resp_buf: [2048]u8 = undefined;

    // Read-only ACTIVE: allowlisted forward relays, non-allowlisted blocked.
    const a = FW.dispatch(&impl, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"wm_list\"},\"id\":1}", &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, a, "forwarded") != null);
    const b = FW.dispatch(&impl, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"wm_quit\"},\"id\":2}", &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, b, "Read-only") != null);

    // Read-only OFF: every forwarded tool relays.
    impl.active = false;
    const c = FW.dispatch(&impl, "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"wm_quit\"},\"id\":3}", &resp_buf, &config);
    try std.testing.expect(std.mem.find(u8, c, "forwarded") != null);
}
