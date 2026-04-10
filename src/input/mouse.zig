//! Mouse event handling for teru.
//!
//! Extracted from main.zig event loop. Handles:
//! - Mouse press (click-to-focus, selection, URL open, border drag, double-click)
//! - Mouse release (selection finalize, border drag finish, PTY reporting)
//! - Mouse motion (border drag resize, selection drag, URL hover, PTY reporting)
//! - Scroll wheel (smooth scrolling up/down)
//! - Mouse reporting to PTY (modes 1000/1002/1003, SGR and X10 encoding)

const std = @import("std");
const Multiplexer = @import("../core/Multiplexer.zig");
const Selection = @import("../core/Selection.zig");
const Clipboard = @import("../core/Clipboard.zig");
const UrlDetector = @import("../core/UrlDetector.zig");
const Ui = @import("../render/Ui.zig");
const compat = @import("../compat.zig");
const LayoutEngine = @import("../tiling/LayoutEngine.zig");
const Workspace = @import("../tiling/Workspace.zig");
const tiling_types = @import("../tiling/types.zig");
const platform_types = @import("../platform/types.zig");

const Rect = LayoutEngine.Rect;

/// Timing constants
const DOUBLE_CLICK_NS: i128 = 300_000_000; // 300ms

/// Master ratio clamps for mouse drag resize
const MASTER_RATIO_MIN: f32 = 0.15;
const MASTER_RATIO_MAX: f32 = 0.85;

const SHIFT_MASK: u32 = 1; // XCB ShiftMask

/// Persistent mouse state tracked across events.
pub const MouseState = struct {
    mouse_down: bool = false,
    mouse_start_row: u16 = 0,
    mouse_start_col: u16 = 0,
    border_dragging: bool = false,
    border_drag_x: u32 = 0,
    border_drag_ratio: f32 = 0.6,
    border_drag_node: u16 = 0,
    hover_url_active: bool = false,
    hover_url_row: u16 = 0,
    hover_url_start: u16 = 0,
    hover_url_end: u16 = 0,
    mouse_cursor_hidden: bool = false,
    last_click_time: i128 = 0,
    last_click_row: u16 = 0,
    last_click_col: u16 = 0,
};

/// Layout parameters passed from main's window/atlas state.
pub const LayoutParams = struct {
    cell_width: u32,
    cell_height: u32,
    grid_rows: u16,
    grid_cols: u16,
    padding: u32,
    status_bar_h: u32,
};

/// Config flags relevant to mouse handling.
pub const MouseConfig = struct {
    copy_on_select: bool,
    scroll_speed: u32,
    word_delimiters: []const u8,
    show_status_bar: bool,
};

/// Result from mouse press handling — tells main.zig what side effects to apply.
pub const PressResult = struct {
    /// The event was fully consumed (caller should `continue` in event loop)
    consumed: bool = false,
    /// Pane layout changed — caller should resize PTYs and force redraw
    panes_changed: bool = false,
    /// Grid needs redraw
    dirty: bool = false,
};

/// Result from mouse release handling.
pub const ReleaseResult = struct {
    consumed: bool = false,
    /// Border drag finished — caller should resize PTYs
    border_drag_finished: bool = false,
    dirty: bool = false,
};

/// Result from mouse motion handling.
pub const MotionResult = struct {
    consumed: bool = false,
    /// Mouse cursor should be shown (was hidden for keyboard typing)
    show_cursor: bool = false,
    dirty: bool = false,
};

// ── PTY Mouse Reporting ──────────────────────────────────────────

/// Report a mouse press event to the PTY (modes 1000/1002/1003).
/// Returns true if the event was reported (and may need to be passed through for scroll).
fn reportMousePress(mux: *Multiplexer, mouse: platform_types.MouseEvent, lp: LayoutParams, ms: *MouseState) bool {
    const pane = mux.getActivePaneMut() orelse return false;
    if (pane.vt.mouse_tracking == .none) return false;

    const mcol: u16 = @intCast(@min(mouse.x / lp.cell_width, @as(u32, lp.grid_cols -| 1)));
    const mrow: u16 = @intCast(@min(mouse.y / lp.cell_height, @as(u32, lp.grid_rows -| 1)));
    const btn: u8 = switch (mouse.button) {
        .left => 0,
        .middle => 1,
        .right => 2,
        .scroll_up => 64,
        .scroll_down => 65,
    };
    var mbuf: [32]u8 = undefined;
    if (pane.vt.mouse_sgr) {
        const mlen = std.fmt.bufPrint(&mbuf, "\x1b[<{d};{d};{d}M", .{ btn, mcol + 1, mrow + 1 }) catch return true;
        _ = pane.ptyWrite(mlen) catch {};
    } else {
        // X10 legacy encoding
        if (mcol + 33 < 256 and mrow + 33 < 256) {
            mbuf[0] = 0x1b;
            mbuf[1] = '[';
            mbuf[2] = 'M';
            mbuf[3] = @intCast(btn + 32);
            mbuf[4] = @intCast(mcol + 33);
            mbuf[5] = @intCast(mrow + 33);
            _ = pane.ptyWrite(mbuf[0..6]) catch {};
        }
    }
    // Track button state for motion reporting (mode 1002)
    if (mouse.button == .left) ms.mouse_down = true;
    // Scroll events: don't consume, let teru handle them too
    return mouse.button != .scroll_up and mouse.button != .scroll_down;
}

/// Report a mouse release event to the PTY.
fn reportMouseRelease(mux: *Multiplexer, mouse: platform_types.MouseEvent, lp: LayoutParams) void {
    const pane = mux.getActivePaneMut() orelse return;
    if (pane.vt.mouse_tracking == .none) return;

    const mcol: u16 = @intCast(@min(mouse.x / lp.cell_width, @as(u32, lp.grid_cols -| 1)));
    const mrow: u16 = @intCast(@min(mouse.y / lp.cell_height, @as(u32, lp.grid_rows -| 1)));
    var mbuf: [32]u8 = undefined;
    if (pane.vt.mouse_sgr) {
        const btn: u8 = switch (mouse.button) {
            .left => 0,
            .middle => 1,
            .right => 2,
            else => 0,
        };
        const mlen = std.fmt.bufPrint(&mbuf, "\x1b[<{d};{d};{d}m", .{ btn, mcol + 1, mrow + 1 }) catch return;
        _ = pane.ptyWrite(mlen) catch {};
    } else {
        if (mcol + 33 < 256 and mrow + 33 < 256) {
            mbuf[0] = 0x1b;
            mbuf[1] = '[';
            mbuf[2] = 'M';
            mbuf[3] = 35; // release = button 3
            mbuf[4] = @intCast(mcol + 33);
            mbuf[5] = @intCast(mrow + 33);
            _ = pane.ptyWrite(mbuf[0..6]) catch {};
        }
    }
}

/// Report mouse motion to the PTY (modes 1002/1003).
fn reportMouseMotion(mux: *Multiplexer, motion_x: u32, motion_y: u32, lp: LayoutParams, mouse_down: bool) void {
    const pane = mux.getActivePaneMut() orelse return;
    const report_motion = switch (pane.vt.mouse_tracking) {
        .any_event => true,
        .button_event => mouse_down,
        else => false,
    };
    if (!report_motion) return;

    const mcol: u16 = @intCast(@min(motion_x / lp.cell_width, @as(u32, lp.grid_cols -| 1)));
    const mrow: u16 = @intCast(@min(motion_y / lp.cell_height, @as(u32, lp.grid_rows -| 1)));
    var mbuf: [32]u8 = undefined;
    if (pane.vt.mouse_sgr) {
        const btn: u8 = if (mouse_down) 32 else 35; // 32 = motion + left button
        const mlen = std.fmt.bufPrint(&mbuf, "\x1b[<{d};{d};{d}M", .{ btn, mcol + 1, mrow + 1 }) catch return;
        _ = pane.ptyWrite(mlen) catch {};
    } else {
        if (mcol + 33 < 256 and mrow + 33 < 256) {
            mbuf[0] = 0x1b;
            mbuf[1] = '[';
            mbuf[2] = 'M';
            mbuf[3] = if (mouse_down) 64 else 67; // motion flag + button
            mbuf[4] = @intCast(mcol + 33);
            mbuf[5] = @intCast(mrow + 33);
            _ = pane.ptyWrite(mbuf[0..6]) catch {};
        }
    }
}

// ── URL Handling ──────────────────────────────────────────────────

/// Handle Shift+click to open URL under cursor.
/// Returns true if a URL action was taken.
fn handleUrlClick(mux: *Multiplexer, row: u16, col: u16) bool {
    const pane = mux.getActivePane() orelse return false;
    const cell = pane.grid.cellAtConst(row, col);
    if (cell.hyperlink_id != 0) {
        // OSC 8 hyperlink — use explicit URI
        const entry = &pane.grid.hyperlinks[cell.hyperlink_id];
        if (entry.uri_len > 0) {
            UrlDetector.openUrl(entry.uri[0..entry.uri_len]);
            return true;
        }
    } else if (UrlDetector.findUrlAt(&pane.grid, row, col)) |match| {
        // Regex-free URL detection fallback
        const row_start = @as(usize, match.row) * @as(usize, pane.grid.cols);
        const row_cells = pane.grid.cells[row_start..][0..pane.grid.cols];
        var url_buf: [2048]u8 = undefined;
        const url_len = UrlDetector.extractUrl(row_cells, match, &url_buf);
        if (url_len > 0) {
            UrlDetector.openUrl(url_buf[0..url_len]);
            return true;
        }
    }
    return false;
}

/// Update URL hover state for Shift+hover underline.
fn updateUrlHover(mux: *Multiplexer, motion_x: u32, motion_y: u32, modifiers: u32, lp: LayoutParams, ms: *MouseState) void {
    if (modifiers & SHIFT_MASK != 0) {
        const hcol: u16 = @intCast(@min(motion_x / lp.cell_width, @as(u32, lp.grid_cols -| 1)));
        const hrow: u16 = @intCast(@min(motion_y / lp.cell_height, @as(u32, lp.grid_rows -| 1)));
        if (mux.getActivePane()) |pane| {
            if (UrlDetector.findUrlAt(&pane.grid, hrow, hcol)) |match| {
                if (!ms.hover_url_active or ms.hover_url_row != match.row or ms.hover_url_start != match.start_col or ms.hover_url_end != match.end_col) {
                    ms.hover_url_active = true;
                    ms.hover_url_row = match.row;
                    ms.hover_url_start = match.start_col;
                    ms.hover_url_end = match.end_col;
                    pane.grid.dirty = true;
                }
            } else if (ms.hover_url_active) {
                ms.hover_url_active = false;
                pane.grid.dirty = true;
            }
        }
    } else if (ms.hover_url_active) {
        ms.hover_url_active = false;
        if (mux.getActivePane()) |pane| pane.grid.dirty = true;
    }
}

// ── Selection Helpers ────────────────────────────────────────────

/// Copy selection text to clipboard and notify.
fn copySelectionToClipboard(mux: *Multiplexer, selection: *Selection) void {
    const pane = mux.getActivePane() orelse return;
    var sel_buf: [65536]u8 = undefined;
    const sb = pane.grid.scrollback;
    const len = selection.getText(&pane.grid, sb, &sel_buf);
    if (len > 0) {
        Clipboard.copy(sel_buf[0..len]);
        mux.notify("Copied to clipboard");
    }
}

// ── Border Drag Detection ────────────────────────────────────────

/// Check if a click is on a split or layout border, starting a drag if so.
/// Returns true if a border drag was started.
fn detectBorderDrag(mux: *Multiplexer, mouse_x: u32, mouse_y: u32, lp: LayoutParams, ms: *MouseState, win_width: u32, win_height: u32) bool {
    const ws = &mux.layout_engine.workspaces[mux.active_workspace];
    const click_screen = Rect{
        .x = @intCast(lp.padding),
        .y = @intCast(lp.padding),
        .width = @intCast(@min(win_width -| lp.padding * 2, std.math.maxInt(u16))),
        .height = @intCast(@min(win_height -| lp.padding * 2, std.math.maxInt(u16))),
    };

    // Tree split drag
    if (ws.split_root != null) {
        if (mux.layout_engine.workspaces[mux.active_workspace].findSplitForBorder(click_screen, mouse_x, mouse_y, 4)) |hit| {
            ms.border_dragging = true;
            const split_dir = mux.layout_engine.workspaces[mux.active_workspace].split_nodes[hit.node_idx].split.dir;
            ms.border_drag_x = if (split_dir == .horizontal) mouse_y else mouse_x;
            ms.border_drag_ratio = mux.layout_engine.workspaces[mux.active_workspace].split_nodes[hit.node_idx].split.ratio;
            ms.border_drag_node = hit.node_idx;
            return true;
        }
    }

    // Flat layout: detect master ratio border
    const layout = ws.layout;
    const ratio = ws.master_ratio;
    const zone: u32 = 4;
    const is_vertical = (layout == .master_stack or layout == .three_col);
    const is_horizontal = (layout == .dishes);
    if (is_vertical) {
        const border_x: u32 = @as(u32, click_screen.x) + @as(u32, @intFromFloat(@as(f32, @floatFromInt(click_screen.width)) * ratio));
        if (mouse_x >= border_x -| zone and mouse_x <= border_x + zone) {
            ms.border_dragging = true;
            ms.border_drag_x = mouse_x;
            ms.border_drag_ratio = ratio;
            ms.border_drag_node = std.math.maxInt(u16); // sentinel: flat layout
            return true;
        }
    } else if (is_horizontal) {
        const border_y: u32 = @as(u32, click_screen.y) + @as(u32, @intFromFloat(@as(f32, @floatFromInt(click_screen.height)) * ratio));
        if (mouse_y >= border_y -| zone and mouse_y <= border_y + zone) {
            ms.border_dragging = true;
            ms.border_drag_x = mouse_y; // store Y for horizontal
            ms.border_drag_ratio = ratio;
            ms.border_drag_node = std.math.maxInt(u16); // sentinel: flat layout
            return true;
        }
    }

    return false;
}

/// Handle click-to-focus: find which pane was clicked and focus it.
/// Returns true if focus changed.
fn handleClickToFocus(mux: *Multiplexer, allocator: std.mem.Allocator, mouse_x: u32, mouse_y: u32, lp: LayoutParams, win_width: u32, win_height: u32) bool {
    const ws = &mux.layout_engine.workspaces[mux.active_workspace];
    const click_screen = Rect{
        .x = @intCast(lp.padding),
        .y = @intCast(lp.padding),
        .width = @intCast(@min(win_width -| lp.padding * 2, std.math.maxInt(u16))),
        .height = @intCast(@min(win_height -| lp.padding * 2, std.math.maxInt(u16))),
    };

    var click_ids_buf: [64]u64 = undefined;
    const click_pane_ids = if (ws.split_root != null) blk: {
        const n = ws.getTreePaneIds(&click_ids_buf);
        break :blk click_ids_buf[0..n];
    } else ws.node_ids.items;

    _ = allocator;

    if (mux.layout_engine.calculate(mux.active_workspace, click_screen)) |click_rects| {
        defer mux.layout_engine.allocator.free(click_rects);
        for (click_rects, 0..) |cr, ci| {
            if (ci >= click_pane_ids.len) break;
            if (mouse_x >= cr.x and mouse_x < @as(u32, cr.x) + cr.width and
                mouse_y >= cr.y and mouse_y < @as(u32, cr.y) + cr.height)
            {
                if (ws.split_root != null) {
                    mux.layout_engine.workspaces[mux.active_workspace].active_node = click_pane_ids[ci];
                } else if (ci != ws.active_index) {
                    mux.layout_engine.workspaces[mux.active_workspace].active_index = ci;
                }
                for (mux.panes.items) |*p| p.grid.dirty = true;
                return true;
            }
        }
    } else |_| {}
    return false;
}

// ── Main Event Handlers ──────────────────────────────────────────

/// Handle a mouse press event.
pub fn handleMousePress(
    mux: *Multiplexer,
    mouse: platform_types.MouseEvent,
    selection: *Selection,
    ms: *MouseState,
    lp: LayoutParams,
    cfg: MouseConfig,
    allocator: std.mem.Allocator,
    win_width: u32,
    win_height: u32,
) PressResult {
    // Mouse reporting to PTY (modes 1000/1002/1003)
    if (reportMousePress(mux, mouse, lp, ms)) {
        return .{ .consumed = true };
    }

    switch (mouse.button) {
        .left => {
            // Status bar click: switch workspace
            if (cfg.show_status_bar) {
                const bar_h: u32 = lp.cell_height + 4;
                if (Ui.hitTestStatusBar(mux, lp.cell_width, lp.padding, win_height, bar_h, mouse.x, mouse.y)) |ws| {
                    mux.switchWorkspace(ws);
                    mux.resizePanePtys(win_width, win_height, lp.cell_width, lp.cell_height, lp.padding, lp.status_bar_h);
                    for (mux.panes.items) |*p| p.grid.dirty = true;
                    return .{ .consumed = true, .panes_changed = true };
                }
            }

            const col: u16 = @intCast(@min(mouse.x / lp.cell_width, @as(u32, lp.grid_cols -| 1)));
            const row: u16 = @intCast(@min(mouse.y / lp.cell_height, @as(u32, lp.grid_rows -| 1)));

            // Shift+click: open URL under cursor
            if (mouse.modifiers & SHIFT_MASK != 0) {
                _ = handleUrlClick(mux, row, col);
                return .{ .consumed = true };
            }

            // Multi-pane: border drag and click-to-focus
            const ws = &mux.layout_engine.workspaces[mux.active_workspace];
            var click_ids_buf: [64]u64 = undefined;
            const click_pane_ids = if (ws.split_root != null) blk: {
                const n = ws.getTreePaneIds(&click_ids_buf);
                break :blk click_ids_buf[0..n];
            } else ws.node_ids.items;

            if (click_pane_ids.len > 1) {
                if (detectBorderDrag(mux, mouse.x, mouse.y, lp, ms, win_width, win_height)) {
                    return .{ .consumed = true };
                }
                if (handleClickToFocus(mux, allocator, mouse.x, mouse.y, lp, win_width, win_height)) {
                    // Don't return consumed — continue to selection handling
                }
            }

            // Double-click: select word
            const click_now = compat.monotonicNow();
            if (click_now - ms.last_click_time < DOUBLE_CLICK_NS and
                row == ms.last_click_row and col == ms.last_click_col)
            {
                if (mux.getActivePane()) |pane| {
                    const so = mux.getScrollOffset();
                    const sbl: u32 = mux.getScrollbackLineCount();
                    selection.selectWord(&pane.grid, row, col, cfg.word_delimiters, so, sbl);
                    pane.grid.dirty = true;
                    if (cfg.copy_on_select) {
                        copySelectionToClipboard(mux, selection);
                    }
                }
                ms.last_click_time = 0; // prevent triple-click triggering
                return .{ .consumed = true, .dirty = true };
            }
            ms.last_click_time = click_now;
            ms.last_click_row = row;
            ms.last_click_col = col;

            // Clear any existing selection on click
            if (selection.active) {
                selection.clear();
                if (mux.getActivePane()) |pane| pane.grid.dirty = true;
            }
            // Record click position — don't start selection yet.
            // Selection only begins on mouse_motion (drag).
            ms.mouse_start_row = row;
            ms.mouse_start_col = col;
            ms.mouse_down = true;

            return .{};
        },
        .middle => {
            // Paste from clipboard (with bracketed paste wrapping)
            if (mux.getActivePaneMut()) |pane| {
                if (pane.vt.bracketed_paste) {
                    _ = pane.ptyWrite("\x1b[200~") catch {};
                }
                Clipboard.paste(&pane.backend.local);
                if (pane.vt.bracketed_paste) {
                    _ = pane.ptyWrite("\x1b[201~") catch {};
                }
            }
            return .{};
        },
        .scroll_up => {
            // Don't scroll teru's scrollback when alt screen is active
            const in_alt = if (mux.getActivePane()) |pane| pane.vt.alt_screen else false;
            if (!in_alt) {
                const max_offset = mux.getScrollbackLineCount();
                if (max_offset > 0) {
                    _ = mux.smoothScroll(@as(i32, @intCast(lp.cell_height)) * @as(i32, @intCast(cfg.scroll_speed)), lp.cell_height, max_offset);
                }
            }
            return .{};
        },
        .scroll_down => {
            const in_alt = if (mux.getActivePane()) |pane| pane.vt.alt_screen else false;
            if (!in_alt) {
                if (mux.getScrollOffset() > 0 or mux.getScrollPixel() > 0) {
                    const max_offset = mux.getScrollbackLineCount();
                    _ = mux.smoothScroll(-@as(i32, @intCast(lp.cell_height)) * @as(i32, @intCast(cfg.scroll_speed)), lp.cell_height, max_offset);
                }
            }
            return .{};
        },
        .right => return .{},
    }
}

/// Handle a mouse release event.
pub fn handleMouseRelease(
    mux: *Multiplexer,
    mouse: platform_types.MouseEvent,
    selection: *Selection,
    ms: *MouseState,
    lp: LayoutParams,
    cfg: MouseConfig,
) ReleaseResult {
    // Mouse release reporting to PTY
    reportMouseRelease(mux, mouse, lp);

    if (mouse.button == .left and ms.border_dragging) {
        ms.border_dragging = false;
        return .{ .consumed = true, .border_drag_finished = true };
    }

    if (mouse.button == .left and ms.mouse_down) {
        ms.mouse_down = false;
        // Don't process selection when mouse tracking is active
        const track_active = if (mux.getActivePane()) |pane| pane.vt.mouse_tracking != .none else false;
        if (track_active) return .{ .consumed = true };

        const col: u16 = @intCast(@min(mouse.x / lp.cell_width, @as(u32, lp.grid_cols -| 1)));
        const row: u16 = @intCast(@min(mouse.y / lp.cell_height, @as(u32, lp.grid_rows -| 1)));
        {
            const so = mux.getScrollOffset();
            const sbl: u32 = mux.getScrollbackLineCount();
            selection.update(row, col, so, sbl);
        }

        // Only finalize selection if mouse actually moved (not a single click)
        if (selection.start_row != selection.end_row or selection.start_col != selection.end_col) {
            selection.finish();
            if (cfg.copy_on_select) {
                copySelectionToClipboard(mux, selection);
            }
        } else {
            // Single click: clear selection (already cleared on press)
            selection.clear();
        }

        return .{ .dirty = true };
    }

    return .{};
}

/// Handle a mouse motion event.
pub fn handleMouseMotion(
    mux: *Multiplexer,
    motion_x: u32,
    motion_y: u32,
    modifiers: u32,
    selection: *Selection,
    ms: *MouseState,
    lp: LayoutParams,
    win_width: u32,
    win_height: u32,
) MotionResult {
    var result = MotionResult{};

    // Show mouse cursor when mouse moves
    if (ms.mouse_cursor_hidden) {
        result.show_cursor = true;
        ms.mouse_cursor_hidden = false;
    }

    // Border drag-to-resize
    if (ms.border_dragging) {
        const ws_mut = &mux.layout_engine.workspaces[mux.active_workspace];
        if (ws_mut.split_root != null and ms.border_drag_node != std.math.maxInt(u16)) {
            // Tree split drag — use correct axis based on split direction
            const node = ws_mut.split_nodes[ms.border_drag_node];
            const is_h = switch (node) {
                .split => |s| s.dir == .horizontal,
                .leaf => false,
            };
            const content_dim = if (is_h) win_height -| lp.padding * 2 else win_width -| lp.padding * 2;
            const mouse_pos = if (is_h) motion_y else motion_x;
            if (content_dim > 0) {
                const delta_px: i32 = @as(i32, @intCast(mouse_pos)) - @as(i32, @intCast(ms.border_drag_x));
                const delta_ratio: f32 = @as(f32, @floatFromInt(delta_px)) / @as(f32, @floatFromInt(content_dim));
                ws_mut.resizeSplit(ms.border_drag_node, std.math.clamp(ms.border_drag_ratio + delta_ratio, MASTER_RATIO_MIN, MASTER_RATIO_MAX));
            }
        } else {
            // Flat layout master_ratio drag
            const is_horizontal = (ws_mut.layout == .dishes);
            const content_size = if (is_horizontal) win_height -| lp.padding * 2 else win_width -| lp.padding * 2;
            const mouse_pos = if (is_horizontal) motion_y else motion_x;
            if (content_size > 0) {
                const delta_px: i32 = @as(i32, @intCast(mouse_pos)) - @as(i32, @intCast(ms.border_drag_x));
                const delta_ratio: f32 = @as(f32, @floatFromInt(delta_px)) / @as(f32, @floatFromInt(content_size));
                ws_mut.master_ratio = std.math.clamp(ms.border_drag_ratio + delta_ratio, MASTER_RATIO_MIN, MASTER_RATIO_MAX);
            }
        }
        for (mux.panes.items) |*p| p.grid.dirty = true;
        result.consumed = true;
        result.dirty = true;
        return result;
    }

    // Mouse motion reporting to PTY (modes 1002/1003)
    reportMouseMotion(mux, motion_x, motion_y, lp, ms.mouse_down);

    // Shift+hover: detect URL under cursor for underline
    updateUrlHover(mux, motion_x, motion_y, modifiers, lp, ms);

    // Only handle selection when mouse tracking is off (app handles mouse)
    const tracking_active = if (mux.getActivePane()) |pane| pane.vt.mouse_tracking != .none else false;
    if (ms.mouse_down and !tracking_active) {
        const col: u16 = @intCast(@min(motion_x / lp.cell_width, @as(u32, lp.grid_cols -| 1)));
        const row: u16 = @intCast(@min(motion_y / lp.cell_height, @as(u32, lp.grid_rows -| 1)));

        // Start selection on first drag movement
        if (!selection.active) {
            const so = mux.getScrollOffset();
            const sbl: u32 = mux.getScrollbackLineCount();
            selection.begin(ms.mouse_start_row, ms.mouse_start_col, so, sbl);
        }

        // Auto-scroll when dragging near viewport edges
        const in_alt = if (mux.getActivePane()) |pane| pane.vt.alt_screen else false;
        if (!in_alt) {
            const pane_rect = mux.getActivePaneRect(win_width, win_height, lp.padding, lp.status_bar_h);
            const edge_zone = lp.cell_height;
            const top_edge = if (pane_rect) |pr| @as(u32, pr.y) else 0;
            const bot_edge = if (pane_rect) |pr| @as(u32, pr.y) + pr.height else @as(u32, lp.grid_rows) * lp.cell_height;

            if (motion_y < top_edge + edge_zone) {
                const max_offset = mux.getScrollbackLineCount();
                if (max_offset > 0) {
                    _ = mux.smoothScroll(@as(i32, @intCast(lp.cell_height)), lp.cell_height, max_offset);
                }
            } else if (motion_y >= bot_edge -| edge_zone) {
                if (mux.getScrollOffset() > 0) {
                    const max_offset = mux.getScrollbackLineCount();
                    _ = mux.smoothScroll(-@as(i32, @intCast(lp.cell_height)), lp.cell_height, max_offset);
                }
            }
        }

        // Update selection AFTER auto-scroll so scroll_offset is current
        {
            const so = mux.getScrollOffset();
            const sbl: u32 = mux.getScrollbackLineCount();
            selection.update(row, col, so, sbl);
        }

        // Mark grid dirty so selection highlight redraws
        if (mux.getActivePane()) |pane| {
            pane.grid.dirty = true;
        }
        result.dirty = true;
    }

    return result;
}

// ── Tests ────────────────────────────────────────────────────────

test "MouseState: default init" {
    const ms = MouseState{};
    try std.testing.expect(!ms.mouse_down);
    try std.testing.expect(!ms.border_dragging);
    try std.testing.expect(!ms.hover_url_active);
    try std.testing.expect(!ms.mouse_cursor_hidden);
    try std.testing.expectEqual(@as(i128, 0), ms.last_click_time);
}

test "LayoutParams: struct fields" {
    const lp = LayoutParams{
        .cell_width = 8,
        .cell_height = 16,
        .grid_rows = 24,
        .grid_cols = 80,
        .padding = 4,
        .status_bar_h = 20,
    };
    try std.testing.expectEqual(@as(u32, 8), lp.cell_width);
    try std.testing.expectEqual(@as(u16, 24), lp.grid_rows);
}

test "constants: ratio bounds" {
    try std.testing.expect(MASTER_RATIO_MIN < MASTER_RATIO_MAX);
    try std.testing.expect(DOUBLE_CLICK_NS > 0);
}
