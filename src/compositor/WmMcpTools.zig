//! Compositor MCP tool implementations — request thunks and tool
//! bodies for WmMcpServer. Split out of WmMcpServer.zig (which now
//! holds only socket lifecycle + dispatch wiring). Each `thunk*`
//! unpacks the JSON params object and calls its `tool*`; the
//! dispatch table in WmMcpServer.zig routes by name to the `pub`
//! thunks here. `self` is always the owning `*WmMcpServer`.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const teru = @import("teru");
const compat = teru.compat;
const ipc = teru.ipc;
const png = teru.png;
const wlr = @import("wlr.zig");
const Server = @import("Server.zig");
const TerminalPane = @import("TerminalPane.zig");
const ServerFont = @import("ServerFont.zig");
const NodeRegistry = @import("Node.zig");
const tools = teru.McpTools;
const version = teru.build_options.version;

// ── JSON helper aliases ───────────────────────────────────────
//
// The canonical implementations live in src/agent/McpTools.zig;
// we alias the ones this server calls frequently so the call sites
// below stay short. Signed coordinates flow through the i64 variant;
// ids / workspace indexes use the u64 one.
const extractJsonString = tools.extractJsonString;
const extractJsonId = tools.extractJsonId;
const extractJsonObject = tools.extractJsonObject;
const extractNestedJsonString = tools.extractNestedJsonString;
const extractNestedJsonInt = tools.extractNestedJsonIntSigned; // i64
const extractNestedJsonBool = tools.extractNestedJsonBool; // whitespace-tolerant
const jsonRpcError = tools.jsonRpcError;
const okText = tools.okText; // success-envelope formatter (see McpTools.okText)
const jsonEscapeString = tools.jsonEscapeString;
const findBody = tools.findHttpBody;
const parseContentLength = tools.parseHttpContentLength;

const WmMcpServer = @import("WmMcpServer.zig");

const max_request: usize = 65536;
const max_response: usize = 65536;
const socket_path_max: usize = 108;

// ── Thunks (arg unpacking; uniform signature) ──────────────────

pub fn thunkListWindows(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return toolListWindows(self, buf, id);
}

pub fn thunkSpawnTerminal(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    // Default to the ACTIVE workspace, not a hardcoded 0: an agent that
    // switched workspaces and spawns "here" expects the terminal where it's
    // looking, not silently on ws0. An explicit, in-range "workspace" overrides.
    const ws: u8 = blk: {
        if (extractNestedJsonInt(p, "workspace")) |w| {
            if (w >= 0 and w < 10) break :blk @intCast(w);
        }
        break :blk self.server.layout_engine.active_workspace;
    };
    return toolSpawnTerminal(self, ws, buf, id);
}

pub fn thunkCloseWindow(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const nid = extractNestedJsonInt(p, "node_id") orelse
        return jsonRpcError(buf, id, -32602, "Missing node_id");
    return toolCloseWindow(self, @intCast(nid), buf, id);
}

pub fn thunkFocusWindow(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const nid = extractNestedJsonInt(p, "node_id") orelse
        return jsonRpcError(buf, id, -32602, "Missing node_id");
    return toolFocusWindow(self, @intCast(nid), buf, id);
}

pub fn thunkMoveToWorkspace(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const nid = extractNestedJsonInt(p, "node_id") orelse
        return jsonRpcError(buf, id, -32602, "Missing node_id");
    const ws = extractNestedJsonInt(p, "workspace") orelse
        return jsonRpcError(buf, id, -32602, "Missing workspace");
    return toolMoveToWorkspace(self, @intCast(nid), @intCast(ws), buf, id);
}

pub fn thunkListWorkspaces(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return toolListWorkspaces(self, buf, id);
}

pub fn thunkSwitchWorkspace(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const ws = extractNestedJsonInt(p, "workspace") orelse
        return jsonRpcError(buf, id, -32602, "Missing workspace");
    return toolSwitchWorkspace(self, @intCast(ws), buf, id);
}

pub fn thunkSetLayout(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const layout_str = extractNestedJsonString(p, "layout") orelse
        return jsonRpcError(buf, id, -32602, "Missing layout");
    const ws = extractNestedJsonInt(p, "workspace") orelse 0;
    return toolSetLayout(self, @intCast(ws), layout_str, buf, id);
}

pub fn thunkZoom(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const dir = extractNestedJsonString(p, "direction") orelse
        return jsonRpcError(buf, id, -32602, "Missing direction");
    return toolZoom(self, dir, buf, id);
}

fn toolZoom(self: *WmMcpServer, dir: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const target: teru.render.FontAtlas.ZoomTarget =
        if (std.mem.eql(u8, dir, "in")) .in
        else if (std.mem.eql(u8, dir, "out")) .out
        else if (std.mem.eql(u8, dir, "reset")) .reset
        else return jsonRpcError(buf, id, -32602, "direction must be in, out, or reset");
    const changed = ServerFont.applyFontZoom(self.server, target);
    if (changed) self.server.scheduleRender();
    return okText(buf, id, "{{\\\"changed\\\":{},\\\"font_size\\\":{d}}}", .{changed, self.server.font_size});
}

/// Per-pane font zoom for the FOCUSED terminal — same effect as Alt+scroll.
/// Only that pane's font changes; the bars and other panes are untouched.
pub fn thunkZoomFocused(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const dir = extractNestedJsonString(p, "direction") orelse
        return jsonRpcError(buf, id, -32602, "Missing direction");
    const target: teru.render.FontAtlas.ZoomTarget =
        if (std.mem.eql(u8, dir, "in")) .in else if (std.mem.eql(u8, dir, "out")) .out else if (std.mem.eql(u8, dir, "reset")) .reset else return jsonRpcError(buf, id, -32602, "direction must be in, out, or reset");
    const tp = self.server.focused_terminal orelse
        return jsonRpcError(buf, id, -32602, "no focused terminal pane");
    const changed = tp.zoomFont(target);
    const size: u16 = if (tp.pane_font_size != 0) tp.pane_font_size else self.server.font_size_base;
    return okText(buf, id, "{{\\\"changed\\\":{},\\\"pane_font_size\\\":{d}}}", .{ changed, size });
}

pub fn thunkGetConfig(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return toolGetConfig(self, buf, id);
}

pub fn thunkSetConfig(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const key = extractNestedJsonString(p, "key") orelse
        return jsonRpcError(buf, id, -32602, "Missing key");
    const value = extractNestedJsonString(p, "value") orelse
        return jsonRpcError(buf, id, -32602, "Missing value");
    return toolSetConfig(self, key, value, buf, id);
}

pub fn thunkScreenshot(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const path = extractNestedJsonString(p, "path") orelse "/tmp/teruwm-screenshot.png";
    return toolScreenshot(self, path, buf, id);
}

pub fn thunkNotify(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const message = extractNestedJsonString(p, "message") orelse
        return jsonRpcError(buf, id, -32602, "Missing message");
    return toolNotify(self, message, buf, id);
}

pub fn thunkReloadConfig(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return toolReloadConfig(self, buf, id);
}

pub fn thunkScreenshotPane(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const path = extractNestedJsonString(p, "path");
    return toolScreenshotPane(self, p, path, buf, id);
}

pub fn thunkSetName(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const new_name = extractNestedJsonString(p, "new_name") orelse
        return jsonRpcError(buf, id, -32602, "Missing new_name");
    return toolSetName(self, p, new_name, buf, id);
}

pub fn thunkPerf(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return toolPerf(self, buf, id);
}

pub fn thunkRestart(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return toolRestart(self, buf, id);
}

pub fn thunkQuit(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return toolQuit(self, buf, id);
}

pub fn thunkToggleBar(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const which = extractNestedJsonString(p, "which") orelse
        return jsonRpcError(buf, id, -32602, "Missing which (top|bottom)");
    return toolToggleBar(self, which, null, buf, id);
}

pub fn thunkSetBar(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const which = extractNestedJsonString(p, "which") orelse
        return jsonRpcError(buf, id, -32602, "Missing which (top|bottom)");
    const args = extractJsonObject(p, "arguments") orelse p;
    const enabled: bool = extractNestedJsonBool(args, "enabled");
    return toolToggleBar(self, which, enabled, buf, id);
}

pub fn thunkSetWidget(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const w_name = extractNestedJsonString(p, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing name");
    const w_text = extractNestedJsonString(p, "text") orelse
        return jsonRpcError(buf, id, -32602, "Missing text");
    const w_class = extractNestedJsonString(p, "class") orelse "";
    return toolSetWidget(self, w_name, w_text, w_class, buf, id);
}

pub fn thunkDeleteWidget(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const w_name = extractNestedJsonString(p, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing name");
    return toolDeleteWidget(self, w_name, buf, id);
}

pub fn thunkListWidgets(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return toolListWidgets(self, buf, id);
}

pub fn thunkTestDrag(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const fx = extractNestedJsonInt(p, "from_x") orelse
        return jsonRpcError(buf, id, -32602, "Missing from_x");
    const fy = extractNestedJsonInt(p, "from_y") orelse
        return jsonRpcError(buf, id, -32602, "Missing from_y");
    const tx = extractNestedJsonInt(p, "to_x") orelse
        return jsonRpcError(buf, id, -32602, "Missing to_x");
    const ty = extractNestedJsonInt(p, "to_y") orelse
        return jsonRpcError(buf, id, -32602, "Missing to_y");
    const args = extractJsonObject(p, "arguments") orelse p;
    const super_held = extractNestedJsonBool(args, "super");
    const button: u32 = blk: {
        const b = extractNestedJsonInt(p, "button") orelse break :blk 272;
        break :blk @intCast(b);
    };
    return toolTestDrag(self, @intCast(fx), @intCast(fy), @intCast(tx), @intCast(ty), super_held, button, buf, id);
}

pub fn thunkTestKey(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const action = extractNestedJsonString(p, "action") orelse
        return jsonRpcError(buf, id, -32602, "Missing action");
    return toolTestKey(self, action, buf, id);
}

pub fn thunkTestMove(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const x = extractNestedJsonInt(p, "x") orelse
        return jsonRpcError(buf, id, -32602, "Missing x");
    const y = extractNestedJsonInt(p, "y") orelse
        return jsonRpcError(buf, id, -32602, "Missing y");
    return toolTestMove(self, @intCast(x), @intCast(y), buf, id);
}

pub fn thunkMousePath(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const fx = extractNestedJsonInt(p, "from_x") orelse
        return jsonRpcError(buf, id, -32602, "Missing from_x");
    const fy = extractNestedJsonInt(p, "from_y") orelse
        return jsonRpcError(buf, id, -32602, "Missing from_y");
    const tx = extractNestedJsonInt(p, "to_x") orelse
        return jsonRpcError(buf, id, -32602, "Missing to_x");
    const ty = extractNestedJsonInt(p, "to_y") orelse
        return jsonRpcError(buf, id, -32602, "Missing to_y");
    const dur_raw = extractNestedJsonInt(p, "duration_ms");
    const dur: u32 = if (dur_raw) |d| @intCast(@max(0, d)) else self.server.wm_config.mouse_path_default_ms;
    const humanize_true = extractNestedJsonBool(p, "humanize");
    const humanize_false = std.mem.find(u8, p, "\"humanize\":false") != null;
    const humanize: bool = if (humanize_true) true else if (humanize_false) false else self.server.wm_config.mouse_humanize;
    const btn_raw = extractNestedJsonInt(p, "button");
    const btn: ?u32 = if (btn_raw) |b| @intCast(@max(0, b)) else null;
    const super_held = extractNestedJsonBool(p, "super");
    return toolMousePath(self, @intCast(fx), @intCast(fy), @intCast(tx), @intCast(ty), dur, humanize, btn, super_held, buf, id);
}

pub fn thunkClick(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const x = extractNestedJsonInt(p, "x") orelse
        return jsonRpcError(buf, id, -32602, "Missing x");
    const y = extractNestedJsonInt(p, "y") orelse
        return jsonRpcError(buf, id, -32602, "Missing y");
    const args_obj = extractJsonObject(p, "arguments") orelse p;
    const button_str = extractJsonString(args_obj, "button") orelse "left";
    const button: u32 = if (std.mem.eql(u8, button_str, "right")) 273 else if (std.mem.eql(u8, button_str, "middle")) 274 else 272;
    return toolClick(self, @intCast(x), @intCast(y), button, buf, id);
}

pub fn thunkType(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const text = extractNestedJsonString(p, "text") orelse
        return jsonRpcError(buf, id, -32602, "Missing text");
    return toolType(self, text, buf, id);
}

pub fn thunkPress(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const key = extractNestedJsonString(p, "key") orelse
        return jsonRpcError(buf, id, -32602, "Missing key");
    const args_obj = extractJsonObject(p, "arguments") orelse p;
    const ctrl = extractNestedJsonBool(args_obj, "ctrl");
    const shift = extractNestedJsonBool(args_obj, "shift");
    const alt = extractNestedJsonBool(args_obj, "alt");
    const sup = extractNestedJsonBool(args_obj, "super");
    return toolPress(self, key, ctrl, shift, alt, sup, buf, id);
}

pub fn thunkScroll(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const x = extractNestedJsonInt(p, "x") orelse
        return jsonRpcError(buf, id, -32602, "Missing x");
    const y = extractNestedJsonInt(p, "y") orelse
        return jsonRpcError(buf, id, -32602, "Missing y");
    const dy = extractNestedJsonInt(p, "dy") orelse 15;
    return toolScroll(self, @intCast(x), @intCast(y), @intCast(dy), buf, id);
}

pub fn thunkToggleScratchpad(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const idx = extractNestedJsonInt(p, "index") orelse
        return jsonRpcError(buf, id, -32602, "Missing index");
    if (idx < 0 or idx > 8) return jsonRpcError(buf, id, -32602, "index must be 0..8");
    return toolToggleScratchpad(self, @intCast(idx), buf, id);
}

pub fn thunkScratchpad(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const name = extractNestedJsonString(p, "name") orelse
        return jsonRpcError(buf, id, -32602, "Missing name");
    const cmd = extractNestedJsonString(p, "cmd");
    return toolScratchpad(self, name, cmd, buf, id);
}

pub fn thunkSubscribeEvents(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = p;
    return toolSubscribeEvents(self, buf, id);
}

pub fn thunkSessionSave(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const name = extractNestedJsonString(p, "name") orelse "default";
    return toolSessionSave(self, name, buf, id);
}

pub fn thunkSessionRestore(self: *WmMcpServer, p: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const name = extractNestedJsonString(p, "name") orelse "default";
    return toolSessionRestore(self, name, buf, id);
}

fn toolSessionSave(self: *WmMcpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const Session = @import("Session.zig");
    Session.save(self.server, name) catch |err| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "session save failed: {}", .{err}) catch "session save failed";
        return jsonRpcError(buf, id, -32603, msg);
    };
    return okText(buf, id, "saved session '{s}'", .{name});
}

fn toolSessionRestore(self: *WmMcpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const Session = @import("Session.zig");
    Session.restore(self.server, name) catch |err| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "session restore failed: {}", .{err}) catch "session restore failed";
        return jsonRpcError(buf, id, -32603, msg);
    };
    return okText(buf, id, "restored session '{s}'", .{name});
}

fn toolSubscribeEvents(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const path = self.event_socket_path[0..self.event_socket_path_len];
    // Path contains `/` and maybe other chars; safe as a JSON string (no
    // need to escape — socket paths don't have quote/backslash/control).
    return okText(buf, id, "{{\\\"socket\\\":\\\"{s}\\\"}}", .{path});
}

// ── Name resolution ───────────────────────────────────────────

/// Resolve a node from MCP params: tries "name" first, then "node_id".
fn resolveNode(self: *WmMcpServer, params_body: []const u8) ?u16 {
    // node_id first: it's unambiguous. "name" must come second because
    // extractNestedJsonString falls back to the full request JSON, where it
    // would match the tool's own "name":"teruwm_set_name" field and resolve to
    // a bogus node (this broke set_name/screenshot_pane by node_id).
    if (extractNestedJsonInt(params_body, "node_id")) |nid| {
        return self.server.nodes.findById(@intCast(nid));
    }
    if (extractNestedJsonString(params_body, "name")) |name| {
        return self.server.nodes.findByName(name, null);
    }
    return null;
}

// ── Tool implementations ──────────────────────────────────────

fn toolListWindows(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..],
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"[
    , .{}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += prefix.len;

    var first = true;
    for (0..NodeRegistry.max_nodes) |slot| {
        if (srv.nodes.kind[slot] != .empty) {
            if (!first) {
                if (pos < buf.len) { buf[pos] = ','; pos += 1; }
            }
            first = false;

            const nid = srv.nodes.node_id[slot];
            const ws = srv.nodes.workspace[slot];
            const kind_str = switch (srv.nodes.kind[slot]) {
                .terminal => "terminal",
                .wayland_surface => "wayland",
                .empty => unreachable,
            };

            // Get title for terminal panes
            var title: []const u8 = "";
            for (srv.terminal_panes) |maybe_tp| {
                if (maybe_tp) |tp| {
                    if (tp.node_id == nid) {
                        if (tp.pane.vt.title_len > 0) {
                            title = tp.pane.vt.title[0..tp.pane.vt.title_len];
                        } else {
                            title = "shell";
                        }
                        break;
                    }
                }
            }

            var title_esc: [256]u8 = undefined;
            const safe_title = jsonEscapeString(title, &title_esc);

            const node_name = srv.nodes.getName(@intCast(slot));
            var name_esc: [64]u8 = undefined;
            const safe_name = jsonEscapeString(node_name, &name_esc);

            const entry = std.fmt.bufPrint(buf[pos..],
                \\{{\"id\":{d},\"name\":\"{s}\",\"workspace\":{d},\"kind\":\"{s}\",\"title\":\"{s}\",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}
            , .{
                nid, safe_name, ws, kind_str, safe_title,
                srv.nodes.pos_x[slot], srv.nodes.pos_y[slot],
                srv.nodes.width[slot], srv.nodes.height[slot],
            }) catch break;
            pos += entry.len;
        }
    }

    const suffix = std.fmt.bufPrint(buf[pos..],
        \\]"}}]}},"id":{s}}}
    , .{id_str}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += suffix.len;
    return buf[0..pos];
}

fn toolSpawnTerminal(self: *WmMcpServer, ws: u8, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;

    srv.spawnTerminal(ws);

    return okText(buf, id, "spawned terminal on workspace {d}", .{ws});
}

fn toolCloseWindow(self: *WmMcpServer, node_id: u64, buf: []u8, id: ?[]const u8) []const u8 {
    if (!self.server.closeNode(node_id)) {
        return jsonRpcError(buf, id, -32602, "Window not found");
    }
    return okText(buf, id, "closed window {d}", .{node_id});
}

fn toolFocusWindow(self: *WmMcpServer, node_id: u64, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;

    // Set as active in workspace, then update focus
    if (srv.nodes.findById(node_id)) |slot| {
        const ws_idx = srv.nodes.workspace[slot];
        if (ws_idx >= 10) return jsonRpcError(buf, id, -32602, "Window is hidden/scratchpad");
        const workspace = &srv.layout_engine.workspaces[ws_idx];
        // Funnel through the single focus normalize point (A1): sets
        // active_node + syncs active_index when tiled.
        workspace.setFocus(node_id);
        srv.updateFocusedTerminal();
        if (srv.bar) |b| _ = b.render(srv);
        return okText(buf, id, "focused window {d}", .{node_id});
    }

    return jsonRpcError(buf, id, -32602, "Window not found");
}

fn toolMoveToWorkspace(self: *WmMcpServer, node_id: u64, ws: u8, buf: []u8, id: ?[]const u8) []const u8 {
    if (ws >= 10) return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    if (self.server.nodes.findById(node_id) == null)
        return jsonRpcError(buf, id, -32602, "Window not found");

    // Route through the single node-identity mutation chokepoint — it
    // handles floating vs tiled, re-arranges affected outputs, calls
    // recomputeVisibility, re-derives focus if the moved node was
    // focused and the target workspace is invisible, and emits
    // `node_moved`. Pre-v0.4.22 this called layout_engine directly
    // and never emitted the event.
    self.server.moveNodeToWorkspace(node_id, ws);
    if (self.server.bar) |b| _ = b.render(self.server);

    return okText(buf, id, "moved window {d} to workspace {d}", .{node_id, ws});
}

fn toolListWorkspaces(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..],
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"[
    , .{}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += prefix.len;

    for (0..10) |wi| {
        if (wi > 0) {
            if (pos < buf.len) { buf[pos] = ','; pos += 1; }
        }
        const ws = &srv.layout_engine.workspaces[wi];
        const layout_str = switch (ws.layout) {
            .master_stack => "master-stack",
            .grid => "grid",
            .monocle => "monocle",
            .dishes => "dishes",
            .accordion => "accordion",
            .spiral => "spiral",
            .three_col => "three-col",
            .columns => "columns",
        };
        const active = if (wi == srv.layout_engine.active_workspace) "true" else "false";
        const count = ws.node_ids.items.len;

        const entry = std.fmt.bufPrint(buf[pos..],
            \\{{\"id\":{d},\"layout\":\"{s}\",\"windows\":{d},\"active\":{s}}}
        , .{ wi, layout_str, count, active }) catch break;
        pos += entry.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..],
        \\]"}}]}},"id":{s}}}
    , .{id_str}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += suffix.len;
    return buf[0..pos];
}

fn toolSwitchWorkspace(self: *WmMcpServer, ws: u8, buf: []u8, id: ?[]const u8) []const u8 {
    if (ws >= 10) return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    // Route through the single workspace-mutation chokepoint so the
    // xmonad pull-swap semantics, recomputeVisibility, and event
    // emission (workspace_switched) all happen. Pre-v0.4.22 this path
    // drove layout_engine directly, bypassing focusWorkspace — which
    // silently swallowed workspace_switched events for every MCP-
    // triggered switch.
    self.server.focusWorkspace(ws);

    return okText(buf, id, "switched to workspace {d}", .{ws});
}

fn toolSetLayout(self: *WmMcpServer, ws: u8, layout_str: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    if (ws >= 10) return jsonRpcError(buf, id, -32602, "Workspace must be 0-9");

    const layout = teru.LayoutEngine.Layout.parse(layout_str) orelse
        return jsonRpcError(buf, id, -32602, "Unknown layout");

    srv.layout_engine.workspaces[ws].layout = layout;
    srv.arrangeworkspace(ws);
    if (srv.bar) |b| _ = b.render(srv);

    return okText(buf, id, "ok", .{});
}

fn toolGetConfig(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const cfg = &self.server.wm_config;
    const srv = self.server;

    const dims = srv.activeOutputDims();
    const out_w: u32 = dims.w;
    const out_h: u32 = dims.h;

    const top_enabled = if (srv.bar) |b| b.top.enabled else false;
    const bot_enabled = if (srv.bar) |b| b.bottom.enabled else false;
    // Font cell dimensions and bar height — derived at runtime from the
    // loaded font atlas. Useful for external tools computing grid layouts,
    // measuring gaps, or debugging. cell_h=16 default, bar_h = cell_h+4.
    const cell_w: u32 = if (srv.font_atlas) |fa| fa.cell_width else 8;
    const cell_h: u32 = if (srv.font_atlas) |fa| fa.cell_height else 16;
    const bar_h: u32 = if (srv.bar) |b| b.bar_height else 0;

    return okText(buf, id, "{{\\\"gap\\\":{d},\\\"border_width\\\":{d},\\\"bg_color\\\":\\\"0x{x:0>8}\\\",\\\"output_width\\\":{d},\\\"output_height\\\":{d},\\\"cell_width\\\":{d},\\\"cell_height\\\":{d},\\\"bar_height\\\":{d},\\\"terminal_count\\\":{d},\\\"active_workspace\\\":{d},\\\"top_bar\\\":{any},\\\"bottom_bar\\\":{any}}}", .{cfg.gap, cfg.border_width, cfg.bg_color, out_w, out_h, cell_w, cell_h, bar_h, srv.terminal_count, srv.layout_engine.active_workspace, top_enabled, bot_enabled});
}

fn toolSetConfig(self: *WmMcpServer, key: []const u8, value: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const cfg = &self.server.wm_config;

    if (std.mem.eql(u8, key, "gap")) {
        cfg.gap = std.fmt.parseInt(u16, value, 10) catch
            return jsonRpcError(buf, id, -32602, "Invalid gap value");
        // Re-arrange all workspaces to apply new gap
        for (0..self.server.layout_engine.workspaces.len) |ws| {
            self.server.arrangeworkspace(@intCast(ws));
        }
    } else if (std.mem.eql(u8, key, "border_width")) {
        cfg.border_width = std.fmt.parseInt(u16, value, 10) catch
            return jsonRpcError(buf, id, -32602, "Invalid border_width value");
    } else if (std.mem.eql(u8, key, "bg_color") or std.mem.eql(u8, key, "bg")) {
        var v = value;
        if (v.len > 0 and v[0] == '#') v = v[1..];
        if (v.len > 2 and v[0] == '0' and (v[1] == 'x' or v[1] == 'X')) v = v[2..];
        const parsed = std.fmt.parseInt(u32, v, 16) catch
            return jsonRpcError(buf, id, -32602, "Invalid bg_color (hex: #rrggbb or 0xaarrggbb)");
        cfg.bg_color = if (v.len <= 6) 0xFF000000 | parsed else parsed;
        if (self.server.bg_rect) |rect| {
            const col = cfg.bg_color;
            const rgba: [4]f32 = .{
                @as(f32, @floatFromInt((col >> 16) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt((col >> 8) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt(col & 0xFF)) / 255.0,
                @as(f32, @floatFromInt((col >> 24) & 0xFF)) / 255.0,
            };
            wlr.wlr_scene_rect_set_color(rect, &rgba);
        }
    } else {
        return jsonRpcError(buf, id, -32602, "Unknown config key (gap, border_width, bg_color)");
    }

    return okText(buf, id, "set {s} = {s}", .{key, value});
}

fn toolScreenshot(self: *WmMcpServer, path: []const u8, buf: []u8, id: ?[]const u8) []const u8 {

    if (!teru.compat.isSafeScreenshotPath(path))
        return jsonRpcError(buf, id, -32602, "Invalid path (no ../ allowed)");

    if (self.server.takeScreenshotToPath(path)) {
        const dims = self.server.activeOutputDims();
        const out_w: u32 = dims.w;
        const out_h: u32 = dims.h;
        return okText(buf, id, "screenshot saved to {s} ({d}x{d})", .{path, out_w, out_h});
    }

    return jsonRpcError(buf, id, -32603, "Screenshot failed");
}

fn toolNotify(self: *WmMcpServer, message: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    // Show it in the bottom-bar {notify} marquee (default_bottom_center).
    // The freedesktop.org D-Bus helper (tools/teruwm-notify-daemon) owns
    // org.freedesktop.Notifications and forwards each Notify call here as a
    // single pre-formatted "app: summary — body" string, so the whole line
    // goes into the summary slot. Also logged to stderr for `tail -F`.
    std.log.scoped(.mcp).info("notify: {s}", .{message});
    self.server.setNotification("", message, "", .normal, 0);
    return okText(buf, id, "notification shown", .{});
}

fn toolReloadConfig(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    self.server.reloadWmConfig();
    return okText(buf, id, "config reloaded (gap={d}, border={d})", .{self.server.wm_config.gap, self.server.wm_config.border_width});
}

fn toolScreenshotPane(self: *WmMcpServer, params_body: []const u8, path_opt: ?[]const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;

    const slot = resolveNode(self, params_body) orelse
        return jsonRpcError(buf, id, -32602, "Pane not found (provide name or node_id)");

    if (srv.nodes.kind[slot] != .terminal)
        return jsonRpcError(buf, id, -32602, "Only terminal pane screenshots are supported");

    const nid = srv.nodes.node_id[slot];
    const pane_name = srv.nodes.getName(slot);

    // Find the TerminalPane
    for (srv.terminal_panes) |maybe_tp| {
        if (maybe_tp) |tp| {
            if (tp.node_id == nid) {
                // Ensure grid is rendered
                tp.render();

                // Build path
                var path_buf: [512:0]u8 = undefined;
                const path = if (path_opt) |p| p else blk: {
                    const p = std.fmt.bufPrint(&path_buf, "/tmp/teruwm-pane-{s}.png", .{
                        if (pane_name.len > 0) pane_name else "unknown",
                    }) catch return jsonRpcError(buf, id, -32603, "Path error");
                    break :blk p;
                };

                // Reject path traversal in user-supplied path. png.write
                // additionally opens with O_NOFOLLOW (defense-in-depth).
                if (!teru.compat.isSafeScreenshotPath(path))
                    return jsonRpcError(buf, id, -32602, "Invalid path (must be under /tmp or $HOME)");

                // Null-terminate
                var path_z: [512:0]u8 = undefined;
                if (path.len >= path_z.len) return jsonRpcError(buf, id, -32602, "Path too long");
                @memcpy(path_z[0..path.len], path);
                path_z[path.len] = 0;

                png.write(srv.zig_allocator, @ptrCast(path_z[0..path.len :0]), tp.renderer.framebuffer, tp.renderer.width, tp.renderer.height) catch |err| {
                    return switch (err) {
                        error.FileOpenFailed => jsonRpcError(buf, id, -32603, "Failed to open output file"),
                        error.OutOfMemory => jsonRpcError(buf, id, -32603, "Out of memory"),
                    };
                };

                return okText(buf, id, "pane screenshot saved to {s} ({d}x{d})", .{path, tp.renderer.width, tp.renderer.height});
            }
        }
    }

    return jsonRpcError(buf, id, -32603, "Terminal pane not found in pane list");
}

fn toolSetName(self: *WmMcpServer, params_body: []const u8, new_name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {

    const slot = resolveNode(self, params_body) orelse
        return jsonRpcError(buf, id, -32602, "Node not found (provide name or node_id)");

    self.server.nodes.setName(slot, new_name);

    return okText(buf, id, "renamed node {d} to {s}", .{self.server.nodes.node_id[slot], new_name});
}

fn toolRestart(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    // Schedule restart after response is sent (via deferred flag)
    self.server.restart_pending = true;
    if (self.server.primary_output) |output| wlr.wlr_output_schedule_frame(output);
    return okText(buf, id, "restart scheduled — compositor will exec() on next frame", .{});
}

fn toolQuit(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    // Format the response BEFORE terminating so the client gets an
    // ack — wl_display_terminate flips a flag that the main run loop
    // (wl_display_run) checks on its next iteration, so this current
    // MCP handler finishes writing out its response before the
    // compositor actually tears down. Clean handshake.
    const id_str = id orelse "null";
    const resp = std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"quit scheduled — compositor will terminate after this response"}}]}},"id":{s}}}
    , .{id_str}) catch
        return jsonRpcError(buf, id, -32603, "Internal error");
    wlr.wl_display_terminate(self.server.display);
    return resp;
}

fn toolPerf(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const perf = &self.server.perf;
    const max_us = if (perf.frame_time_max_us == std.math.maxInt(u64)) @as(u64, 0) else perf.frame_time_max_us;

    return std.fmt.bufPrint(buf,
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"frames: {d}, avg: {d}us, max: {d}us, min: {d}us, pty_reads: {d}, pty_bytes: {d}, terminals: {d}"}}]}},"id":{s}}}
    , .{
        perf.frame_count,
        perf.avgFrameUs(),
        max_us,
        if (perf.frame_time_min_us == std.math.maxInt(u64)) @as(u64, 0) else perf.frame_time_min_us,
        perf.pty_reads,
        perf.pty_bytes,
        self.server.terminal_count,
        id_str,
    }) catch
        jsonRpcError(buf, id, -32603, "Internal error");
}

/// Toggle (explicit=null) or set (explicit=true/false) a bar's enabled state.
fn toolToggleBar(self: *WmMcpServer, which: []const u8, explicit: ?bool, buf: []u8, id: ?[]const u8) []const u8 {
    const bar = self.server.bar orelse
        return jsonRpcError(buf, id, -32603, "bar not initialized");

    const is_top = std.mem.eql(u8, which, "top");
    const is_bot = std.mem.eql(u8, which, "bottom");
    if (!is_top and !is_bot)
        return jsonRpcError(buf, id, -32602, "which must be 'top' or 'bottom'");

    const bar_instance = if (is_top) &bar.top else &bar.bottom;
    const new_val = explicit orelse !bar_instance.enabled;
    bar_instance.enabled = new_val;

    // Hide/show the bar's scene node so it doesn't occupy pixels when disabled
    bar.updateVisibility();

    // Re-arrange every workspace — layout area changes when bar toggles
    for (0..self.server.layout_engine.workspaces.len) |ws| {
        self.server.arrangeworkspace(@intCast(ws));
    }
    if (new_val) _ = bar.render(self.server);

    return okText(buf, id, "{s} bar {s}", .{which, if (new_val) "enabled" else "disabled"});
}

// ── Push widget tools ──────────────────────────────────────────

fn toolSetWidget(self: *WmMcpServer, name: []const u8, text: []const u8, class_str: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    if (name.len == 0) return jsonRpcError(buf, id, -32602, "Empty name");
    if (name.len > teru.render.PushWidget.max_name)
        return jsonRpcError(buf, id, -32602, "Name too long (max 32)");
    if (text.len > teru.render.PushWidget.max_text)
        return jsonRpcError(buf, id, -32602, "Text too long (max 128)");

    const class = teru.render.PushWidget.Class.fromString(class_str);
    const ok = self.server.setPushWidget(name, text, class);
    if (!ok) return jsonRpcError(buf, id, -32603, "Out of widget slots (max 32)");

    return okText(buf, id, "widget '{s}' set", .{name});
}

fn toolDeleteWidget(self: *WmMcpServer, name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    if (name.len == 0) return jsonRpcError(buf, id, -32602, "Empty name");
    const removed = self.server.deletePushWidget(name);
    const msg = if (removed) "deleted" else "not found";
    return okText(buf, id, "widget '{s}' {s}", .{name, msg});
}

fn toolListWidgets(self: *WmMcpServer, buf: []u8, id: ?[]const u8) []const u8 {
    const id_str = id orelse "null";
    const srv = self.server;
    var pos: usize = 0;

    const prefix = std.fmt.bufPrint(buf[pos..],
        \\{{"jsonrpc":"2.0","result":{{"content":[{{"type":"text","text":"[
    , .{}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += prefix.len;

    var first = true;
    const now_ns: i64 = @intCast(teru.compat.monotonicNow());
    for (&srv.push_widgets) |*pw| {
        if (!pw.used) continue;
        if (!first) {
            if (pos < buf.len) { buf[pos] = ','; pos += 1; }
        }
        first = false;

        const age_ms: u64 = blk: {
            if (pw.last_update_ns == 0) break :blk 0;
            const diff: i64 = now_ns -| pw.last_update_ns;
            if (diff < 0) break :blk 0;
            break :blk @intCast(@divTrunc(diff, std.time.ns_per_ms));
        };
        const class_name = @tagName(pw.class);

        var text_esc_buf: [256]u8 = undefined;
        const safe_text = jsonEscapeString(pw.text(), &text_esc_buf);
        var name_esc_buf: [64]u8 = undefined;
        const safe_name = jsonEscapeString(pw.name(), &name_esc_buf);

        const entry = std.fmt.bufPrint(buf[pos..],
            \\{{\"name\":\"{s}\",\"text\":\"{s}\",\"class\":\"{s}\",\"age_ms\":{d}}}
        , .{ safe_name, safe_text, class_name, age_ms }) catch break;
        pos += entry.len;
    }

    const suffix = std.fmt.bufPrint(buf[pos..],
        \\]"}}]}},"id":{s}}}
    , .{id_str}) catch return jsonRpcError(buf, id, -32603, "Internal error");
    pos += suffix.len;
    return buf[0..pos];
}

// ── E2E test tools (internal) ──────────────────────────────────

fn toolTestDrag(self: *WmMcpServer, from_x: i32, from_y: i32, to_x: i32, to_y: i32, super_held: bool, button: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;

    // Four strictly-increasing monotonic timestamps. Chromium's
    // Ozone and GTK track (serial, time) per pointer event; when a
    // press shares the preceding motion's timestamp, their "defer
    // in-flight press" path drops the press, and the later release
    // arrives after Chromium has ack'd the activate-configure —
    // looking like a spurious up. Spacing each phase ≥5 ms avoids
    // that. Same hazard applies to same-time press + release
    // (toolkits read it as "drag-without-motion" noise). Source:
    // 2026-04-16 deep research, Hyprland #7519 style.
    const base = monotonicMs();
    const t_motion: u32 = base;
    const t_press: u32 = base +% 5;
    const t_drag: u32 = base +% 10;
    const t_release: u32 = base +% 20;

    // Phase 1: warp cursor to start, fire motion so focus follows.
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(from_x), @floatFromInt(from_y));
    srv.processCursorMotion(t_motion);

    // Phase 2: button press — distinct ts from motion (prevents the
    // Ozone "deferred press" drop).
    srv.processCursorButton(button, 1, t_press, super_held);

    // Phase 3: warp to destination, fire motion so drag tracks.
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(to_x), @floatFromInt(to_y));
    srv.processCursorMotion(t_drag);

    // Phase 4: button release at t_release — realistic down-up interval.
    srv.processCursorButton(button, 0, t_release, super_held);

    return okText(buf, id, "drag ({d},{d})->({d},{d}) super={any} button={d}", .{from_x, from_y, to_x, to_y, super_held, button});
}

fn toolTestMove(self: *WmMcpServer, x: i32, y: i32, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(x), @floatFromInt(y));
    // Real monotonic timestamp, not 0. Chromium's Ozone tracks
    // (serial, time) pairs per pointer.enter; a time=0 motion poisons
    // the enter-serial cache so any subsequent click on the same
    // surface is dropped as "not associated with a valid enter".
    srv.processCursorMotion(monotonicMs());
    return okText(buf, id, "cursor at ({d},{d})", .{x, y});
}

fn toolMousePath(
    self: *WmMcpServer,
    from_x: i32, from_y: i32, to_x: i32, to_y: i32,
    duration_ms: u32, humanize: bool, button: ?u32, super_held: bool,
    buf: []u8, id: ?[]const u8,
) []const u8 {
    @import("ServerMouse.zig").pathMove(
        self.server,
        from_x, from_y, to_x, to_y,
        duration_ms, humanize, button, super_held,
    );
    const btn_val: i32 = if (button) |b| @intCast(b) else -1;
    return okText(buf, id, "path ({d},{d})->({d},{d}) {d}ms humanize={any} button={d}", .{from_x, from_y, to_x, to_y, duration_ms, humanize, btn_val});
}

fn toolToggleScratchpad(self: *WmMcpServer, index: u8, buf: []u8, id: ?[]const u8) []const u8 {
    // Compat shim: numbered index delegates to named pad<N+1>. Report
    // the toggle result by reading the new state from the NodeRegistry.
    var name_buf: [8]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "pad{d}", .{index + 1}) catch return jsonRpcError(buf, id, -32603, "bad index");
    self.server.toggleScratchpadByName(name);

    const slot = self.server.nodes.findByScratchpad(name);
    const created = slot != null;
    const visible = if (slot) |s| !self.server.nodes.isHidden(s) else false;
    return okText(buf, id, "scratchpad {d} name={s} visible={any} created={any}", .{index, name, visible, created});
}

fn toolScratchpad(self: *WmMcpServer, name: []const u8, cmd: ?[]const u8, buf: []u8, id: ?[]const u8) []const u8 {
    _ = cmd; // `cmd` param is wire-compat with the MCP schema — per-name
             // spawn commands live in `[scratchpad.NAME] cmd = …` now.
             // This MCP field stays for back-compat but is ignored.
    if (name.len == 0) return jsonRpcError(buf, id, -32602, "scratchpad name required");
    self.server.toggleScratchpadByName(name);

    const slot = self.server.nodes.findByScratchpad(name);
    const created = slot != null;
    const visible = if (slot) |s| !self.server.nodes.isHidden(s) else false;
    return okText(buf, id, "scratchpad name={s} visible={any} created={any}", .{name, visible, created});
}

fn toolTestKey(self: *WmMcpServer, action_name: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const Action = teru.Keybinds.Action;
    // Parse action from string (exhaustive — unknown → error)
    const action: Action = blk: {
        const ei = @typeInfo(Action).@"enum";
        inline for (ei.field_names, ei.field_values) |name, value| {
            if (std.mem.eql(u8, name, action_name)) {
                break :blk @enumFromInt(value);
            }
        }
        return jsonRpcError(buf, id, -32602, "Unknown action name");
    };

    const handled = self.server.executeAction(action);
    return okText(buf, id, "action '{s}' handled={any}", .{action_name, handled});
}

// ── AI-first physical input MCP tools ──────────────────────────
//
// teruwm is an AI-first WM. These tools let an agent drive the same
// pointer/keyboard pipeline a real touchpad/keyboard would, through
// the wlroots seat — clients (Chromium, Firefox, GIMP, …) cannot
// distinguish synthetic events from physical ones.

fn toolClick(self: *WmMcpServer, x: i32, y: i32, button: u32, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    const ms_now = monotonicMs();

    // Warp cursor + motion (sets pointer focus on the surface under
    // the new cursor position).
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(x), @floatFromInt(y));
    srv.processCursorMotion(ms_now);

    // Identify what we landed on for the response (so the agent can
    // verify the click went where it intended).
    const hit_id = srv.nodeAtPoint(@floatFromInt(x), @floatFromInt(y));
    var kind_str: []const u8 = "none";
    if (hit_id) |h| {
        if (srv.nodes.findById(h)) |slot| {
            kind_str = switch (srv.nodes.kind[slot]) {
                .terminal => "terminal",
                .wayland_surface => "wayland",
                .empty => "none",
            };
        }
    }

    // Press + release with distinct timestamps from the preceding
    // motion. Same-ts motion+press triggers Chromium's Ozone
    // "deferred press" drop. +5ms press, +20ms release mirrors a
    // real touchpad tap (10-30 ms hold).
    srv.processCursorButton(button, 1, ms_now +% 5, false);
    srv.processCursorButton(button, 0, ms_now +% 20, false);

    return okText(buf, id, "{{\\\"cx\\\":{d},\\\"cy\\\":{d},\\\"hit\\\":{?d},\\\"kind\\\":\\\"{s}\\\"}}", .{x, y, hit_id, kind_str});
}

fn toolType(self: *WmMcpServer, text: []const u8, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    var sent: u32 = 0;
    var dropped: u32 = 0;

    // Native terminal panes aren't Wayland clients — they have no
    // wl_surface behind their scene_buffer, so wlr_seat_keyboard_notify_key
    // has nowhere to deliver. Mirror ServerInput.handleKeyEvent's
    // terminal fast-path: write bytes directly to the focused pane's
    // PTY. Without this, MCP-driven typing into teruwm-native panes was
    // a no-op even though real keyboard worked.
    if (srv.focused_terminal) |tp| {
        for (text) |c| {
            const bytes: [1]u8 = .{c};
            tp.writeInput(&bytes);
            sent += 1;
        }
        return okText(buf, id, "{{\\\"sent\\\":{d},\\\"dropped\\\":{d}}}", .{sent, dropped});
    }

    // Fallback: synthetic keyboard events to whatever client owns
    // seat keyboard focus (xdg / xwayland).
    var ms = monotonicMs();
    for (text) |c| {
        const map = asciiToKeycode(c) orelse {
            dropped += 1;
            continue;
        };
        if (map.shift) {
            sendKey(srv, KEY_LEFTSHIFT, true, ms);
            ms += 1;
        }
        sendKey(srv, map.keycode, true, ms);
        ms += 5;
        sendKey(srv, map.keycode, false, ms);
        ms += 1;
        if (map.shift) {
            sendKey(srv, KEY_LEFTSHIFT, false, ms);
            ms += 1;
        }
        sent += 1;
    }

    return okText(buf, id, "{{\\\"sent\\\":{d},\\\"dropped\\\":{d}}}", .{sent, dropped});
}

fn toolPress(self: *WmMcpServer, key: []const u8, ctrl: bool, shift: bool, alt: bool, sup: bool, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;

    const keycode = nameToKeycode(key) orelse return jsonRpcError(buf, id, -32602, "Unknown key name");

    // Focused terminal pane: translate to PTY-bound escape bytes and
    // write directly. Mirrors the special-key section of
    // ServerInput.handleKeyEvent so real keyboard + MCP feel identical
    // on native panes.
    if (srv.focused_terminal) |tp| {
        const bytes = ptyBytesForKeyname(key, ctrl, shift, alt);
        if (bytes.len > 0) {
            tp.writeInput(bytes);
            return okText(buf, id, "{{\\\"key\\\":\\\"{s}\\\",\\\"keycode\\\":{d},\\\"route\\\":\\\"pty\\\"}}", .{key, keycode});
        }
        // Unknown name — fall through to the seat path so Ctrl+a / F1
        // etc. still reach if somehow a client claims the seat.
    }

    // Seat path for xdg / xwayland focused clients.
    var ms = monotonicMs();

    if (ctrl) { sendKey(srv, KEY_LEFTCTRL, true, ms); ms += 1; }
    if (shift) { sendKey(srv, KEY_LEFTSHIFT, true, ms); ms += 1; }
    if (alt) { sendKey(srv, KEY_LEFTALT, true, ms); ms += 1; }
    if (sup) { sendKey(srv, KEY_LEFTMETA, true, ms); ms += 1; }

    sendKey(srv, keycode, true, ms);
    ms += 10;
    sendKey(srv, keycode, false, ms);
    ms += 1;

    if (sup) { sendKey(srv, KEY_LEFTMETA, false, ms); ms += 1; }
    if (alt) { sendKey(srv, KEY_LEFTALT, false, ms); ms += 1; }
    if (shift) { sendKey(srv, KEY_LEFTSHIFT, false, ms); ms += 1; }
    if (ctrl) { sendKey(srv, KEY_LEFTCTRL, false, ms); ms += 1; }

    return okText(buf, id, "{{\\\"key\\\":\\\"{s}\\\",\\\"keycode\\\":{d}}}", .{key, keycode});
}

/// Map a named key ("Return", "Escape", "Tab", arrows…) to the byte
/// sequence a PTY-attached app expects. Ctrl prefix wraps
/// printable letters with Ctrl (a → 0x01). Returns empty slice when
/// the key is not mappable here — caller falls back to seat dispatch.
fn ptyBytesForKeyname(key: []const u8, ctrl: bool, shift: bool, alt: bool) []const u8 {
    _ = shift;
    _ = alt;
    if (std.mem.eql(u8, key, "Return") or std.mem.eql(u8, key, "Enter")) return "\r";
    if (std.mem.eql(u8, key, "BackSpace") or std.mem.eql(u8, key, "Backspace")) return "\x7f";
    if (std.mem.eql(u8, key, "Tab")) return "\t";
    if (std.mem.eql(u8, key, "Escape")) return "\x1b";
    if (std.mem.eql(u8, key, "Up")) return "\x1b[A";
    if (std.mem.eql(u8, key, "Down")) return "\x1b[B";
    if (std.mem.eql(u8, key, "Right")) return "\x1b[C";
    if (std.mem.eql(u8, key, "Left")) return "\x1b[D";
    if (std.mem.eql(u8, key, "Home")) return "\x1b[H";
    if (std.mem.eql(u8, key, "End")) return "\x1b[F";
    if (std.mem.eql(u8, key, "PageUp")) return "\x1b[5~";
    if (std.mem.eql(u8, key, "PageDown")) return "\x1b[6~";
    if (std.mem.eql(u8, key, "Delete")) return "\x1b[3~";
    if (ctrl and key.len == 1) {
        const c = key[0];
        if (c >= 'a' and c <= 'z') {
            // Ctrl+a..z → 0x01..0x1a. Emit from a static table.
            return ctrlLetterSlice(c);
        }
    }
    return "";
}

const ctrl_letters: [26][1]u8 = blk: {
    var tab: [26][1]u8 = undefined;
    for (&tab, 0..) |*e, i| e.* = .{@intCast(i + 1)};
    break :blk tab;
};

fn ctrlLetterSlice(c: u8) []const u8 {
    return ctrl_letters[@as(usize, c - 'a')][0..1];
}

fn toolScroll(self: *WmMcpServer, x: i32, y: i32, dy: i32, buf: []u8, id: ?[]const u8) []const u8 {
    const srv = self.server;
    const ms_now = monotonicMs();

    // Position cursor + sync pointer focus
    wlr.wlr_cursor_warp_closest(srv.cursor, null, @floatFromInt(x), @floatFromInt(y));
    srv.processCursorMotion(ms_now);

    // Send axis event. wlroots: orientation 0 = vertical, source 0 = wheel.
    wlr.wlr_seat_pointer_notify_axis(
        srv.seat,
        ms_now,
        0, // WL_POINTER_AXIS_VERTICAL_SCROLL
        @floatFromInt(dy),
        if (dy > 0) 1 else -1,
        0, // WL_POINTER_AXIS_SOURCE_WHEEL
        0, // WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL
    );
    wlr.wlr_seat_pointer_notify_frame(srv.seat);

    return okText(buf, id, "{{\\\"x\\\":{d},\\\"y\\\":{d},\\\"dy\\\":{d}}}", .{x, y, dy});
}

// ── Keyboard helpers ──────────────────────────────────────────

/// evdev keycodes (from include/uapi/linux/input-event-codes.h). These
/// are what wlr_seat_keyboard_notify_key takes. xkb adds 8 internally.
const KEY_ESC: u32 = 1;
const KEY_BACKSPACE: u32 = 14;
const KEY_TAB: u32 = 15;
const KEY_ENTER: u32 = 28;
const KEY_LEFTCTRL: u32 = 29;
const KEY_LEFTSHIFT: u32 = 42;
const KEY_LEFTALT: u32 = 56;
const KEY_LEFTMETA: u32 = 125;
const KEY_SPACE: u32 = 57;
const KEY_UP: u32 = 103;
const KEY_LEFT: u32 = 105;
const KEY_RIGHT: u32 = 106;
const KEY_DOWN: u32 = 108;
const KEY_HOME: u32 = 102;
const KEY_END: u32 = 107;
const KEY_PAGEUP: u32 = 104;
const KEY_PAGEDOWN: u32 = 109;

const AsciiMap = struct { keycode: u32, shift: bool };

/// US QWERTY ASCII → evdev keycode + shift. Not locale-aware; assumes
/// the user / agent target a US layout. Non-US users will see swapped
/// punctuation. Future: read xkb_keymap and reverse-look up properly.
fn asciiToKeycode(c: u8) ?AsciiMap {
    return switch (c) {
        ' ' => .{ .keycode = KEY_SPACE, .shift = false },
        'a' => .{ .keycode = 30, .shift = false },
        'b' => .{ .keycode = 48, .shift = false },
        'c' => .{ .keycode = 46, .shift = false },
        'd' => .{ .keycode = 32, .shift = false },
        'e' => .{ .keycode = 18, .shift = false },
        'f' => .{ .keycode = 33, .shift = false },
        'g' => .{ .keycode = 34, .shift = false },
        'h' => .{ .keycode = 35, .shift = false },
        'i' => .{ .keycode = 23, .shift = false },
        'j' => .{ .keycode = 36, .shift = false },
        'k' => .{ .keycode = 37, .shift = false },
        'l' => .{ .keycode = 38, .shift = false },
        'm' => .{ .keycode = 50, .shift = false },
        'n' => .{ .keycode = 49, .shift = false },
        'o' => .{ .keycode = 24, .shift = false },
        'p' => .{ .keycode = 25, .shift = false },
        'q' => .{ .keycode = 16, .shift = false },
        'r' => .{ .keycode = 19, .shift = false },
        's' => .{ .keycode = 31, .shift = false },
        't' => .{ .keycode = 20, .shift = false },
        'u' => .{ .keycode = 22, .shift = false },
        'v' => .{ .keycode = 47, .shift = false },
        'w' => .{ .keycode = 17, .shift = false },
        'x' => .{ .keycode = 45, .shift = false },
        'y' => .{ .keycode = 21, .shift = false },
        'z' => .{ .keycode = 44, .shift = false },
        'A'...'Z' => |u| .{ .keycode = (asciiToKeycode(u + 32) orelse return null).keycode, .shift = true },
        '0' => .{ .keycode = 11, .shift = false },
        '1'...'9' => |d| .{ .keycode = @as(u32, d - '1' + 2), .shift = false },
        '!' => .{ .keycode = 2, .shift = true },
        '@' => .{ .keycode = 3, .shift = true },
        '#' => .{ .keycode = 4, .shift = true },
        '$' => .{ .keycode = 5, .shift = true },
        '%' => .{ .keycode = 6, .shift = true },
        '^' => .{ .keycode = 7, .shift = true },
        '&' => .{ .keycode = 8, .shift = true },
        '*' => .{ .keycode = 9, .shift = true },
        '(' => .{ .keycode = 10, .shift = true },
        ')' => .{ .keycode = 11, .shift = true },
        '-' => .{ .keycode = 12, .shift = false },
        '_' => .{ .keycode = 12, .shift = true },
        '=' => .{ .keycode = 13, .shift = false },
        '+' => .{ .keycode = 13, .shift = true },
        '[' => .{ .keycode = 26, .shift = false },
        '{' => .{ .keycode = 26, .shift = true },
        ']' => .{ .keycode = 27, .shift = false },
        '}' => .{ .keycode = 27, .shift = true },
        '\\' => .{ .keycode = 43, .shift = false },
        '|' => .{ .keycode = 43, .shift = true },
        ';' => .{ .keycode = 39, .shift = false },
        ':' => .{ .keycode = 39, .shift = true },
        '\'' => .{ .keycode = 40, .shift = false },
        '"' => .{ .keycode = 40, .shift = true },
        ',' => .{ .keycode = 51, .shift = false },
        '<' => .{ .keycode = 51, .shift = true },
        '.' => .{ .keycode = 52, .shift = false },
        '>' => .{ .keycode = 52, .shift = true },
        '/' => .{ .keycode = 53, .shift = false },
        '?' => .{ .keycode = 53, .shift = true },
        '`' => .{ .keycode = 41, .shift = false },
        '~' => .{ .keycode = 41, .shift = true },
        '\n' => .{ .keycode = KEY_ENTER, .shift = false },
        '\t' => .{ .keycode = KEY_TAB, .shift = false },
        else => null,
    };
}

fn nameToKeycode(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "Return")) return KEY_ENTER;
    if (std.mem.eql(u8, name, "Enter")) return KEY_ENTER;
    if (std.mem.eql(u8, name, "Tab")) return KEY_TAB;
    if (std.mem.eql(u8, name, "Escape")) return KEY_ESC;
    if (std.mem.eql(u8, name, "Esc")) return KEY_ESC;
    if (std.mem.eql(u8, name, "BackSpace")) return KEY_BACKSPACE;
    if (std.mem.eql(u8, name, "Backspace")) return KEY_BACKSPACE;
    if (std.mem.eql(u8, name, "Up")) return KEY_UP;
    if (std.mem.eql(u8, name, "Down")) return KEY_DOWN;
    if (std.mem.eql(u8, name, "Left")) return KEY_LEFT;
    if (std.mem.eql(u8, name, "Right")) return KEY_RIGHT;
    if (std.mem.eql(u8, name, "Home")) return KEY_HOME;
    if (std.mem.eql(u8, name, "End")) return KEY_END;
    if (std.mem.eql(u8, name, "PageUp")) return KEY_PAGEUP;
    if (std.mem.eql(u8, name, "PageDown")) return KEY_PAGEDOWN;
    if (std.mem.eql(u8, name, "Space")) return KEY_SPACE;
    if (name.len == 1) {
        if (asciiToKeycode(name[0])) |m| return m.keycode;
    }
    return null;
}

fn sendKey(srv: *Server, evdev_keycode: u32, pressed: bool, time_ms: u32) void {
    const state: u32 = if (pressed) 1 else 0;
    wlr.wlr_seat_keyboard_notify_key(srv.seat, time_ms, evdev_keycode, state);
}

fn monotonicMs() u32 {
    const ns_per_ms: i128 = 1_000_000;
    const t_ns: i128 = teru.compat.monotonicNow();
    return @intCast(@mod(@divTrunc(t_ns, ns_per_ms), 0xFFFFFFFF));
}
