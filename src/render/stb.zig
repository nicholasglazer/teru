//! stb_truetype C bindings, declared by hand (the project does not use
//! `@cImport`). The implementation is compiled from vendor/stb_truetype.c.

/// Opaque storage for an `stbtt_fontinfo`. The real struct is about 160
/// bytes; vendor/stb_truetype.c carries a `_Static_assert` guarding this cap.
/// It holds pointers into the font bytes it was initialised from, so those
/// bytes must outlive it.
pub const stbtt_fontinfo = extern struct {
    _storage: [256]u8 align(8) = undefined,
};

pub extern fn stbtt_InitFont(info: *stbtt_fontinfo, data: [*]const u8, offset: c_int) callconv(.c) c_int;
/// Byte offset of face `index` in a font file: 0 for a plain .ttf/.otf, the
/// face's table directory for a .ttc collection, -1 when there is no such face.
pub extern fn stbtt_GetFontOffsetForIndex(data: [*]const u8, index: c_int) callconv(.c) c_int;
/// Initialise `info` for the first face in `data`. A collection (.ttc, such
/// as macOS's Menlo.ttc) starts with a `ttcf` header, not a font, so the
/// face's offset has to be looked up; passing 0 makes stb fail on it.
pub fn initFirstFace(info: *stbtt_fontinfo, data: []const u8) bool {
    // stb reads the 4-byte tag and, for a collection, the 12-byte header
    // without knowing the length.
    if (data.len < 16) return false;
    const offset = stbtt_GetFontOffsetForIndex(data.ptr, 0);
    if (offset < 0) return false;
    return stbtt_InitFont(info, data.ptr, offset) != 0;
}

pub extern fn stbtt_FindGlyphIndex(info: *const stbtt_fontinfo, codepoint: c_int) callconv(.c) c_int;
pub extern fn stbtt_ScaleForPixelHeight(info: *const stbtt_fontinfo, pixel_height: f32) callconv(.c) f32;
/// Scale at which the font's em square is `pixels` tall.
pub extern fn stbtt_ScaleForMappingEmToPixels(info: *const stbtt_fontinfo, pixels: f32) callconv(.c) f32;
pub extern fn stbtt_GetFontVMetrics(info: *const stbtt_fontinfo, ascent: *c_int, descent: *c_int, line_gap: *c_int) callconv(.c) void;
pub extern fn stbtt_GetCodepointHMetrics(info: *const stbtt_fontinfo, cp: c_int, advance_width: *c_int, left_side_bearing: *c_int) callconv(.c) void;
/// Glyph bounding box in unscaled font units, y up. Returns 0 for an empty glyph.
pub extern fn stbtt_GetCodepointBox(info: *const stbtt_fontinfo, cp: c_int, x0: *c_int, y0: *c_int, x1: *c_int, y1: *c_int) callconv(.c) c_int;
pub extern fn stbtt_GetCodepointBitmapBox(info: *const stbtt_fontinfo, cp: c_int, scale_x: f32, scale_y: f32, ix0: *c_int, iy0: *c_int, ix1: *c_int, iy1: *c_int) callconv(.c) void;
pub extern fn stbtt_MakeCodepointBitmap(info: *const stbtt_fontinfo, output: [*]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, codepoint: c_int) callconv(.c) void;

/// Allocations stb made with libc `malloc` because its scratch arena was full
/// (see vendor/stb_truetype.c). Stays 0 while the arena is large enough.
pub extern var teru_stbtt_fallback_allocs: c_uint;

const std = @import("std");

test "initFirstFace: rejects data that is not a font" {
    var info: stbtt_fontinfo = .{};
    try std.testing.expect(!initFirstFace(&info, ""));
    try std.testing.expect(!initFirstFace(&info, "ttcf"));
    try std.testing.expect(!initFirstFace(&info, "this is not a font file at all"));
}

test "initFirstFace: reads the first face of a .ttc collection" {
    // macOS ships its terminal fonts (Menlo, and the CJK fallbacks) as
    // collections. Wrap a host .ttf in a one-face collection: a 16-byte
    // `ttcf` header, then the font with each table offset moved by 16,
    // since collection offsets count from the start of the file.
    const candidates = [_][]const u8{
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
        "/System/Library/Fonts/Monaco.ttf",
    };
    const gpa = std.testing.allocator;
    const ttf = for (candidates) |path| {
        break std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(64 << 20)) catch continue;
    } else return error.SkipZigTest;
    defer gpa.free(ttf);

    var plain: stbtt_fontinfo = .{};
    try std.testing.expect(initFirstFace(&plain, ttf));

    const header_len = 16;
    const ttc = try gpa.alloc(u8, header_len + ttf.len);
    defer gpa.free(ttc);
    @memcpy(ttc[0..4], "ttcf");
    std.mem.writeInt(u32, ttc[4..8], 0x0001_0000, .big);
    std.mem.writeInt(u32, ttc[8..12], 1, .big);
    std.mem.writeInt(u32, ttc[12..16], header_len, .big);
    @memcpy(ttc[header_len..], ttf);
    const face = ttc[header_len..];
    const num_tables = std.mem.readInt(u16, face[4..6], .big);
    for (0..num_tables) |i| {
        const off_field = face[12 + i * 16 + 8 ..][0..4];
        std.mem.writeInt(u32, off_field, std.mem.readInt(u32, off_field, .big) + header_len, .big);
    }

    // Offset 0 is the collection header, which is what broke Menlo.ttc.
    var at_zero: stbtt_fontinfo = .{};
    try std.testing.expectEqual(@as(c_int, 0), stbtt_InitFont(&at_zero, ttc.ptr, 0));

    var info: stbtt_fontinfo = .{};
    try std.testing.expect(initFirstFace(&info, ttc));
    try std.testing.expect(stbtt_FindGlyphIndex(&info, 'A') != 0);
}
