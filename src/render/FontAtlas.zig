//! Font atlas builder using stb_truetype (embedded, zero system deps).
//!
//! Rasterizes ASCII printable glyphs (32-126) into a single-channel
//! grayscale texture atlas. Finds fonts by scanning standard paths
//! or accepting an explicit font path. No FreeType, no fontconfig.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const compat = @import("../compat.zig");
const FontSynth = @import("FontSynth.zig");
const FontAtlas = @This();

// ── stb_truetype C bindings ────────────────────────────────────────
//
// Hand-declared per .claude/rules/zig-terminal.md anti-pattern #10.
// The real stbtt_fontinfo is 160 bytes (10 ints + 2 ptrs + 6 × 16-byte
// stbtt__buf). A 256-byte aligned buffer is our opaque stack storage;
// vendor/stb_truetype.c carries a _Static_assert guarding that ceiling.

const stbtt = struct {
    /// Opaque stack storage for an stbtt_fontinfo. Real struct is ~160 B;
    /// vendor/stb_truetype.c carries a _Static_assert guarding this cap.
    pub const stbtt_fontinfo = extern struct {
        _storage: [256]u8 align(8) = undefined,
    };

    pub extern fn stbtt_InitFont(info: *stbtt_fontinfo, data: [*]const u8, offset: c_int) callconv(.c) c_int;
    pub extern fn stbtt_ScaleForPixelHeight(info: *const stbtt_fontinfo, pixel_height: f32) callconv(.c) f32;
    pub extern fn stbtt_GetFontVMetrics(info: *const stbtt_fontinfo, ascent: *c_int, descent: *c_int, line_gap: *c_int) callconv(.c) void;
    pub extern fn stbtt_GetCodepointHMetrics(info: *const stbtt_fontinfo, cp: c_int, advance_width: *c_int, left_side_bearing: *c_int) callconv(.c) void;
    pub extern fn stbtt_GetCodepointBitmapBox(info: *const stbtt_fontinfo, cp: c_int, scale_x: f32, scale_y: f32, ix0: *c_int, iy0: *c_int, ix1: *c_int, iy1: *c_int) callconv(.c) void;
    pub extern fn stbtt_MakeCodepointBitmap(info: *const stbtt_fontinfo, output: [*]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, codepoint: c_int) callconv(.c) void;
};

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
    FontSynth.drawBoxDrawing(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);
    FontSynth.drawBlocks(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);

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

    FontSynth.drawBoxDrawing(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);
    FontSynth.drawBlocks(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);

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
