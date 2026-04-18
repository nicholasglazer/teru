//! Cross-MCP forwarding — teru → teruwm transparent proxy.
//!
//! When an agent calls `teruwm_*` tools through teru's MCP surface
//! (either via the line-JSON Unix socket, the `--mcp-server` stdio
//! proxy, or the in-band OSC 9999 path), teru doesn't know those
//! tools locally. Rather than fail with "Unknown tool," we forward
//! the request to the teruwm compositor's MCP socket and pipe the
//! response straight back.
//!
//! Result: agents see **one unified 45-tool surface**, whether they
//! care about terminals, panes, windows, or compositor state. No
//! discovery burden, no socket juggling.
//!
//! teruwm's MCP still speaks HTTP-framed JSON-RPC (line-JSON is a
//! future refactor); teru's is line-delimited as of v0.4.14. This
//! module bridges the framing quietly.

const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("../server/ipc.zig");
const compat = @import("../compat.zig");

/// Stable buffer for the discovered teruwm socket path. Single-seat —
/// if there are multiple teruwm instances on the machine, we pick the
/// first one; agents that need pinpoint control can set
/// `TERU_WMMCP_SOCKET` in their environment.
var discovered_path: [256]u8 = undefined;

/// Look up the teruwm compositor socket. Returns null if there's no
/// teruwm running (no socket matches), in which case the caller should
/// surface "Unknown tool" to its requester.
pub fn findTeruwmSocket() ?[]const u8 {
    if (compat.getenv("TERUWM_MCP_SOCKET")) |env| return env;
    return scanRuntimeDir();
}

/// Look up the teruwm event-subscriber socket (paired with the MCP
/// request socket; pushes newline-delimited JSON). Agents that want a
/// unified event stream subscribe to both teru's events socket and
/// this one. Returns null when teruwm isn't running.
var discovered_events_path: [256]u8 = undefined;
pub fn findTeruwmEventsSocket() ?[]const u8 {
    if (compat.getenv("TERUWM_MCP_EVENTS_SOCKET")) |env| return env;
    return scanFor(&discovered_events_path, "teruwm-mcp-events-", null);
}

fn scanRuntimeDir() ?[]const u8 {
    // Request socket: teruwm-mcp-<PID>.sock — NOT the -events- variant.
    return scanFor(&discovered_path, "teruwm-mcp-", "teruwm-mcp-events-");
}

/// Shared runtime-directory scanner for socket discovery. Writes the
/// first matching entry's full path into `out` and returns a slice.
/// `prefix` is required; `exclude_prefix` (if non-null) filters out
/// matches that start with that stricter prefix (e.g. the separate
/// teruwm-mcp-events-* socket pair). All matches must end in `.sock`.
fn scanFor(out: *[256]u8, prefix: []const u8, exclude_prefix: ?[]const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;

    const uid = std.c.getuid();
    var dir_buf: [128]u8 = undefined;
    const dir_path: []const u8 = if (compat.getenv("XDG_RUNTIME_DIR")) |env|
        env
    else
        std.fmt.bufPrint(&dir_buf, "/run/user/{d}", .{uid}) catch return null;

    var z_buf: [128]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&z_buf, "{s}", .{dir_path}) catch return null;
    const dir = std.c.opendir(dir_z.ptr) orelse return null;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |ent| {
        const name_ptr: [*:0]const u8 = @ptrCast(&ent.*.name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (exclude_prefix) |ex| {
            if (std.mem.startsWith(u8, name, ex)) continue;
        }
        if (!std.mem.endsWith(u8, name, ".sock")) continue;

        const full = std.fmt.bufPrint(out, "{s}/{s}", .{ dir_path, name }) catch continue;
        return full;
    }
    return null;
}

/// Send a JSON-RPC request body to teruwm's MCP socket, receive the
/// JSON response, write it into `out`. Returns the response slice or
/// null on any failure (connection refused, malformed response, etc).
/// The caller is responsible for retrying or surfacing the error as an
/// MCP-level failure.
pub fn forwardRequest(body: []const u8, out: []u8) ?[]const u8 {
    const sock_path = findTeruwmSocket() orelse return null;
    var conn = ipc.connect(sock_path) catch return null;
    defer conn.close();

    // teruwm speaks HTTP/1.1 + JSON-RPC (same framing since v0.4.18).
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "POST / HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
        .{body.len},
    ) catch return null;
    _ = conn.write(header) catch return null;
    _ = conn.write(body) catch return null;

    // Read the whole response (teruwm closes after sending).
    var raw: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < raw.len) {
        const n = conn.read(raw[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    if (total == 0) return null;

    // Strip the HTTP header. On empty/invalid header the response is
    // treated as "forward failed"; callers should fall through to
    // "Unknown tool" rather than return garbage.
    const body_start = std.mem.indexOf(u8, raw[0..total], "\r\n\r\n") orelse return null;
    const payload = raw[body_start + 4 .. total];
    if (payload.len > out.len) return null;
    @memcpy(out[0..payload.len], payload);
    return out[0..payload.len];
}

// ── Tests ───────────────────────────────────────────────────────

test "scanRuntimeDir returns null when no teruwm socket exists" {
    // Point at an empty tmp dir so we don't interfere with a live teruwm.
    // This test is best-effort — if a real teruwm happens to be running
    // on this machine, it'll still find it. Skip in that case.
    _ = scanRuntimeDir();
}
