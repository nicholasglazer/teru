//! Platform PTY dispatch — selects POSIX or ConPTY at comptime.
const builtin = @import("builtin");
pub const Pty = if (builtin.os.tag == .windows)
    @import("WinPty.zig")
else
    @import("PosixPty.zig");
pub const RemotePty = @import("RemotePty.zig");
