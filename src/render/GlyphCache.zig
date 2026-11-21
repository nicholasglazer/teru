//! Glyphs drawn on demand, for codepoints the fixed atlas has no slot for.
//!
//! The fixed atlas pre-rasterizes a few hundred codepoints (ASCII, Latin-1,
//! box drawing, symbols). Everything else — Hangul, kana, Han, Greek, Latin
//! Extended — used to draw nothing. This cache gives those codepoints a slot
//! the first time a renderer asks for one.
//!
//! Slots live in rows reserved at the end of the atlas bitmap, so renderers
//! blit them exactly like fixed slots and the bitmap is never reallocated.
//! Every entry is a pair of adjacent slots: a wide glyph fills both, the left
//! half drawn in its cell and the right half in the trailer cell after it; a
//! narrow glyph uses only the left one.
//!
//! Nothing here allocates. A miss rasterizes straight into the reserved rows
//! (stb's own scratch memory is a static arena, see vendor/stb_truetype.c),
//! and when the cache is full it is emptied and refilled as glyphs are drawn
//! again. Pixels already blitted to a framebuffer are unaffected by that.

const std = @import("std");
const stb = @import("stb.zig");
const FallbackFonts = @import("FallbackFonts.zig");

const GlyphCache = @This();

/// Most pairs a cache holds. The lookup table is sized for this.
pub const max_pairs = 2048;
/// Bytes of atlas the reserved rows may take, which limits the pair count at
/// large font sizes. Sized so a screen of CJK text, which shows on the order
/// of a thousand distinct glyphs, fits without the cache emptying itself on
/// every repaint.
const max_reserved_bytes = 4 * 1024 * 1024;

/// Entries in the lookup table: a power of two, at least 2 × max_pairs.
pub const table_len = 4096;
/// Table value for a free entry. Zero, so an empty table is plain zeroed
/// memory; a real entry is never zero because codepoint 0 is never cached.
const empty: u32 = 0;
const pair_bits = 11;

comptime {
    std.debug.assert(max_pairs <= (1 << pair_bits));
    std.debug.assert(table_len >= 2 * max_pairs);
}

/// A font the owning atlas already holds, drawn at the atlas's own scale and
/// baseline so its glyphs match the pre-rasterized ones.
pub const AtlasFont = struct {
    info: stb.stbtt_fontinfo = .{},
    scale: f32 = 0,
    present: bool = false,

    /// `bytes` must outlive the cache.
    pub fn init(bytes: ?[]const u8, scale: f32) AtlasFont {
        const data = bytes orelse return .{};
        var font: AtlasFont = .{ .scale = scale };
        font.present = stb.stbtt_InitFont(&font.info, data.ptr, 0) != 0;
        return font;
    }
};

/// The whole atlas bitmap; the reserved rows are its tail.
pixels: []u8 = &.{},
atlas_w: u32 = 0,
cell_w: u32 = 0,
cell_h: u32 = 0,
/// Slot index of the first reserved slot; a multiple of the slots per row.
first_slot: u32 = 0,
/// Pairs the reserved rows hold. Zero disables the cache.
capacity: u32 = 0,
count: u32 = 0,
/// Open-addressed map from codepoint to pair: `(codepoint << pair_bits) | pair`.
/// `table_len` entries, owned by whoever set the cache up. Kept out of the
/// struct so the atlas that embeds this stays cheap to copy.
table: []u32 = &.{},
main: AtlasFont = .{},
symbol: AtlasFont = .{},
/// Row of the main font's baseline within a cell.
baseline: i32 = 0,
chain: []const FallbackFonts.Font = &.{},

pub const Config = struct {
    /// The whole atlas bitmap, reserved rows included.
    pixels: []u8,
    atlas_w: u32,
    cell_w: u32,
    cell_h: u32,
    first_slot: u32,
    capacity: u32,
    /// `table_len` entries of scratch for the lookup table.
    table: []u32,
    /// Font bytes the owning atlas holds; they must outlive the cache.
    main_font: ?[]const u8,
    main_scale: f32,
    symbol_font: ?[]const u8,
    symbol_scale: f32,
    baseline: i32,
    chain: []const FallbackFonts.Font,
};

/// Initialise in place as an empty cache.
pub fn setUp(self: *GlyphCache, config: Config) void {
    std.debug.assert(config.table.len == table_len);
    self.pixels = config.pixels;
    self.atlas_w = config.atlas_w;
    self.cell_w = config.cell_w;
    self.cell_h = config.cell_h;
    self.first_slot = config.first_slot;
    self.capacity = config.capacity;
    self.count = 0;
    self.table = config.table;
    @memset(self.table, empty);
    self.main = .init(config.main_font, config.main_scale);
    self.symbol = .init(config.symbol_font, config.symbol_scale);
    self.baseline = config.baseline;
    self.chain = config.chain;
}

/// How many pairs to reserve for cells of this size, a multiple of 8 so the
/// pairs fill whole atlas rows of 16 slots.
pub fn pairsFor(cell_w: u32, cell_h: u32, limit: u32) u32 {
    const pair_bytes = 2 * cell_w * cell_h;
    if (pair_bytes == 0) return 0;
    return @min(@min(limit, max_pairs), max_reserved_bytes / pair_bytes) & ~@as(u32, 7);
}

/// Left slot of the glyph for `cp`, rasterizing it first if this is its first
/// use. The right half of a wide glyph is the next slot. Null when the cache
/// has no reserved rows.
pub fn resolve(self: *GlyphCache, cp: u21, wide: bool) ?u32 {
    if (self.capacity == 0 or cp == 0) return null;
    var i = hash(cp);
    while (true) : (i = (i + 1) & (table_len - 1)) {
        const entry = self.table[i];
        if (entry == empty) break;
        if (entry >> pair_bits == cp) return self.slotOf(entry & ((1 << pair_bits) - 1));
    }
    return self.fill(cp, wide);
}

/// Store ready-made coverage for `cp`: `alpha` is `2 * cell_w` by `cell_h`,
/// row-major. For tests, and for callers that draw their own glyphs.
pub fn insertRaw(self: *GlyphCache, cp: u21, alpha: []const u8) ?u32 {
    if (self.capacity == 0 or cp == 0) return null;
    const box_w = 2 * self.cell_w;
    std.debug.assert(alpha.len == box_w * self.cell_h);
    const slot = self.claim(cp);
    const origin = self.originOf(slot);
    for (0..self.cell_h) |y| {
        const dst = origin + y * self.atlas_w;
        @memcpy(self.pixels[dst..][0..box_w], alpha[y * box_w ..][0..box_w]);
    }
    return slot;
}

fn hash(cp: u21) usize {
    return @intCast((@as(u32, cp) *% 0x9E3779B1) >> (32 - 12));
}

comptime {
    std.debug.assert(table_len == 1 << 12); // `hash` keeps the top 12 bits
}

fn slotOf(self: *const GlyphCache, pair: u32) u32 {
    return self.first_slot + pair * 2;
}

/// Byte offset in `pixels` of the top-left corner of `slot`.
fn originOf(self: *const GlyphCache, slot: u32) usize {
    const per_row = self.atlas_w / self.cell_w;
    const x: usize = (slot % per_row) * self.cell_w;
    const y: usize = (slot / per_row) * self.cell_h;
    return y * self.atlas_w + x;
}

/// Take the next free pair for `cp` and record it, emptying the cache first
/// when it is full.
fn claim(self: *GlyphCache, cp: u21) u32 {
    if (self.count == self.capacity) {
        @memset(self.table, empty);
        self.count = 0;
    }
    const pair = self.count;
    self.count += 1;
    var i = hash(cp);
    while (self.table[i] != empty) i = (i + 1) & (table_len - 1);
    self.table[i] = (@as(u32, cp) << pair_bits) | pair;
    return self.slotOf(pair);
}

/// Kept out of line: this is the rare path, and `resolve` sits in the
/// per-cell render loop.
noinline fn fill(self: *GlyphCache, cp: u21, wide: bool) u32 {
    const slot = self.claim(cp);
    const origin = self.originOf(slot);
    const cw = self.cell_w;
    const ch = self.cell_h;
    for (0..ch) |y| @memset(self.pixels[origin + y * self.atlas_w ..][0 .. 2 * cw], 0);

    // Controls and default-ignorable codepoints that the grid still stores
    // in a cell (DEL, C1, the byte-order mark, tags, variation selectors)
    // are invisible: no glyph and no placeholder box.
    switch (cp) {
        0x7F...0x9F, 0xFEFF, 0xE0000...0xE0FFF => return slot,
        else => {},
    }

    const box_w: u32 = if (wide) 2 * cw else cw;
    if (self.main.present and stb.stbtt_FindGlyphIndex(&self.main.info, cp) != 0) {
        self.drawOnBaseline(&self.main, cp, origin, box_w);
    } else if (self.symbol.present and stb.stbtt_FindGlyphIndex(&self.symbol.info, cp) != 0) {
        self.drawOnBaseline(&self.symbol, cp, origin, box_w);
    } else for (self.chain) |*font| {
        if (stb.stbtt_FindGlyphIndex(&font.info, cp) == 0) continue;
        self.drawCentred(font, cp, origin, box_w, wide);
        break;
    } else self.drawPlaceholder(origin, box_w);
    return slot;
}

/// Draw at the font's atlas scale on the main baseline, the same placement
/// the fixed atlas uses, clipped to the box.
fn drawOnBaseline(self: *GlyphCache, font: *const AtlasFont, cp: u21, origin: usize, box_w: u32) void {
    var ix0: c_int = 0;
    var iy0: c_int = 0;
    var ix1: c_int = 0;
    var iy1: c_int = 0;
    stb.stbtt_GetCodepointBitmapBox(&font.info, cp, font.scale, font.scale, &ix0, &iy0, &ix1, &iy1);
    self.rasterize(&font.info, font.scale, cp, origin, box_w, @max(0, ix0), @max(0, self.baseline + iy0), ix1 - ix0, iy1 - iy0);
}

/// Draw a fallback-chain glyph scaled so its em square fits the box, centred
/// horizontally on its advance and vertically on the font's CJK ink.
fn drawCentred(self: *GlyphCache, font: *const FallbackFonts.Font, cp: u21, origin: usize, box_w: u32, wide: bool) void {
    const ch_f: f32 = @floatFromInt(self.cell_h);
    const box_f: f32 = @floatFromInt(box_w);
    var advance: c_int = 0;
    var bearing: c_int = 0;
    stb.stbtt_GetCodepointHMetrics(&font.info, cp, &advance, &bearing);
    const advance_f: f32 = @floatFromInt(advance);

    // A wide glyph gets an em of two cells (or the cell height, if smaller).
    // A narrow one keeps that size when it fits one cell, as half-width forms
    // do, and is shrunk to the cell otherwise.
    const em_px: f32 = @floatFromInt(@min(2 * self.cell_w, self.cell_h));
    var scale = em_px * font.em_scale;
    if (!wide and advance_f * scale > box_f) scale = box_f / advance_f;

    var ix0: c_int = 0;
    var iy0: c_int = 0;
    var ix1: c_int = 0;
    var iy1: c_int = 0;
    stb.stbtt_GetCodepointBitmapBox(&font.info, cp, scale, scale, &ix0, &iy0, &ix1, &iy1);
    const w = ix1 - ix0;
    const h = iy1 - iy0;

    const pad: i32 = @intFromFloat(@round((box_f - advance_f * scale) / 2));
    const base: i32 = @intFromFloat(@round(ch_f / 2 + font.ink_mid * scale));
    const x = std.math.clamp(pad + ix0, 0, @max(0, @as(i32, @intCast(box_w)) - w));
    const y = std.math.clamp(base + iy0, 0, @max(0, @as(i32, @intCast(self.cell_h)) - h));
    self.rasterize(&font.info, scale, cp, origin, box_w, x, y, w, h);
}

/// Rasterize `cp` with its bitmap's top-left corner at (`x`, `y`) inside the
/// box, clipping whatever falls outside it.
fn rasterize(self: *GlyphCache, info: *const stb.stbtt_fontinfo, scale: f32, cp: u21, origin: usize, box_w: u32, x: i32, y: i32, w: i32, h: i32) void {
    if (w <= 0 or h <= 0) return; // blank glyph, such as a space
    const bw: i32 = @intCast(box_w);
    const bh: i32 = @intCast(self.cell_h);
    if (x >= bw or y >= bh) return;
    const out_w = @min(w, bw - x);
    const out_h = @min(h, bh - y);
    const dst = origin + @as(usize, @intCast(y)) * self.atlas_w + @as(usize, @intCast(x));
    stb.stbtt_MakeCodepointBitmap(info, self.pixels.ptr + dst, out_w, out_h, @intCast(self.atlas_w), scale, scale, cp);
}

/// No font has the codepoint: draw a hollow box, so the cell visibly holds a
/// character instead of looking empty.
fn drawPlaceholder(self: *GlyphCache, origin: usize, box_w: u32) void {
    const ch = self.cell_h;
    if (box_w < 4 or ch < 6) return;
    const left: usize = 1;
    const right: usize = box_w - 2;
    const top: usize = 2;
    const bottom: usize = ch - 3;
    for (top..bottom + 1) |y| {
        const row = self.pixels[origin + y * self.atlas_w ..][0..box_w];
        if (y == top or y == bottom) {
            @memset(row[left .. right + 1], 0xFF);
        } else {
            row[left] = 0xFF;
            row[right] = 0xFF;
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

/// A cache with no fonts over `buf`, laid out like a real atlas: 16 slots per
/// row, `static_rows` fixed rows, then the reserved rows.
var test_table: [table_len]u32 = undefined;

fn testCache(buf: []u8, cw: u32, ch: u32, static_rows: u32, pairs: u32) GlyphCache {
    @memset(buf, 0);
    @memset(&test_table, empty);
    return .{
        .table = &test_table,
        .pixels = buf,
        .atlas_w = 16 * cw,
        .cell_w = cw,
        .cell_h = ch,
        .first_slot = static_rows * 16,
        .capacity = pairs,
    };
}

fn inkIn(cache: *const GlyphCache, slot: u32) usize {
    const origin = cache.originOf(slot);
    var n: usize = 0;
    for (0..cache.cell_h) |y| {
        for (cache.pixels[origin + y * cache.atlas_w ..][0..cache.cell_w]) |a| n += @intFromBool(a != 0);
    }
    return n;
}

test "pairsFor fills whole rows and respects the byte budget" {
    try testing.expectEqual(@as(u32, 2048), pairsFor(8, 16, max_pairs));
    try testing.expectEqual(@as(u32, 256), pairsFor(8, 16, 256));
    // 32x64 cells: 4096 bytes a pair, so the 4 MiB budget allows 1024.
    try testing.expectEqual(@as(u32, 1024), pairsFor(32, 64, max_pairs));
    try testing.expectEqual(@as(u32, 0), pairsFor(0, 16, max_pairs));
    try testing.expectEqual(@as(u32, 0), pairsFor(8, 16, 100) % 8);
}

test "a disabled cache resolves nothing" {
    var cache: GlyphCache = .{};
    try testing.expect(cache.resolve(0xD55C, true) == null);
}

test "a miss with no fonts draws a placeholder; a hit returns the same slot" {
    const cw = 8;
    const ch = 16;
    var buf: [16 * cw * 3 * ch]u8 = undefined; // 1 fixed row + 2 reserved
    var cache = testCache(&buf, cw, ch, 1, 16);

    const wide = cache.resolve(0xD55C, true).?;
    try testing.expectEqual(@as(u32, 16), wide);
    try testing.expect(inkIn(&cache, wide) > 0);
    try testing.expect(inkIn(&cache, wide + 1) > 0);
    try testing.expectEqual(wide, cache.resolve(0xD55C, true).?);
    try testing.expectEqual(@as(u32, 1), cache.count);

    // A narrow codepoint takes the next pair and inks only its left slot.
    const narrow = cache.resolve(0x03B1, false).?;
    try testing.expectEqual(@as(u32, 18), narrow);
    try testing.expect(inkIn(&cache, narrow) > 0);
    try testing.expectEqual(@as(usize, 0), inkIn(&cache, narrow + 1));

    // Nothing was written into the fixed row.
    for (buf[0 .. 16 * cw * ch]) |a| try testing.expectEqual(@as(u8, 0), a);
}

test "invisible codepoints get an empty slot, not a placeholder" {
    const cw = 8;
    const ch = 16;
    var buf: [16 * cw * 2 * ch]u8 = undefined;
    var cache = testCache(&buf, cw, ch, 1, 8);
    for ([_]u21{ 0x7F, 0x85, 0xFEFF, 0xE0041, 0xE0100 }) |cp| {
        const slot = cache.resolve(cp, false).?;
        try testing.expectEqual(@as(usize, 0), inkIn(&cache, slot));
        try testing.expectEqual(@as(usize, 0), inkIn(&cache, slot + 1));
    }
}

test "a full cache empties itself and keeps working" {
    const cw = 4;
    const ch = 8;
    var buf: [16 * cw * 2 * ch]u8 = undefined; // 1 fixed row + 1 reserved = 8 pairs
    var cache = testCache(&buf, cw, ch, 1, 8);

    for (0..8) |i| _ = cache.resolve(@intCast(0x4E00 + i), true).?;
    try testing.expectEqual(@as(u32, 8), cache.count);
    const first = cache.resolve(0x4E00, true).?;
    try testing.expectEqual(@as(u32, 16), first);
    try testing.expectEqual(@as(u32, 8), cache.count); // still a hit

    // The ninth distinct codepoint empties the cache and takes pair 0.
    const ninth = cache.resolve(0x4E08, true).?;
    try testing.expectEqual(@as(u32, 16), ninth);
    try testing.expectEqual(@as(u32, 1), cache.count);
    // An evicted codepoint is rasterized again into the next pair.
    try testing.expectEqual(@as(u32, 18), cache.resolve(0x4E00, true).?);
    try testing.expect(inkIn(&cache, 18) > 0);
}

test "insertRaw stores coverage that resolve then finds" {
    const cw = 4;
    const ch = 8;
    var buf: [16 * cw * 2 * ch]u8 = undefined;
    var cache = testCache(&buf, cw, ch, 1, 8);

    var alpha: [2 * cw * ch]u8 = @splat(0);
    alpha[0] = 0x11; // top-left of the left half
    alpha[2 * cw * ch - 1] = 0x22; // bottom-right of the right half
    const slot = cache.insertRaw(0xD55C, &alpha).?;
    try testing.expectEqual(slot, cache.resolve(0xD55C, true).?);

    const origin = cache.originOf(slot);
    try testing.expectEqual(@as(u8, 0x11), buf[origin]);
    try testing.expectEqual(@as(u8, 0x22), buf[origin + (ch - 1) * cache.atlas_w + 2 * cw - 1]);
}
