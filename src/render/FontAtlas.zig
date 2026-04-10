//! Font atlas builder using stb_truetype (embedded, zero system deps).
//!
//! Rasterizes ASCII printable glyphs (32-126) into a single-channel
//! grayscale texture atlas. Finds fonts by scanning standard paths
//! or accepting an explicit font path. No FreeType, no fontconfig.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const compat = @import("../compat.zig");
const FontAtlas = @This();

// ── stb_truetype C bindings ────────────────────────────────────────

const stbtt = @cImport({
    @cInclude("stb_truetype.h");
});

// ── Public types ───────────────────────────────────────────────────

pub const GlyphInfo = struct {
    atlas_x: u16,
    atlas_y: u16,
    width: u16,
    height: u16,
    bearing_x: i16,
    bearing_y: i16,
    advance: u16,
};

// ── Font atlas ─────────────────────────────────────────────────────

atlas_data: []u8,
atlas_width: u32,
atlas_height: u32,
/// ASCII + Latin-1 Supplement (codepoints 0-255)
glyphs: [256]?GlyphInfo,
/// Box Drawing (U+2500-U+257F)
box_glyphs: [128]?GlyphInfo,
/// Block Elements (U+2580-U+259F)
block_glyphs: [32]?GlyphInfo,
/// Cyrillic (U+0400-U+04FF)
cyrillic_glyphs: [256]?GlyphInfo,
/// Geometric Shapes (U+25A0-U+25FF)
geometric_glyphs: [96]?GlyphInfo,
/// Braille Patterns (U+2800-U+28FF)
braille_glyphs: [256]?GlyphInfo,
cell_width: u32,
cell_height: u32,
allocator: std.mem.Allocator,
font_data: []u8, // kept alive for stbtt

pub fn init(allocator: std.mem.Allocator, font_path: ?[]const u8, font_size: u16, io: Io) !FontAtlas {
    // Load font file
    const path = font_path orelse try findMonospaceFont(allocator, io);
    const free_path = font_path == null;
    defer if (free_path) allocator.free(path);

    const font_data = try loadFile(allocator, path, io);
    errdefer allocator.free(font_data);

    // Initialize stbtt
    var font_info: stbtt.stbtt_fontinfo = undefined;
    if (stbtt.stbtt_InitFont(&font_info, font_data.ptr, 0) == 0) {
        return error.FontInitFailed;
    }

    const scale = stbtt.stbtt_ScaleForPixelHeight(&font_info, @floatFromInt(font_size));

    // Get font metrics
    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    stbtt.stbtt_GetFontVMetrics(&font_info, &ascent, &descent, &line_gap);

    const f_ascent: f32 = @as(f32, @floatFromInt(ascent)) * scale;
    const f_descent: f32 = @as(f32, @floatFromInt(descent)) * scale;
    const cell_h: u32 = @intFromFloat(@ceil(f_ascent - f_descent));

    // Get advance of 'M' for cell width
    var m_advance: c_int = 0;
    var m_lsb: c_int = 0;
    stbtt.stbtt_GetCodepointHMetrics(&font_info, 'M', &m_advance, &m_lsb);
    const cell_w: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(m_advance)) * scale));

    if (cell_w == 0 or cell_h == 0) return error.InvalidFontMetrics;

    // Glyph ranges to rasterize:
    //   ASCII printable:     32-126  (95 glyphs)
    //   Latin-1 Supplement: 160-255  (96 glyphs)
    //   Box Drawing:     0x2500-0x257F (128 glyphs)
    //   Block Elements:  0x2580-0x259F (32 glyphs)
    //   Cyrillic:        0x0400-0x04FF (256 glyphs)
    //   Geometric Shapes: 0x25A0-0x25FF (96 glyphs)
    //   Braille Patterns: 0x2800-0x28FF (256 glyphs)
    // Total: 959 glyphs
    const total_glyphs: u32 = 95 + 96 + 128 + 32 + 256 + 96 + 256; // 959
    const glyphs_per_row: u32 = 16;
    const num_rows: u32 = (total_glyphs + glyphs_per_row - 1) / glyphs_per_row;
    const atlas_w = glyphs_per_row * cell_w;
    const atlas_h = num_rows * cell_h;

    const atlas_data = try allocator.alloc(u8, atlas_w * atlas_h);
    @memset(atlas_data, 0);

    // Initialize glyph tables
    var glyphs: [256]?GlyphInfo = [_]?GlyphInfo{null} ** 256;
    var box_glyphs: [128]?GlyphInfo = [_]?GlyphInfo{null} ** 128;
    var block_glyphs: [32]?GlyphInfo = [_]?GlyphInfo{null} ** 32;
    var cyrillic_glyphs: [256]?GlyphInfo = [_]?GlyphInfo{null} ** 256;
    var geometric_glyphs: [96]?GlyphInfo = [_]?GlyphInfo{null} ** 96;
    var braille_glyphs: [256]?GlyphInfo = [_]?GlyphInfo{null} ** 256;
    const baseline: i32 = @intFromFloat(f_ascent);

    // Build a flat list of codepoints to rasterize
    const Codepoint = struct { cp: u21, slot: u32 };
    var codepoints: [total_glyphs]Codepoint = undefined;
    var slot: u32 = 0;

    // ASCII printable: 32-126
    for (32..127) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    // Latin-1 Supplement: 160-255
    for (160..256) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    // Box Drawing: U+2500-U+257F
    for (0x2500..0x2580) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    // Block Elements: U+2580-U+259F
    for (0x2580..0x25A0) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    // Cyrillic: U+0400-U+04FF
    for (0x0400..0x0500) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    // Geometric Shapes: U+25A0-U+25FF
    for (0x25A0..0x2600) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    // Braille Patterns: U+2800-U+2900
    for (0x2800..0x2900) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }

    for (codepoints[0..slot]) |entry| {
        const col = entry.slot % glyphs_per_row;
        const row = entry.slot / glyphs_per_row;
        const atlas_x: u32 = @intCast(col * cell_w);
        const atlas_y: u32 = @intCast(row * cell_h);

        // Get glyph metrics
        var advance_c: c_int = 0;
        var lsb: c_int = 0;
        stbtt.stbtt_GetCodepointHMetrics(&font_info, @intCast(entry.cp), &advance_c, &lsb);

        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        stbtt.stbtt_GetCodepointBitmapBox(&font_info, @intCast(entry.cp), scale, scale, &ix0, &iy0, &ix1, &iy1);

        const glyph_w: u32 = @intCast(@max(0, ix1 - ix0));
        const glyph_h: u32 = @intCast(@max(0, iy1 - iy0));

        if (glyph_w > 0 and glyph_h > 0) {
            // Render glyph into atlas, clipping to cell boundaries.
            // Box drawing and block elements intentionally exceed cell_h
            // to fill the entire cell including line spacing.
            const offset_y: u32 = @intCast(@max(0, baseline + iy0));
            const offset_x: u32 = @intCast(@max(0, ix0));
            const dst_x = atlas_x + @min(offset_x, cell_w - 1);
            const dst_y = atlas_y + @min(offset_y, cell_h - 1);

            // Clip render dimensions to cell bounds
            const render_w = @min(glyph_w, cell_w -| @min(offset_x, cell_w - 1));
            const render_h = @min(glyph_h, cell_h -| @min(offset_y, cell_h - 1));

            if (render_w > 0 and render_h > 0) {
                stbtt.stbtt_MakeCodepointBitmap(
                    &font_info,
                    atlas_data.ptr + dst_y * atlas_w + dst_x,
                    @intCast(@min(render_w, atlas_w - dst_x)),
                    @intCast(@min(render_h, atlas_h - dst_y)),
                    @intCast(atlas_w),
                    scale,
                    scale,
                    @intCast(entry.cp),
                );
            }
        }

        const info = GlyphInfo{
            .atlas_x = @intCast(atlas_x),
            .atlas_y = @intCast(atlas_y),
            .width = @intCast(@min(glyph_w, cell_w)),
            .height = @intCast(@min(glyph_h, cell_h)),
            .bearing_x = @intCast(ix0),
            .bearing_y = @intCast(iy0),
            .advance = @intCast(@as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(advance_c)) * scale)))),
        };

        // Store in the correct lookup table
        if (entry.cp < 256) {
            glyphs[entry.cp] = info;
        } else if (entry.cp >= 0x2500 and entry.cp < 0x2580) {
            box_glyphs[entry.cp - 0x2500] = info;
        } else if (entry.cp >= 0x2580 and entry.cp < 0x25A0) {
            block_glyphs[entry.cp - 0x2580] = info;
        } else if (entry.cp >= 0x0400 and entry.cp < 0x0500) {
            cyrillic_glyphs[entry.cp - 0x0400] = info;
        } else if (entry.cp >= 0x25A0 and entry.cp < 0x2600) {
            geometric_glyphs[entry.cp - 0x25A0] = info;
        } else if (entry.cp >= 0x2800 and entry.cp < 0x2900) {
            braille_glyphs[entry.cp - 0x2800] = info;
        }
    }

    // Override box-drawing and block elements with programmatic rendering.
    // This ensures seamless edge-to-edge connections regardless of font metrics.
    drawBoxDrawingRange(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);
    drawBlockElements(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);

    return FontAtlas{
        .atlas_data = atlas_data,
        .atlas_width = atlas_w,
        .atlas_height = atlas_h,
        .glyphs = glyphs,
        .box_glyphs = box_glyphs,
        .block_glyphs = block_glyphs,
        .cyrillic_glyphs = cyrillic_glyphs,
        .geometric_glyphs = geometric_glyphs,
        .braille_glyphs = braille_glyphs,
        .cell_width = cell_w,
        .cell_height = cell_h,
        .allocator = allocator,
        .font_data = font_data,
    };
}

/// Re-rasterize the atlas at a new font size using the already-loaded font data.
/// No file I/O — pure CPU rasterization from memory. Returns a new atlas;
/// caller must deinit the old one.
pub fn rasterizeAtSize(self: *const FontAtlas, new_size: u16) !FontAtlas {
    var font_info: stbtt.stbtt_fontinfo = undefined;
    if (stbtt.stbtt_InitFont(&font_info, self.font_data.ptr, 0) == 0) {
        return error.FontInitFailed;
    }

    const scale = stbtt.stbtt_ScaleForPixelHeight(&font_info, @floatFromInt(new_size));

    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    stbtt.stbtt_GetFontVMetrics(&font_info, &ascent, &descent, &line_gap);

    const f_ascent: f32 = @as(f32, @floatFromInt(ascent)) * scale;
    const f_descent: f32 = @as(f32, @floatFromInt(descent)) * scale;
    const cell_h: u32 = @intFromFloat(@ceil(f_ascent - f_descent));

    var m_advance: c_int = 0;
    var m_lsb: c_int = 0;
    stbtt.stbtt_GetCodepointHMetrics(&font_info, 'M', &m_advance, &m_lsb);
    const cell_w: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(m_advance)) * scale));

    if (cell_w == 0 or cell_h == 0) return error.InvalidFontMetrics;

    const total_glyphs: u32 = 95 + 96 + 128 + 32 + 256 + 96 + 256; // 959
    const glyphs_per_row: u32 = 16;
    const num_rows: u32 = (total_glyphs + glyphs_per_row - 1) / glyphs_per_row;
    const atlas_w = glyphs_per_row * cell_w;
    const atlas_h = num_rows * cell_h;

    const atlas_data = try self.allocator.alloc(u8, atlas_w * atlas_h);
    @memset(atlas_data, 0);

    var glyphs: [256]?GlyphInfo = [_]?GlyphInfo{null} ** 256;
    var box_glyphs: [128]?GlyphInfo = [_]?GlyphInfo{null} ** 128;
    var block_glyphs: [32]?GlyphInfo = [_]?GlyphInfo{null} ** 32;
    var cyrillic_glyphs: [256]?GlyphInfo = [_]?GlyphInfo{null} ** 256;
    var geometric_glyphs: [96]?GlyphInfo = [_]?GlyphInfo{null} ** 96;
    var braille_glyphs: [256]?GlyphInfo = [_]?GlyphInfo{null} ** 256;
    const baseline: i32 = @intFromFloat(f_ascent);

    const Codepoint = struct { cp: u21, slot: u32 };
    var codepoints: [total_glyphs]Codepoint = undefined;
    var slot: u32 = 0;
    for (32..127) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (160..256) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x2500..0x2580) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x2580..0x25A0) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x0400..0x0500) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x25A0..0x2600) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x2800..0x2900) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }

    for (codepoints[0..slot]) |entry| {
        const col = entry.slot % glyphs_per_row;
        const row = entry.slot / glyphs_per_row;
        const atlas_x: u32 = @intCast(col * cell_w);
        const atlas_y: u32 = @intCast(row * cell_h);

        var advance_c: c_int = 0;
        var lsb: c_int = 0;
        stbtt.stbtt_GetCodepointHMetrics(&font_info, @intCast(entry.cp), &advance_c, &lsb);

        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        stbtt.stbtt_GetCodepointBitmapBox(&font_info, @intCast(entry.cp), scale, scale, &ix0, &iy0, &ix1, &iy1);

        const glyph_w: u32 = @intCast(@max(0, ix1 - ix0));
        const glyph_h: u32 = @intCast(@max(0, iy1 - iy0));

        if (glyph_w > 0 and glyph_h > 0) {
            const offset_y: u32 = @intCast(@max(0, baseline + iy0));
            const offset_x: u32 = @intCast(@max(0, ix0));
            const dst_x = atlas_x + @min(offset_x, cell_w - 1);
            const dst_y = atlas_y + @min(offset_y, cell_h - 1);
            const render_w = @min(glyph_w, cell_w -| @min(offset_x, cell_w - 1));
            const render_h = @min(glyph_h, cell_h -| @min(offset_y, cell_h - 1));

            if (render_w > 0 and render_h > 0) {
                stbtt.stbtt_MakeCodepointBitmap(
                    &font_info,
                    atlas_data.ptr + dst_y * atlas_w + dst_x,
                    @intCast(@min(render_w, atlas_w - dst_x)),
                    @intCast(@min(render_h, atlas_h - dst_y)),
                    @intCast(atlas_w),
                    scale,
                    scale,
                    @intCast(entry.cp),
                );
            }
        }

        const info = GlyphInfo{
            .atlas_x = @intCast(atlas_x),
            .atlas_y = @intCast(atlas_y),
            .width = @intCast(@min(glyph_w, cell_w)),
            .height = @intCast(@min(glyph_h, cell_h)),
            .bearing_x = @intCast(ix0),
            .bearing_y = @intCast(iy0),
            .advance = @intCast(@as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(advance_c)) * scale)))),
        };

        if (entry.cp < 256) { glyphs[entry.cp] = info; }
        else if (entry.cp >= 0x2500 and entry.cp < 0x2580) { box_glyphs[entry.cp - 0x2500] = info; }
        else if (entry.cp >= 0x2580 and entry.cp < 0x25A0) { block_glyphs[entry.cp - 0x2580] = info; }
        else if (entry.cp >= 0x0400 and entry.cp < 0x0500) { cyrillic_glyphs[entry.cp - 0x0400] = info; }
        else if (entry.cp >= 0x25A0 and entry.cp < 0x2600) { geometric_glyphs[entry.cp - 0x25A0] = info; }
        else if (entry.cp >= 0x2800 and entry.cp < 0x2900) { braille_glyphs[entry.cp - 0x2800] = info; }
    }

    drawBoxDrawingRange(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);
    drawBlockElements(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);

    // Reuse existing font_data (don't free it — the old atlas still owns it until caller deinits)
    const font_data_copy = try self.allocator.alloc(u8, self.font_data.len);
    @memcpy(font_data_copy, self.font_data);

    return FontAtlas{
        .atlas_data = atlas_data,
        .atlas_width = atlas_w,
        .atlas_height = atlas_h,
        .glyphs = glyphs,
        .box_glyphs = box_glyphs,
        .block_glyphs = block_glyphs,
        .cyrillic_glyphs = cyrillic_glyphs,
        .geometric_glyphs = geometric_glyphs,
        .braille_glyphs = braille_glyphs,
        .cell_width = cell_w,
        .cell_height = cell_h,
        .allocator = self.allocator,
        .font_data = font_data_copy,
    };
}

/// Load a font variant (bold, italic, etc.) and rasterize it into a new atlas
/// with the SAME cell dimensions and layout as the primary font. The caller
/// owns the returned atlas data and the font_data kept alive for stbtt.
pub fn loadVariant(self: *const FontAtlas, allocator: std.mem.Allocator, font_path: []const u8, io: Io) !VariantAtlas {
    // Load font file
    const font_data = try loadFile(allocator, font_path, io);
    errdefer allocator.free(font_data);

    // Init stbtt with the variant font
    var font_info: stbtt.stbtt_fontinfo = undefined;
    if (stbtt.stbtt_InitFont(&font_info, font_data.ptr, 0) == 0) {
        allocator.free(font_data);
        return error.FontInitFailed;
    }

    // Scale to match the primary font's cell height
    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    stbtt.stbtt_GetFontVMetrics(&font_info, &ascent, &descent, &line_gap);
    const target_h: f32 = @floatFromInt(self.cell_height);
    const scale = target_h / (@as(f32, @floatFromInt(ascent)) - @as(f32, @floatFromInt(descent)));

    // Allocate atlas with SAME dimensions as primary
    const atlas = try allocator.alloc(u8, self.atlas_width * self.atlas_height);
    errdefer allocator.free(atlas);
    @memset(atlas, 0);

    const baseline: i32 = @intFromFloat(@as(f32, @floatFromInt(ascent)) * scale);
    const cw = self.cell_width;
    const ch = self.cell_height;
    const aw = self.atlas_width;
    const ah = self.atlas_height;
    const glyphs_per_row: u32 = 16;

    // Build same codepoint list as init
    const total_glyphs: u32 = 95 + 96 + 128 + 32 + 256 + 96 + 256; // 959
    const Codepoint = struct { cp: u21, slot: u32 };
    var codepoints: [total_glyphs]Codepoint = undefined;
    var slot: u32 = 0;

    for (32..127) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (160..256) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (0x2500..0x2580) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (0x2580..0x25A0) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (0x0400..0x0500) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (0x25A0..0x2600) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (0x2800..0x2900) |cp| {
        codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }

    for (codepoints[0..slot]) |entry| {
        const col = entry.slot % glyphs_per_row;
        const row = entry.slot / glyphs_per_row;
        const atlas_x: u32 = @intCast(col * cw);
        const atlas_y: u32 = @intCast(row * ch);

        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        stbtt.stbtt_GetCodepointBitmapBox(&font_info, @intCast(entry.cp), scale, scale, &ix0, &iy0, &ix1, &iy1);

        const glyph_w: u32 = @intCast(@max(0, ix1 - ix0));
        const glyph_h: u32 = @intCast(@max(0, iy1 - iy0));

        if (glyph_w > 0 and glyph_h > 0) {
            const offset_y: u32 = @intCast(@max(0, baseline + iy0));
            const offset_x: u32 = @intCast(@max(0, ix0));
            const dst_x = atlas_x + @min(offset_x, cw - 1);
            const dst_y = atlas_y + @min(offset_y, ch - 1);
            const render_w = @min(glyph_w, cw -| @min(offset_x, cw - 1));
            const render_h = @min(glyph_h, ch -| @min(offset_y, ch - 1));

            if (render_w > 0 and render_h > 0) {
                stbtt.stbtt_MakeCodepointBitmap(
                    &font_info,
                    atlas.ptr + dst_y * aw + dst_x,
                    @intCast(@min(render_w, aw - dst_x)),
                    @intCast(@min(render_h, ah - dst_y)),
                    @intCast(aw),
                    scale,
                    scale,
                    @intCast(entry.cp),
                );
            }
        }
    }

    return .{
        .data = atlas,
        .font_data = font_data,
    };
}

/// Re-rasterize a variant from its already-loaded font_data at the current
/// primary atlas dimensions. No file I/O — pure CPU rasterization.
pub fn rasterizeVariant(self: *const FontAtlas, allocator: std.mem.Allocator, variant: *VariantAtlas) !VariantAtlas {
    // Init stbtt from cached font bytes
    var font_info: stbtt.stbtt_fontinfo = undefined;
    if (stbtt.stbtt_InitFont(&font_info, variant.font_data.ptr, 0) == 0)
        return error.FontInitFailed;

    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    stbtt.stbtt_GetFontVMetrics(&font_info, &ascent, &descent, &line_gap);
    const target_h: f32 = @floatFromInt(self.cell_height);
    const scale = target_h / (@as(f32, @floatFromInt(ascent)) - @as(f32, @floatFromInt(descent)));

    const atlas_buf = try allocator.alloc(u8, self.atlas_width * self.atlas_height);
    errdefer allocator.free(atlas_buf);
    @memset(atlas_buf, 0);

    const baseline: i32 = @intFromFloat(@as(f32, @floatFromInt(ascent)) * scale);
    const cw = self.cell_width;
    const ch = self.cell_height;
    const aw = self.atlas_width;
    const ah = self.atlas_height;
    const glyphs_per_row: u32 = 16;

    const total_glyphs: u32 = 95 + 96 + 128 + 32 + 256 + 96 + 256; // 959
    const Codepoint = struct { cp: u21, slot: u32 };
    var codepoints: [total_glyphs]Codepoint = undefined;
    var slot: u32 = 0;
    for (32..127) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (160..256) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x2500..0x2580) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x2580..0x25A0) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x0400..0x0500) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x25A0..0x2600) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }
    for (0x2800..0x2900) |cp| { codepoints[slot] = .{ .cp = @intCast(cp), .slot = slot }; slot += 1; }

    for (codepoints[0..slot]) |entry| {
        const col = entry.slot % glyphs_per_row;
        const row = entry.slot / glyphs_per_row;
        const atlas_x: u32 = @intCast(col * cw);
        const atlas_y: u32 = @intCast(row * ch);
        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        stbtt.stbtt_GetCodepointBitmapBox(&font_info, @intCast(entry.cp), scale, scale, &ix0, &iy0, &ix1, &iy1);
        const glyph_w: u32 = @intCast(@max(0, ix1 - ix0));
        const glyph_h: u32 = @intCast(@max(0, iy1 - iy0));
        if (glyph_w > 0 and glyph_h > 0) {
            const offset_y: u32 = @intCast(@max(0, baseline + iy0));
            const offset_x: u32 = @intCast(@max(0, ix0));
            const dst_x = atlas_x + @min(offset_x, cw - 1);
            const dst_y = atlas_y + @min(offset_y, ch - 1);
            const render_w = @min(glyph_w, cw -| @min(offset_x, cw - 1));
            const render_h = @min(glyph_h, ch -| @min(offset_y, ch - 1));
            if (render_w > 0 and render_h > 0) {
                stbtt.stbtt_MakeCodepointBitmap(
                    &font_info,
                    atlas_buf.ptr + dst_y * aw + dst_x,
                    @intCast(@min(render_w, aw - dst_x)),
                    @intCast(@min(render_h, ah - dst_y)),
                    @intCast(aw),
                    scale,
                    scale,
                    @intCast(entry.cp),
                );
            }
        }
    }

    // Keep font_data alive — copy it so old variant can be freed independently
    const font_data_copy = try allocator.alloc(u8, variant.font_data.len);
    @memcpy(font_data_copy, variant.font_data);

    return .{
        .data = atlas_buf,
        .font_data = font_data_copy,
    };
}

/// Result of loadVariant — owns both the atlas bitmap and the font file data.
pub const VariantAtlas = struct {
    data: []u8,
    font_data: []u8,

    pub fn deinit(self: *VariantAtlas, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.font_data);
    }
};

pub fn deinit(self: *FontAtlas) void {
    self.allocator.free(self.atlas_data);
    self.allocator.free(self.font_data);
}

pub fn getGlyph(self: *const FontAtlas, codepoint: u21) ?GlyphInfo {
    if (codepoint < 256) return self.glyphs[codepoint];
    if (codepoint >= 0x0400 and codepoint < 0x0500)
        return self.cyrillic_glyphs[codepoint - 0x0400];
    if (codepoint >= 0x2500 and codepoint < 0x2580)
        return self.box_glyphs[codepoint - 0x2500];
    if (codepoint >= 0x2580 and codepoint < 0x25A0)
        return self.block_glyphs[codepoint - 0x2580];
    if (codepoint >= 0x25A0 and codepoint < 0x2600)
        return self.geometric_glyphs[codepoint - 0x25A0];
    if (codepoint >= 0x2800 and codepoint < 0x2900)
        return self.braille_glyphs[codepoint - 0x2800];
    return null;
}

/// Convert a codepoint to its atlas slot index (for renderer blitting).
/// Returns null if the codepoint is not in the atlas.
pub fn glyphSlot(codepoint: u21) ?u32 {
    if (codepoint >= 32 and codepoint < 127) return @as(u32, codepoint - 32);
    if (codepoint >= 160 and codepoint < 256) return @as(u32, codepoint - 160) + 95;
    if (codepoint >= 0x2500 and codepoint < 0x2580) return @as(u32, codepoint - 0x2500) + 95 + 96;
    if (codepoint >= 0x2580 and codepoint < 0x25A0) return @as(u32, codepoint - 0x2580) + 95 + 96 + 128;
    if (codepoint >= 0x0400 and codepoint < 0x0500) return @as(u32, codepoint - 0x0400) + 95 + 96 + 128 + 32;
    if (codepoint >= 0x25A0 and codepoint < 0x2600) return @as(u32, codepoint - 0x25A0) + 95 + 96 + 128 + 32 + 256;
    if (codepoint >= 0x2800 and codepoint < 0x2900) return @as(u32, codepoint - 0x2800) + 95 + 96 + 128 + 32 + 256 + 96;
    return null;
}

// ── Font discovery (no fontconfig) ─────────────────────────────────

const font_search_paths = switch (@import("builtin").os.tag) {
    .macos => &[_][]const u8{
        "/System/Library/Fonts",
        "/System/Library/Fonts/Supplemental",
        "/Library/Fonts",
    },
    .windows => &[_][]const u8{
        "C:\\Windows\\Fonts",
    },
    else => &[_][]const u8{ // Linux
        "/usr/share/fonts/TTF",           // Arch Linux
        "/usr/share/fonts/nerd-fonts",    // Arch nerd-fonts
        "/usr/share/fonts/OTF",           // Arch OTF
        "/usr/share/fonts/truetype/hack", // Debian/Ubuntu hack
        "/usr/share/fonts/truetype/dejavu", // Debian/Ubuntu dejavu
        "/usr/share/fonts/truetype/liberation", // Debian/Ubuntu liberation
        "/usr/share/fonts/truetype",      // Debian/Ubuntu general
        "/usr/share/fonts/Adwaita",       // GNOME/Fedora
        "/usr/local/share/fonts",         // User-installed
    },
};

const preferred_fonts = switch (@import("builtin").os.tag) {
    .macos => &[_][]const u8{
        "SF-Mono-Regular.otf",
        "SFMono-Regular.otf",
        "Menlo.ttc",
        "Monaco.ttf",
        "Courier New.ttf",
    },
    .windows => &[_][]const u8{
        "consola.ttf",  // Consolas
        "cour.ttf",     // Courier New
        "lucon.ttf",    // Lucida Console
        "cascadiamono.ttf", // Cascadia Mono
        "CascadiaCode.ttf",
    },
    else => &[_][]const u8{ // Linux
        "Hack-Regular.ttf",
        "HackNerdFont-Regular.ttf",
        "HackNerdFontMono-Regular.ttf",
        "JetBrainsMono-Regular.ttf",
        "JetBrainsMonoNerdFont-Regular.ttf",
        "SourceCodePro-Regular.ttf",
        "FiraCode-Regular.ttf",
        "DejaVuSansMono.ttf",
        "LiberationMono-Regular.ttf",
        "UbuntuMono-Regular.ttf",
        "Inconsolata-Regular.ttf",
        "RobotoMono-Regular.ttf",
        "AdwaitaMono-Regular.ttf",
        "DroidSansMono.ttf",
    },
};

fn findMonospaceFont(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    _ = io; // Font discovery uses fast libc access() — no Io overhead

    // Try preferred fonts in standard paths (fast: raw access syscall)
    for (font_search_paths) |dir| {
        for (preferred_fonts) |font_name| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, font_name });
            if (accessFast(path)) {
                return path;
            }
            allocator.free(path);
        }
    }

    // Try user font directories
    const user_home_env: [*:0]const u8 = switch (@import("builtin").os.tag) {
        .windows => "LOCALAPPDATA",
        else => "HOME",
    };
    const user_font_suffix: []const u8 = switch (@import("builtin").os.tag) {
        .macos => "/Library/Fonts",
        .windows => "\\Microsoft\\Windows\\Fonts",
        else => "/.local/share/fonts",
    };
    if (compat.getenv(user_home_env)) |base| {
        for (preferred_fonts) |font_name| {
            const path = try std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ base, user_font_suffix, font_name });
            if (accessFast(path)) {
                return path;
            }
            allocator.free(path);
        }
    }

    return error.NoMonospaceFontFound;
}

/// Fast file existence check via libc access() — avoids Io vtable overhead.
fn accessFast(path: []const u8) bool {
    // Need null-terminated path for C access()
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(&buf, 0) == 0; // F_OK = 0
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8, io: Io) ![]u8 {
    const file = Dir.cwd().openFile(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    const s = file.stat(io) catch return error.StatFailed;
    const size: usize = @intCast(s.size);
    const data = try allocator.alloc(u8, size);
    const n = file.readPositionalAll(io, data, 0) catch {
        allocator.free(data);
        return error.ReadFailed;
    };
    if (n != size) {
        allocator.free(data);
        return error.IncompleteRead;
    }
    return data;
}

// ── Programmatic box-drawing ───────────────────────────────────────
//
// Draws box-drawing (U+2500-U+257F) and block elements (U+2580-U+259F)
// directly into the atlas bitmap, ensuring seamless edge-to-edge rendering.
// Each character is encoded as 4 connections (left, right, up, down) with
// weight 0=none, 1=light, 2=heavy, 3=double.

const BoxConn = packed struct {
    left: u2 = 0,
    right: u2 = 0,
    up: u2 = 0,
    down: u2 = 0,
};

// Connection weight lookup table for U+2500-U+257F (128 entries).
// Dashed variants use the same connection pattern as solid.
const box_connections: [128]BoxConn = blk: {
    var t: [128]BoxConn = @splat(.{});
    // U+2500 ─  U+2501 ━
    t[0x00] = .{ .left = 1, .right = 1 };
    t[0x01] = .{ .left = 2, .right = 2 };
    // U+2502 │  U+2503 ┃
    t[0x02] = .{ .up = 1, .down = 1 };
    t[0x03] = .{ .up = 2, .down = 2 };
    // U+2504-250B: dashed variants (same connections as solid)
    t[0x04] = .{ .left = 1, .right = 1 }; // ┄
    t[0x05] = .{ .left = 2, .right = 2 }; // ┅
    t[0x06] = .{ .up = 1, .down = 1 }; // ┆
    t[0x07] = .{ .up = 2, .down = 2 }; // ┇
    t[0x08] = .{ .left = 1, .right = 1 }; // ┈
    t[0x09] = .{ .left = 2, .right = 2 }; // ┉
    t[0x0A] = .{ .up = 1, .down = 1 }; // ┊
    t[0x0B] = .{ .up = 2, .down = 2 }; // ┋
    // U+250C-250F: down+right corners
    t[0x0C] = .{ .right = 1, .down = 1 }; // ┌
    t[0x0D] = .{ .right = 2, .down = 1 }; // ┍
    t[0x0E] = .{ .right = 1, .down = 2 }; // ┎
    t[0x0F] = .{ .right = 2, .down = 2 }; // ┏
    // U+2510-2513: down+left corners
    t[0x10] = .{ .left = 1, .down = 1 }; // ┐
    t[0x11] = .{ .left = 2, .down = 1 }; // ┑
    t[0x12] = .{ .left = 1, .down = 2 }; // ┒
    t[0x13] = .{ .left = 2, .down = 2 }; // ┓
    // U+2514-2517: up+right corners
    t[0x14] = .{ .right = 1, .up = 1 }; // └
    t[0x15] = .{ .right = 2, .up = 1 }; // ┕
    t[0x16] = .{ .right = 1, .up = 2 }; // ┖
    t[0x17] = .{ .right = 2, .up = 2 }; // ┗
    // U+2518-251B: up+left corners
    t[0x18] = .{ .left = 1, .up = 1 }; // ┘
    t[0x19] = .{ .left = 2, .up = 1 }; // ┙
    t[0x1A] = .{ .left = 1, .up = 2 }; // ┚
    t[0x1B] = .{ .left = 2, .up = 2 }; // ┛
    // U+251C-2523: vertical+right T-junctions
    t[0x1C] = .{ .right = 1, .up = 1, .down = 1 }; // ├
    t[0x1D] = .{ .right = 2, .up = 1, .down = 1 }; // ┝
    t[0x1E] = .{ .right = 1, .up = 2, .down = 1 }; // ┞
    t[0x1F] = .{ .right = 1, .up = 1, .down = 2 }; // ┟
    t[0x20] = .{ .right = 1, .up = 2, .down = 2 }; // ┠
    t[0x21] = .{ .right = 2, .up = 2, .down = 1 }; // ┡
    t[0x22] = .{ .right = 2, .up = 1, .down = 2 }; // ┢
    t[0x23] = .{ .right = 2, .up = 2, .down = 2 }; // ┣
    // U+2524-252B: vertical+left T-junctions
    t[0x24] = .{ .left = 1, .up = 1, .down = 1 }; // ┤
    t[0x25] = .{ .left = 2, .up = 1, .down = 1 }; // ┥
    t[0x26] = .{ .left = 1, .up = 2, .down = 1 }; // ┦
    t[0x27] = .{ .left = 1, .up = 1, .down = 2 }; // ┧
    t[0x28] = .{ .left = 1, .up = 2, .down = 2 }; // ┨
    t[0x29] = .{ .left = 2, .up = 2, .down = 1 }; // ┩
    t[0x2A] = .{ .left = 2, .up = 1, .down = 2 }; // ┪
    t[0x2B] = .{ .left = 2, .up = 2, .down = 2 }; // ┫
    // U+252C-2533: horizontal+down T-junctions
    t[0x2C] = .{ .left = 1, .right = 1, .down = 1 }; // ┬
    t[0x2D] = .{ .left = 2, .right = 1, .down = 1 }; // ┭
    t[0x2E] = .{ .left = 1, .right = 2, .down = 1 }; // ┮
    t[0x2F] = .{ .left = 2, .right = 2, .down = 1 }; // ┯
    t[0x30] = .{ .left = 1, .right = 1, .down = 2 }; // ┰
    t[0x31] = .{ .left = 2, .right = 1, .down = 2 }; // ┱
    t[0x32] = .{ .left = 1, .right = 2, .down = 2 }; // ┲
    t[0x33] = .{ .left = 2, .right = 2, .down = 2 }; // ┳
    // U+2534-253B: horizontal+up T-junctions
    t[0x34] = .{ .left = 1, .right = 1, .up = 1 }; // ┴
    t[0x35] = .{ .left = 2, .right = 1, .up = 1 }; // ┵
    t[0x36] = .{ .left = 1, .right = 2, .up = 1 }; // ┶
    t[0x37] = .{ .left = 2, .right = 2, .up = 1 }; // ┷
    t[0x38] = .{ .left = 1, .right = 1, .up = 2 }; // ┸
    t[0x39] = .{ .left = 2, .right = 1, .up = 2 }; // ┹
    t[0x3A] = .{ .left = 1, .right = 2, .up = 2 }; // ┺
    t[0x3B] = .{ .left = 2, .right = 2, .up = 2 }; // ┻
    // U+253C-254B: crosses
    t[0x3C] = .{ .left = 1, .right = 1, .up = 1, .down = 1 }; // ┼
    t[0x3D] = .{ .left = 2, .right = 1, .up = 1, .down = 1 }; // ┽
    t[0x3E] = .{ .left = 1, .right = 2, .up = 1, .down = 1 }; // ┾
    t[0x3F] = .{ .left = 2, .right = 2, .up = 1, .down = 1 }; // ┿
    t[0x40] = .{ .left = 1, .right = 1, .up = 2, .down = 1 }; // ╀
    t[0x41] = .{ .left = 1, .right = 1, .up = 1, .down = 2 }; // ╁
    t[0x42] = .{ .left = 1, .right = 1, .up = 2, .down = 2 }; // ╂
    t[0x43] = .{ .left = 2, .right = 1, .up = 2, .down = 1 }; // ╃
    t[0x44] = .{ .left = 1, .right = 2, .up = 2, .down = 1 }; // ╄
    t[0x45] = .{ .left = 2, .right = 1, .up = 1, .down = 2 }; // ╅
    t[0x46] = .{ .left = 1, .right = 2, .up = 1, .down = 2 }; // ╆
    t[0x47] = .{ .left = 2, .right = 2, .up = 2, .down = 1 }; // ╇
    t[0x48] = .{ .left = 2, .right = 2, .up = 1, .down = 2 }; // ╈
    t[0x49] = .{ .left = 2, .right = 1, .up = 2, .down = 2 }; // ╉
    t[0x4A] = .{ .left = 1, .right = 2, .up = 2, .down = 2 }; // ╊
    t[0x4B] = .{ .left = 2, .right = 2, .up = 2, .down = 2 }; // ╋
    // U+254C-254F: dashed double
    t[0x4C] = .{ .left = 1, .right = 1 }; // ╌
    t[0x4D] = .{ .left = 2, .right = 2 }; // ╍
    t[0x4E] = .{ .up = 1, .down = 1 }; // ╎
    t[0x4F] = .{ .up = 2, .down = 2 }; // ╏
    // U+2550-256C: double-line variants (use weight=3)
    t[0x50] = .{ .left = 3, .right = 3 }; // ═
    t[0x51] = .{ .up = 3, .down = 3 }; // ║
    t[0x52] = .{ .right = 3, .down = 1 }; // ╒
    t[0x53] = .{ .right = 1, .down = 3 }; // ╓
    t[0x54] = .{ .right = 3, .down = 3 }; // ╔
    t[0x55] = .{ .left = 3, .down = 1 }; // ╕
    t[0x56] = .{ .left = 1, .down = 3 }; // ╖
    t[0x57] = .{ .left = 3, .down = 3 }; // ╗
    t[0x58] = .{ .right = 3, .up = 1 }; // ╘
    t[0x59] = .{ .right = 1, .up = 3 }; // ╙
    t[0x5A] = .{ .right = 3, .up = 3 }; // ╚
    t[0x5B] = .{ .left = 3, .up = 1 }; // ╛
    t[0x5C] = .{ .left = 1, .up = 3 }; // ╜
    t[0x5D] = .{ .left = 3, .up = 3 }; // ╝
    t[0x5E] = .{ .right = 3, .up = 1, .down = 1 }; // ╞
    t[0x5F] = .{ .right = 1, .up = 3, .down = 3 }; // ╟
    t[0x60] = .{ .right = 3, .up = 3, .down = 3 }; // ╠
    t[0x61] = .{ .left = 3, .up = 1, .down = 1 }; // ╡
    t[0x62] = .{ .left = 1, .up = 3, .down = 3 }; // ╢
    t[0x63] = .{ .left = 3, .up = 3, .down = 3 }; // ╣
    t[0x64] = .{ .left = 3, .right = 3, .down = 1 }; // ╤
    t[0x65] = .{ .left = 1, .right = 1, .down = 3 }; // ╥
    t[0x66] = .{ .left = 3, .right = 3, .down = 3 }; // ╦
    t[0x67] = .{ .left = 3, .right = 3, .up = 1 }; // ╧
    t[0x68] = .{ .left = 1, .right = 1, .up = 3 }; // ╨
    t[0x69] = .{ .left = 3, .right = 3, .up = 3 }; // ╩
    t[0x6A] = .{ .left = 3, .right = 3, .up = 1, .down = 1 }; // ╪
    t[0x6B] = .{ .left = 1, .right = 1, .up = 3, .down = 3 }; // ╫
    t[0x6C] = .{ .left = 3, .right = 3, .up = 3, .down = 3 }; // ╬
    // U+256D-2570: rounded corners (draw as regular corners)
    t[0x6D] = .{ .right = 1, .down = 1 }; // ╭
    t[0x6E] = .{ .left = 1, .down = 1 }; // ╮
    t[0x6F] = .{ .left = 1, .up = 1 }; // ╯
    t[0x70] = .{ .right = 1, .up = 1 }; // ╰
    // U+2571-2573: diagonals (skip — leave font glyph)
    // U+2574-257F: half lines
    t[0x74] = .{ .left = 1 }; // ╴
    t[0x75] = .{ .up = 1 }; // ╵
    t[0x76] = .{ .right = 1 }; // ╶
    t[0x77] = .{ .down = 1 }; // ╷
    t[0x78] = .{ .left = 2 }; // ╸
    t[0x79] = .{ .up = 2 }; // ╹
    t[0x7A] = .{ .right = 2 }; // ╺
    t[0x7B] = .{ .down = 2 }; // ╻
    t[0x7C] = .{ .left = 1, .right = 2 }; // ╼
    t[0x7D] = .{ .up = 1, .down = 2 }; // ╽
    t[0x7E] = .{ .left = 2, .right = 1 }; // ╾
    t[0x7F] = .{ .up = 2, .down = 1 }; // ╿
    break :blk t;
};

/// Overwrite box-drawing glyph slots in the atlas with programmatic rendering.
fn drawBoxDrawingRange(atlas: []u8, aw: u32, cw: u32, ch: u32, glyphs_per_row: u32) void {
    for (0..128) |idx| {
        const conn = box_connections[idx];
        // Skip empty entries (diagonals U+2571-2573 keep font glyphs)
        if (@as(u8, @bitCast(conn)) == 0) continue;

        const slot = glyphSlot(@as(u21, @intCast(0x2500 + idx))) orelse continue;
        const glyph_col = slot % glyphs_per_row;
        const glyph_row = slot / glyphs_per_row;
        const ax: u32 = glyph_col * cw;
        const ay: u32 = glyph_row * ch;

        // Clear the slot first
        for (0..ch) |dy| {
            const row_off = (ay + @as(u32, @intCast(dy))) * aw + ax;
            if (row_off + cw <= atlas.len) {
                @memset(atlas[row_off..][0..cw], 0);
            }
        }

        const cx = cw / 2; // center x
        const cy = ch / 2; // center y

        // Light line is 1px, heavy is ~cw/4 (min 2px), double is two 1px lines with 2px gap
        const heavy_w: u32 = @max(2, cw / 4);
        const heavy_h: u32 = @max(2, ch / 4);

        // Draw horizontal connections
        if (conn.left > 0) {
            drawHSegment(atlas, aw, ax, ay, 0, cx, cy, conn.left, cw, ch, heavy_w, heavy_h);
        }
        if (conn.right > 0) {
            drawHSegment(atlas, aw, ax, ay, cx, cw, cy, conn.right, cw, ch, heavy_w, heavy_h);
        }
        // Draw vertical connections
        if (conn.up > 0) {
            drawVSegment(atlas, aw, ax, ay, 0, cy, cx, conn.up, cw, ch, heavy_w, heavy_h);
        }
        if (conn.down > 0) {
            drawVSegment(atlas, aw, ax, ay, cy, ch, cx, conn.down, cw, ch, heavy_w, heavy_h);
        }
    }
}

/// Draw a horizontal segment from x0 to x1 at vertical center cy.
fn drawHSegment(atlas: []u8, aw: u32, ax: u32, ay: u32, x0: u32, x1: u32, cy: u32, weight: u2, cw: u32, ch: u32, heavy_w: u32, heavy_h: u32) void {
    _ = cw;
    switch (weight) {
        1 => {
            // Light: 1px line at cy
            setPixelRow(atlas, aw, ax, ay, x0, x1, cy);
        },
        2 => {
            // Heavy: heavy_h px centered on cy
            const y0 = cy -| (heavy_h / 2);
            const y1 = @min(y0 + heavy_h, ch);
            for (y0..y1) |y| {
                setPixelRow(atlas, aw, ax, ay, x0, x1, @intCast(y));
            }
        },
        3 => {
            // Double: two 1px lines with gap
            const gap: u32 = @max(1, heavy_w / 2);
            const y_top = cy -| gap;
            const y_bot = @min(cy + gap, ch - 1);
            setPixelRow(atlas, aw, ax, ay, x0, x1, y_top);
            setPixelRow(atlas, aw, ax, ay, x0, x1, y_bot);
        },
        0 => {},
    }
}

/// Draw a vertical segment from y0 to y1 at horizontal center cx.
fn drawVSegment(atlas: []u8, aw: u32, ax: u32, ay: u32, y0: u32, y1: u32, cx: u32, weight: u2, cw: u32, ch: u32, heavy_w: u32, heavy_h: u32) void {
    _ = ch;
    _ = heavy_h;
    switch (weight) {
        1 => {
            // Light: 1px line at cx
            for (y0..y1) |y| {
                setPixel(atlas, aw, ax + cx, ay + @as(u32, @intCast(y)));
            }
        },
        2 => {
            // Heavy: heavy_w px centered on cx
            const x0 = cx -| (heavy_w / 2);
            const x1 = @min(x0 + heavy_w, cw);
            for (y0..y1) |y| {
                setPixelRow(atlas, aw, ax, ay, x0, x1, @intCast(y));
            }
        },
        3 => {
            // Double: two 1px columns with gap
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
    if (offset < atlas.len) {
        atlas[offset] = 255;
    }
}

/// Overwrite block element glyph slots with programmatic rendering.
/// Block elements are simple filled rectangles.
fn drawBlockElements(atlas: []u8, aw: u32, cw: u32, ch: u32, glyphs_per_row: u32) void {
    for (0x2580..0x25A0) |cp| {
        const slot = glyphSlot(@as(u21, @intCast(cp))) orelse continue;
        const glyph_col = slot % glyphs_per_row;
        const glyph_row = slot / glyphs_per_row;
        const ax: u32 = glyph_col * cw;
        const ay: u32 = glyph_row * ch;

        // Clear the slot
        for (0..ch) |dy| {
            const row_off = (ay + @as(u32, @intCast(dy))) * aw + ax;
            if (row_off + cw <= atlas.len) {
                @memset(atlas[row_off..][0..cw], 0);
            }
        }

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
            // 0x2591-0x2593: shade characters (skip — use font)
            // 0x2594: upper 1/8 block
            0x2594 => fillRect(atlas, aw, ax, ay, cw, ch / 8),
            // 0x2595: right 1/8 block
            0x2595 => fillRect(atlas, aw, ax + cw - cw / 8, ay, cw / 8, ch),
            // 0x2596-259F: quadrant blocks
            0x2596 => fillRect(atlas, aw, ax, ay + ch / 2, cw / 2, ch / 2), // ▖ lower left
            0x2597 => fillRect(atlas, aw, ax + cw / 2, ay + ch / 2, cw / 2, ch / 2), // ▗ lower right
            0x2598 => fillRect(atlas, aw, ax, ay, cw / 2, ch / 2), // ▘ upper left
            0x2599 => { // ▙ upper left + lower
                fillRect(atlas, aw, ax, ay, cw / 2, ch / 2);
                fillRect(atlas, aw, ax, ay + ch / 2, cw, ch / 2);
            },
            0x259A => { // ▚ upper left + lower right
                fillRect(atlas, aw, ax, ay, cw / 2, ch / 2);
                fillRect(atlas, aw, ax + cw / 2, ay + ch / 2, cw / 2, ch / 2);
            },
            0x259B => { // ▛ upper + lower left
                fillRect(atlas, aw, ax, ay, cw, ch / 2);
                fillRect(atlas, aw, ax, ay + ch / 2, cw / 2, ch / 2);
            },
            0x259C => { // ▜ upper + lower right
                fillRect(atlas, aw, ax, ay, cw, ch / 2);
                fillRect(atlas, aw, ax + cw / 2, ay + ch / 2, cw / 2, ch / 2);
            },
            0x259D => fillRect(atlas, aw, ax + cw / 2, ay, cw / 2, ch / 2), // ▝ upper right
            0x259E => { // ▞ upper right + lower left
                fillRect(atlas, aw, ax + cw / 2, ay, cw / 2, ch / 2);
                fillRect(atlas, aw, ax, ay + ch / 2, cw / 2, ch / 2);
            },
            0x259F => { // ▟ upper right + lower
                fillRect(atlas, aw, ax + cw / 2, ay, cw / 2, ch / 2);
                fillRect(atlas, aw, ax, ay + ch / 2, cw, ch / 2);
            },
            else => {},
        }
    }
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

// ── Tests ──────────────────────────────────────────────────────────

test "GlyphInfo has expected fields" {
    const g = GlyphInfo{ .atlas_x = 0, .atlas_y = 0, .width = 8, .height = 16, .bearing_x = 0, .bearing_y = -12, .advance = 8 };
    try std.testing.expectEqual(@as(u16, 8), g.width);
    try std.testing.expectEqual(@as(i16, -12), g.bearing_y);
}

test "preferred font list is not empty" {
    try std.testing.expect(preferred_fonts.len > 0);
    try std.testing.expect(font_search_paths.len > 0);
}

test "glyphSlot: ASCII range" {
    // Space (32) = slot 0
    try std.testing.expectEqual(@as(?u32, 0), glyphSlot(32));
    // 'A' (65) = slot 33
    try std.testing.expectEqual(@as(?u32, 33), glyphSlot('A'));
    // '~' (126) = slot 94
    try std.testing.expectEqual(@as(?u32, 94), glyphSlot(126));
    // DEL (127) = not in atlas
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(127));
}

test "glyphSlot: Latin-1 Supplement" {
    // 160 (NBSP) = slot 95
    try std.testing.expectEqual(@as(?u32, 95), glyphSlot(160));
    // 255 = slot 190
    try std.testing.expectEqual(@as(?u32, 190), glyphSlot(255));
    // 128-159: not in atlas (C1 controls)
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(128));
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(159));
}

test "glyphSlot: Box Drawing" {
    // U+2500 = slot 191
    try std.testing.expectEqual(@as(?u32, 191), glyphSlot(0x2500));
    // U+257F = slot 318
    try std.testing.expectEqual(@as(?u32, 318), glyphSlot(0x257F));
}

test "glyphSlot: Block Elements" {
    // U+2580 = slot 319
    try std.testing.expectEqual(@as(?u32, 319), glyphSlot(0x2580));
    // U+259F = slot 350
    try std.testing.expectEqual(@as(?u32, 350), glyphSlot(0x259F));
}

test "glyphSlot: Cyrillic" {
    // U+0400 = slot 351 (95+96+128+32)
    try std.testing.expectEqual(@as(?u32, 351), glyphSlot(0x0400));
    // U+0410 (А) = slot 367
    try std.testing.expectEqual(@as(?u32, 367), glyphSlot(0x0410));
    // U+0430 (а) = slot 399
    try std.testing.expectEqual(@as(?u32, 399), glyphSlot(0x0430));
    // U+04FF = slot 606 (last Cyrillic)
    try std.testing.expectEqual(@as(?u32, 606), glyphSlot(0x04FF));
    // U+0500 = not in atlas
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x0500));
}

test "glyphSlot: out of range" {
    // CJK character - not in atlas
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x4E2D));
    // Emoji - not in atlas
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x1F600));
}
