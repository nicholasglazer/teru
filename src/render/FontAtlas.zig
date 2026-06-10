//! Font atlas builder using stb_truetype (embedded, zero system deps).
//!
//! Rasterizes ASCII printable glyphs (32-126) into a single-channel
//! grayscale texture atlas. Finds fonts by scanning standard paths
//! or accepting an explicit font path. No FreeType, no fontconfig.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const build_options = @import("build_options");
const compat = @import("../compat.zig");
const FontSynth = @import("FontSynth.zig");
const FontAtlas = @This();

// Glyph-range gates resolved at compile time from `-Dglyphs=...`.
// Ascii + Latin-1 + Box + Block are always included (terminal essentials).
// extended (the default) adds everything a modern TUI emits: Geometric
// Shapes, General Punctuation (– — … ' '), Arrows (→), Misc Technical
// (⏺ ⌘ ⏎), Dingbats (✓ ✳ ✶ ✻ — claude-code's task marks + spinner frames
// live here; without them the spinner literally blinks in and out of
// existence), and Braille (⠋⠙… — every ora/rich-style CLI spinner).
// Cyrillic only at full.
const include_geometric: bool = build_options.glyph_budget != .ascii;
const include_punct: bool = build_options.glyph_budget != .ascii;
const include_arrows: bool = build_options.glyph_budget != .ascii;
const include_misc_tech: bool = build_options.glyph_budget != .ascii;
const include_dingbats: bool = build_options.glyph_budget != .ascii;
const include_braille: bool = build_options.glyph_budget != .ascii;
const include_cyrillic: bool = build_options.glyph_budget == .full;

/// One codepoint's flat slot in the atlas grid.
const Codepoint = struct { cp: u21, slot: u32 };

/// Checkbox / consent / mark glyphs synthesized procedurally (font-independent),
/// like box-drawing and block elements. These live in Misc-Symbols/Dingbats and
/// are absent from every `-Dglyphs` budget's rasterized ranges, so FontAtlas
/// would otherwise return null and the renderer would leave a blank cell.
/// ALWAYS-ON (not budget-gated). Placed immediately after Block (U+2580-259F),
/// before the budget-gated geometric/cyrillic/braille ranges.
/// A LOCAL copy lives in FontSynth.drawSymbols and MUST match this order.
const symbol_codepoints = [_]u21{ 0x2022, 0x2610, 0x2611, 0x2612, 0x2713, 0x2714, 0x2717, 0x2718, 0xFFFD };

/// Linear scan: codepoint → index into `symbol_codepoints`, or null if absent.
fn symbolIndex(cp: u21) ?u32 {
    for (symbol_codepoints, 0..) |s, i| {
        if (s == cp) return @intCast(i);
    }
    return null;
}

/// Slots occupied by the always-on ranges (ASCII, Latin-1, Box, Block,
/// Symbols) — the budget-gated ranges start here. Used to disambiguate the
/// symbol/dingbats overlap when storing GlyphInfo (✓✔✗✘ appear in both).
const always_on_slots: u32 = 95 + 96 + 128 + 32 + symbol_codepoints.len;

/// Symbol-fallback font candidates, best coverage first. Probed only for
/// glyphs the MAIN font lacks, so a fully-covered main font never reads
/// these. No fontconfig — fixed well-known paths, same philosophy as
/// font_search_paths below.
const fallback_font_paths = [_][]const u8{
    "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf",
    "/usr/share/fonts/gnu-free/FreeMono.otf",
    "/System/Library/Fonts/Apple Symbols.ttf",
};

/// Total glyph slots for the active `-Dglyphs` budget. SINGLE SOURCE OF TRUTH:
/// atlas dimensions, glyphSlot() offsets, and every rasterizer derive from it.
/// ascii=360, extended=1384, full=1640.
const atlas_total_glyphs: u32 = 95 + 96 + 128 + 32 + 9 +
    (if (include_geometric) 96 else 0) +
    (if (include_cyrillic) 256 else 0) +
    (if (include_braille) 256 else 0) +
    (if (include_punct) 112 else 0) +
    (if (include_arrows) 112 else 0) +
    (if (include_misc_tech) 256 else 0) +
    (if (include_dingbats) 192 else 0);

/// Fill `buf` with the budget-gated codepoint→slot list in the canonical order
/// glyphSlot() resolves: ASCII, Latin-1, Box, Block, Symbols, [Geometric],
/// [Cyrillic], [Braille]. Returns the count (== atlas_total_glyphs). Shared by
/// init() and
/// every re-raster path (zoom / variant) so they cannot drift in count or
/// order — divergence here caused a heap overflow in non-full builds plus
/// wrong-glyph corruption after a font zoom (fixed 2026-05).
fn buildAtlasCodepoints(buf: []Codepoint) u32 {
    var slot: u32 = 0;
    for (32..127) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (160..256) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (0x2500..0x2580) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (0x2580..0x25A0) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    }
    for (symbol_codepoints) |cp| {
        buf[slot] = .{ .cp = cp, .slot = slot };
        slot += 1;
    }
    if (include_geometric) for (0x25A0..0x2600) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    };
    if (include_cyrillic) for (0x0400..0x0500) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    };
    if (include_braille) for (0x2800..0x2900) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    };
    if (include_punct) for (0x2000..0x2070) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    };
    if (include_arrows) for (0x2190..0x2200) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    };
    if (include_misc_tech) for (0x2300..0x2400) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    };
    if (include_dingbats) for (0x2700..0x27C0) |cp| {
        buf[slot] = .{ .cp = @intCast(cp), .slot = slot };
        slot += 1;
    };
    return slot;
}

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
    pub extern fn stbtt_FindGlyphIndex(info: *const stbtt_fontinfo, codepoint: c_int) callconv(.c) c_int;
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
/// Synthesized checkbox/consent/mark glyphs (see `symbol_codepoints`)
symbols_glyphs: [symbol_codepoints.len]?GlyphInfo,
/// Cyrillic (U+0400-U+04FF)
cyrillic_glyphs: [256]?GlyphInfo,
/// Geometric Shapes (U+25A0-U+25FF)
geometric_glyphs: [96]?GlyphInfo,
/// Braille Patterns (U+2800-U+28FF)
braille_glyphs: [256]?GlyphInfo,
/// General Punctuation (U+2000-U+206F): – — … ' ' " "
punct_glyphs: [112]?GlyphInfo,
/// Arrows (U+2190-U+21FF)
arrows_glyphs: [112]?GlyphInfo,
/// Miscellaneous Technical (U+2300-U+23FF): ⏺ ⌘ ⏎ ⌫
misc_tech_glyphs: [256]?GlyphInfo,
/// Dingbats (U+2700-U+27BF): ✓ ✳ ✶ ✻ — TUI marks + spinner frames
dingbats_glyphs: [192]?GlyphInfo,
cell_width: u32,
cell_height: u32,
allocator: std.mem.Allocator,
font_data: []u8, // kept alive for stbtt
/// Symbol-fallback font (AdwaitaMono / DejaVu probe — no fontconfig):
/// rasterizes any codepoint the main font lacks. Null when no fallback
/// was found; rendering then degrades to the synthesized glyphs / blank,
/// exactly as before.
fallback_font_data: ?[]u8 = null,

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

    // Symbol fallback: first probe-able candidate wins. Loaded once here;
    // per-glyph use below is gated on the MAIN font actually missing the
    // codepoint, so a fully-covered main font never touches it. Without a
    // fallback, coding fonts (JetBrains Mono, Hack, …) leave most of the
    // TUI symbol ranges as .notdef lumps or blanks.
    var fallback_font_data: ?[]u8 = null;
    errdefer if (fallback_font_data) |fb| allocator.free(fb);
    var fb_info: stbtt.stbtt_fontinfo = undefined;
    for (fallback_font_paths) |fp| {
        const data = loadFile(allocator, fp, io) catch continue;
        if (stbtt.stbtt_InitFont(&fb_info, data.ptr, 0) == 0) {
            allocator.free(data);
            continue;
        }
        fallback_font_data = data;
        break;
    }
    const fb_scale: f32 = if (fallback_font_data != null)
        stbtt.stbtt_ScaleForPixelHeight(&fb_info, @floatFromInt(font_size))
    else
        0;

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

    // Glyph ranges to rasterize (always-on first):
    //   ASCII printable:     32-126  (95 glyphs)
    //   Latin-1 Supplement: 160-255  (96 glyphs)
    //   Box Drawing:     0x2500-0x257F (128 glyphs)
    //   Block Elements:  0x2580-0x259F (32 glyphs)
    //   Symbols (synth): see symbol_codepoints (9 glyphs)
    // Optional via -Dglyphs:
    //   Geometric Shapes: 0x25A0-0x25FF (96 glyphs)   [extended, full]
    //   Cyrillic:        0x0400-0x04FF (256 glyphs)   [full only]
    //   Braille Patterns: 0x2800-0x28FF (256 glyphs)  [full only]
    // Totals: 360 (ascii) / 1384 (extended) / 1640 (full)
    const total_glyphs: u32 = atlas_total_glyphs;
    const glyphs_per_row: u32 = 16;
    const num_rows: u32 = (total_glyphs + glyphs_per_row - 1) / glyphs_per_row;
    const atlas_w = glyphs_per_row * cell_w;
    const atlas_h = num_rows * cell_h;

    const atlas_data = try allocator.alloc(u8, atlas_w * atlas_h);
    @memset(atlas_data, 0);

    // Initialize glyph tables
    var glyphs: [256]?GlyphInfo = @splat(null);
    var box_glyphs: [128]?GlyphInfo = @splat(null);
    var block_glyphs: [32]?GlyphInfo = @splat(null);
    var symbols_glyphs: [symbol_codepoints.len]?GlyphInfo = @splat(null);
    var cyrillic_glyphs: [256]?GlyphInfo = @splat(null);
    var geometric_glyphs: [96]?GlyphInfo = @splat(null);
    var braille_glyphs: [256]?GlyphInfo = @splat(null);
    var punct_glyphs: [112]?GlyphInfo = @splat(null);
    var arrows_glyphs: [112]?GlyphInfo = @splat(null);
    var misc_tech_glyphs: [256]?GlyphInfo = @splat(null);
    var dingbats_glyphs: [192]?GlyphInfo = @splat(null);
    const baseline: i32 = @intFromFloat(f_ascent);

    // Build the flat codepoint→slot list (budget-gated, canonical order).
    // Shared with the zoom/variant rasterizers via buildAtlasCodepoints so
    // they can never drift in count or order.
    var codepoints: [atlas_total_glyphs]Codepoint = undefined;
    const slot = buildAtlasCodepoints(&codepoints);

    for (codepoints[0..slot]) |entry| {
        const col = entry.slot % glyphs_per_row;
        const row = entry.slot / glyphs_per_row;
        const atlas_x: u32 = @intCast(col * cell_w);
        const atlas_y: u32 = @intCast(row * cell_h);

        // Per-glyph font pick: use the fallback when the main font lacks
        // the codepoint — stb would otherwise rasterize glyph 0 (.notdef),
        // the "lump" that used to stand in for ✔ on coding fonts.
        const use_fb = fallback_font_data != null and
            stbtt.stbtt_FindGlyphIndex(&font_info, @intCast(entry.cp)) == 0 and
            stbtt.stbtt_FindGlyphIndex(&fb_info, @intCast(entry.cp)) != 0;
        const fi: *const stbtt.stbtt_fontinfo = if (use_fb) &fb_info else &font_info;
        const fsc: f32 = if (use_fb) fb_scale else scale;

        // Get glyph metrics
        var advance_c: c_int = 0;
        var lsb: c_int = 0;
        stbtt.stbtt_GetCodepointHMetrics(fi, @intCast(entry.cp), &advance_c, &lsb);

        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        stbtt.stbtt_GetCodepointBitmapBox(fi, @intCast(entry.cp), fsc, fsc, &ix0, &iy0, &ix1, &iy1);

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
                    fi,
                    atlas_data.ptr + dst_y * atlas_w + dst_x,
                    @intCast(@min(render_w, atlas_w - dst_x)),
                    @intCast(@min(render_h, atlas_h - dst_y)),
                    @intCast(atlas_w),
                    fsc,
                    fsc,
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
            .advance = @intCast(@as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(advance_c)) * fsc)))),
        };

        // Store in the correct lookup table. The slot < always_on_slots
        // guard matters for the symbol/dingbats OVERLAP (✓✔✗✘ are in both
        // the always-on symbol list AND the Dingbats range): each entry
        // must store into the table its SLOT belongs to, or the dingbats
        // duplicate would repoint symbols_glyphs at the dingbats slot.
        if (entry.cp < 256) {
            glyphs[entry.cp] = info;
        } else if (entry.cp >= 0x2500 and entry.cp < 0x2580) {
            box_glyphs[entry.cp - 0x2500] = info;
        } else if (entry.cp >= 0x2580 and entry.cp < 0x25A0) {
            block_glyphs[entry.cp - 0x2580] = info;
        } else if (symbolIndex(entry.cp) != null and entry.slot < always_on_slots) {
            symbols_glyphs[symbolIndex(entry.cp).?] = info;
        } else if (entry.cp >= 0x0400 and entry.cp < 0x0500) {
            cyrillic_glyphs[entry.cp - 0x0400] = info;
        } else if (entry.cp >= 0x25A0 and entry.cp < 0x2600) {
            geometric_glyphs[entry.cp - 0x25A0] = info;
        } else if (entry.cp >= 0x2800 and entry.cp < 0x2900) {
            braille_glyphs[entry.cp - 0x2800] = info;
        } else if (entry.cp >= 0x2000 and entry.cp < 0x2070) {
            punct_glyphs[entry.cp - 0x2000] = info;
        } else if (entry.cp >= 0x2190 and entry.cp < 0x2200) {
            arrows_glyphs[entry.cp - 0x2190] = info;
        } else if (entry.cp >= 0x2300 and entry.cp < 0x2400) {
            misc_tech_glyphs[entry.cp - 0x2300] = info;
        } else if (entry.cp >= 0x2700 and entry.cp < 0x27C0) {
            dingbats_glyphs[entry.cp - 0x2700] = info;
        }
    }

    // Override box-drawing and block elements with programmatic rendering.
    // This ensures seamless edge-to-edge connections regardless of font metrics.
    FontSynth.drawBoxDrawing(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);
    FontSynth.drawBlocks(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);
    // Symbols: synthesize ONLY where neither font has a real glyph — a
    // font-drawn ✓ beats the procedural approximation every time.
    var synth_mask: [symbol_codepoints.len]bool = undefined;
    for (symbol_codepoints, 0..) |cp, i| {
        const in_main = stbtt.stbtt_FindGlyphIndex(&font_info, @intCast(cp)) != 0;
        const in_fb = fallback_font_data != null and
            stbtt.stbtt_FindGlyphIndex(&fb_info, @intCast(cp)) != 0;
        synth_mask[i] = !in_main and !in_fb;
    }
    FontSynth.drawSymbols(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row, &synth_mask);

    return FontAtlas{
        .atlas_data = atlas_data,
        .atlas_width = atlas_w,
        .atlas_height = atlas_h,
        .glyphs = glyphs,
        .box_glyphs = box_glyphs,
        .block_glyphs = block_glyphs,
        .symbols_glyphs = symbols_glyphs,
        .cyrillic_glyphs = cyrillic_glyphs,
        .geometric_glyphs = geometric_glyphs,
        .braille_glyphs = braille_glyphs,
        .punct_glyphs = punct_glyphs,
        .arrows_glyphs = arrows_glyphs,
        .misc_tech_glyphs = misc_tech_glyphs,
        .dingbats_glyphs = dingbats_glyphs,
        .cell_width = cell_w,
        .cell_height = cell_h,
        .allocator = allocator,
        .font_data = font_data,
        .fallback_font_data = fallback_font_data,
    };
}

/// Direction of a font-size zoom step. `.reset` returns to the config size.
pub const ZoomTarget = enum { in, out, reset };

/// Smallest font size a zoom-out is allowed to reach — below this glyphs
/// stop being legible and `rasterizeAtSize` risks `error.InvalidFontMetrics`.
pub const min_font_size: u16 = 6;

/// Compute the font size after one zoom step. Pure — the standalone
/// terminal (windowed mode) and the compositor share this so their zoom
/// behaviour can never drift. `current` is the live size; `config_size`
/// is the size to restore on `.reset`.
pub fn zoomedFontSize(target: ZoomTarget, current: u16, config_size: u16) u16 {
    return switch (target) {
        .in => current +| 1,
        .out => @max(min_font_size, current -| 1),
        .reset => config_size,
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

    // Re-init the symbol fallback from the bytes init() already loaded.
    var fb_info: stbtt.stbtt_fontinfo = undefined;
    var have_fb = false;
    if (self.fallback_font_data) |fbd| {
        if (stbtt.stbtt_InitFont(&fb_info, fbd.ptr, 0) != 0) have_fb = true;
    }
    const fb_scale: f32 = if (have_fb)
        stbtt.stbtt_ScaleForPixelHeight(&fb_info, @floatFromInt(new_size))
    else
        0;

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

    const total_glyphs: u32 = atlas_total_glyphs;
    const glyphs_per_row: u32 = 16;
    const num_rows: u32 = (total_glyphs + glyphs_per_row - 1) / glyphs_per_row;
    const atlas_w = glyphs_per_row * cell_w;
    const atlas_h = num_rows * cell_h;

    const atlas_data = try self.allocator.alloc(u8, atlas_w * atlas_h);
    @memset(atlas_data, 0);

    var glyphs: [256]?GlyphInfo = @splat(null);
    var box_glyphs: [128]?GlyphInfo = @splat(null);
    var block_glyphs: [32]?GlyphInfo = @splat(null);
    var symbols_glyphs: [symbol_codepoints.len]?GlyphInfo = @splat(null);
    var cyrillic_glyphs: [256]?GlyphInfo = @splat(null);
    var geometric_glyphs: [96]?GlyphInfo = @splat(null);
    var braille_glyphs: [256]?GlyphInfo = @splat(null);
    var punct_glyphs: [112]?GlyphInfo = @splat(null);
    var arrows_glyphs: [112]?GlyphInfo = @splat(null);
    var misc_tech_glyphs: [256]?GlyphInfo = @splat(null);
    var dingbats_glyphs: [192]?GlyphInfo = @splat(null);
    const baseline: i32 = @intFromFloat(f_ascent);

    var codepoints: [atlas_total_glyphs]Codepoint = undefined;
    const slot = buildAtlasCodepoints(&codepoints);

    for (codepoints[0..slot]) |entry| {
        const col = entry.slot % glyphs_per_row;
        const row = entry.slot / glyphs_per_row;
        const atlas_x: u32 = @intCast(col * cell_w);
        const atlas_y: u32 = @intCast(row * cell_h);

        const use_fb = have_fb and
            stbtt.stbtt_FindGlyphIndex(&font_info, @intCast(entry.cp)) == 0 and
            stbtt.stbtt_FindGlyphIndex(&fb_info, @intCast(entry.cp)) != 0;
        const fi: *const stbtt.stbtt_fontinfo = if (use_fb) &fb_info else &font_info;
        const fsc: f32 = if (use_fb) fb_scale else scale;

        var advance_c: c_int = 0;
        var lsb: c_int = 0;
        stbtt.stbtt_GetCodepointHMetrics(fi, @intCast(entry.cp), &advance_c, &lsb);

        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        stbtt.stbtt_GetCodepointBitmapBox(fi, @intCast(entry.cp), fsc, fsc, &ix0, &iy0, &ix1, &iy1);

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
                    fi,
                    atlas_data.ptr + dst_y * atlas_w + dst_x,
                    @intCast(@min(render_w, atlas_w - dst_x)),
                    @intCast(@min(render_h, atlas_h - dst_y)),
                    @intCast(atlas_w),
                    fsc,
                    fsc,
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
            .advance = @intCast(@as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(advance_c)) * fsc)))),
        };

        if (entry.cp < 256) { glyphs[entry.cp] = info; }
        else if (entry.cp >= 0x2500 and entry.cp < 0x2580) { box_glyphs[entry.cp - 0x2500] = info; }
        else if (entry.cp >= 0x2580 and entry.cp < 0x25A0) { block_glyphs[entry.cp - 0x2580] = info; }
        else if (symbolIndex(entry.cp) != null and entry.slot < always_on_slots) { symbols_glyphs[symbolIndex(entry.cp).?] = info; }
        else if (entry.cp >= 0x0400 and entry.cp < 0x0500) { cyrillic_glyphs[entry.cp - 0x0400] = info; }
        else if (entry.cp >= 0x25A0 and entry.cp < 0x2600) { geometric_glyphs[entry.cp - 0x25A0] = info; }
        else if (entry.cp >= 0x2800 and entry.cp < 0x2900) { braille_glyphs[entry.cp - 0x2800] = info; }
        else if (entry.cp >= 0x2000 and entry.cp < 0x2070) { punct_glyphs[entry.cp - 0x2000] = info; }
        else if (entry.cp >= 0x2190 and entry.cp < 0x2200) { arrows_glyphs[entry.cp - 0x2190] = info; }
        else if (entry.cp >= 0x2300 and entry.cp < 0x2400) { misc_tech_glyphs[entry.cp - 0x2300] = info; }
        else if (entry.cp >= 0x2700 and entry.cp < 0x27C0) { dingbats_glyphs[entry.cp - 0x2700] = info; }
    }

    FontSynth.drawBoxDrawing(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);
    FontSynth.drawBlocks(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row);
    var synth_mask: [symbol_codepoints.len]bool = undefined;
    for (symbol_codepoints, 0..) |cp, i| {
        const in_main = stbtt.stbtt_FindGlyphIndex(&font_info, @intCast(cp)) != 0;
        const in_fb = have_fb and stbtt.stbtt_FindGlyphIndex(&fb_info, @intCast(cp)) != 0;
        synth_mask[i] = !in_main and !in_fb;
    }
    FontSynth.drawSymbols(atlas_data, atlas_w, cell_w, cell_h, glyphs_per_row, &synth_mask);

    // Reuse existing font_data (don't free it — the old atlas still owns it until caller deinits)
    const font_data_copy = try self.allocator.alloc(u8, self.font_data.len);
    errdefer self.allocator.free(font_data_copy);
    @memcpy(font_data_copy, self.font_data);

    // The new atlas owns its own copy of the fallback bytes too.
    var fallback_copy: ?[]u8 = null;
    if (self.fallback_font_data) |fbd| {
        const c = try self.allocator.alloc(u8, fbd.len);
        @memcpy(c, fbd);
        fallback_copy = c;
    }

    return FontAtlas{
        .atlas_data = atlas_data,
        .atlas_width = atlas_w,
        .atlas_height = atlas_h,
        .glyphs = glyphs,
        .box_glyphs = box_glyphs,
        .block_glyphs = block_glyphs,
        .symbols_glyphs = symbols_glyphs,
        .cyrillic_glyphs = cyrillic_glyphs,
        .geometric_glyphs = geometric_glyphs,
        .braille_glyphs = braille_glyphs,
        .punct_glyphs = punct_glyphs,
        .arrows_glyphs = arrows_glyphs,
        .misc_tech_glyphs = misc_tech_glyphs,
        .dingbats_glyphs = dingbats_glyphs,
        .cell_width = cell_w,
        .cell_height = cell_h,
        .allocator = self.allocator,
        .font_data = font_data_copy,
        .fallback_font_data = fallback_copy,
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

    // Same budget-gated codepoint list / order as init() — shared helper so a
    // non-full build's variant atlas is sized to the real glyph count (not a
    // hardcoded 959) and slots line up with glyphSlot().
    var codepoints: [atlas_total_glyphs]Codepoint = undefined;
    const slot = buildAtlasCodepoints(&codepoints);

    // Symbol fallback (borrowed from the primary atlas) — same rationale
    // as rasterizeVariant: a variant font missing a codepoint must not
    // leave an empty slot where the regular weight renders a glyph.
    var fb_info: stbtt.stbtt_fontinfo = undefined;
    var have_fb = false;
    if (self.fallback_font_data) |fbd| {
        if (stbtt.stbtt_InitFont(&fb_info, fbd.ptr, 0) != 0) have_fb = true;
    }
    const fb_scale: f32 = if (have_fb)
        stbtt.stbtt_ScaleForPixelHeight(&fb_info, target_h)
    else
        0;

    for (codepoints[0..slot]) |entry| {
        const col = entry.slot % glyphs_per_row;
        const row = entry.slot / glyphs_per_row;
        const atlas_x: u32 = @intCast(col * cw);
        const atlas_y: u32 = @intCast(row * ch);

        const use_fb = have_fb and
            stbtt.stbtt_FindGlyphIndex(&font_info, @intCast(entry.cp)) == 0 and
            stbtt.stbtt_FindGlyphIndex(&fb_info, @intCast(entry.cp)) != 0;
        const fi: *const stbtt.stbtt_fontinfo = if (use_fb) &fb_info else &font_info;
        const fsc: f32 = if (use_fb) fb_scale else scale;

        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        stbtt.stbtt_GetCodepointBitmapBox(fi, @intCast(entry.cp), fsc, fsc, &ix0, &iy0, &ix1, &iy1);

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
                    fi,
                    atlas.ptr + dst_y * aw + dst_x,
                    @intCast(@min(render_w, aw - dst_x)),
                    @intCast(@min(render_h, ah - dst_y)),
                    @intCast(aw),
                    fsc,
                    fsc,
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

    // Symbol fallback (borrowed from the primary atlas — read-only here):
    // a bold/italic variant font missing a codepoint would otherwise leave
    // an empty variant slot, making e.g. a BOLD ✓ vanish while the regular
    // one renders.
    var fb_info: stbtt.stbtt_fontinfo = undefined;
    var have_fb = false;
    if (self.fallback_font_data) |fbd| {
        if (stbtt.stbtt_InitFont(&fb_info, fbd.ptr, 0) != 0) have_fb = true;
    }
    const fb_scale: f32 = if (have_fb)
        stbtt.stbtt_ScaleForPixelHeight(&fb_info, target_h)
    else
        0;

    const atlas_buf = try allocator.alloc(u8, self.atlas_width * self.atlas_height);
    errdefer allocator.free(atlas_buf);
    @memset(atlas_buf, 0);

    const baseline: i32 = @intFromFloat(@as(f32, @floatFromInt(ascent)) * scale);
    const cw = self.cell_width;
    const ch = self.cell_height;
    const aw = self.atlas_width;
    const ah = self.atlas_height;
    const glyphs_per_row: u32 = 16;

    var codepoints: [atlas_total_glyphs]Codepoint = undefined;
    const slot = buildAtlasCodepoints(&codepoints);

    for (codepoints[0..slot]) |entry| {
        const col = entry.slot % glyphs_per_row;
        const row = entry.slot / glyphs_per_row;
        const atlas_x: u32 = @intCast(col * cw);
        const atlas_y: u32 = @intCast(row * ch);

        const use_fb = have_fb and
            stbtt.stbtt_FindGlyphIndex(&font_info, @intCast(entry.cp)) == 0 and
            stbtt.stbtt_FindGlyphIndex(&fb_info, @intCast(entry.cp)) != 0;
        const fi: *const stbtt.stbtt_fontinfo = if (use_fb) &fb_info else &font_info;
        const fsc: f32 = if (use_fb) fb_scale else scale;

        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        stbtt.stbtt_GetCodepointBitmapBox(fi, @intCast(entry.cp), fsc, fsc, &ix0, &iy0, &ix1, &iy1);
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
                    fi,
                    atlas_buf.ptr + dst_y * aw + dst_x,
                    @intCast(@min(render_w, aw - dst_x)),
                    @intCast(@min(render_h, ah - dst_y)),
                    @intCast(aw),
                    fsc,
                    fsc,
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
    if (self.fallback_font_data) |fb| self.allocator.free(fb);
}

pub fn getGlyph(self: *const FontAtlas, codepoint: u21) ?GlyphInfo {
    if (codepoint < 256) return self.glyphs[codepoint];
    if (codepoint >= 0x2500 and codepoint < 0x2580)
        return self.box_glyphs[codepoint - 0x2500];
    if (codepoint >= 0x2580 and codepoint < 0x25A0)
        return self.block_glyphs[codepoint - 0x2580];
    if (symbolIndex(codepoint)) |i| return self.symbols_glyphs[i];
    if (include_geometric and codepoint >= 0x25A0 and codepoint < 0x2600)
        return self.geometric_glyphs[codepoint - 0x25A0];
    if (include_cyrillic and codepoint >= 0x0400 and codepoint < 0x0500)
        return self.cyrillic_glyphs[codepoint - 0x0400];
    if (include_braille and codepoint >= 0x2800 and codepoint < 0x2900)
        return self.braille_glyphs[codepoint - 0x2800];
    if (include_punct and codepoint >= 0x2000 and codepoint < 0x2070)
        return self.punct_glyphs[codepoint - 0x2000];
    if (include_arrows and codepoint >= 0x2190 and codepoint < 0x2200)
        return self.arrows_glyphs[codepoint - 0x2190];
    if (include_misc_tech and codepoint >= 0x2300 and codepoint < 0x2400)
        return self.misc_tech_glyphs[codepoint - 0x2300];
    if (include_dingbats and codepoint >= 0x2700 and codepoint < 0x27C0)
        return self.dingbats_glyphs[codepoint - 0x2700];
    return null;
}

/// Convert a codepoint to its atlas slot index (for renderer blitting).
/// Returns null if the codepoint is not in the atlas.
///
/// Slot layout MUST match the build order in `init()`. Always-on ranges
/// occupy slots 0..360 in fixed order (ASCII, Latin-1, Box, Block, Symbols).
/// Optional ranges follow in the
/// order { geometric, cyrillic, braille } — only the included ones
/// consume slot space, so users with `-Dglyphs=ascii` get an atlas with
/// no wasted rows for ranges they don't have.
pub fn glyphSlot(codepoint: u21) ?u32 {
    if (codepoint >= 32 and codepoint < 127) return @as(u32, codepoint - 32);
    if (codepoint >= 160 and codepoint < 256) return @as(u32, codepoint - 160) + 95;
    if (codepoint >= 0x2500 and codepoint < 0x2580) return @as(u32, codepoint - 0x2500) + 95 + 96;
    if (codepoint >= 0x2580 and codepoint < 0x25A0) return @as(u32, codepoint - 0x2580) + 95 + 96 + 128;
    if (symbolIndex(codepoint)) |i| return 95 + 96 + 128 + 32 + i;

    comptime var opt_offset: u32 = 95 + 96 + 128 + 32 + symbol_codepoints.len; // = 360
    if (include_geometric) {
        if (codepoint >= 0x25A0 and codepoint < 0x2600) return @as(u32, codepoint - 0x25A0) + opt_offset;
        opt_offset += 96;
    }
    if (include_cyrillic) {
        if (codepoint >= 0x0400 and codepoint < 0x0500) return @as(u32, codepoint - 0x0400) + opt_offset;
        opt_offset += 256;
    }
    if (include_braille) {
        if (codepoint >= 0x2800 and codepoint < 0x2900) return @as(u32, codepoint - 0x2800) + opt_offset;
        opt_offset += 256;
    }
    if (include_punct) {
        if (codepoint >= 0x2000 and codepoint < 0x2070) return @as(u32, codepoint - 0x2000) + opt_offset;
        opt_offset += 112;
    }
    if (include_arrows) {
        if (codepoint >= 0x2190 and codepoint < 0x2200) return @as(u32, codepoint - 0x2190) + opt_offset;
        opt_offset += 112;
    }
    if (include_misc_tech) {
        if (codepoint >= 0x2300 and codepoint < 0x2400) return @as(u32, codepoint - 0x2300) + opt_offset;
        opt_offset += 256;
    }
    if (include_dingbats) {
        if (codepoint >= 0x2700 and codepoint < 0x27C0) return @as(u32, codepoint - 0x2700) + opt_offset;
    }
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
    var buf: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.access(&buf, 0) == 0; // F_OK = 0
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8, io: Io) ![]u8 {
    const file = Dir.cwd().openFile(io, path, .{}) catch return error.FileNotFound;
    defer file.close(io);
    const s = file.stat(io) catch return error.StatFailed;
    // Guard the u64→usize cast: stat.size is u64 but fonts larger than
    // 16 MiB are implausible (DejaVu Sans is ~700 KB, Noto Sans CJK is
    // ~20 MB collection file). Refuse something that smells wrong
    // before the allocator does.
    if (s.size > 32 * 1024 * 1024) return error.FontTooLarge;
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

test "zoomedFontSize: in/out step by one, reset to config" {
    try std.testing.expectEqual(@as(u16, 17), zoomedFontSize(.in, 16, 14));
    try std.testing.expectEqual(@as(u16, 15), zoomedFontSize(.out, 16, 14));
    try std.testing.expectEqual(@as(u16, 14), zoomedFontSize(.reset, 16, 14));
}

test "zoomedFontSize: zoom-out clamps at min_font_size" {
    try std.testing.expectEqual(min_font_size, zoomedFontSize(.out, min_font_size, 14));
    try std.testing.expectEqual(min_font_size, zoomedFontSize(.out, min_font_size + 1, 14));
}

test "zoomedFontSize: zoom-in saturates instead of overflowing" {
    const max = std.math.maxInt(u16);
    try std.testing.expectEqual(max, zoomedFontSize(.in, max, 14));
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

test "glyphSlot: synthesized symbols (always-on, after Block)" {
    // symbol_codepoints = { 0x2022, 0x2610, 0x2611, 0x2612, 0x2713, 0x2714,
    //                       0x2717, 0x2718, 0xFFFD } at slot base 351.
    const base: u32 = 95 + 96 + 128 + 32; // = 351
    try std.testing.expectEqual(@as(?u32, base + 0), glyphSlot(0x2022)); // • index 0 → 351
    try std.testing.expectEqual(@as(?u32, base + 1), glyphSlot(0x2610)); // ☐ index 1 → 352
    try std.testing.expectEqual(@as(?u32, base + 4), glyphSlot(0x2713)); // ✓ index 4 → 355
    try std.testing.expectEqual(@as(?u32, base + 8), glyphSlot(0xFFFD)); // � index 8 → 359
    // 0x2715 ✕ is not in the symbol LIST but now lives in the Dingbats
    // range (extended budget) — present there, absent at ascii budget.
    if (include_dingbats) {
        try std.testing.expect(glyphSlot(0x2715) != null);
    } else {
        try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x2715));
    }
    // A codepoint outside every atlas range is absent (Glagolitic).
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x2C00));
    // symbolIndex maps codepoint → array index.
    try std.testing.expectEqual(@as(?u32, 0), symbolIndex(0x2022));
    try std.testing.expectEqual(@as(?u32, 8), symbolIndex(0xFFFD));
    try std.testing.expectEqual(@as(?u32, null), symbolIndex(0x2715));
}

test "glyphSlot: Cyrillic" {
    // Slot positions depend on which optional ranges precede Cyrillic:
    //   .full     → Cyrillic comes after Geometric → starts at 360 + 96 = 456
    //   .full without Geometric (impossible today) → would be 360
    //   .ascii / .extended → Cyrillic excluded entirely
    if (!include_cyrillic) {
        try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x0400));
        return;
    }
    // Always-on ranges = 351 + 9 synthesized symbols = 360, then geometric (96).
    const base: u32 = 95 + 96 + 128 + 32 + symbol_codepoints.len + (if (include_geometric) @as(u32, 96) else 0);
    try std.testing.expectEqual(@as(?u32, base), glyphSlot(0x0400));
    try std.testing.expectEqual(@as(?u32, base + 0x10), glyphSlot(0x0410));
    try std.testing.expectEqual(@as(?u32, base + 0x30), glyphSlot(0x0430));
    try std.testing.expectEqual(@as(?u32, base + 0xFF), glyphSlot(0x04FF));
    // U+0500 = not in atlas
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x0500));
}

test "glyphSlot: out of range" {
    // CJK character - not in atlas
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x4E2D));
    // Emoji - not in atlas
    try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x1F600));
}

test "atlas builder and glyphSlot agree (no count/order drift)" {
    // Regression guard: the atlas rasterizers (init, zoom, bold/italic variant)
    // and glyphSlot() MUST agree on count and slot order. When they diverged
    // (hardcoded 959 + Cyrillic-before-Geometric), non-full builds overflowed
    // the variant atlas and a font zoom rendered the wrong glyphs.
    var buf: [atlas_total_glyphs]Codepoint = undefined;
    const n = buildAtlasCodepoints(&buf);
    try std.testing.expectEqual(atlas_total_glyphs, n);
    for (buf[0..n]) |entry| {
        // Every rasterized slot is addressable within the budget-sized atlas.
        try std.testing.expect(entry.slot < atlas_total_glyphs);
        // ✓✔✗✘ are deliberately rasterized TWICE (always-on symbol list AND
        // the Dingbats range); lookup prefers the always-on symbol slot.
        if (symbolIndex(entry.cp) != null and entry.slot >= always_on_slots) {
            try std.testing.expectEqual(
                @as(?u32, 95 + 96 + 128 + 32 + symbolIndex(entry.cp).?),
                glyphSlot(entry.cp),
            );
            continue;
        }
        // glyphSlot() resolves the same codepoint to the same slot the
        // rasterizer wrote it to — otherwise the renderer reads a wrong glyph.
        try std.testing.expectEqual(@as(?u32, entry.slot), glyphSlot(entry.cp));
    }
}

test "glyphSlot: TUI symbol ranges (punct/arrows/misc-tech/dingbats/braille at extended)" {
    if (!include_dingbats) {
        try std.testing.expectEqual(@as(?u32, null), glyphSlot(0x2733)); // ✳
        return;
    }
    // The spinner sparkles + marks every modern TUI emits must resolve —
    // these rendered as BLANK cells before the extended budget grew, which
    // made claude-code's sparkle spinner blink in and out of existence.
    try std.testing.expect(glyphSlot(0x2014) != null); // — em dash
    try std.testing.expect(glyphSlot(0x2026) != null); // … ellipsis
    try std.testing.expect(glyphSlot(0x2192) != null); // → arrow
    try std.testing.expect(glyphSlot(0x23FA) != null); // ⏺ record
    try std.testing.expect(glyphSlot(0x2722) != null); // ✢
    try std.testing.expect(glyphSlot(0x2733) != null); // ✳
    try std.testing.expect(glyphSlot(0x2736) != null); // ✶
    try std.testing.expect(glyphSlot(0x273B) != null); // ✻
    try std.testing.expect(glyphSlot(0x2800) != null); // ⠀ braille (extended now)
    try std.testing.expect(glyphSlot(0x28FF) != null);
    // Lookup order: ✔ prefers its always-on symbol slot over the dingbats one.
    try std.testing.expectEqual(@as(?u32, 95 + 96 + 128 + 32 + 5), glyphSlot(0x2714));
}
