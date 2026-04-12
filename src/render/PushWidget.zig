//! Push widget state for bars.
//!
//! Users register widgets externally (via MCP in teruwm) and push text
//! updates when their state changes — complementing the polling-based
//! `{exec:N:cmd}` widget. Referenced from a bar format string with
//! `{widget:name}`.
//!
//! Storage policy: fixed-size arrays, no allocations. A widget has a
//! short name, a bounded text payload, and an optional semantic class
//! that the renderer maps to a ColorScheme palette entry. Unknown
//! classes fall back to `fg`. Missing widgets render as empty string.

const std = @import("std");

// Storage budgets. Chosen to match existing compositor conventions:
// name matches NodeRegistry.name[32], text matches BarWidget.max_exec_output.
pub const max_widgets = 32;
pub const max_name = 32;
pub const max_text = 128;

/// Semantic color class for a push widget. Matches the vocabulary used by
/// polybar / waybar so scripts and daemons ported from those tools map
/// straight across. The renderer resolves each class to a ColorScheme
/// palette entry; users override colors by changing the theme.
pub const Class = enum(u8) {
    none,      // fg (default text color)
    muted,     // ansi[8] (dim)
    info,      // ansi[4] (blue)
    success,   // ansi[2] (green)
    warning,   // ansi[3] (yellow)
    critical,  // ansi[1] (red)
    accent,    // ansi[6] (cyan)

    /// Parse a class from its string name. Also accepts common synonyms
    /// (`dim` for muted, `good` for success, `error` for critical).
    pub fn fromString(s: []const u8) Class {
        if (s.len == 0) return .none;
        const eql = std.mem.eql;
        if (eql(u8, s, "none")) return .none;
        if (eql(u8, s, "muted") or eql(u8, s, "dim")) return .muted;
        if (eql(u8, s, "info")) return .info;
        if (eql(u8, s, "success") or eql(u8, s, "good") or eql(u8, s, "ok")) return .success;
        if (eql(u8, s, "warning") or eql(u8, s, "warn")) return .warning;
        if (eql(u8, s, "critical") or eql(u8, s, "error") or eql(u8, s, "bad")) return .critical;
        if (eql(u8, s, "accent") or eql(u8, s, "highlight")) return .accent;
        return .none;
    }
};

/// One registered push widget. Stored inline in a fixed-size array
/// (no allocations). `used` discriminates empty slots; `name_len` / `text_len`
/// cap valid content inside the static buffers.
pub const PushWidget = struct {
    name_buf: [max_name]u8 = undefined,
    name_len: u8 = 0,
    text_buf: [max_text]u8 = undefined,
    text_len: u8 = 0,
    class: Class = .none,
    /// Monotonic nanosecond timestamp of last set. Exposed via
    /// teruwm_list_widgets for diagnostics; not used for rendering yet.
    /// i64 (not i128) so the enclosing Server keeps natural alignment
    /// for @fieldParentPtr lookups in wlroots listener callbacks.
    last_update_ns: i64 = 0,
    used: bool = false,

    pub fn name(self: *const PushWidget) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn text(self: *const PushWidget) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

test "Class.fromString standard names" {
    try std.testing.expectEqual(Class.none, Class.fromString(""));
    try std.testing.expectEqual(Class.none, Class.fromString("none"));
    try std.testing.expectEqual(Class.muted, Class.fromString("muted"));
    try std.testing.expectEqual(Class.muted, Class.fromString("dim"));
    try std.testing.expectEqual(Class.info, Class.fromString("info"));
    try std.testing.expectEqual(Class.success, Class.fromString("success"));
    try std.testing.expectEqual(Class.success, Class.fromString("good"));
    try std.testing.expectEqual(Class.warning, Class.fromString("warning"));
    try std.testing.expectEqual(Class.critical, Class.fromString("critical"));
    try std.testing.expectEqual(Class.critical, Class.fromString("error"));
    try std.testing.expectEqual(Class.accent, Class.fromString("accent"));
    // Unknown falls back to none rather than crashing
    try std.testing.expectEqual(Class.none, Class.fromString("wat"));
}
