//! Raw TTY mode — teru running without a window (SSH, serial console,
//! or forced via --raw). Spawns one shell, hands the PTY off to
//! Terminal.runLoop, exits when the shell exits.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const compat = @import("../compat.zig");
const Pty = @import("../pty/pty.zig").Pty;
const Terminal = @import("../core/Terminal.zig");
const ProcessGraph = @import("../graph/ProcessGraph.zig");
const SignalManager = @import("../core/SignalManager.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = io;
    var graph = ProcessGraph.init(allocator);
    defer graph.deinit();

    var terminal = Terminal.init();
    defer terminal.deinit();

    const size = terminal.getSize() catch Terminal.TermSize{ .rows = common.DEFAULT_ROWS, .cols = common.DEFAULT_COLS };

    var buf: [256]u8 = undefined;
    common.outFmt(&buf, "\x1b[38;5;208m[teru {s}]\x1b[0m AI-first terminal · {d}x{d}\n", .{ common.version, size.cols, size.rows });

    var pty_inst = try Pty.spawn(.{ .rows = size.rows, .cols = size.cols });
    defer pty_inst.deinit();

    const node_id = try graph.spawn(.{
        .name = "shell",
        .kind = .shell,
        .pid = if (builtin.os.tag == .windows) null else pty_inst.child_pid,
    });

    var sig = SignalManager.init(pty_inst.master, terminal.hostFd());
    sig.registerWinch();

    try terminal.enterRawMode();
    common.out("\x1b[2J\x1b[H");
    terminal.runLoop(&pty_inst) catch |err| {
        var ebuf: [128]u8 = undefined;
        common.outFmt(&ebuf, "[teru] terminal loop error: {s}\n", .{@errorName(err)});
    };
    terminal.exitRawMode();

    if (pty_inst.child_pid != null) {
        const status = pty_inst.waitForExit() catch 0;
        graph.markFinished(node_id, @truncate(status >> 8));
    }
    common.outFmt(&buf, "\n\x1b[38;5;208m[teru]\x1b[0m session ended · {d} node(s)\n", .{graph.nodeCount()});
}
