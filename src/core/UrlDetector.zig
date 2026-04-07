//! URL detection in terminal grid cells.
//!
//! Scans grid rows for URL patterns (http:// and https://) and returns
//! match positions. Regex-free — uses simple prefix matching and
//! character-class termination.
//!
//! Used for Ctrl+click URL opening (xdg-open) and optional underline
//! highlighting during rendering.

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const compat = @import("../compat.zig");
const Grid = @import("Grid.zig");

pub const UrlMatch = struct {
    row: u16,
    start_col: u16,
    end_col: u16, // exclusive
};

/// Characters that terminate a URL.
fn isUrlTerminator(c: u21) bool {
    return switch (c) {
        ' ', '\t', '"', '\'', '<', '>', '|', '{', '}', '^', '`' => true,
        else => c < 33, // control chars and NUL
    };
}

/// Strip trailing punctuation that's likely not part of the URL.
/// For example, a URL followed by ")" or "." in prose.
fn stripTrailingPunct(cells: []const Grid.Cell, start: u16, end: u16) u16 {
    var e = end;
    while (e > start) {
        const c = cells[e - 1].char;
        switch (c) {
            '.', ',', ';', ':', '!', '?' => e -= 1,
            ')' => {
                // Only strip trailing ')' if there's no matching '(' in the URL
                var parens: i32 = 0;
                for (cells[start..e]) |cell| {
                    if (cell.char == '(') parens += 1;
                    if (cell.char == ')') parens -= 1;
                }
                if (parens < 0) {
                    e -= 1;
                } else break;
            },
            ']' => {
                var brackets: i32 = 0;
                for (cells[start..e]) |cell| {
                    if (cell.char == '[') brackets += 1;
                    if (cell.char == ']') brackets -= 1;
                }
                if (brackets < 0) {
                    e -= 1;
                } else break;
            },
            else => break,
        }
    }
    return e;
}

/// Scan a row of cells for URL patterns.
/// Returns the number of matches found (up to buf.len).
pub fn scanRow(cells: []const Grid.Cell, cols: u16, row: u16, buf: []UrlMatch) usize {
    var count: usize = 0;
    var col: u16 = 0;

    while (col + 7 <= cols and count < buf.len) { // "http://" is 7 chars minimum
        // Check for 'h' as first char
        const c0 = cells[col].char;
        if (c0 != 'h') {
            col += 1;
            continue;
        }

        // Try to match "http://" or "https://"
        var prefix_len: u16 = 0;
        if (col + 8 <= cols and matchPrefix(cells[col..col + 8], "https://")) {
            prefix_len = 8;
        } else if (col + 7 <= cols and matchPrefix(cells[col..col + 7], "http://")) {
            prefix_len = 7;
        }

        if (prefix_len == 0) {
            col += 1;
            continue;
        }

        // Found URL start — scan forward until terminator
        var end: u16 = col + prefix_len;
        while (end < cols) {
            if (isUrlTerminator(cells[end].char)) break;
            end += 1;
        }

        // Must have at least 1 char after the prefix
        if (end > col + prefix_len) {
            const trimmed_end = stripTrailingPunct(cells, col, end);
            if (trimmed_end > col + prefix_len) {
                buf[count] = .{
                    .row = row,
                    .start_col = col,
                    .end_col = trimmed_end,
                };
                count += 1;
                col = trimmed_end;
                continue;
            }
        }

        col = end;
    }

    return count;
}

/// Match a prefix string against cell chars.
fn matchPrefix(cells: []const Grid.Cell, prefix: []const u8) bool {
    if (cells.len < prefix.len) return false;
    for (prefix, 0..) |ch, i| {
        if (cells[i].char != ch) return false;
    }
    return true;
}

/// Extract URL text from cells into a buffer.
/// Returns the number of bytes written.
pub fn extractUrl(cells: []const Grid.Cell, match: UrlMatch, buf: []u8) usize {
    var len: usize = 0;
    var col = match.start_col;
    while (col < match.end_col and len < buf.len) {
        const cp = cells[col].char;
        if (cp < 128) {
            buf[len] = @intCast(cp);
            len += 1;
        }
        col += 1;
    }
    return len;
}

// Win32 shell API extern (link against shell32)
extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    lpOperation: ?[*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: c_int,
) callconv(.c) isize;
const SW_SHOW: c_int = 5;

/// Open a URL with the platform's default browser (fire-and-forget).
pub fn openUrl(url: []const u8) void {
    if (builtin.os.tag == .windows) {
        // Convert URL (ASCII) to UTF-16 for ShellExecuteW
        var url_w: [2049]u16 = undefined;
        var i: usize = 0;
        for (url) |byte| {
            if (i >= url_w.len - 1) break;
            url_w[i] = byte;
            i += 1;
        }
        url_w[i] = 0;
        const open_str = std.unicode.utf8ToUtf16LeStringLiteral("open");
        _ = ShellExecuteW(null, open_str, @ptrCast(url_w[0..i :0]), null, null, SW_SHOW);
        return;
    }

    var path_buf: [2048]u8 = undefined;
    if (url.len >= path_buf.len - 1) return;
    @memcpy(path_buf[0..url.len], url);
    path_buf[url.len] = 0;

    const opener: [*:0]const u8 = switch (builtin.os.tag) {
        .macos => "/usr/bin/open",
        else => "/usr/bin/xdg-open", // Linux
    };
    const argv = [_:null]?[*:0]const u8{
        opener,
        @ptrCast(path_buf[0..url.len :0]),
        null,
    };

    const pid = compat.posixFork();
    if (pid < 0) return;
    if (pid == 0) {
        const devnull = posix.system.open("/dev/null", .{ .ACCMODE = .WRONLY }, @as(std.posix.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, posix.STDOUT_FILENO);
            _ = std.c.dup2(devnull, posix.STDERR_FILENO);
            _ = posix.system.close(devnull);
        }
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = posix.system.execve(argv[0].?, &argv, @ptrCast(envp));
        compat.posixExit(1);
    }
}

/// Find a URL at a specific grid position.
/// Returns the match if the position is inside a URL, null otherwise.
pub fn findUrlAt(grid: *const Grid, row: u16, col: u16) ?UrlMatch {
    if (row >= grid.rows) return null;
    const row_start = @as(usize, row) * @as(usize, grid.cols);
    const row_cells = grid.cells[row_start..][0..grid.cols];

    var matches: [8]UrlMatch = undefined;
    const count = scanRow(row_cells, grid.cols, row, &matches);

    for (matches[0..count]) |m| {
        if (col >= m.start_col and col < m.end_col) return m;
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────

test "scanRow: detect https URL" {
    const allocator = std.testing.allocator;
    const cols: u16 = 40;
    const cells = try allocator.alloc(Grid.Cell, cols);
    defer allocator.free(cells);
    for (cells) |*c| c.* = Grid.Cell.blank();

    // Write "https://example.com" starting at col 5
    const url = "https://example.com";
    for (url, 0..) |ch, i| {
        cells[5 + i].char = ch;
    }

    var matches: [4]UrlMatch = undefined;
    const count = scanRow(cells, cols, 0, &matches);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u16, 5), matches[0].start_col);
    try std.testing.expectEqual(@as(u16, 24), matches[0].end_col);
}

test "scanRow: detect http URL" {
    const allocator = std.testing.allocator;
    const cols: u16 = 30;
    const cells = try allocator.alloc(Grid.Cell, cols);
    defer allocator.free(cells);
    for (cells) |*c| c.* = Grid.Cell.blank();

    const url = "http://foo.bar/baz";
    for (url, 0..) |ch, i| {
        cells[0 + i].char = ch;
    }

    var matches: [4]UrlMatch = undefined;
    const count = scanRow(cells, cols, 2, &matches);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u16, 0), matches[0].start_col);
    try std.testing.expectEqual(@as(u16, 18), matches[0].end_col);
    try std.testing.expectEqual(@as(u16, 2), matches[0].row);
}

test "scanRow: strip trailing punctuation" {
    const allocator = std.testing.allocator;
    const cols: u16 = 40;
    const cells = try allocator.alloc(Grid.Cell, cols);
    defer allocator.free(cells);
    for (cells) |*c| c.* = Grid.Cell.blank();

    // "https://example.com)."
    const url = "https://example.com).";
    for (url, 0..) |ch, i| {
        cells[i].char = ch;
    }

    var matches: [4]UrlMatch = undefined;
    const count = scanRow(cells, cols, 0, &matches);

    try std.testing.expectEqual(@as(usize, 1), count);
    // Should strip ")." since no matching "(" in URL
    try std.testing.expectEqual(@as(u16, 19), matches[0].end_col);
}

test "scanRow: preserve parens in URL" {
    const allocator = std.testing.allocator;
    const cols: u16 = 60;
    const cells = try allocator.alloc(Grid.Cell, cols);
    defer allocator.free(cells);
    for (cells) |*c| c.* = Grid.Cell.blank();

    // Wikipedia-style URL with parens: "https://en.wikipedia.org/wiki/Zig_(lang)"
    const url = "https://en.wikipedia.org/wiki/Zig_(lang)";
    for (url, 0..) |ch, i| {
        cells[i].char = ch;
    }

    var matches: [4]UrlMatch = undefined;
    const count = scanRow(cells, cols, 0, &matches);

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u16, @intCast(url.len)), matches[0].end_col);
}

test "scanRow: no match for non-URL text" {
    const allocator = std.testing.allocator;
    const cols: u16 = 20;
    const cells = try allocator.alloc(Grid.Cell, cols);
    defer allocator.free(cells);
    for (cells) |*c| c.* = Grid.Cell.blank();

    const text = "hello world";
    for (text, 0..) |ch, i| {
        cells[i].char = ch;
    }

    var matches: [4]UrlMatch = undefined;
    const count = scanRow(cells, cols, 0, &matches);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "scanRow: multiple URLs in one row" {
    const allocator = std.testing.allocator;
    const cols: u16 = 80;
    const cells = try allocator.alloc(Grid.Cell, cols);
    defer allocator.free(cells);
    for (cells) |*c| c.* = Grid.Cell.blank();

    const text = "see https://a.com and http://b.org/path for info";
    for (text, 0..) |ch, i| {
        if (i >= cols) break;
        cells[i].char = ch;
    }

    var matches: [4]UrlMatch = undefined;
    const count = scanRow(cells, cols, 0, &matches);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "extractUrl: extracts ASCII text" {
    const allocator = std.testing.allocator;
    const cols: u16 = 30;
    const cells = try allocator.alloc(Grid.Cell, cols);
    defer allocator.free(cells);
    for (cells) |*c| c.* = Grid.Cell.blank();

    const url = "https://example.com";
    for (url, 0..) |ch, i| {
        cells[i].char = ch;
    }

    var matches: [4]UrlMatch = undefined;
    const count = scanRow(cells, cols, 0, &matches);
    try std.testing.expectEqual(@as(usize, 1), count);

    var buf: [256]u8 = undefined;
    const len = extractUrl(cells, matches[0], &buf);
    try std.testing.expectEqualStrings("https://example.com", buf[0..len]);
}

test "findUrlAt: hit and miss" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 3, 40);
    defer grid.deinit(allocator);

    // Write a URL at row 1, starting at col 2
    const url = "https://test.dev/page";
    for (url, 0..) |ch, i| {
        grid.cellAt(1, @intCast(2 + i)).char = ch;
    }

    // Hit: click inside URL
    const hit = findUrlAt(&grid, 1, 10);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u16, 2), hit.?.start_col);

    // Miss: click outside URL
    const miss = findUrlAt(&grid, 1, 0);
    try std.testing.expect(miss == null);

    // Miss: wrong row
    const miss2 = findUrlAt(&grid, 0, 10);
    try std.testing.expect(miss2 == null);
}
