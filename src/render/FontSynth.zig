//! Programmatic box-drawing + block-element synthesis.
//!
//! Fonts vary wildly in how they render Unicode box-drawing (U+2500–257F)
//! and block elements (U+2580–259F). Seams appear where glyphs don't
//! quite touch, heavy/double variants are missing, corners don't align.
//! Rather than rely on the font, we paint these glyphs directly into
//! the atlas bitmap.
//!
//! Each box-drawing codepoint is encoded as four connections (left,
//! right, up, down) with weights 0=none, 1=light, 2=heavy, 3=double.
//! Block elements are simple filled rectangles at rational fractions
//! of the cell.
//!
//! Public entrypoints:
//!   * drawBoxDrawing — overwrite U+2500–257F slots
//!   * drawBlocks     — overwrite U+2580–259F slots
//!
//! Both operate on the grayscale atlas bitmap the caller owns; value
//! 255 = opaque pixel, 0 = transparent. Diagonal codepoints
//! (U+2571–2573) keep their font glyphs since the straight-segment
//! encoding doesn't fit them.
//!
//! Slot resolution matches FontAtlas.glyphSlot; a small local copy
//! avoids the FontAtlas↔FontSynth import cycle.

// ── Internal: slot lookup matching FontAtlas.glyphSlot ──────────────

fn glyphSlot(codepoint: u21) ?u32 {
    if (codepoint >= 0x2500 and codepoint < 0x2580) return @as(u32, codepoint - 0x2500) + 95 + 96;
    if (codepoint >= 0x2580 and codepoint < 0x25A0) return @as(u32, codepoint - 0x2580) + 95 + 96 + 128;
    return null;
}

// ── Box-drawing encoding table ─────────────────────────────────────

const BoxConn = packed struct {
    left: u2 = 0,
    right: u2 = 0,
    up: u2 = 0,
    down: u2 = 0,
};

/// Connection weight lookup for U+2500..U+257F (128 entries).
/// Dashed variants use the same connection pattern as solid. Double
/// lines use weight 3. Diagonals (U+2571–2573) left as zero to fall
/// back on the font glyph.
const box_connections: [128]BoxConn = blk: {
    var t: [128]BoxConn = @splat(.{});
    // U+2500 ─  U+2501 ━
    t[0x00] = .{ .left = 1, .right = 1 };
    t[0x01] = .{ .left = 2, .right = 2 };
    // U+2502 │  U+2503 ┃
    t[0x02] = .{ .up = 1, .down = 1 };
    t[0x03] = .{ .up = 2, .down = 2 };
    // U+2504-250B: dashed variants
    t[0x04] = .{ .left = 1, .right = 1 };
    t[0x05] = .{ .left = 2, .right = 2 };
    t[0x06] = .{ .up = 1, .down = 1 };
    t[0x07] = .{ .up = 2, .down = 2 };
    t[0x08] = .{ .left = 1, .right = 1 };
    t[0x09] = .{ .left = 2, .right = 2 };
    t[0x0A] = .{ .up = 1, .down = 1 };
    t[0x0B] = .{ .up = 2, .down = 2 };
    // U+250C-250F: down+right corners
    t[0x0C] = .{ .right = 1, .down = 1 };
    t[0x0D] = .{ .right = 2, .down = 1 };
    t[0x0E] = .{ .right = 1, .down = 2 };
    t[0x0F] = .{ .right = 2, .down = 2 };
    // U+2510-2513: down+left corners
    t[0x10] = .{ .left = 1, .down = 1 };
    t[0x11] = .{ .left = 2, .down = 1 };
    t[0x12] = .{ .left = 1, .down = 2 };
    t[0x13] = .{ .left = 2, .down = 2 };
    // U+2514-2517: up+right corners
    t[0x14] = .{ .right = 1, .up = 1 };
    t[0x15] = .{ .right = 2, .up = 1 };
    t[0x16] = .{ .right = 1, .up = 2 };
    t[0x17] = .{ .right = 2, .up = 2 };
    // U+2518-251B: up+left corners
    t[0x18] = .{ .left = 1, .up = 1 };
    t[0x19] = .{ .left = 2, .up = 1 };
    t[0x1A] = .{ .left = 1, .up = 2 };
    t[0x1B] = .{ .left = 2, .up = 2 };
    // U+251C-2523: vertical+right T-junctions
    t[0x1C] = .{ .right = 1, .up = 1, .down = 1 };
    t[0x1D] = .{ .right = 2, .up = 1, .down = 1 };
    t[0x1E] = .{ .right = 1, .up = 2, .down = 1 };
    t[0x1F] = .{ .right = 1, .up = 1, .down = 2 };
    t[0x20] = .{ .right = 1, .up = 2, .down = 2 };
    t[0x21] = .{ .right = 2, .up = 2, .down = 1 };
    t[0x22] = .{ .right = 2, .up = 1, .down = 2 };
    t[0x23] = .{ .right = 2, .up = 2, .down = 2 };
    // U+2524-252B: vertical+left T-junctions
    t[0x24] = .{ .left = 1, .up = 1, .down = 1 };
    t[0x25] = .{ .left = 2, .up = 1, .down = 1 };
    t[0x26] = .{ .left = 1, .up = 2, .down = 1 };
    t[0x27] = .{ .left = 1, .up = 1, .down = 2 };
    t[0x28] = .{ .left = 1, .up = 2, .down = 2 };
    t[0x29] = .{ .left = 2, .up = 2, .down = 1 };
    t[0x2A] = .{ .left = 2, .up = 1, .down = 2 };
    t[0x2B] = .{ .left = 2, .up = 2, .down = 2 };
    // U+252C-2533: horizontal+down T-junctions
    t[0x2C] = .{ .left = 1, .right = 1, .down = 1 };
    t[0x2D] = .{ .left = 2, .right = 1, .down = 1 };
    t[0x2E] = .{ .left = 1, .right = 2, .down = 1 };
    t[0x2F] = .{ .left = 2, .right = 2, .down = 1 };
    t[0x30] = .{ .left = 1, .right = 1, .down = 2 };
    t[0x31] = .{ .left = 2, .right = 1, .down = 2 };
    t[0x32] = .{ .left = 1, .right = 2, .down = 2 };
    t[0x33] = .{ .left = 2, .right = 2, .down = 2 };
    // U+2534-253B: horizontal+up T-junctions
    t[0x34] = .{ .left = 1, .right = 1, .up = 1 };
    t[0x35] = .{ .left = 2, .right = 1, .up = 1 };
    t[0x36] = .{ .left = 1, .right = 2, .up = 1 };
    t[0x37] = .{ .left = 2, .right = 2, .up = 1 };
    t[0x38] = .{ .left = 1, .right = 1, .up = 2 };
    t[0x39] = .{ .left = 2, .right = 1, .up = 2 };
    t[0x3A] = .{ .left = 1, .right = 2, .up = 2 };
    t[0x3B] = .{ .left = 2, .right = 2, .up = 2 };
    // U+253C-254B: crosses
    t[0x3C] = .{ .left = 1, .right = 1, .up = 1, .down = 1 };
    t[0x3D] = .{ .left = 2, .right = 1, .up = 1, .down = 1 };
    t[0x3E] = .{ .left = 1, .right = 2, .up = 1, .down = 1 };
    t[0x3F] = .{ .left = 2, .right = 2, .up = 1, .down = 1 };
    t[0x40] = .{ .left = 1, .right = 1, .up = 2, .down = 1 };
    t[0x41] = .{ .left = 1, .right = 1, .up = 1, .down = 2 };
    t[0x42] = .{ .left = 1, .right = 1, .up = 2, .down = 2 };
    t[0x43] = .{ .left = 2, .right = 1, .up = 2, .down = 1 };
    t[0x44] = .{ .left = 1, .right = 2, .up = 2, .down = 1 };
    t[0x45] = .{ .left = 2, .right = 1, .up = 1, .down = 2 };
    t[0x46] = .{ .left = 1, .right = 2, .up = 1, .down = 2 };
    t[0x47] = .{ .left = 2, .right = 2, .up = 2, .down = 1 };
    t[0x48] = .{ .left = 2, .right = 2, .up = 1, .down = 2 };
    t[0x49] = .{ .left = 2, .right = 1, .up = 2, .down = 2 };
    t[0x4A] = .{ .left = 1, .right = 2, .up = 2, .down = 2 };
    t[0x4B] = .{ .left = 2, .right = 2, .up = 2, .down = 2 };
    // U+254C-254F: dashed double
    t[0x4C] = .{ .left = 1, .right = 1 };
    t[0x4D] = .{ .left = 2, .right = 2 };
    t[0x4E] = .{ .up = 1, .down = 1 };
    t[0x4F] = .{ .up = 2, .down = 2 };
    // U+2550-256C: double-line variants
    t[0x50] = .{ .left = 3, .right = 3 };
    t[0x51] = .{ .up = 3, .down = 3 };
    t[0x52] = .{ .right = 3, .down = 1 };
    t[0x53] = .{ .right = 1, .down = 3 };
    t[0x54] = .{ .right = 3, .down = 3 };
    t[0x55] = .{ .left = 3, .down = 1 };
    t[0x56] = .{ .left = 1, .down = 3 };
    t[0x57] = .{ .left = 3, .down = 3 };
    t[0x58] = .{ .right = 3, .up = 1 };
    t[0x59] = .{ .right = 1, .up = 3 };
    t[0x5A] = .{ .right = 3, .up = 3 };
    t[0x5B] = .{ .left = 3, .up = 1 };
    t[0x5C] = .{ .left = 1, .up = 3 };
    t[0x5D] = .{ .left = 3, .up = 3 };
    t[0x5E] = .{ .right = 3, .up = 1, .down = 1 };
    t[0x5F] = .{ .right = 1, .up = 3, .down = 3 };
    t[0x60] = .{ .right = 3, .up = 3, .down = 3 };
    t[0x61] = .{ .left = 3, .up = 1, .down = 1 };
    t[0x62] = .{ .left = 1, .up = 3, .down = 3 };
    t[0x63] = .{ .left = 3, .up = 3, .down = 3 };
    t[0x64] = .{ .left = 3, .right = 3, .down = 1 };
    t[0x65] = .{ .left = 1, .right = 1, .down = 3 };
    t[0x66] = .{ .left = 3, .right = 3, .down = 3 };
    t[0x67] = .{ .left = 3, .right = 3, .up = 1 };
    t[0x68] = .{ .left = 1, .right = 1, .up = 3 };
    t[0x69] = .{ .left = 3, .right = 3, .up = 3 };
    t[0x6A] = .{ .left = 3, .right = 3, .up = 1, .down = 1 };
    t[0x6B] = .{ .left = 1, .right = 1, .up = 3, .down = 3 };
    t[0x6C] = .{ .left = 3, .right = 3, .up = 3, .down = 3 };
    // U+256D-2570: rounded corners (drawn as regular corners)
    t[0x6D] = .{ .right = 1, .down = 1 };
    t[0x6E] = .{ .left = 1, .down = 1 };
    t[0x6F] = .{ .left = 1, .up = 1 };
    t[0x70] = .{ .right = 1, .up = 1 };
    // U+2571-2573: diagonals skipped (font glyph kept)
    // U+2574-257F: half lines
    t[0x74] = .{ .left = 1 };
    t[0x75] = .{ .up = 1 };
    t[0x76] = .{ .right = 1 };
    t[0x77] = .{ .down = 1 };
    t[0x78] = .{ .left = 2 };
    t[0x79] = .{ .up = 2 };
    t[0x7A] = .{ .right = 2 };
    t[0x7B] = .{ .down = 2 };
    t[0x7C] = .{ .left = 1, .right = 2 };
    t[0x7D] = .{ .up = 1, .down = 2 };
    t[0x7E] = .{ .left = 2, .right = 1 };
    t[0x7F] = .{ .up = 2, .down = 1 };
    break :blk t;
};

// ── Public entrypoints ─────────────────────────────────────────────

/// Overwrite box-drawing glyph slots (U+2500..U+257F) in the atlas
/// with programmatic rendering.
pub fn drawBoxDrawing(atlas: []u8, aw: u32, cw: u32, ch: u32, glyphs_per_row: u32) void {
    for (0..128) |idx| {
        const conn = box_connections[idx];
        if (@as(u8, @bitCast(conn)) == 0) continue; // skip empty (diagonals)

        const slot = glyphSlot(@as(u21, @intCast(0x2500 + idx))) orelse continue;
        const glyph_col = slot % glyphs_per_row;
        const glyph_row = slot / glyphs_per_row;
        const ax: u32 = glyph_col * cw;
        const ay: u32 = glyph_row * ch;

        clearSlot(atlas, aw, ax, ay, cw, ch);

        const cx = cw / 2;
        const cy = ch / 2;

        // Light = 1px; heavy = ~cw/4 (min 2px); double = two 1px lines with a 2px gap.
        const heavy_w: u32 = @max(2, cw / 4);
        const heavy_h: u32 = @max(2, ch / 4);

        if (conn.left > 0) drawHSegment(atlas, aw, ax, ay, 0, cx, cy, conn.left, cw, ch, heavy_w, heavy_h);
        if (conn.right > 0) drawHSegment(atlas, aw, ax, ay, cx, cw, cy, conn.right, cw, ch, heavy_w, heavy_h);
        if (conn.up > 0) drawVSegment(atlas, aw, ax, ay, 0, cy, cx, conn.up, cw, ch, heavy_w, heavy_h);
        if (conn.down > 0) drawVSegment(atlas, aw, ax, ay, cy, ch, cx, conn.down, cw, ch, heavy_w, heavy_h);
    }
}

/// Overwrite block element glyph slots (U+2580..U+259F) with simple
/// filled rectangles at rational fractions of the cell.
pub fn drawBlocks(atlas: []u8, aw: u32, cw: u32, ch: u32, glyphs_per_row: u32) void {
    for (0x2580..0x25A0) |cp| {
        const slot = glyphSlot(@as(u21, @intCast(cp))) orelse continue;
        const glyph_col = slot % glyphs_per_row;
        const glyph_row = slot / glyphs_per_row;
        const ax: u32 = glyph_col * cw;
        const ay: u32 = glyph_row * ch;

        clearSlot(atlas, aw, ax, ay, cw, ch);

        switch (@as(u21, @intCast(cp))) {
            0x2580 => fillRect(atlas, aw, ax, ay, cw, ch / 2), // ▀ upper half
            0x2581 => fillRect(atlas, aw, ax, ay + ch - ch / 8, cw, ch / 8), // ▁ lower 1/8
            0x2582 => fillRect(atlas, aw, ax, ay + ch - ch / 4, cw, ch / 4), // ▂ lower 1/4
            0x2583 => fillRect(atlas, aw, ax, ay + ch - ch * 3 / 8, cw, ch * 3 / 8), // ▃ lower 3/8
            0x2584 => fillRect(atlas, aw, ax, ay + ch / 2, cw, ch / 2), // ▄ lower half
            0x2585 => fillRect(atlas, aw, ax, ay + ch - ch * 5 / 8, cw, ch * 5 / 8), // ▅ lower 5/8
            0x2586 => fillRect(atlas, aw, ax, ay + ch - ch * 3 / 4, cw, ch * 3 / 4), // ▆ lower 3/4
            0x2587 => fillRect(atlas, aw, ax, ay + ch - ch * 7 / 8, cw, ch * 7 / 8), // ▇ lower 7/8
            0x2588 => fillRect(atlas, aw, ax, ay, cw, ch), // █ full block
            0x2589 => fillRect(atlas, aw, ax, ay, cw * 7 / 8, ch), // ▉ left 7/8
            0x258A => fillRect(atlas, aw, ax, ay, cw * 3 / 4, ch), // ▊ left 3/4
            0x258B => fillRect(atlas, aw, ax, ay, cw * 5 / 8, ch), // ▋ left 5/8
            0x258C => fillRect(atlas, aw, ax, ay, cw / 2, ch), // ▌ left half
            0x258D => fillRect(atlas, aw, ax, ay, cw * 3 / 8, ch), // ▍ left 3/8
            0x258E => fillRect(atlas, aw, ax, ay, cw / 4, ch), // ▎ left 1/4
            0x258F => fillRect(atlas, aw, ax, ay, cw / 8, ch), // ▏ left 1/8
            0x2590 => fillRect(atlas, aw, ax + cw / 2, ay, cw / 2, ch), // ▐ right half
            // U+2591-2593 shade characters — use font glyph
            0x2594 => fillRect(atlas, aw, ax, ay, cw, ch / 8),
            0x2595 => fillRect(atlas, aw, ax + cw - cw / 8, ay, cw / 8, ch),
            // U+2596-259F quadrant blocks
            0x2596 => fillRect(atlas, aw, ax, ay + ch / 2, cw / 2, ch / 2),
            0x2597 => fillRect(atlas, aw, ax + cw / 2, ay + ch / 2, cw / 2, ch / 2),
            0x2598 => fillRect(atlas, aw, ax, ay, cw / 2, ch / 2),
            0x2599 => {
                fillRect(atlas, aw, ax, ay, cw / 2, ch / 2);
                fillRect(atlas, aw, ax, ay + ch / 2, cw, ch / 2);
            },
            0x259A => {
                fillRect(atlas, aw, ax, ay, cw / 2, ch / 2);
                fillRect(atlas, aw, ax + cw / 2, ay + ch / 2, cw / 2, ch / 2);
            },
            0x259B => {
                fillRect(atlas, aw, ax, ay, cw, ch / 2);
                fillRect(atlas, aw, ax, ay + ch / 2, cw / 2, ch / 2);
            },
            0x259C => {
                fillRect(atlas, aw, ax, ay, cw, ch / 2);
                fillRect(atlas, aw, ax + cw / 2, ay + ch / 2, cw / 2, ch / 2);
            },
            0x259D => fillRect(atlas, aw, ax + cw / 2, ay, cw / 2, ch / 2),
            0x259E => {
                fillRect(atlas, aw, ax + cw / 2, ay, cw / 2, ch / 2);
                fillRect(atlas, aw, ax, ay + ch / 2, cw / 2, ch / 2);
            },
            0x259F => {
                fillRect(atlas, aw, ax + cw / 2, ay, cw / 2, ch / 2);
                fillRect(atlas, aw, ax, ay + ch / 2, cw, ch / 2);
            },
            else => {},
        }
    }
}

// ── Pixel primitives ───────────────────────────────────────────────

fn clearSlot(atlas: []u8, aw: u32, ax: u32, ay: u32, cw: u32, ch: u32) void {
    for (0..ch) |dy| {
        const row_off = (ay + @as(u32, @intCast(dy))) * aw + ax;
        if (row_off + cw <= atlas.len) {
            @memset(atlas[row_off..][0..cw], 0);
        }
    }
}

/// Horizontal segment from x0 to x1 at vertical center cy.
fn drawHSegment(atlas: []u8, aw: u32, ax: u32, ay: u32, x0: u32, x1: u32, cy: u32, weight: u2, cw: u32, ch: u32, heavy_w: u32, heavy_h: u32) void {
    _ = cw;
    switch (weight) {
        1 => setPixelRow(atlas, aw, ax, ay, x0, x1, cy),
        2 => {
            // Heavy: heavy_h rows centered on cy.
            const y0 = cy -| (heavy_h / 2);
            const y1 = @min(y0 + heavy_h, ch);
            for (y0..y1) |y| setPixelRow(atlas, aw, ax, ay, x0, x1, @intCast(y));
        },
        3 => {
            // Double: two 1px lines with gap.
            const gap: u32 = @max(1, heavy_w / 2);
            const y_top = cy -| gap;
            const y_bot = @min(cy + gap, ch - 1);
            setPixelRow(atlas, aw, ax, ay, x0, x1, y_top);
            setPixelRow(atlas, aw, ax, ay, x0, x1, y_bot);
        },
        0 => {},
    }
}

/// Vertical segment from y0 to y1 at horizontal center cx.
fn drawVSegment(atlas: []u8, aw: u32, ax: u32, ay: u32, y0: u32, y1: u32, cx: u32, weight: u2, cw: u32, ch: u32, heavy_w: u32, heavy_h: u32) void {
    _ = ch;
    _ = heavy_h;
    switch (weight) {
        1 => {
            for (y0..y1) |y| setPixel(atlas, aw, ax + cx, ay + @as(u32, @intCast(y)));
        },
        2 => {
            const x0 = cx -| (heavy_w / 2);
            const x1 = @min(x0 + heavy_w, cw);
            for (y0..y1) |y| setPixelRow(atlas, aw, ax, ay, x0, x1, @intCast(y));
        },
        3 => {
            const gap: u32 = @max(1, heavy_w / 2);
            const x_left = cx -| gap;
            const x_right = @min(cx + gap, cw - 1);
            for (y0..y1) |y| {
                setPixel(atlas, aw, ax + x_left, ay + @as(u32, @intCast(y)));
                setPixel(atlas, aw, ax + x_right, ay + @as(u32, @intCast(y)));
            }
        },
        0 => {},
    }
}

fn setPixelRow(atlas: []u8, aw: u32, ax: u32, ay: u32, x0: u32, x1: u32, y: u32) void {
    const offset = (ay + y) * aw + ax;
    if (offset + x1 <= atlas.len and x0 < x1) {
        @memset(atlas[offset + x0 .. offset + x1], 255);
    }
}

fn setPixel(atlas: []u8, aw: u32, x: u32, y: u32) void {
    const offset = y * aw + x;
    if (offset < atlas.len) atlas[offset] = 255;
}

fn fillRect(atlas: []u8, aw: u32, x: u32, y: u32, w: u32, h: u32) void {
    if (w == 0 or h == 0) return;
    for (0..h) |dy| {
        const row_off = (y + @as(u32, @intCast(dy))) * aw + x;
        if (row_off + w <= atlas.len) {
            @memset(atlas[row_off..][0..w], 255);
        }
    }
}
