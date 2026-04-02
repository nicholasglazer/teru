//! UI overlay rendering: search bar, text status bar, character blitting.
//!
//! These functions render UI elements on top of the terminal grid.
//! Extracted from main.zig for modularity. Zero allocations in hot path.

const std = @import("std");
const SoftwareRenderer = @import("software.zig").SoftwareRenderer;
const Grid = @import("../core/Grid.zig");
const Multiplexer = @import("../core/Multiplexer.zig");
const FontAtlas = @import("FontAtlas.zig");
const Scrollback = @import("../persist/Scrollback.zig");

// ── Search overlay (Feature 9) ───────────────────────────────────

/// Render search highlights on matching cells and draw search input bar.
pub fn renderSearchOverlay(
    cpu: *SoftwareRenderer,
    grid: *const Grid,
    query: []const u8,
    active: bool,
    cell_width: u32,
    cell_height: u32,
) void {
    const fb_w: usize = cpu.width;
    const fb_h: usize = cpu.height;
    const cw: usize = cell_width;
    const ch: usize = cell_height;

    // Highlight matching cells with a yellow tint
    if (query.len > 0) {
        for (0..grid.rows) |row| {
            var col: usize = 0;
            while (col + query.len <= grid.cols) {
                var match = true;
                for (query, 0..) |qch, qi| {
                    const cell = grid.cellAtConst(@intCast(row), @intCast(col + qi));
                    const cell_lower: u8 = if (cell.char >= 'A' and cell.char <= 'Z') @intCast(cell.char + 32) else if (cell.char < 128) @intCast(cell.char) else 0;
                    const q_lower: u8 = if (qch >= 'A' and qch <= 'Z') qch + 32 else qch;
                    if (cell_lower != q_lower) {
                        match = false;
                        break;
                    }
                }

                if (match) {
                    for (0..query.len) |qi| {
                        const sx = (col + qi) * cw;
                        const sy = row * ch;
                        for (sy..@min(sy + ch, fb_h)) |py| {
                            for (sx..@min(sx + cw, fb_w)) |px| {
                                const idx = py * fb_w + px;
                                if (idx < cpu.framebuffer.len) {
                                    const orig = cpu.framebuffer[idx];
                                    const r: u32 = (orig >> 16) & 0xFF;
                                    const g: u32 = (orig >> 8) & 0xFF;
                                    const b: u32 = orig & 0xFF;
                                    const nr: u32 = @min(255, (r * 6 + 255 * 4) / 10);
                                    const ng: u32 = @min(255, (g * 6 + 204 * 4) / 10);
                                    const nb: u32 = b * 6 / 10;
                                    cpu.framebuffer[idx] = (@as(u32, 0xFF) << 24) | (nr << 16) | (ng << 8) | nb;
                                }
                            }
                        }
                    }
                    col += query.len;
                } else {
                    col += 1;
                }
            }
        }
    }

    // Draw search bar at the bottom if actively searching
    if (active) {
        const bar_h: usize = ch + 4;
        if (fb_h < bar_h + 10) return;
        const bar_y = fb_h - bar_h;
        const s = &cpu.scheme;
        const bar_bg = s.ansi[0];

        for (bar_y..fb_h) |y| {
            if (y >= fb_h) break;
            const row_start = y * fb_w;
            const end = @min(row_start + fb_w, cpu.framebuffer.len);
            if (row_start < end) {
                @memset(cpu.framebuffer[row_start..end], bar_bg);
            }
        }

        // Accent separator line
        if (bar_y > 0) {
            const sep_start = bar_y * fb_w;
            const sep_end = @min(sep_start + fb_w, cpu.framebuffer.len);
            if (sep_start < sep_end) {
                @memset(cpu.framebuffer[sep_start..sep_end], s.cursor);
            }
        }

        // Render prompt and query text
        const text_y = bar_y + 2;
        var text_x: usize = 4;

        blitCharAt(cpu, '/', text_x, text_y, s.cursor);
        text_x += cw;

        for (query) |qch| {
            blitCharAt(cpu, qch, text_x, text_y, s.fg);
            text_x += cw;
        }

        // Cursor line
        for (text_y..@min(text_y + ch, fb_h)) |py| {
            if (text_x < fb_w) {
                const idx = py * fb_w + text_x;
                if (idx < cpu.framebuffer.len) {
                    cpu.framebuffer[idx] = s.fg;
                }
            }
        }
    }
}

// ── Text status bar (Feature 10) ─────────────────────────────────

/// Render a text status bar at the very bottom of the framebuffer.
pub fn renderTextStatusBar(
    cpu: *SoftwareRenderer,
    mux: *const Multiplexer,
    grid_cols: u16,
    grid_rows: u16,
    cell_width: u32,
    cell_height: u32,
    prefix_active: bool,
) void {
    const fb_w: usize = cpu.width;
    const fb_h: usize = cpu.height;
    const ch: usize = cell_height;
    const cw: usize = cell_width;
    const pad: usize = cpu.padding;

    const s = &cpu.scheme;
    const bar_h: usize = ch + 4;
    if (fb_h < bar_h + ch) return;
    const bar_y = fb_h - bar_h;

    for (bar_y..fb_h) |y| {
        if (y >= fb_h) break;
        const row_start = y * fb_w;
        const end = @min(row_start + fb_w, cpu.framebuffer.len);
        if (row_start < end) {
            @memset(cpu.framebuffer[row_start..end], s.bg);
        }
    }

    // Top separator
    if (bar_y > 0 and bar_y < fb_h) {
        const sep_start = bar_y * fb_w;
        const sep_end = @min(sep_start + fb_w, cpu.framebuffer.len);
        if (sep_start < sep_end) {
            @memset(cpu.framebuffer[sep_start..sep_end], s.selection_bg);
        }
    }

    const text_y = bar_y + 2;

    // Left: workspace + pane info (with left padding)
    var left_buf: [64]u8 = undefined;
    const ws_num = mux.active_workspace + 1;
    const active_idx = blk: {
        const ws = &mux.layout_engine.workspaces[mux.active_workspace];
        break :blk ws.active_index + 1;
    };
    const total_panes = mux.panes.items.len;
    const left_text = std.fmt.bufPrint(&left_buf, " [{d}] {d}/{d}", .{ ws_num, active_idx, total_panes }) catch " [?]";

    var x: usize = pad;
    for (left_text) |ch_byte| {
        if (ch_byte == '[' or ch_byte == ']') {
            blitCharAt(cpu, ch_byte, x, text_y, s.cursor);
        } else if (ch_byte >= '0' and ch_byte <= '9') {
            blitCharAt(cpu, ch_byte, x, text_y, s.ansi[6]); // cyan
        } else {
            blitCharAt(cpu, ch_byte, x, text_y, s.ansi[8]); // bright black
        }
        x += cw;
    }

    // Separator
    x += cw;
    blitCharAt(cpu, '|', x, text_y, s.selection_bg);
    x += cw * 2;

    // Center: label (or PREFIX indicator when prefix key is active)
    if (prefix_active) {
        const prefix_text = "PREFIX";
        for (prefix_text) |ch_byte| {
            blitCharAt(cpu, ch_byte, x, text_y, s.cursor); // bright accent color
            x += cw;
        }
    } else {
        const center_text = "shell";
        for (center_text) |ch_byte| {
            blitCharAt(cpu, ch_byte, x, text_y, s.fg);
            x += cw;
        }
    }

    // Right: scroll indicator + dimensions + help hint
    var right_buf: [96]u8 = undefined;
    const right_text = if (mux.scroll_offset > 0)
        std.fmt.bufPrint(&right_buf, "\xe2\x86\x91{d}  {d}x{d}  C-Space ?", .{ mux.scroll_offset, grid_cols, grid_rows }) catch ""
    else
        std.fmt.bufPrint(&right_buf, "{d}x{d}  C-Space ?", .{ grid_cols, grid_rows }) catch "";
    const right_start = if (fb_w > right_text.len * cw + cw + pad) fb_w - right_text.len * cw - cw - pad else 0;
    var rx = right_start;
    for (right_text) |ch_byte| {
        if (ch_byte >= '0' and ch_byte <= '9') {
            blitCharAt(cpu, ch_byte, rx, text_y, s.ansi[4]); // blue
        } else {
            blitCharAt(cpu, ch_byte, rx, text_y, s.ansi[8]); // bright black
        }
        rx += cw;
    }
}

// ── Character blitting ────────────────────────────────────────────

/// Blit a single character at a pixel position using the atlas.
pub fn blitCharAt(cpu: *SoftwareRenderer, char: u8, screen_x: usize, screen_y: usize, fg: u32) void {
    if (char < 32 or char >= 127) return;
    if (cpu.atlas_width == 0 or cpu.glyph_atlas.len == 0) return;

    const cw: usize = cpu.cell_width;
    const ch: usize = cpu.cell_height;
    const aw: usize = cpu.atlas_width;
    const fb_w: usize = cpu.width;
    const fb_h: usize = cpu.height;

    const glyph_index: usize = char - 32;
    const glyphs_per_row = if (aw >= cw) aw / cw else return;
    const glyph_row = glyph_index / glyphs_per_row;
    const glyph_col = glyph_index % glyphs_per_row;
    const atlas_x = glyph_col * cw;
    const atlas_y = glyph_row * ch;

    const fg_r: u16 = @truncate((fg >> 16) & 0xFF);
    const fg_g: u16 = @truncate((fg >> 8) & 0xFF);
    const fg_b: u16 = @truncate(fg & 0xFF);

    for (0..ch) |dy| {
        if (screen_y + dy >= fb_h) break;
        if (atlas_y + dy >= cpu.atlas_height) break;
        const atlas_row_offset = (atlas_y + dy) * aw + atlas_x;
        if (atlas_row_offset + cw > cpu.glyph_atlas.len) break;

        for (0..cw) |dx| {
            if (screen_x + dx >= fb_w) break;
            const alpha: u16 = cpu.glyph_atlas[atlas_row_offset + dx];
            if (alpha == 0) continue;

            const fb_idx = (screen_y + dy) * fb_w + (screen_x + dx);
            if (fb_idx >= cpu.framebuffer.len) continue;

            if (alpha == 255) {
                cpu.framebuffer[fb_idx] = fg;
            } else {
                const bg = cpu.framebuffer[fb_idx];
                const bg_r: u16 = @truncate((bg >> 16) & 0xFF);
                const bg_g: u16 = @truncate((bg >> 8) & 0xFF);
                const bg_b: u16 = @truncate(bg & 0xFF);
                const inv: u16 = 255 - alpha;
                const r = (fg_r * alpha + bg_r * inv) / 255;
                const g = (fg_g * alpha + bg_g * inv) / 255;
                const b = (fg_b * alpha + bg_b * inv) / 255;
                cpu.framebuffer[fb_idx] = (0xFF << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
            }
        }
    }
}

// ── Scroll overlay (non-destructive) ──────────────────────────────

/// Render scrollback lines onto the framebuffer WITHOUT modifying the grid.
/// Paints scrollback text over the top N rows of the rendered frame,
/// shifting the visible content down by scroll_offset lines.
pub fn renderScrollOverlay(
    cpu: *SoftwareRenderer,
    sb: *const Scrollback,
    scroll_offset: u32,
    cell_width: u32,
    cell_height: u32,
) void {
    const fb_w: usize = cpu.width;
    const fb_h: usize = cpu.height;
    const cw: usize = cell_width;
    const ch: usize = cell_height;
    const pad: usize = cpu.padding;
    const s = &cpu.scheme;

    const sb_lines: u32 = @intCast(sb.lineCount());
    if (sb_lines == 0) return;

    // How many scrollback lines to render at the top of the screen
    const lines_to_show = @min(scroll_offset, sb_lines);

    // Shift the existing framebuffer content DOWN by (lines_to_show * ch) pixels.
    // We do this by copying rows bottom-to-top to avoid overlap corruption.
    const shift_px = lines_to_show * @as(u32, @intCast(ch));
    if (shift_px > 0 and shift_px < fb_h) {
        var y: usize = fb_h - 1;
        while (y >= shift_px) : (y -= 1) {
            const dst_start = y * fb_w;
            const src_start = (y - shift_px) * fb_w;
            if (dst_start + fb_w <= cpu.framebuffer.len and src_start + fb_w <= cpu.framebuffer.len) {
                @memcpy(cpu.framebuffer[dst_start..][0..fb_w], cpu.framebuffer[src_start..][0..fb_w]);
            }
            if (y == 0) break;
        }
    }

    // Fill the top (shift_px) rows with background color
    const fill_end = @min(shift_px * fb_w, cpu.framebuffer.len);
    @memset(cpu.framebuffer[0..fill_end], s.bg);

    // Render scrollback text into the top rows
    // scrollback offset 0 = most recent line, offset N = N lines back
    // We want to show: lines [scroll_offset - lines_to_show, scroll_offset) from bottom
    var line: u32 = 0;
    while (line < lines_to_show) : (line += 1) {
        // Which scrollback line? offset 0=newest, so for the topmost visible row
        // we want the oldest of the shown lines
        const sb_offset = scroll_offset - 1 - line;
        const text = sb.getLineByOffset(sb_offset) orelse continue;

        const screen_y = pad + @as(usize, line) * ch;
        if (screen_y + ch > fb_h) break;

        var col: usize = 0;
        for (text) |byte| {
            if (byte < 32 or byte > 126) continue; // skip non-printable
            const screen_x = pad + col * cw;
            if (screen_x + cw > fb_w) break;

            // Blit character from atlas (dim color for scrollback)
            blitCharAt(cpu, byte, screen_x, screen_y, s.ansi[8]);
            col += 1;
        }
    }
}
