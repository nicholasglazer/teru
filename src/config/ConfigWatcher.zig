//! Cross-platform config file watcher.
//!
//! Watches ~/.config/teru/ for modifications to teru.conf.
//! - Linux: inotify (zero polling, fd becomes readable on change)
//! - macOS: kqueue + EVFILT_VNODE (same pattern, fd-based)
//! - Windows: polling fallback (stat-based, checks every N frames)

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const compat = @import("../compat.zig");

const ConfigWatcher = @This();

fd: posix.fd_t,
wd: i32, // watch descriptor (inotify) or 0 (kqueue/poll)
last_mtime: i128 = 0, // for polling fallback

/// Initialize and watch the config directory/file.
/// Returns null if unavailable.
pub fn init() ?ConfigWatcher {
    return switch (builtin.os.tag) {
        .linux => initInotify(),
        .macos => initKqueue(),
        else => initPolling(),
    };
}

/// Check if teru.conf was modified (non-blocking).
pub fn poll(self: *ConfigWatcher) bool {
    return switch (builtin.os.tag) {
        .linux => pollInotify(self),
        .macos => pollKqueue(self),
        else => pollStat(self),
    };
}

pub fn deinit(self: *ConfigWatcher) void {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            _ = linux.inotify_rm_watch(@intCast(self.fd), self.wd);
            _ = posix.system.close(self.fd);
        },
        else => {
            if (self.fd >= 0) _ = posix.system.close(self.fd);
        },
    }
}

// ── Linux: inotify ──────────────────────────────────────────────

fn initInotify() ?ConfigWatcher {
    if (builtin.os.tag != .linux) return null;
    const linux = std.os.linux;

    const home = compat.getenv("HOME") orelse return null;
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

    return .{ .fd = @intCast(fd), .wd = @intCast(wd) };
}

fn pollInotify(self: *ConfigWatcher) bool {
    if (builtin.os.tag != .linux) return false;
    const linux = std.os.linux;

    var buf: [4096]u8 = undefined;
    const n = posix.read(self.fd, &buf) catch return false;
    if (n == 0) return false;

    const target = "teru.conf";
    var offset: usize = 0;
    while (offset + @sizeOf(linux.inotify_event) <= n) {
        const event: *const linux.inotify_event = @ptrCast(@alignCast(buf[offset..].ptr));
        const name_len = event.len;
        if (name_len > 0) {
            const name_start = offset + @sizeOf(linux.inotify_event);
            const name_end = @min(name_start + name_len, n);
            const name_bytes = buf[name_start..name_end];
            const name = if (std.mem.indexOfScalar(u8, name_bytes, 0)) |nul| name_bytes[0..nul] else name_bytes;
            if (std.mem.eql(u8, name, target)) return true;
        }
        offset += @sizeOf(linux.inotify_event) + name_len;
    }
    return false;
}

// ── macOS: kqueue ───────────────────────────────────────────────

fn initKqueue() ?ConfigWatcher {
    // kqueue requires opening the file to watch it
    const home = compat.getenv("HOME") orelse return null;
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/teru/teru.conf", .{home}) catch return null;
    if (path.len >= path_buf.len) return null;
    path_buf[path.len] = 0;

    // Open the file for kqueue monitoring (read-only, non-blocking)
    const file_fd = posix.system.open(@ptrCast(path_buf[0..path.len :0]), .{ .ACCMODE = .RDONLY }, @as(std.posix.mode_t, 0));
    if (file_fd < 0) return null;

    // Create kqueue
    const kq = std.c.kqueue();
    if (kq < 0) {
        _ = posix.system.close(file_fd);
        return null;
    }

    // Register EVFILT_VNODE for writes
    var changelist = [1]std.posix.Kevent{.{
        .ident = @intCast(file_fd),
        .filter = std.posix.system.EVFILT.VNODE,
        .flags = std.posix.system.EV.ADD | std.posix.system.EV.CLEAR,
        .fflags = std.posix.system.NOTE.WRITE | std.posix.system.NOTE.ATTRIB,
        .data = 0,
        .udata = 0,
    }};
    const rc = std.posix.system.kevent(kq, &changelist, 1, null, 0, null);
    if (rc < 0) {
        _ = posix.system.close(file_fd);
        _ = posix.system.close(kq);
        return null;
    }

    return .{ .fd = kq, .wd = file_fd };
}

fn pollKqueue(self: *ConfigWatcher) bool {
    const timeout = std.posix.timespec{ .sec = 0, .nsec = 0 }; // non-blocking
    var events: [4]std.posix.Kevent = undefined;
    const n = std.posix.system.kevent(self.fd, null, 0, &events, events.len, &timeout);
    return n > 0;
}

// ── Windows / fallback: stat polling ────────────────────────────

fn initPolling() ?ConfigWatcher {
    return .{ .fd = -1, .wd = 0, .last_mtime = 0 };
}

fn pollStat(self: *ConfigWatcher) bool {
    const home = compat.getenv("HOME") orelse return false;
    var path_buf: [512:0]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.config/teru/teru.conf", .{home}) catch return false;
    path_buf[path.len] = 0;

    // Use C stat for portability
    var stat_buf: std.c.Stat = undefined;
    if (std.c.stat(@ptrCast(path_buf[0..path.len :0]), &stat_buf) != 0) return false;

    const mtime: i128 = @as(i128, stat_buf.mtim.sec) * std.time.ns_per_s + stat_buf.mtim.nsec;
    if (self.last_mtime == 0) {
        self.last_mtime = mtime;
        return false;
    }
    if (mtime != self.last_mtime) {
        self.last_mtime = mtime;
        return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────

test "ConfigWatcher init returns null gracefully when no config" {
    if (ConfigWatcher.init()) |*w| {
        var watcher = w.*;
        defer watcher.deinit();
        try std.testing.expect(!watcher.poll());
    }
}
