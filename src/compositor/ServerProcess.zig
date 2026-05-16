//! Detached process spawning for teruwm. Double-fork so a spawned
//! shell reparents to init (PID 1) and never zombies the compositor.
//! Server.zig keeps thin `spawnProcess` / `spawnShell` delegators.

const std = @import("std");

/// Spawn a shell command detached from the compositor (double-fork to
/// avoid zombies). Uses /bin/sh -c so commands with arguments and pipes
/// work; inherits the compositor's environment so children see
/// WAYLAND_DISPLAY, DISPLAY (Xwayland), HOME, etc.
pub fn spawnProcess(cmd: [*:0]const u8) void {
    const pid = std.os.linux.fork();
    if (pid == 0) {
        const pid2 = std.os.linux.fork();
        if (pid2 == 0) {
            // Grandchild: exec via shell to handle args/pipes.
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            _ = std.posix.system.execve("/bin/sh", &argv, @ptrCast(envp));
            std.os.linux.exit(1);
        }
        std.os.linux.exit(0);
    }
    if (pid > 0) {
        // Reap the intermediate child. It exit(0)s right after the
        // second fork, so this blocks for microseconds — effectively
        // never. WNOHANG would race the kernel scheduler and leak a
        // zombie when the exit hasn't been processed yet.
        _ = std.c.waitpid(@intCast(pid), null, 0);
    }
}

/// Same as spawnProcess but takes a non-nul-terminated slice. Copies
/// into a stack buffer and nul-terminates. Commands longer than 511
/// bytes are truncated (matches the config parser's bound).
pub fn spawnShell(cmd: []const u8) void {
    var buf: [512:0]u8 = undefined;
    if (cmd.len >= buf.len) {
        std.debug.print("teruwm: spawnShell command truncated ({d} > 512)\n", .{cmd.len});
    }
    const n = @min(cmd.len, buf.len);
    @memcpy(buf[0..n], cmd[0..n]);
    buf[n] = 0;
    spawnProcess(@ptrCast(&buf));
}
