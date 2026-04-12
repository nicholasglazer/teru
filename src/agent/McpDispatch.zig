//! Tool dispatch table for the teru agent MCP server.
//!
//! Single source of truth for every tool: its name, its JSON schema
//! fragment (used in `tools/list`), and the handler that implements it.
//!
//! The handler table is exported by `McpServer.zig` (handlers close over
//! `*McpServer` state). This file only carries the *declaration* surface
//! — names and schemas — which is transport-agnostic and reusable by:
//!   • the MCP HTTP / stdio path in `McpServer.zig`
//!   • the in-band OSC-query path in `in_band.zig` (Tier 3)
//!   • any future transport (plain Unix line-JSON, WebSocket, …)
//!
//! Adding a tool is one entry below + one wrapper in McpServer's
//! dispatch array. A missing wrapper is a compile error (array length
//! mismatch against `tools` here), which is the point.

const std = @import("std");

pub const Tool = struct {
    /// Tool identifier exposed to clients (e.g. `teru_list_panes`).
    name: []const u8,
    /// JSON object body — everything between the opening `{` and closing
    /// `}` in a `tools/list` entry, *excluding* the `"name":"..."` pair.
    /// Must start with `"description":"..."`.
    schema_json: []const u8,
};

/// Every tool exposed over MCP. Order matches `McpServer.dispatch_table`.
pub const tools = [_]Tool{
    .{
        .name = "teru_list_panes",
        .schema_json =
        \\"description":"List all panes with id, workspace, agent name, status","inputSchema":{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "teru_read_output",
        .schema_json =
        \\"description":"Get recent N lines from a pane scrollback","inputSchema":{"type":"object","properties":{"pane_id":{"type":"integer"},"lines":{"type":"integer","default":50}},"required":["pane_id"]}
        ,
    },
    .{
        .name = "teru_get_graph",
        .schema_json =
        \\"description":"Get the process graph as JSON","inputSchema":{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "teru_send_input",
        .schema_json =
        \\"description":"Write text to a pane PTY stdin","inputSchema":{"type":"object","properties":{"pane_id":{"type":"integer"},"text":{"type":"string"}},"required":["pane_id","text"]}
        ,
    },
    .{
        .name = "teru_create_pane",
        .schema_json =
        \\"description":"Spawn a new pane in a workspace","inputSchema":{"type":"object","properties":{"workspace":{"type":"integer","default":0},"direction":{"type":"string","enum":["vertical","horizontal"],"default":"vertical"},"command":{"type":"string","description":"Command to run (default: user shell)"},"cwd":{"type":"string","description":"Working directory (default: active pane CWD)"}},"required":[]}
        ,
    },
    .{
        .name = "teru_broadcast",
        .schema_json =
        \\"description":"Send text to all panes in a workspace","inputSchema":{"type":"object","properties":{"workspace":{"type":"integer"},"text":{"type":"string"}},"required":["workspace","text"]}
        ,
    },
    .{
        .name = "teru_send_keys",
        .schema_json =
        \\"description":"Send named keystrokes to a pane (e.g. enter, ctrl+c, up, f1)","inputSchema":{"type":"object","properties":{"pane_id":{"type":"integer"},"keys":{"type":"array","items":{"type":"string"}}},"required":["pane_id","keys"]}
        ,
    },
    .{
        .name = "teru_get_state",
        .schema_json =
        \\"description":"Query terminal state for a pane (cursor, size, modes, title)","inputSchema":{"type":"object","properties":{"pane_id":{"type":"integer"}},"required":["pane_id"]}
        ,
    },
    .{
        .name = "teru_focus_pane",
        .schema_json =
        \\"description":"Focus a specific pane by ID","inputSchema":{"type":"object","properties":{"pane_id":{"type":"integer"}},"required":["pane_id"]}
        ,
    },
    .{
        .name = "teru_close_pane",
        .schema_json =
        \\"description":"Close a pane by ID","inputSchema":{"type":"object","properties":{"pane_id":{"type":"integer"}},"required":["pane_id"]}
        ,
    },
    .{
        .name = "teru_switch_workspace",
        .schema_json =
        \\"description":"Switch the active workspace (0-9)","inputSchema":{"type":"object","properties":{"workspace":{"type":"integer"}},"required":["workspace"]}
        ,
    },
    .{
        .name = "teru_scroll",
        .schema_json =
        \\"description":"Scroll a pane's scrollback (up/down/bottom)","inputSchema":{"type":"object","properties":{"pane_id":{"type":"integer"},"direction":{"type":"string","enum":["up","down","bottom"]},"lines":{"type":"integer","default":10}},"required":["pane_id","direction"]}
        ,
    },
    .{
        .name = "teru_wait_for",
        .schema_json =
        \\"description":"Check if text pattern exists in pane output (non-blocking)","inputSchema":{"type":"object","properties":{"pane_id":{"type":"integer"},"pattern":{"type":"string"},"lines":{"type":"integer","default":20}},"required":["pane_id","pattern"]}
        ,
    },
    .{
        .name = "teru_set_layout",
        .schema_json =
        \\"description":"Set the layout for a workspace. Layouts: master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion","inputSchema":{"type":"object","properties":{"workspace":{"type":"integer","default":0},"layout":{"type":"string","enum":["master-stack","grid","monocle","dishes","spiral","three-col","columns","accordion"]}},"required":["layout"]}
        ,
    },
    .{
        .name = "teru_set_config",
        .schema_json =
        \\"description":"Set a config value. Writes to teru.conf and triggers hot-reload. Keys: font_size, padding, opacity, theme, cursor_shape, cursor_blink, scroll_speed, bold_is_bright, bell, copy_on_select, bg, fg, cursor_color, attention_color","inputSchema":{"type":"object","properties":{"key":{"type":"string"},"value":{"type":"string"}},"required":["key","value"]}
        ,
    },
    .{
        .name = "teru_get_config",
        .schema_json =
        \\"description":"Get current live config values as JSON","inputSchema":{"type":"object","properties":{},"required":[]}
        ,
    },
    .{
        .name = "teru_session_save",
        .schema_json =
        \\"description":"Save current session state to a .tsess file. Captures workspaces, layouts, pane CWDs and commands.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Session name (saved to ~/.config/teru/sessions/NAME.tsess)"}},"required":["name"]}
        ,
    },
    .{
        .name = "teru_session_restore",
        .schema_json =
        \\"description":"Restore a session from a .tsess file. Idempotent: panes matched by role are not duplicated.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Session name to restore"}},"required":["name"]}
        ,
    },
    .{
        .name = "teru_screenshot",
        .schema_json =
        \\"description":"Capture the terminal framebuffer as a PNG image file. Returns the file path and dimensions. Only works in windowed mode (X11/Wayland).","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Output file path (default: /tmp/teru-screenshot.png)"}},"required":[]}
        ,
    },
};

/// The complete `tools/list` JSON array body (everything between the `[`
/// and `]`), assembled once at compile time.
pub const tools_list_body: []const u8 = blk: {
    @setEvalBranchQuota(20000);
    var out: []const u8 = "";
    for (tools, 0..) |t, i| {
        if (i > 0) out = out ++ ",";
        out = out ++ "{\"name\":\"" ++ t.name ++ "\"," ++ t.schema_json ++ "}";
    }
    break :blk out;
};

/// O(log n) tool-name → table-index lookup. Returned value is the index
/// into `tools` (and into `McpServer.dispatch_table`, which is 1:1).
pub const tool_index = std.StaticStringMap(usize).initComptime(blk: {
    var entries: [tools.len]struct { []const u8, usize } = undefined;
    for (tools, 0..) |t, i| entries[i] = .{ t.name, i };
    break :blk entries;
});

// ── Inline tests ─────────────────────────────────────────────────

test "every tool has a lookup entry" {
    for (tools, 0..) |t, i| {
        const got = tool_index.get(t.name) orelse return error.Missing;
        try std.testing.expectEqual(i, got);
    }
}

test "tools_list_body starts with { and parses as non-empty" {
    try std.testing.expect(tools_list_body.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), tools_list_body[0]);
    // Contains every tool's name
    for (tools) |t| {
        try std.testing.expect(std.mem.indexOf(u8, tools_list_body, t.name) != null);
    }
}

test "unknown tool returns null from index" {
    try std.testing.expect(tool_index.get("definitely_not_a_tool") == null);
}
