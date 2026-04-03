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

    // Watch the DIRECTORY so we detect file creation, not just modification
    var dir_buf: [512]u8 = undefined;
    const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/.config/teru", .{home}) catch return null;
    if (dir_path.len >= dir_buf.len) return null;
    dir_buf[dir_path.len] = 0;
    const dir_z: [*:0]const u8 = @ptrCast(dir_buf[0..dir_path.len :0]);

    const fd = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (@as(isize, @bitCast(fd)) < 0) return null;

    const wd = linux.inotify_add_watch(@intCast(fd), dir_z, linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.CREATE | linux.IN.MOVED_TO);
    if (@as(isize, @bitCast(wd)) < 0) {
        _ = posix.system.close(@intCast(fd));
        return null;
    }

    return ConfigWatcher{
        .fd = @intCast(fd),
        .wd = @intCast(wd),
    };
}

/// Check if teru.conf was modified (non-blocking).
/// Filters directory events to only match "teru.conf".
pub fn poll(self: *ConfigWatcher) bool {
    var buf: [4096]u8 = undefined;
    const n = posix.read(self.fd, &buf) catch |err| switch (err) {
        error.WouldBlock => return false,
        else => return false,
    };
    if (n == 0) return false;

    // Parse inotify events to check if "teru.conf" was the file
    const target = "teru.conf";
    var offset: usize = 0;
    while (offset + @sizeOf(linux.inotify_event) <= n) {
        const event: *const linux.inotify_event = @ptrCast(@alignCast(buf[offset..].ptr));
        const name_len = event.len;
        if (name_len > 0) {
            const name_start = offset + @sizeOf(linux.inotify_event);
            const name_end = @min(name_start + name_len, n);
            const name_bytes = buf[name_start..name_end];
            // Find null terminator
            const name = if (std.mem.indexOfScalar(u8, name_bytes, 0)) |nul|
                name_bytes[0..nul]
            else
                name_bytes;
            if (std.mem.eql(u8, name, target)) return true;
        }
        offset += @sizeOf(linux.inotify_event) + name_len;
    }
    return false;
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
