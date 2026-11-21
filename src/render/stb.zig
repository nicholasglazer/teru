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
