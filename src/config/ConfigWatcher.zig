//! inotify-based config file watcher.
//!
//! Watches ~/.config/teru/teru.conf for modifications using Linux inotify.
//! Zero polling — the inotify fd becomes readable only when the file changes.
//! Non-blocking read in the main loop checks for events each iteration.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const compat = @import("../compat.zig");

const ConfigWatcher = @This();

fd: posix.fd_t,
wd: i32, // watch descriptor

/// Initialize inotify and watch the config file.
/// Returns null if inotify or the config file is unavailable.
pub fn init() ?ConfigWatcher {
    const home = compat.getenv("HOME") orelse return null;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/teru/teru.conf", .{home}) catch return null;

    // Null-terminate for inotify_add_watch
    if (path.len >= path_buf.len) return null;
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);

    const fd = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (@as(isize, @bitCast(fd)) < 0) return null;

    const wd = linux.inotify_add_watch(@intCast(fd), path_z, linux.IN.MODIFY | linux.IN.CLOSE_WRITE);
    if (@as(isize, @bitCast(wd)) < 0) {
        _ = posix.system.close(@intCast(fd));
        return null;
    }

    return ConfigWatcher{
        .fd = @intCast(fd),
        .wd = @intCast(wd),
    };
}

/// Check if the config file has been modified (non-blocking).
/// Returns true if a modification was detected.
pub fn poll(self: *ConfigWatcher) bool {
    var buf: [256]u8 = undefined;
    const n = posix.read(self.fd, &buf) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return false,
    };
    // Any data means the file was modified
    return n > 0;
}

pub fn deinit(self: *ConfigWatcher) void {
    _ = linux.inotify_rm_watch(@intCast(self.fd), self.wd);
    _ = posix.system.close(self.fd);
}

// ── Tests ────────────────────────────────────────────────────────

test "ConfigWatcher init returns null gracefully when no config" {
    // In test environment, config file likely doesn't exist
    // but inotify_init should succeed
    if (ConfigWatcher.init()) |*w| {
        var watcher = w.*;
        defer watcher.deinit();
        // No modifications yet
        try std.testing.expect(!watcher.poll());
    }
}
