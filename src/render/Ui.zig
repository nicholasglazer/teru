//! UI overlay rendering: search bar, text status bar, character blitting.
//!
//! These functions render UI elements on top of the terminal grid.
//! Extracted from main.zig for modularity. Zero allocations in hot path.

const std = @import("std");
const SoftwareRenderer = @import("software.zig").SoftwareRenderer;
const Grid = @import("../core/Grid.zig");
const Multiplexer = @import("../core/Multiplexer.zig");
const FontAtlas = @import("FontAtlas.zig");
const Compositor = @import("Compositor.zig");
const Scrollback = @import("../persist/Scrollback.zig");
const LayoutEngine = @import("../tiling/LayoutEngine.zig");
const Rect = LayoutEngine.Rect;

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

/// Render the status bar at the very bottom of the framebuffer.
/// Layout: [workspace tabs] | [layout] [title]          [dimensions]
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

    // Clear bar area
    for (bar_y..fb_h) |y| {
        const row_start = y * fb_w;
        const end = @min(row_start + fb_w, cpu.framebuffer.len);
        if (row_start < end) @memset(cpu.framebuffer[row_start..end], s.bg);
    }

    // Top separator line
    if (bar_y > 0 and bar_y < fb_h) {
        const sep_start = bar_y * fb_w;
        const sep_end = @min(sep_start + fb_w, cpu.framebuffer.len);
        if (sep_start < sep_end) @memset(cpu.framebuffer[sep_start..sep_end], s.selection_bg);
    }

    const text_y = bar_y + 2;
    var x: usize = pad;

    // ── Left: workspace tabs ──
    // Show all workspaces that have panes or are active
    for (0..9) |wi| {
        const ws = &mux.layout_engine.workspaces[wi];
        const has_panes = ws.node_ids.items.len > 0;
        const is_active = wi == mux.active_workspace;
        if (!has_panes and !is_active) continue;

        blitCharAt(cpu, ' ', x, text_y, s.bg);
        x += cw;

        // Workspace number
        const ws_char: u8 = '1' + @as(u8, @intCast(wi));
        const ws_color = if (is_active) s.cursor else s.ansi[8];
        blitCharAt(cpu, ws_char, x, text_y, ws_color);
        x += cw;

        // :name (if workspace has a custom name)
        if (ws.name.len > 0 and ws.name[0] != ws_char) {
            blitCharAt(cpu, ':', x, text_y, s.ansi[8]);
            x += cw;
            for (ws.name) |c| {
                if (c < 32 or c > 126) continue;
                blitCharAt(cpu, c, x, text_y, ws_color);
                x += cw;
                if (x + cw > fb_w / 2) break; // don't overflow
            }
        }

        blitCharAt(cpu, ' ', x, text_y, s.bg);
        x += cw;
    }

    // Separator
    blitCharAt(cpu, '|', x, text_y, s.selection_bg);
    x += cw * 2;

    // ── Center: notification > PREFIX > layout + title ──
    const has_notification = blk: {
        if (mux.notification_len > 0) {
            var ts_now: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &ts_now);
            const now: i128 = @as(i128, ts_now.sec) * 1_000_000_000 + ts_now.nsec;
            if (now - mux.notification_time < mux.notification_duration_ns) break :blk true;
            const mux_mut: *Multiplexer = @constCast(mux);
            mux_mut.notification_len = 0;
        }
        break :blk false;
    };

    if (has_notification) {
        for (mux.notification[0..mux.notification_len]) |c| {
            blitCharAt(cpu, c, x, text_y, s.ansi[2]);
            x += cw;
        }
    } else if (prefix_active) {
        for ("PREFIX") |c| {
            blitCharAt(cpu, c, x, text_y, s.cursor);
            x += cw;
        }
    } else {
        // Layout indicator
        const active_ws = &mux.layout_engine.workspaces[mux.active_workspace];
        const layout_char: u8 = switch (active_ws.layout) {
            .master_stack => 'M',
            .grid => 'G',
            .monocle => '#',
            .floating => 'F',
        };
        blitCharAt(cpu, '[', x, text_y, s.ansi[8]);
        x += cw;
        blitCharAt(cpu, layout_char, x, text_y, s.ansi[5]); // magenta
        x += cw;
        blitCharAt(cpu, ']', x, text_y, s.ansi[8]);
        x += cw * 2;

        // Pane title (from OSC or "shell")
        if (@as(*Multiplexer, @constCast(mux)).getActivePaneMut()) |pane| {
            const title = if (pane.vt.title_len > 0)
                pane.vt.title[0..pane.vt.title_len]
            else
                "shell";
            for (title) |c| {
                if (c < 32 or c > 126) continue;
                blitCharAt(cpu, c, x, text_y, s.fg);
                x += cw;
                if (x + cw > fb_w * 2 / 3) break; // don't overflow into right section
            }
        }
    }

    // ── Right: scroll indicator + dimensions ──
    var right_buf: [64]u8 = undefined;
    const active_scroll = mux.getScrollOffset();
    const right_text = if (active_scroll > 0)
        std.fmt.bufPrint(&right_buf, "\xe2\x86\x91{d}  {d}x{d}", .{ active_scroll, grid_cols, grid_rows }) catch ""
    else
        std.fmt.bufPrint(&right_buf, "{d}x{d}", .{ grid_cols, grid_rows }) catch "";
    const right_start = if (fb_w > right_text.len * cw + cw + pad) fb_w - right_text.len * cw - cw - pad else 0;
    var rx = right_start;
    for (right_text) |ch_byte| {
        if (ch_byte >= '0' and ch_byte <= '9') {
            blitCharAt(cpu, ch_byte, rx, text_y, s.ansi[4]);
        } else {
            blitCharAt(cpu, ch_byte, rx, text_y, s.ansi[8]);
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
    pane_rect: Rect,
    scroll_pixel: i32,
) void {
    const fb_w: usize = cpu.width;
    const cw: usize = cell_width;
    const ch: usize = cell_height;
    const s = &cpu.scheme;

    const sb_lines: u32 = @intCast(sb.lineCount());
    if (sb_lines == 0) return;

    // Pane content area from layout rect
    const rx: usize = pane_rect.x;
    const ry: usize = pane_rect.y;
    const rw: usize = pane_rect.width;
    const rh: usize = pane_rect.height;
    if (rh < ch or rw < cw) return;

    // How many scrollback lines to render at the top of this pane.
    // Add 1 extra line when there's a pixel offset (partial line visible at boundary)
    const pane_rows: u32 = @intCast(rh / ch);
    const pixel_extra: u32 = if (scroll_pixel > 0) 1 else 0;
    const lines_to_show = @min(scroll_offset + pixel_extra, @min(sb_lines, pane_rows -| 1));

    // Total pixel shift: full lines + sub-cell pixel offset
    const sub_px: usize = if (scroll_pixel > 0) @intCast(scroll_pixel) else 0;
    const shift_px = lines_to_show * @as(u32, @intCast(ch)) -| @as(u32, @intCast(sub_px));
    if (shift_px > 0 and shift_px < rh) {
        var y: usize = ry + rh - 1;
        while (y >= ry + shift_px) : (y -= 1) {
            const dst_start = y * fb_w + rx;
            const src_start = (y - shift_px) * fb_w + rx;
            if (dst_start + rw <= cpu.framebuffer.len and src_start + rw <= cpu.framebuffer.len) {
                @memcpy(cpu.framebuffer[dst_start..][0..rw], cpu.framebuffer[src_start..][0..rw]);
            }
            if (y == ry) break;
        }
    }

    // Fill the top (shift_px) rows of the pane rect with background color
    for (ry..@min(ry + shift_px, ry + rh)) |y| {
        const row_start = y * fb_w + rx;
        if (row_start + rw <= cpu.framebuffer.len) {
            @memset(cpu.framebuffer[row_start..][0..rw], s.bg);
        }
    }

    // Render scrollback text into the top rows of the pane.
    // Parses SGR escape sequences to preserve fg/bg colors and attributes.
    var line: u32 = 0;
    while (line < lines_to_show) : (line += 1) {
        const sb_offset = scroll_offset - 1 - line;
        const text = sb.getLineByOffset(sb_offset) orelse continue;

        // Offset text Y by the sub-pixel amount (scrolls text up within the area)
        const base_y = ry + @as(usize, line) * ch;
        const screen_y = if (sub_px <= base_y) base_y - sub_px else 0;
        if (screen_y + ch > ry + rh) break;
        if (screen_y < ry) continue; // clipped above pane rect

        var col: usize = 0;
        var fg_color: u32 = s.fg;
        var bg_color: u32 = s.bg;
        var is_bold = false;
        var is_dim = false;
        var is_inverse = false;
        var i: usize = 0;
        while (i < text.len) {
            // Parse ESC [ ... m sequences for color/attrs
            if (i + 2 < text.len and text[i] == 0x1b and text[i + 1] == '[') {
                i += 2;
                var params: [8]u16 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
                var param_count: usize = 0;
                var num: u16 = 0;
                var has_num = false;
                while (i < text.len) : (i += 1) {
                    const c = text[i];
                    if (c >= '0' and c <= '9') {
                        num = num *| 10 +| (c - '0');
                        has_num = true;
                    } else if (c == ';') {
                        if (param_count < params.len) {
                            params[param_count] = num;
                            param_count += 1;
                        }
                        num = 0;
                        has_num = false;
                    } else {
                        if (has_num and param_count < params.len) {
                            params[param_count] = num;
                            param_count += 1;
                        }
                        if (c == 'm') {
                            if (param_count == 0) {
                                fg_color = s.fg;
                                bg_color = s.bg;
                                is_bold = false;
                                is_dim = false;
                                is_inverse = false;
                            }
                            var p: usize = 0;
                            while (p < param_count) : (p += 1) {
                                switch (params[p]) {
                                    0 => {
                                        fg_color = s.fg;
                                        bg_color = s.bg;
                                        is_bold = false;
                                        is_dim = false;
                                        is_inverse = false;
                                    },
                                    1 => is_bold = true,
                                    2 => is_dim = true,
                                    7 => is_inverse = true,
                                    22 => { is_bold = false; is_dim = false; },
                                    27 => is_inverse = false,
                                    30...37 => fg_color = s.ansi[params[p] - 30],
                                    38 => {
                                        if (p + 2 < param_count and params[p + 1] == 5) {
                                            fg_color = s.indexed256(@intCast(params[p + 2]));
                                            p += 2;
                                        } else if (p + 4 < param_count and params[p + 1] == 2) {
                                            const r = @as(u32, @min(255, params[p + 2]));
                                            const g = @as(u32, @min(255, params[p + 3]));
                                            const b = @as(u32, @min(255, params[p + 4]));
                                            fg_color = (0xFF << 24) | (r << 16) | (g << 8) | b;
                                            p += 4;
                                        }
                                    },
                                    39 => fg_color = s.fg,
                                    40...47 => bg_color = s.ansi[params[p] - 40],
                                    48 => {
                                        if (p + 2 < param_count and params[p + 1] == 5) {
                                            bg_color = s.indexed256(@intCast(params[p + 2]));
                                            p += 2;
                                        } else if (p + 4 < param_count and params[p + 1] == 2) {
                                            const r = @as(u32, @min(255, params[p + 2]));
                                            const g = @as(u32, @min(255, params[p + 3]));
                                            const b = @as(u32, @min(255, params[p + 4]));
                                            bg_color = (0xFF << 24) | (r << 16) | (g << 8) | b;
                                            p += 4;
                                        }
                                    },
                                    49 => bg_color = s.bg,
                                    90...97 => fg_color = s.ansi[params[p] - 90 + 8],
                                    100...107 => bg_color = s.ansi[params[p] - 100 + 8],
                                    else => {},
                                }
                            }
                        }
                        i += 1;
                        break;
                    }
                }
                continue;
            }

            // Decode UTF-8 codepoint
            const byte = text[i];
            if (byte < 32) { i += 1; continue; }

            var cp: u21 = 0;
            var seq_len: usize = 1;
            if (byte < 0x80) {
                cp = byte;
            } else if (byte < 0xC0) {
                i += 1; continue; // continuation byte, skip
            } else if (byte < 0xE0) {
                seq_len = 2;
                if (i + 2 > text.len) { i += 1; continue; }
                cp = (@as(u21, byte & 0x1F) << 6) | @as(u21, text[i + 1] & 0x3F);
            } else if (byte < 0xF0) {
                seq_len = 3;
                if (i + 3 > text.len) { i += 1; continue; }
                cp = (@as(u21, byte & 0x0F) << 12) | (@as(u21, text[i + 1] & 0x3F) << 6) | @as(u21, text[i + 2] & 0x3F);
            } else {
                seq_len = 4;
                if (i + 4 > text.len) { i += 1; continue; }
                cp = (@as(u21, byte & 0x07) << 18) | (@as(u21, text[i + 1] & 0x3F) << 12) |
                    (@as(u21, text[i + 2] & 0x3F) << 6) | @as(u21, text[i + 3] & 0x3F);
            }
            i += seq_len;

            const screen_x = rx + col * cw;
            if (screen_x + cw > rx + rw) break;

            // Apply inverse and dim
            var eff_fg = fg_color;
            var eff_bg = bg_color;
            if (is_inverse) { eff_fg = bg_color; eff_bg = fg_color; }
            if (is_dim) eff_fg = s.dimColor(eff_fg);

            // Fill cell background
            const max_y = @min(screen_y + ch, ry + rh);
            const max_x = @min(screen_x + cw, rx + rw);
            if (eff_bg != s.bg) {
                for (screen_y..max_y) |py| {
                    if (py >= cpu.height) break;
                    const row_start = py * fb_w;
                    if (row_start + max_x <= cpu.framebuffer.len and screen_x < max_x) {
                        @memset(cpu.framebuffer[row_start + screen_x .. row_start + max_x], eff_bg);
                    }
                }
            }

            // Blit glyph using atlas (supports box-drawing, Latin-1, etc.)
            if (cpu.atlas_width > 0 and cpu.glyph_atlas.len > 0) {
                if (FontAtlas.glyphSlot(@intCast(cp))) |slot| {
                    const atlas = cpu.getAtlasForAttrs(is_bold, false);
                    Compositor.blitGlyphInRect(cpu, @intCast(slot), screen_x, screen_y, max_x, max_y, eff_fg, eff_bg, atlas);
                } else if (cp < 127 and cp >= 32) {
                    // Fallback to simple ASCII blit
                    blitCharAt(cpu, @intCast(cp), screen_x, screen_y, eff_fg);
                }
            }
            col += 1;
        }
    }
}
