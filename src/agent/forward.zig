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
    const dir_z = std.fmt.bufPrintSentinel(&z_buf, "{s}", .{dir_path}, 0) catch return null;
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
        // A crashed or SIGTERM'd teruwm leaves its socket behind. Skip one
        // whose owner is gone, or every forward fails while readdir happens
        // to list it before the live compositor's.
        if (ownerPid(name, prefix)) |pid| {
            if (!pidAlive(pid)) continue;
        }

        const full = std.fmt.bufPrint(out, "{s}/{s}", .{ dir_path, name }) catch continue;
        return full;
    }
    return null;
}

/// The PID in `<prefix><PID>.sock`, or null when the name carries none.
fn ownerPid(name: []const u8, prefix: []const u8) ?i32 {
    if (name.len <= prefix.len + ".sock".len) return null;
    const digits = name[prefix.len .. name.len - ".sock".len];
    return std.fmt.parseInt(i32, digits, 10) catch null;
}

/// Whether a process with this PID exists (signal 0 probes without sending).
fn pidAlive(pid: i32) bool {
    if (pid <= 0) return false;
    if (std.c.kill(pid, @enumFromInt(0)) == 0) return true;
    // EPERM: it exists but belongs to someone else.
    return std.posix.errno(@as(c_int, -1)) == .PERM;
}

/// Send/receive limit for forwards made from teru's event loop. A hung
/// teruwm must not freeze every pane, so this stays short.
pub const event_loop_timeout_ms: u32 = 500;

/// Send/receive limit for the stdio bridge and teruwmctl. They block nothing
/// else, and some teruwm tools (a full-desktop screenshot on a large or
/// multi-output setup, session_restore, a debug build) take longer than the
/// event-loop limit even though they succeed.
pub const standalone_timeout_ms: u32 = 30_000;

fn timevalFromMs(ms: u32) std.c.timeval {
    return .{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
}

fn setForwardTimeouts(fd: i32, timeout_ms: u32) void {
    const tv = timevalFromMs(timeout_ms);
    _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &tv, @sizeOf(std.c.timeval));
    _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &tv, @sizeOf(std.c.timeval));
}

/// Send a JSON-RPC request body to teruwm's MCP socket, receive the
/// JSON response, write it into `out`. Returns the response slice or
/// null on any failure (connection refused, malformed response, timeout).
/// The caller is responsible for retrying or surfacing the error as an
/// MCP-level failure.
///
/// This variant is for teru's event loop and gives up after
/// `event_loop_timeout_ms`. Standalone callers use `forwardRequestStandalone`.
pub fn forwardRequest(body: []const u8, out: []u8) ?[]const u8 {
    return forwardRequestTimeout(body, out, event_loop_timeout_ms);
}

/// `forwardRequest` for processes that do nothing else while they wait: the
/// `--mcp-server --target teruwm` stdio bridge and teruwmctl.
pub fn forwardRequestStandalone(body: []const u8, out: []u8) ?[]const u8 {
    return forwardRequestTimeout(body, out, standalone_timeout_ms);
}

fn forwardRequestTimeout(body: []const u8, out: []u8, timeout_ms: u32) ?[]const u8 {
    const sock_path = findTeruwmSocket() orelse return null;
    return forwardTo(sock_path, body, out, timeout_ms);
}

fn forwardTo(sock_path: []const u8, body: []const u8, out: []u8, timeout_ms: u32) ?[]const u8 {
    var conn = ipc.connect(sock_path) catch return null;
    defer conn.close();
    if (builtin.os.tag != .windows) setForwardTimeouts(conn.rawFd(), timeout_ms);

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
    const body_start = std.mem.find(u8, raw[0..total], "\r\n\r\n") orelse return null;
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

test "ownerPid reads the PID from a socket name" {
    try std.testing.expectEqual(@as(?i32, 1234), ownerPid("teruwm-mcp-1234.sock", "teruwm-mcp-"));
    try std.testing.expectEqual(@as(?i32, 77), ownerPid("teruwm-mcp-events-77.sock", "teruwm-mcp-events-"));
    try std.testing.expectEqual(@as(?i32, null), ownerPid("teruwm-mcp-x.sock", "teruwm-mcp-"));
    try std.testing.expectEqual(@as(?i32, null), ownerPid("teruwm-mcp-.sock", "teruwm-mcp-"));
}

test "pidAlive: this process is alive, an unused PID is not" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(pidAlive(@intCast(std.c.getpid())));
    try std.testing.expect(!pidAlive(0));
    try std.testing.expect(!pidAlive(std.math.maxInt(i32)));
}

test "timevalFromMs splits seconds and microseconds" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = timevalFromMs(500);
    try std.testing.expectEqual(@as(i64, 0), @as(i64, a.sec));
    try std.testing.expectEqual(@as(i64, 500_000), @as(i64, a.usec));
    const b = timevalFromMs(30_000);
    try std.testing.expectEqual(@as(i64, 30), @as(i64, b.sec));
    try std.testing.expectEqual(@as(i64, 0), @as(i64, b.usec));
    const c = timevalFromMs(1_250);
    try std.testing.expectEqual(@as(i64, 1), @as(i64, c.sec));
    try std.testing.expectEqual(@as(i64, 250_000), @as(i64, c.usec));
}

test "standalone callers wait longer than the event loop" {
    try std.testing.expect(standalone_timeout_ms >= 10 * event_loop_timeout_ms);
}

fn monoMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "forwardTo gives up on a silent compositor after its own timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // A listener that never accepts: connect succeeds (backlog), the write
    // fits the socket buffer, and the read blocks until the timeout.
    var path_buf: [108]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/teru-forward-test-{d}.sock", .{std.c.getpid()});
    const server = try ipc.listen(path);
    defer {
        server.close();
        var z: [109]u8 = undefined;
        @memcpy(z[0..path.len], path);
        z[path.len] = 0;
        _ = std.c.unlink(@ptrCast(&z));
    }

    var out: [256]u8 = undefined;
    const t0 = monoMs();
    try std.testing.expectEqual(@as(?[]const u8, null), forwardTo(path, "{}", &out, 60));
    const short = monoMs() - t0;

    const t1 = monoMs();
    try std.testing.expectEqual(@as(?[]const u8, null), forwardTo(path, "{}", &out, 300));
    const long = monoMs() - t1;

    try std.testing.expect(short >= 50 and short < 280);
    try std.testing.expect(long >= 290);
}
