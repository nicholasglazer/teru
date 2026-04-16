//! MCP helper functions — JSON parsing, escaping, and filesystem utilities.
//!
//! Extracted from McpServer.zig to reduce coupling. These are pure functions
//! that don't depend on McpServer state (no `self` parameter).

const std = @import("std");
const compat = @import("../compat.zig");

/// Escape a string for safe embedding inside a JSON string value.
/// Handles: " \ \n \r \t and strips control chars below 0x20.
pub fn jsonEscapeString(input: []const u8, output: []u8) []const u8 {
    var out_pos: usize = 0;
    for (input) |c| {
        if (out_pos + 2 > output.len) break;
        switch (c) {
            '"' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = '"';
                out_pos += 1;
            },
            '\\' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = '\\';
                out_pos += 1;
            },
            '\n' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = 'n';
                out_pos += 1;
            },
            '\r' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = 'r';
                out_pos += 1;
            },
            '\t' => {
                output[out_pos] = '\\';
                out_pos += 1;
                output[out_pos] = 't';
                out_pos += 1;
            },
            else => {
                if (c >= 0x20) {
                    output[out_pos] = c;
                    out_pos += 1;
                }
                // Skip control chars
            },
        }
    }
    return output[0..out_pos];
}

/// Format a JSON-RPC 2.0 error response into `buf`.
/// Returns the formatted slice, or a static fallback on overflow.
pub fn jsonRpcError(buf: []u8, id: ?[]const u8, code: i32, message: []const u8) []const u8 {
    const id_str = id orelse "null";
    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","error":{{"code":{d},"message":"{s}"}},"id":{s}}}
    , .{ code, message, id_str }) catch "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"},\"id\":null}";
}

/// Extract a top-level `"key":"value"` string from JSON.
/// Returns the unquoted value slice, or null if not found.
pub fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key":"value" pattern
    // Build the search pattern "key":"
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, needle) orelse return null;
    const after_key = key_pos + needle.len;

    // Skip whitespace
    var i = after_key;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len or json[i] != '"') return null;
    i += 1; // skip opening quote

    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {
        if (json[i] == '\\') i += 1; // skip escaped char
    }
    if (i >= json.len) return null;

    return json[start..i];
}

/// Extract a `"key":"value"` string, searching first within `"arguments"` then top-level.
pub fn extractNestedJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Same as extractJsonString but searches for the key within "arguments" or at top level
    // First try within "arguments" block
    if (std.mem.indexOf(u8, json, "\"arguments\"")) |args_pos| {
        if (extractJsonString(json[args_pos..], key)) |val| return val;
    }
    return extractJsonString(json, key);
}

/// Extract a `"key":N` integer, searching first within `"arguments"` then top-level.
pub fn extractNestedJsonInt(json: []const u8, key: []const u8) ?u64 {
    // Find "key":N pattern (number value)
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;

    // Search in "arguments" first, then top-level
    const search_start = if (std.mem.indexOf(u8, json, "\"arguments\"")) |ap| ap else 0;
    const key_pos = std.mem.indexOf(u8, json[search_start..], needle) orelse
        std.mem.indexOf(u8, json, needle) orelse return null;

    const after_key = search_start + key_pos + needle.len;

    var i = after_key;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len) return null;

    // Could be a number
    const start = i;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
    if (i == start) return null;

    return std.fmt.parseInt(u64, json[start..i], 10) catch null;
}

/// Check if a config file line starts with `key` followed by whitespace or `=`.
pub fn lineMatchesKey(line: []const u8, key: []const u8) bool {
    // Trim leading whitespace
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    const trimmed = line[start..];
    if (trimmed.len < key.len) return false;
    if (!std.mem.startsWith(u8, trimmed, key)) return false;
    // After key, expect whitespace or '='
    if (trimmed.len == key.len) return true;
    const next = trimmed[key.len];
    return next == ' ' or next == '=' or next == '\t';
}

/// Ensure parent directory exists using C mkdir (recursive).
/// Thin forwarder to compat so callers outside agent/ (compositor, main)
/// share one mkdir-p implementation.
pub fn ensureParentDirC(path: []const u8) void {
    compat.ensureParentDirC(path);
}

/// Unescape JSON string escape sequences: \n \r \t \\ \"
pub fn unescapeJson(src: []const u8, dst: []u8) []const u8 {
    var di: usize = 0;
    var si: usize = 0;
    while (si < src.len and di < dst.len) {
        if (src[si] == '\\' and si + 1 < src.len) {
            switch (src[si + 1]) {
                'n' => {
                    dst[di] = '\n';
                    di += 1;
                    si += 2;
                },
                'r' => {
                    dst[di] = '\r';
                    di += 1;
                    si += 2;
                },
                't' => {
                    dst[di] = '\t';
                    di += 1;
                    si += 2;
                },
                '\\' => {
                    dst[di] = '\\';
                    di += 1;
                    si += 2;
                },
                '"' => {
                    dst[di] = '"';
                    di += 1;
                    si += 2;
                },
                else => {
                    dst[di] = src[si];
                    di += 1;
                    si += 1;
                },
            }
        } else {
            dst[di] = src[si];
            di += 1;
            si += 1;
        }
    }
    return dst[0..di];
}

// ── Tests ──────────────────────────────────────────────────────

const t = std.testing;

test "extractJsonString basic" {
    const json = "{\"method\":\"tools/list\",\"id\":1}";
    const method = extractJsonString(json, "method");
    try t.expect(method != null);
    try t.expectEqualStrings("tools/list", method.?);
}

test "extractJsonString with spaces" {
    const json = "{\"method\": \"tools/call\", \"id\": 2}";
    const method = extractJsonString(json, "method");
    try t.expect(method != null);
    try t.expectEqualStrings("tools/call", method.?);
}

test "extractJsonString missing key" {
    const json = "{\"method\":\"tools/list\"}";
    try t.expectEqual(@as(?[]const u8, null), extractJsonString(json, "missing"));
}

test "extractNestedJsonInt" {
    const json = "{\"params\":{\"name\":\"teru_read_output\",\"arguments\":{\"pane_id\":3,\"lines\":20}}}";
    const pane_id = extractNestedJsonInt(json, "pane_id");
    try t.expect(pane_id != null);
    try t.expectEqual(@as(u64, 3), pane_id.?);

    const lines = extractNestedJsonInt(json, "lines");
    try t.expect(lines != null);
    try t.expectEqual(@as(u64, 20), lines.?);
}

test "extractNestedJsonString" {
    const json = "{\"params\":{\"name\":\"teru_send_input\",\"arguments\":{\"pane_id\":1,\"text\":\"hello\"}}}";
    const text = extractNestedJsonString(json, "text");
    try t.expect(text != null);
    try t.expectEqualStrings("hello", text.?);

    const name = extractNestedJsonString(json, "name");
    try t.expect(name != null);
    try t.expectEqualStrings("teru_send_input", name.?);
}

test "jsonEscapeString" {
    var buf: [256]u8 = undefined;

    const result1 = jsonEscapeString("hello world", &buf);
    try t.expectEqualStrings("hello world", result1);

    const result2 = jsonEscapeString("line1\nline2", &buf);
    try t.expectEqualStrings("line1\\nline2", result2);

    const result3 = jsonEscapeString("a\"b\\c", &buf);
    try t.expectEqualStrings("a\\\"b\\\\c", result3);
}

test "jsonEscapeString quotes and backslash" {
    var buf: [256]u8 = undefined;
    const result = jsonEscapeString("hello \"world\"", &buf);
    try t.expectEqualStrings("hello \\\"world\\\"", result);

    const result2 = jsonEscapeString("path\\to\\file", &buf);
    try t.expectEqualStrings("path\\\\to\\\\file", result2);

    const result3 = jsonEscapeString("{\"key\":\"val\"}", &buf);
    try t.expectEqualStrings("{\\\"key\\\":\\\"val\\\"}", result3);
}

test "jsonRpcError" {
    var buf: [512]u8 = undefined;
    const result = jsonRpcError(&buf, "1", -32601, "Method not found");
    try t.expect(std.mem.indexOf(u8, result, "-32601") != null);
    try t.expect(std.mem.indexOf(u8, result, "Method not found") != null);
    try t.expect(std.mem.indexOf(u8, result, "\"id\":1") != null);
}

test "lineMatchesKey" {
    try t.expect(lineMatchesKey("font_size = 14", "font_size"));
    try t.expect(lineMatchesKey("  font_size = 14", "font_size"));
    try t.expect(lineMatchesKey("font_size=14", "font_size"));
    try t.expect(lineMatchesKey("font_size\t= 14", "font_size"));
    try t.expect(!lineMatchesKey("font_size_extra = 14", "font_size"));
    try t.expect(!lineMatchesKey("bg = #000", "font_size"));
    try t.expect(!lineMatchesKey("", "font_size"));
}

test "unescapeJson" {
    var buf: [256]u8 = undefined;

    const r1 = unescapeJson("hello\\nworld", &buf);
    try t.expectEqualStrings("hello\nworld", r1);

    const r2 = unescapeJson("tab\\there", &buf);
    try t.expectEqualStrings("tab\there", r2);

    const r3 = unescapeJson("a\\\"b\\\\c", &buf);
    try t.expectEqualStrings("a\"b\\c", r3);

    const r4 = unescapeJson("no escapes", &buf);
    try t.expectEqualStrings("no escapes", r4);
}

test "ensureParentDirC no crash on edge cases" {
    // Just verify it doesn't crash — actual dir creation needs root or tmpdir
    ensureParentDirC("/tmp/teru-test-mcp-tools/sub/file.txt");
    ensureParentDirC("no-slash");
    ensureParentDirC("/root-only");
    ensureParentDirC("");
}
