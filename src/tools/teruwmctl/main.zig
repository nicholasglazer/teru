//! teruwmctl — shell CLI + MCP stdio adapter for teruwm.
//!
//! Three modes, same binary:
//!
//!   teruwmctl <verb> [args…]           shell CLI — one-shot tool call
//!   teruwmctl call <tool> [json]       generic — call any tool name
//!   teruwmctl watch                    stream compositor events to stdout
//!   teruwmctl --mcp-stdio              stdio proxy — for Claude Code / Cursor
//!
//! Verb form: `teruwmctl list-windows` becomes a `tools/call` for
//! `teruwm_list_windows`, and `result.content[0].text` is printed to
//! stdout. Dashes in the verb map to underscores; the `teruwm_` prefix
//! is implicit.
//!
//! Positional arguments: common verbs accept positional shell-style
//! args (e.g. `teruwmctl notify hello`, `teruwmctl click 100 200`,
//! `teruwmctl switch-workspace 2`). If the first remaining arg starts
//! with `{`, it's treated as a raw JSON payload instead, so anything
//! unusual can still be driven with the generic form.
//!
//! `watch` subscribes to the compositor's event push channel and
//! streams newline-delimited JSON to stdout until EOF/SIGINT. Events
//! include `urgent`, `focus_changed`, `workspace_switched`,
//! `window_mapped`. Best-effort (last-subscriber-wins at the server).
//!
//! The stdio mode is spec-conformant MCP (newline-delimited JSON-RPC
//! 2.0, per MCP 2024-11-05). Internally it just calls
//! `teru.McpBridge.run(io, .teruwm)` — same transport the
//! `teru --mcp-server --target teruwm` command uses. Exists as an
//! alias so users can register `teruwmctl` in their MCP config without
//! needing `teru` on PATH.

const std = @import("std");
const teru = @import("teru");
const forward = teru.forward;
const ipc = teru.ipc;
const McpBridge = teru.McpBridge;

fn out(s: []const u8) void {
    _ = std.c.write(1, s.ptr, s.len);
}

fn outFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn errFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, s.ptr, s.len);
}

const usage =
    \\teruwmctl — control the running teruwm compositor
    \\
    \\Usage:
    \\  teruwmctl <verb> [args…]          shell verb form (see below)
    \\  teruwmctl call <tool> [json]      generic — call any tool name
    \\  teruwmctl list-tools              print every tool teruwm exposes
    \\  teruwmctl watch                   stream compositor events
    \\  teruwmctl --mcp-stdio             MCP stdio proxy (for Claude Code / Cursor)
    \\  teruwmctl -h | --help             this text
    \\
    \\Verb form examples:
    \\  teruwmctl list-windows
    \\  teruwmctl switch-workspace 2
    \\  teruwmctl focus-window 7
    \\  teruwmctl close-window 7
    \\  teruwmctl move-to-workspace 7 3
    \\  teruwmctl notify "deploy finished"
    \\  teruwmctl screenshot /tmp/s.png
    \\  teruwmctl spawn-terminal [N]
    \\  teruwmctl set-layout grid
    \\  teruwmctl toggle-bar top
    \\  teruwmctl set-config gap 8
    \\  teruwmctl type "echo hi"
    \\  teruwmctl press Return
    \\  teruwmctl click 100 200 [left|right|middle]
    \\  teruwmctl scroll 100 200 15
    \\  teruwmctl toggle-scratchpad 0
    \\  teruwmctl session-save [NAME]
    \\  teruwmctl session-restore [NAME]
    \\  teruwmctl quit
    \\  teruwmctl restart
    \\
    \\Anything you can't express positionally: pass raw JSON as the next
    \\arg, e.g. `teruwmctl set-widget '{"name":"x","text":"y","class":"accent"}'`.
    \\
    \\Discovery:
    \\  TERUWM_MCP_SOCKET env var, else scan $XDG_RUNTIME_DIR/teruwm-mcp-*.sock
    \\
    \\Exit codes:
    \\  0 ok  1 tool-call error  2 no socket / connection  3 bad args
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_it.deinit();
    _ = args_it.next(); // argv[0]

    const first = args_it.next() orelse {
        errFmt("{s}", .{usage});
        std.process.exit(3);
    };

    // Help flags
    if (std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "--help")) {
        out(usage);
        return;
    }

    // MCP stdio alias — delegate to the shared bridge targeting teruwm.
    if (std.mem.eql(u8, first, "--mcp-stdio") or
        std.mem.eql(u8, first, "--mcp-server") or
        std.mem.eql(u8, first, "--mcp-bridge"))
    {
        return McpBridge.run(io, .teruwm);
    }

    // list-tools — forward tools/list, print compact.
    if (std.mem.eql(u8, first, "list-tools")) {
        try callAndPrint("tools/list", "{}");
        return;
    }

    // watch — stream events. Own code path because the response channel
    // is a separate Unix socket, not the MCP request socket.
    if (std.mem.eql(u8, first, "watch")) {
        try runWatch();
        return;
    }

    // Generic call form: `teruwmctl call <tool_name> [json_args]`.
    if (std.mem.eql(u8, first, "call")) {
        const tool = args_it.next() orelse {
            errFmt("teruwmctl: `call` needs a tool name\n", .{});
            std.process.exit(3);
        };
        const args_json = args_it.next() orelse "{}";
        try callTool(tool, args_json);
        return;
    }

    // Verb form. Collect remaining args into a small stack array so we
    // can dispatch positional shapes without heap allocation.
    var positional: [8][]const u8 = undefined;
    var n_positional: usize = 0;
    while (args_it.next()) |a| {
        if (n_positional >= positional.len) {
            errFmt("teruwmctl: too many arguments (max {d})\n", .{positional.len});
            std.process.exit(3);
        }
        positional[n_positional] = a;
        n_positional += 1;
    }
    const args_slice = positional[0..n_positional];

    var verb_buf: [128]u8 = undefined;
    const tool_name = buildVerb(&verb_buf, first) catch |err| switch (err) {
        error.TooLong => {
            errFmt("teruwmctl: verb too long: {s}\n", .{first});
            std.process.exit(3);
        },
        error.InvalidChar => {
            errFmt("teruwmctl: unknown verb '{s}'. Use `teruwmctl --help`.\n", .{first});
            std.process.exit(3);
        },
    };

    var args_buf: [4096]u8 = undefined;
    const args_json = buildArgsJson(first, args_slice, &args_buf) catch |err| switch (err) {
        error.NeedJson => {
            errFmt("teruwmctl: `{s}` needs arguments — pass JSON as the next arg\n", .{first});
            std.process.exit(3);
        },
        error.BadInt => {
            errFmt("teruwmctl: `{s}` expects an integer argument\n", .{first});
            std.process.exit(3);
        },
        error.BadFloat => {
            errFmt("teruwmctl: `{s}` expects a numeric argument\n", .{first});
            std.process.exit(3);
        },
        error.TooManyArgs => {
            errFmt("teruwmctl: too many positional args for `{s}`\n", .{first});
            std.process.exit(3);
        },
        error.BufferTooSmall => {
            errFmt("teruwmctl: argument too long for internal buffer\n", .{});
            std.process.exit(3);
        },
        error.UnescapableChar => {
            errFmt("teruwmctl: argument contains a control character — use the JSON form\n", .{});
            std.process.exit(3);
        },
    };
    try callTool(tool_name, args_json);
}

/// `list-windows` → `teruwm_list_windows`. Plain ASCII letters + dashes
/// only; anything else is rejected. Guarantees the constructed name is
/// safe to embed into a JSON string literal without escaping.
fn buildVerb(buf: *[128]u8, verb: []const u8) ![]const u8 {
    const prefix = "teruwm_";
    if (verb.len + prefix.len >= buf.len) return error.TooLong;
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = 0;
    while (i < verb.len) : (i += 1) {
        const c = verb[i];
        const mapped: u8 = if (c == '-') '_' else c;
        if (!isValidToolChar(mapped)) return error.InvalidChar;
        buf[prefix.len + i] = mapped;
    }
    return buf[0 .. prefix.len + verb.len];
}

fn isValidToolChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

// ── Positional-arg dispatch ────────────────────────────────────────

/// Convert the remaining positional args into a JSON `arguments`
/// payload for the named verb. If the first arg starts with `{`, pass
/// it through unchanged so the JSON escape hatch always works.
fn buildArgsJson(verb: []const u8, args: []const []const u8, buf: []u8) ![]const u8 {
    // JSON escape hatch: first arg is a JSON object literal.
    if (args.len >= 1 and args[0].len > 0 and args[0][0] == '{') {
        if (args[0].len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[0..args[0].len], args[0]);
        return buf[0..args[0].len];
    }

    // Empty args always serialise to `{}` — works for every tool whose
    // inputSchema has no required fields (list-windows, perf, quit,
    // restart, list-workspaces, get-config, list-widgets, …).
    if (args.len == 0) return copyStatic(buf, "{}");

    // Verb-specific positional shapes. Order roughly by expected usage.
    // Every case validates arity; missing-required errors back up as
    // error.NeedJson.
    if (eq(verb, "notify")) return kvStr(buf, "message", args, 1);
    if (eq(verb, "switch-workspace")) return kvInt(buf, "workspace", args, 1);
    if (eq(verb, "focus-window")) return kvInt(buf, "node_id", args, 1);
    if (eq(verb, "close-window")) return kvInt(buf, "node_id", args, 1);
    if (eq(verb, "set-layout")) return kvStr(buf, "layout", args, 1);
    if (eq(verb, "toggle-bar")) return kvStr(buf, "which", args, 1);
    if (eq(verb, "type")) return kvStr(buf, "text", args, 1);
    if (eq(verb, "toggle-scratchpad")) return kvInt(buf, "index", args, 1);
    if (eq(verb, "scratchpad")) return kvStr(buf, "name", args, 1);
    if (eq(verb, "screenshot")) return kvStrOpt(buf, "path", args, 1);
    if (eq(verb, "session-save")) return kvStrOpt(buf, "name", args, 1);
    if (eq(verb, "session-restore")) return kvStrOpt(buf, "name", args, 1);
    if (eq(verb, "spawn-terminal")) return kvIntOpt(buf, "workspace", args, 1);

    if (eq(verb, "move-to-workspace")) {
        if (args.len != 2) return error.NeedJson;
        return formatTwoInt(buf, "node_id", args[0], "workspace", args[1]);
    }
    if (eq(verb, "set-config")) {
        if (args.len != 2) return error.NeedJson;
        return formatTwoStr(buf, "key", args[0], "value", args[1]);
    }
    if (eq(verb, "set-name")) {
        // `set-name NEW_NAME` (focused), or `set-name ID NEW_NAME`.
        if (args.len == 1) return kvStr(buf, "new_name", args, 1);
        if (args.len == 2) {
            return std.fmt.bufPrint(buf, "{{\"node_id\":{s},\"new_name\":\"{s}\"}}", .{
                try parseIntSafe(args[0]),
                try escapeJsonString(args[1]),
            }) catch error.BufferTooSmall;
        }
        return error.NeedJson;
    }
    if (eq(verb, "set-bar")) {
        // `set-bar top on` / `set-bar bottom off`
        if (args.len != 2) return error.NeedJson;
        const enabled = parseBool(args[1]) orelse return error.NeedJson;
        const esc = try escapeJsonString(args[0]);
        return std.fmt.bufPrint(buf, "{{\"which\":\"{s}\",\"enabled\":{s}}}", .{
            esc,
            if (enabled) "true" else "false",
        }) catch error.BufferTooSmall;
    }
    if (eq(verb, "press")) {
        // `press KEY [mods...]` — mods = ctrl|shift|alt|super
        if (args.len < 1) return error.NeedJson;
        return formatPress(buf, args);
    }
    if (eq(verb, "click")) {
        // `click X Y [BUTTON]`
        if (args.len < 2 or args.len > 3) return error.NeedJson;
        const x = try parseIntSafe(args[0]);
        const y = try parseIntSafe(args[1]);
        if (args.len == 2) {
            return std.fmt.bufPrint(buf, "{{\"x\":{s},\"y\":{s}}}", .{ x, y }) catch error.BufferTooSmall;
        }
        return std.fmt.bufPrint(buf, "{{\"x\":{s},\"y\":{s},\"button\":\"{s}\"}}", .{
            x, y, try escapeJsonString(args[2]),
        }) catch error.BufferTooSmall;
    }
    if (eq(verb, "scroll")) {
        // `scroll X Y DY`
        if (args.len != 3) return error.NeedJson;
        const x = try parseIntSafe(args[0]);
        const y = try parseIntSafe(args[1]);
        const dy = try parseFloatSafe(args[2]);
        return std.fmt.bufPrint(buf, "{{\"x\":{s},\"y\":{s},\"dy\":{s}}}", .{ x, y, dy }) catch error.BufferTooSmall;
    }
    if (eq(verb, "delete-widget")) return kvStr(buf, "name", args, 1);
    if (eq(verb, "screenshot-pane")) {
        // `screenshot-pane NAME [PATH]` — name path both optional but at
        // least one expected; fall through to JSON for both-empty.
        if (args.len == 1) return kvStr(buf, "name", args, 1);
        if (args.len == 2) return formatTwoStr(buf, "name", args[0], "path", args[1]);
        return error.NeedJson;
    }

    // Verb unknown to positional parser — require JSON.
    return error.NeedJson;
}

// ── Helpers for positional JSON building ───────────────────────────

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn copyStatic(buf: []u8, s: []const u8) []const u8 {
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// `{"<key>":"<args[0]>"}` — fixed-arity 1 string value, required.
fn kvStr(buf: []u8, key: []const u8, args: []const []const u8, expected: usize) ![]const u8 {
    if (args.len != expected) return error.NeedJson;
    const esc = try escapeJsonString(args[0]);
    return std.fmt.bufPrint(buf, "{{\"{s}\":\"{s}\"}}", .{ key, esc }) catch error.BufferTooSmall;
}

/// `{"<key>":"<args[0]>"}` — fixed-arity 1 string value, optional.
/// If no args, returns `{}`.
fn kvStrOpt(buf: []u8, key: []const u8, args: []const []const u8, max: usize) ![]const u8 {
    if (args.len == 0) return copyStatic(buf, "{}");
    if (args.len > max) return error.TooManyArgs;
    const esc = try escapeJsonString(args[0]);
    return std.fmt.bufPrint(buf, "{{\"{s}\":\"{s}\"}}", .{ key, esc }) catch error.BufferTooSmall;
}

/// `{"<key>":<args[0]>}` — fixed-arity 1 integer, required.
fn kvInt(buf: []u8, key: []const u8, args: []const []const u8, expected: usize) ![]const u8 {
    if (args.len != expected) return error.NeedJson;
    const n = try parseIntSafe(args[0]);
    return std.fmt.bufPrint(buf, "{{\"{s}\":{s}}}", .{ key, n }) catch error.BufferTooSmall;
}

fn kvIntOpt(buf: []u8, key: []const u8, args: []const []const u8, max: usize) ![]const u8 {
    if (args.len == 0) return copyStatic(buf, "{}");
    if (args.len > max) return error.TooManyArgs;
    const n = try parseIntSafe(args[0]);
    return std.fmt.bufPrint(buf, "{{\"{s}\":{s}}}", .{ key, n }) catch error.BufferTooSmall;
}

fn formatTwoInt(buf: []u8, k1: []const u8, v1: []const u8, k2: []const u8, v2: []const u8) ![]const u8 {
    const n1 = try parseIntSafe(v1);
    const n2 = try parseIntSafe(v2);
    return std.fmt.bufPrint(buf, "{{\"{s}\":{s},\"{s}\":{s}}}", .{ k1, n1, k2, n2 }) catch error.BufferTooSmall;
}

fn formatTwoStr(buf: []u8, k1: []const u8, v1: []const u8, k2: []const u8, v2: []const u8) ![]const u8 {
    const e1 = try escapeJsonString(v1);
    const e2 = try escapeJsonString2(v2);
    return std.fmt.bufPrint(buf, "{{\"{s}\":\"{s}\",\"{s}\":\"{s}\"}}", .{ k1, e1, k2, e2 }) catch error.BufferTooSmall;
}

fn formatPress(buf: []u8, args: []const []const u8) ![]const u8 {
    var ctrl = false;
    var shift = false;
    var alt = false;
    var super = false;
    for (args[1..]) |m| {
        if (eq(m, "ctrl")) ctrl = true
        else if (eq(m, "shift")) shift = true
        else if (eq(m, "alt")) alt = true
        else if (eq(m, "super") or eq(m, "mod")) super = true
        else return error.NeedJson;
    }
    const key_esc = try escapeJsonString(args[0]);
    return std.fmt.bufPrint(
        buf,
        "{{\"key\":\"{s}\",\"ctrl\":{s},\"shift\":{s},\"alt\":{s},\"super\":{s}}}",
        .{
            key_esc,
            if (ctrl) "true" else "false",
            if (shift) "true" else "false",
            if (alt) "true" else "false",
            if (super) "true" else "false",
        },
    ) catch error.BufferTooSmall;
}

/// Validates and returns `s` iff it parses as a signed integer. Uses
/// the original slice so we can interpolate directly into JSON without
/// reformatting. Rejects leading/trailing whitespace.
fn parseIntSafe(s: []const u8) ![]const u8 {
    _ = std.fmt.parseInt(i64, s, 10) catch return error.BadInt;
    return s;
}

fn parseFloatSafe(s: []const u8) ![]const u8 {
    _ = std.fmt.parseFloat(f64, s) catch return error.BadFloat;
    return s;
}

fn parseBool(s: []const u8) ?bool {
    if (eq(s, "on") or eq(s, "true") or eq(s, "1") or eq(s, "yes")) return true;
    if (eq(s, "off") or eq(s, "false") or eq(s, "0") or eq(s, "no")) return false;
    return null;
}

/// Two 512-byte scratch buffers for JSON-escaping argument strings.
/// Two is enough for every positional verb — the widest shape
/// (`formatTwoStr`, `set-name`) needs exactly two concurrent escaped
/// values; everything else is one-at-a-time. A round-robin scheme
/// would feel clever but three concurrent values doesn't happen.
var escape_buf_a: [512]u8 = undefined;
var escape_buf_b: [512]u8 = undefined;

fn escapeJsonString(s: []const u8) ![]const u8 {
    return escapeJsonStringInto(&escape_buf_a, s);
}
fn escapeJsonString2(s: []const u8) ![]const u8 {
    return escapeJsonStringInto(&escape_buf_b, s);
}

fn escapeJsonStringInto(buf: []u8, s: []const u8) ![]const u8 {
    var w: usize = 0;
    for (s) |c| {
        // Control chars that have short JSON escapes fall through to
        // the per-char write below; any other control char in 0..0x1f
        // is rejected (would need \uXXXX — not worth the complexity,
        // shell arguments shouldn't contain them).
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t') {
            return error.UnescapableChar;
        }
        const need: usize = switch (c) {
            '"', '\\', '\n', '\r', '\t' => 2,
            else => 1,
        };
        if (w + need >= buf.len) return error.BufferTooSmall;
        switch (c) {
            '"' => {
                buf[w] = '\\';
                buf[w + 1] = '"';
                w += 2;
            },
            '\\' => {
                buf[w] = '\\';
                buf[w + 1] = '\\';
                w += 2;
            },
            '\n' => {
                buf[w] = '\\';
                buf[w + 1] = 'n';
                w += 2;
            },
            '\r' => {
                buf[w] = '\\';
                buf[w + 1] = 'r';
                w += 2;
            },
            '\t' => {
                buf[w] = '\\';
                buf[w + 1] = 't';
                w += 2;
            },
            else => {
                buf[w] = c;
                w += 1;
            },
        }
    }
    return buf[0..w];
}

// ── Tool call plumbing ─────────────────────────────────────────────

/// Issue a `tools/call` against teruwm, print the `result.content[0].text`
/// if present (that's where teruwm returns its JSON-encoded payload
/// strings), else the raw `result`. On JSON-RPC error: print `error.message`
/// to stderr and exit 1.
fn callTool(tool: []const u8, args_json: []const u8) !void {
    var req_buf: [8192]u8 = undefined;
    const body = std.fmt.bufPrint(&req_buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
        .{ tool, args_json },
    ) catch {
        errFmt("teruwmctl: request body too long\n", .{});
        std.process.exit(3);
    };
    try runAndPrint(body);
}

/// Issue a raw JSON-RPC method (no `tools/call` wrapping). Used for
/// `tools/list` which lives at the top level of the JSON-RPC
/// envelope rather than under `tools/call`.
fn callAndPrint(method: []const u8, params_json: []const u8) !void {
    var req_buf: [4096]u8 = undefined;
    const body = std.fmt.bufPrint(&req_buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params_json },
    ) catch {
        errFmt("teruwmctl: request body too long\n", .{});
        std.process.exit(3);
    };
    try runAndPrint(body);
}

fn runAndPrint(body: []const u8) !void {
    var resp_buf: [65536]u8 = undefined;
    const resp = forward.forwardRequest(body, &resp_buf) orelse {
        errFmt("teruwmctl: no teruwm MCP socket. Set TERUWM_MCP_SOCKET or start teruwm.\n", .{});
        std.process.exit(2);
    };

    // JSON-RPC error → stderr + exit 1. Conservative string search;
    // full parse would need std.json. The server always places
    // `"error":{` at a fixed depth, so substring match is reliable.
    if (std.mem.indexOf(u8, resp, "\"error\":{") != null) {
        _ = std.c.write(2, resp.ptr, resp.len);
        out("\n");
        std.process.exit(1);
    }

    // Extract result.content[0].text if it's a tools/call response
    // (teruwm wraps its payload strings there). For tools/list or
    // other envelopes, fall through and print the whole response.
    if (extractContentText(resp)) |inner| {
        // `inner` is the raw byte slice between the `"text":"…"` delimiters,
        // so JSON escape sequences are still literal (`\"`, `\\`, `\n`…).
        // Unescape once before printing so users see readable JSON /
        // text, not `\"gap\":4` etc. Single-pass is correct for the
        // teruwm server's output shape (one level of embedding).
        var unescape_buf: [65536]u8 = undefined;
        const decoded = unescapeJsonString(inner, &unescape_buf) orelse inner;
        out(decoded);
        if (decoded.len == 0 or decoded[decoded.len - 1] != '\n') out("\n");
        return;
    }

    out(resp);
    out("\n");
}

/// Unescape a JSON string-body slice (the contents between the outer
/// `"…"`). Handles the subset the teruwm server emits: `\"`, `\\`,
/// `\n`, `\r`, `\t`, `\/`, `\b`, `\f`. Unknown `\x` sequences are
/// copied through verbatim (safer than rejecting — keeps odd tool
/// output readable). Returns null if the result wouldn't fit in
/// `out_buf`.
fn unescapeJsonString(s: []const u8, out_buf: []u8) ?[]const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (w >= out_buf.len) return null;
        if (s[i] != '\\' or i + 1 >= s.len) {
            out_buf[w] = s[i];
            w += 1;
            continue;
        }
        const next = s[i + 1];
        const mapped: u8 = switch (next) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'b' => 0x08,
            'f' => 0x0c,
            else => 0, // signal: keep the backslash literally
        };
        if (mapped != 0 or next == 0) {
            out_buf[w] = mapped;
            w += 1;
            i += 1; // skip the escape char
        } else {
            // Unknown escape — emit backslash, fall through to re-read
            // next on the following iteration.
            out_buf[w] = '\\';
            w += 1;
        }
    }
    return out_buf[0..w];
}

/// If the response body looks like
///   {"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"<PAYLOAD>"}]},"id":1}
/// return the unescaped PAYLOAD slice pointing inside `resp`. Otherwise
/// null. We only handle the exact shape teruwm produces — no fancy
/// JSON walking — because the server's output format is known-stable.
fn extractContentText(resp: []const u8) ?[]const u8 {
    const marker = "\"text\":\"";
    const start = std.mem.indexOf(u8, resp, marker) orelse return null;
    const body_start = start + marker.len;
    // Walk forward looking for the unescaped closing quote.
    var i = body_start;
    while (i < resp.len) : (i += 1) {
        if (resp[i] == '\\') {
            i += 1;
            continue;
        }
        if (resp[i] == '"') break;
    }
    if (i >= resp.len) return null;
    return resp[body_start..i];
}

// ── watch subcommand ───────────────────────────────────────────────

/// Call teruwm_subscribe_events, get the events socket path, connect,
/// and pipe newline-delimited JSON to stdout until the server closes.
fn runWatch() !void {
    // Step 1: ask the compositor for its events-socket path.
    var req_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&req_buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"teruwm_subscribe_events\",\"arguments\":{{}}}}}}",
        .{},
    ) catch unreachable;

    var resp_buf: [4096]u8 = undefined;
    const resp = forward.forwardRequest(body, &resp_buf) orelse {
        errFmt("teruwmctl: no teruwm MCP socket. Set TERUWM_MCP_SOCKET or start teruwm.\n", .{});
        std.process.exit(2);
    };

    if (std.mem.indexOf(u8, resp, "\"error\":{") != null) {
        _ = std.c.write(2, resp.ptr, resp.len);
        out("\n");
        std.process.exit(1);
    }

    // Payload shape: `{\"socket\":\"<path>\"}` inside result.content[0].text.
    const inner = extractContentText(resp) orelse {
        errFmt("teruwmctl: unexpected subscribe_events response\n", .{});
        std.process.exit(1);
    };
    const socket_path = extractSocketField(inner) orelse {
        errFmt("teruwmctl: couldn't parse socket path from: {s}\n", .{inner});
        std.process.exit(1);
    };

    // Step 2: connect to the events socket. Copy the path first — it
    // points into resp_buf which we don't want to reuse mid-loop.
    var path_buf: [256]u8 = undefined;
    if (socket_path.len > path_buf.len) {
        errFmt("teruwmctl: socket path too long\n", .{});
        std.process.exit(1);
    }
    @memcpy(path_buf[0..socket_path.len], socket_path);
    const path = path_buf[0..socket_path.len];

    const conn = ipc.connect(path) catch |err| {
        errFmt("teruwmctl: connect to {s} failed: {s}\n", .{ path, @errorName(err) });
        std.process.exit(2);
    };
    defer conn.close();

    // Step 3: pipe. Loop on read, forward each chunk to stdout. EOF ==
    // compositor shutdown or subscriber replaced. No buffering: the
    // server already emits one JSON object per line.
    var pipe_buf: [4096]u8 = undefined;
    while (true) {
        const n = conn.read(&pipe_buf) catch |err| {
            errFmt("teruwmctl: read error: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        if (n == 0) return; // EOF — clean exit
        _ = std.c.write(1, (&pipe_buf).ptr, n);
    }
}

/// Extract the value of `"socket":"…"` from the escaped JSON payload
/// `{\"socket\":\"/run/user/.../sock\"}`. We only decode the specific
/// escape we know is present (`\"` → `"`) and then read until the next
/// `\"`, unescaping backslashes and quotes in-place into a static
/// buffer. Socket paths don't contain quotes or backslashes in
/// practice, so a naive search works fine.
fn extractSocketField(escaped_payload: []const u8) ?[]const u8 {
    const marker = "\\\"socket\\\":\\\"";
    const start = std.mem.indexOf(u8, escaped_payload, marker) orelse return null;
    const body_start = start + marker.len;
    const end_marker = "\\\"";
    const end_rel = std.mem.indexOf(u8, escaped_payload[body_start..], end_marker) orelse return null;
    return escaped_payload[body_start .. body_start + end_rel];
}

// ── Tests ─────────────────────────────────────────────────────────

test "buildVerb: simple dash-to-underscore" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("teruwm_list_windows", try buildVerb(&buf, "list-windows"));
    try std.testing.expectEqualStrings("teruwm_screenshot", try buildVerb(&buf, "screenshot"));
    try std.testing.expectEqualStrings("teruwm_set_layout", try buildVerb(&buf, "set-layout"));
}

test "buildVerb: rejects garbage" {
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidChar, buildVerb(&buf, "list windows"));
    try std.testing.expectError(error.InvalidChar, buildVerb(&buf, "list;rm -rf"));
}

test "extractContentText: finds teruwm's wrapped payload" {
    const resp = "{\"jsonrpc\":\"2.0\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[]\"}]},\"id\":1}";
    try std.testing.expectEqualStrings("[]", extractContentText(resp).?);
}

test "extractContentText: null on non-content response" {
    const resp = "{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":[]},\"id\":1}";
    try std.testing.expect(extractContentText(resp) == null);
}

test "extractSocketField: parses the escaped JSON payload" {
    // Shape after extractContentText strips the outer envelope: the
    // payload still has its inner quotes escaped.
    const payload = "{\\\"socket\\\":\\\"/run/user/1000/teruwm-mcp-events-123.sock\\\"}";
    const got = extractSocketField(payload).?;
    try std.testing.expectEqualStrings("/run/user/1000/teruwm-mcp-events-123.sock", got);
}

test "buildArgsJson: empty args → {}" {
    var buf: [256]u8 = undefined;
    const out_str = try buildArgsJson("list-windows", &.{}, &buf);
    try std.testing.expectEqualStrings("{}", out_str);
}

test "buildArgsJson: json escape hatch" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{"{\"workspace\":3}"};
    const out_str = try buildArgsJson("switch-workspace", &args, &buf);
    try std.testing.expectEqualStrings("{\"workspace\":3}", out_str);
}

test "buildArgsJson: notify positional" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{"hello"};
    const out_str = try buildArgsJson("notify", &args, &buf);
    try std.testing.expectEqualStrings("{\"message\":\"hello\"}", out_str);
}

test "buildArgsJson: switch-workspace positional" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{"3"};
    const out_str = try buildArgsJson("switch-workspace", &args, &buf);
    try std.testing.expectEqualStrings("{\"workspace\":3}", out_str);
}

test "buildArgsJson: click with button" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{ "100", "200", "right" };
    const out_str = try buildArgsJson("click", &args, &buf);
    try std.testing.expectEqualStrings("{\"x\":100,\"y\":200,\"button\":\"right\"}", out_str);
}

test "buildArgsJson: move-to-workspace two ints" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{ "7", "3" };
    const out_str = try buildArgsJson("move-to-workspace", &args, &buf);
    try std.testing.expectEqualStrings("{\"node_id\":7,\"workspace\":3}", out_str);
}

test "buildArgsJson: set-config key value" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{ "gap", "8" };
    const out_str = try buildArgsJson("set-config", &args, &buf);
    try std.testing.expectEqualStrings("{\"key\":\"gap\",\"value\":\"8\"}", out_str);
}

test "buildArgsJson: set-name focused-only" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{"editor"};
    const out_str = try buildArgsJson("set-name", &args, &buf);
    try std.testing.expectEqualStrings("{\"new_name\":\"editor\"}", out_str);
}

test "buildArgsJson: set-name by id" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{ "5", "editor" };
    const out_str = try buildArgsJson("set-name", &args, &buf);
    try std.testing.expectEqualStrings("{\"node_id\":5,\"new_name\":\"editor\"}", out_str);
}

test "buildArgsJson: scroll dy float" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{ "100", "200", "15" };
    const out_str = try buildArgsJson("scroll", &args, &buf);
    try std.testing.expectEqualStrings("{\"x\":100,\"y\":200,\"dy\":15}", out_str);
}

test "buildArgsJson: screenshot optional path" {
    var buf: [256]u8 = undefined;
    const empty = try buildArgsJson("screenshot", &.{}, &buf);
    try std.testing.expectEqualStrings("{}", empty);
    const args = [_][]const u8{"/tmp/s.png"};
    const with_path = try buildArgsJson("screenshot", &args, &buf);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp/s.png\"}", with_path);
}

test "buildArgsJson: bad int" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{"abc"};
    try std.testing.expectError(error.BadInt, buildArgsJson("switch-workspace", &args, &buf));
}

test "buildArgsJson: press with mods" {
    var buf: [256]u8 = undefined;
    const args = [_][]const u8{ "Return", "ctrl", "shift" };
    const out_str = try buildArgsJson("press", &args, &buf);
    try std.testing.expectEqualStrings(
        "{\"key\":\"Return\",\"ctrl\":true,\"shift\":true,\"alt\":false,\"super\":false}",
        out_str,
    );
}

test "escapeJsonString: handles quotes + backslashes + newlines" {
    const got = try escapeJsonString("a\"b\\c\nd");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd", got);
}

test "escapeJsonString: rejects control chars" {
    try std.testing.expectError(error.UnescapableChar, escapeJsonString("a\x01b"));
}

test "unescapeJsonString: handles common escapes" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "[{\"id\":0}]",
        unescapeJsonString("[{\\\"id\\\":0}]", &buf).?,
    );
    try std.testing.expectEqualStrings(
        "a\nb\tc",
        unescapeJsonString("a\\nb\\tc", &buf).?,
    );
    try std.testing.expectEqualStrings(
        "backslash: \\",
        unescapeJsonString("backslash: \\\\", &buf).?,
    );
}

test "unescapeJsonString: pass-through for unknown escapes" {
    // Unknown `\x` sequences preserve the backslash + char — avoids
    // silently eating data we don't recognise.
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "hello\\zworld",
        unescapeJsonString("hello\\zworld", &buf).?,
    );
}
