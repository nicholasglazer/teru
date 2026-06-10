//! Env-gated structured logging for teru + teruwm.
//!
//! Set `TERU_LOG=debug|info|warn|err` to control verbosity at RUNTIME — no
//! rebuild. Default is `info` (shows info/warn/err, hides debug). All levels
//! are compiled in; this gates output. `mcp`-scoped debug lines are the full
//! MCP request/response trace, so `TERU_LOG=debug` captures all tool traffic
//! for both the teru and teruwm servers (they share `McpFramework.dispatch`).
//!
//! Use it via std.log:
//!     std.log.scoped(.mcp).debug("→ {s}", .{request});
//!     std.log.scoped(.compositor).info("output added {s}", .{name});
//!     std.log.scoped(.pty).err("spawn failed: {s}", .{@errorName(e)});
//!
//! Wire it up once per binary in the ROOT source file (main.zig /
//! compositor/main.zig):
//!     pub const std_options = teru.log.std_options;
//!
//! Output goes to stderr only; redirect there to capture to a file (the
//! `run-teruwm.sh debug` mode does this). Format: `[level] (scope) message`.

const std = @import("std");
const compat = @import("compat.zig");

/// Drop-in for the root file's `std_options`. `log_level = .debug` compiles
/// every level in; `logFn` applies the runtime `TERU_LOG` filter.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = logFn,
};

var cached_level: ?std.log.Level = null;

/// Active threshold from `TERU_LOG`, cached on first use. A message is emitted
/// when its level is at least as severe as the threshold (err=0 … debug=3).
pub fn activeLevel() std.log.Level {
    if (cached_level) |l| return l;
    const env = compat.getenv("TERU_LOG");
    const s = if (env) |p| std.mem.sliceTo(p, 0) else "";
    const l: std.log.Level =
        if (std.mem.eql(u8, s, "debug")) .debug
        else if (std.mem.eql(u8, s, "info")) .info
        else if (std.mem.eql(u8, s, "warn") or std.mem.eql(u8, s, "warning")) .warn
        else if (std.mem.eql(u8, s, "err") or std.mem.eql(u8, s, "error")) .err
        else .info; // default
    cached_level = l;
    return l;
}

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    // Runtime gate: lower enum value = more severe; emit when at/below threshold.
    if (@intFromEnum(level) > @intFromEnum(activeLevel())) return;

    const prefix = "[" ++ @tagName(level) ++ "] (" ++ @tagName(scope) ++ ") ";
    var buf: [4096]u8 = undefined;
    const line: []const u8 = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch
        prefix ++ "<log line too long; truncated>\n";
    // stderr write. NOTE: std.c.write's fd-arg type differs on the Windows
    // libc binding (0.17 std) — the Windows port (task) must route this through
    // the Win32 stderr HANDLE. Fine on Linux/macOS, which is what ships today.
    _ = std.c.write(2, line.ptr, line.len);
}
