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
//!   * drawSymbols    — paint synthesized checkbox/consent/mark glyphs
//!                      (☐☑☒ ✓✔✗✘ • U+FFFD) that no font budget rasterizes
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

// ── Synthesized symbol slots (must match FontAtlas) ─────────────────
//
// LOCAL copy of FontAtlas.symbol_codepoints — these MUST stay in the same
// order as the array in FontAtlas.zig (same rationale as the glyphSlot copy
// above: avoids the FontAtlas↔FontSynth import cycle). Drift here writes the
// synthesized glyph into the wrong atlas cell.
const symbol_codepoints = [_]u21{ 0x2022, 0x2610, 0x2611, 0x2612, 0x2713, 0x2714, 0x2717, 0x2718, 0xFFFD };
/// Fixed slot base = 95 (ASCII) + 96 (Latin-1) + 128 (Box) + 32 (Block) = 351.
const symbols_slot_base: u32 = 95 + 96 + 128 + 32;

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

/// Paint the synthesized checkbox / consent / mark glyphs into their atlas
/// slots. These codepoints live in Misc-Symbols / Dingbats and are absent
/// from every -Dglyphs budget, so without this they render as a blank cell.
/// Font-independent, like drawBoxDrawing / drawBlocks.
pub fn drawSymbols(atlas: []u8, aw: u32, cw: u32, ch: u32, glyphs_per_row: u32) void {
    // Inset the drawable box a touch from the cell edges so adjacent glyphs
    // don't visually merge; thickness scales with cell width.
    const inset_x: u32 = @max(1, cw / 8);
    const inset_y: u32 = @max(1, ch / 8);
    const thick: u32 = @max(1, cw / 12);

    const bx0: i32 = @intCast(inset_x);
    const by0: i32 = @intCast(inset_y);
    const bx1: i32 = @intCast(cw -| inset_x);
    const by1: i32 = @intCast(ch -| inset_y);

    for (symbol_codepoints, 0..) |cp, idx| {
        const slot = symbols_slot_base + @as(u32, @intCast(idx));
        const glyph_col = slot % glyphs_per_row;
        const glyph_row = slot / glyphs_per_row;
        const ax: u32 = glyph_col * cw;
        const ay: u32 = glyph_row * ch;

        clearSlot(atlas, aw, ax, ay, cw, ch);

        switch (cp) {
            // • bullet — small centered filled disc
            0x2022 => {
                const r: i32 = @intCast(@max(1, cw / 6));
                fillDisc(atlas, aw, ax, ay, @intCast(cw / 2), @intCast(ch / 2), r);
            },
            // ☐ ballot box — rectangle outline
            0x2610 => drawBoxOutline(atlas, aw, ax, ay, bx0, by0, bx1, by1, thick),
            // ☑ ballot box with check — box outline + check mark
            0x2611 => {
                drawBoxOutline(atlas, aw, ax, ay, bx0, by0, bx1, by1, thick);
                drawCheck(atlas, aw, ax, ay, cw, ch, 1);
            },
            // ☒ ballot box with X — box outline + X across the inner box
            0x2612 => {
                drawBoxOutline(atlas, aw, ax, ay, bx0, by0, bx1, by1, thick);
                drawLine(atlas, aw, ax, ay, bx0, by0, bx1, by1);
                drawLine(atlas, aw, ax, ay, bx1, by0, bx0, by1);
            },
            // ✓ check mark
            0x2713 => drawCheck(atlas, aw, ax, ay, cw, ch, 1),
            // ✔ heavy check mark (2px thick)
            0x2714 => drawCheck(atlas, aw, ax, ay, cw, ch, 2),
            // ✗ ballot X — full-cell X
            0x2717 => drawFullX(atlas, aw, ax, ay, cw, ch, 1),
            // ✘ heavy ballot X — full-cell X, 2px thick
            0x2718 => drawFullX(atlas, aw, ax, ay, cw, ch, 2),
            // U+FFFD replacement char — conventional tofu box outline
            0xFFFD => drawBoxOutline(atlas, aw, ax, ay, bx0, by0, bx1, by1, thick),
            else => {},
        }
    }
}

/// Rectangle outline (4 inset edges) of the given thickness.
fn drawBoxOutline(atlas: []u8, aw: u32, ax: u32, ay: u32, x0: i32, y0: i32, x1: i32, y1: i32, thick: u32) void {
    if (x1 <= x0 or y1 <= y0) return;
    const ox0: u32 = @intCast(x0);
    const oy0: u32 = @intCast(y0);
    const w: u32 = @intCast(x1 - x0);
    const h: u32 = @intCast(y1 - y0);
    // top + bottom edges
    fillRect(atlas, aw, ax + ox0, ay + oy0, w, thick);
    fillRect(atlas, aw, ax + ox0, ay + @as(u32, @intCast(y1)) -| thick, w, thick);
    // left + right edges
    fillRect(atlas, aw, ax + ox0, ay + oy0, thick, h);
    fillRect(atlas, aw, ax + @as(u32, @intCast(x1)) -| thick, ay + oy0, thick, h);
}

/// Draw a check mark (two joined segments) scaled to the cell, `extra` extra
/// rows/cols of thickness around each segment.
fn drawCheck(atlas: []u8, aw: u32, ax: u32, ay: u32, cw: u32, ch: u32, extra: u32) void {
    const x0: i32 = @intCast(cw * 20 / 100);
    const y0: i32 = @intCast(ch * 55 / 100);
    const x1: i32 = @intCast(cw * 42 / 100);
    const y1: i32 = @intCast(ch * 78 / 100);
    const x2: i32 = @intCast(cw * 80 / 100);
    const y2: i32 = @intCast(ch * 25 / 100);
    drawThickLine(atlas, aw, ax, ay, x0, y0, x1, y1, extra);
    drawThickLine(atlas, aw, ax, ay, x1, y1, x2, y2, extra);
}

/// Draw a full-cell X (two diagonals) with `extra` thickness.
fn drawFullX(atlas: []u8, aw: u32, ax: u32, ay: u32, cw: u32, ch: u32, extra: u32) void {
    const x0: i32 = @intCast(cw * 15 / 100);
    const y0: i32 = @intCast(ch * 15 / 100);
    const x1: i32 = @intCast(cw * 85 / 100);
    const y1: i32 = @intCast(ch * 85 / 100);
    drawThickLine(atlas, aw, ax, ay, x0, y0, x1, y1, extra);
    drawThickLine(atlas, aw, ax, ay, x1, y0, x0, y1, extra);
}

/// A Bresenham line plus, for each plotted pixel, a small `extra`-radius
/// square so the stroke is `1 + 2*extra` px thick.
fn drawThickLine(atlas: []u8, aw: u32, ax: u32, ay: u32, x0: i32, y0: i32, x1: i32, y1: i32, extra: u32) void {
    if (extra == 0) {
        drawLine(atlas, aw, ax, ay, x0, y0, x1, y1);
        return;
    }
    const e: i32 = @intCast(extra);
    var oy: i32 = -e;
    while (oy <= e) : (oy += 1) {
        var ox: i32 = -e;
        while (ox <= e) : (ox += 1) {
            drawLine(atlas, aw, ax, ay, x0 + ox, y0 + oy, x1 + ox, y1 + oy);
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

/// Set a pixel at cell-relative (cx, cy). Negative or out-of-cell coordinates
/// are silently dropped, so synth glyphs can never bleed into a neighbour cell
/// or out of the atlas.
fn setPixelCell(atlas: []u8, aw: u32, ax: u32, ay: u32, cx: i32, cy: i32) void {
    if (cx < 0 or cy < 0) return;
    setPixel(atlas, aw, ax + @as(u32, @intCast(cx)), ay + @as(u32, @intCast(cy)));
}

/// Bresenham line between two cell-relative endpoints.
fn drawLine(atlas: []u8, aw: u32, ax: u32, ay: u32, x0: i32, y0: i32, x1: i32, y1: i32) void {
    var x = x0;
    var y = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        setPixelCell(atlas, aw, ax, ay, x, y);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

/// Filled disc of radius `r` centered at cell-relative (ccx, ccy).
fn fillDisc(atlas: []u8, aw: u32, ax: u32, ay: u32, ccx: i32, ccy: i32, r: i32) void {
    if (r <= 0) return;
    const r2 = r * r;
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dy * dy <= r2) {
                setPixelCell(atlas, aw, ax, ay, ccx + dx, ccy + dy);
            }
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const std = @import("std");

/// Count non-zero pixels inside one cell slot.
fn slotPixelCount(atlas: []const u8, aw: u32, cw: u32, ch: u32, glyphs_per_row: u32, slot: u32) u32 {
    const ax = (slot % glyphs_per_row) * cw;
    const ay = (slot / glyphs_per_row) * ch;
    var n: u32 = 0;
    for (0..ch) |dy| {
        for (0..cw) |dx| {
            const off = (ay + @as(u32, @intCast(dy))) * aw + ax + @as(u32, @intCast(dx));
            if (off < atlas.len and atlas[off] != 0) n += 1;
        }
    }
    return n;
}

test "drawSymbols paints non-blank cells for box and check slots" {
    const cw: u32 = 12;
    const ch: u32 = 24;
    const glyphs_per_row: u32 = 16;
    // Atlas large enough to hold every synthesized symbol slot.
    const last_slot = symbols_slot_base + symbol_codepoints.len - 1;
    const num_rows = last_slot / glyphs_per_row + 1;
    const aw = glyphs_per_row * cw;
    const ah = num_rows * ch;
    const atlas = try std.testing.allocator.alloc(u8, aw * ah);
    defer std.testing.allocator.free(atlas);
    @memset(atlas, 0);

    drawSymbols(atlas, aw, cw, ch, glyphs_per_row);

    // ☐ U+2610 is index 1 → slot 352; ✓ U+2713 is index 4 → slot 355.
    const box_slot = symbols_slot_base + 1;
    const check_slot = symbols_slot_base + 4;
    try std.testing.expect(slotPixelCount(atlas, aw, cw, ch, glyphs_per_row, box_slot) > 0);
    try std.testing.expect(slotPixelCount(atlas, aw, cw, ch, glyphs_per_row, check_slot) > 0);
    // • U+2022 index 0 → slot 351 should also paint a disc.
    try std.testing.expect(slotPixelCount(atlas, aw, cw, ch, glyphs_per_row, symbols_slot_base) > 0);
}

test "symbol_codepoints/slot base agree with FontAtlas layout" {
    // Guard the local copy against drift from FontAtlas.symbol_codepoints.
    try std.testing.expectEqual(@as(usize, 9), symbol_codepoints.len);
    try std.testing.expectEqual(@as(u32, 351), symbols_slot_base);
    try std.testing.expectEqual(@as(u21, 0x2610), symbol_codepoints[1]);
    try std.testing.expectEqual(@as(u21, 0x2713), symbol_codepoints[4]);
    try std.testing.expectEqual(@as(u21, 0xFFFD), symbol_codepoints[8]);
}
