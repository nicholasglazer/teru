//! Fonts for codepoints that neither the main font nor the symbol fallback
//! has: Hangul, kana, Han ideographs, fullwidth forms. A monospace coding
//! font covers none of these, and the fixed atlas has no slots for them, so
//! `GlyphCache` rasterizes them on first use from the fonts found here.
//!
//! The chain is process-wide. Font files are memory-mapped read-only and never
//! unmapped: they are megabytes each, every `FontAtlas` (one per zoom level,
//! one per zoomed pane) reads the same bytes, and only the pages of glyphs
//! actually drawn are ever touched.
//!
//! Like the rest of font discovery there is no fontconfig: fixed, well-known
//! paths, first match per codepoint wins. The order decides which regional
//! shape a unified Han ideograph gets.

const std = @import("std");
const builtin = @import("builtin");
const stb = @import("stb.zig");
const Io = std.Io;

pub const Font = struct {
    info: stb.stbtt_fontinfo,
    /// Scale at which this font's em square is one pixel tall.
    em_scale: f32,
    /// Vertical middle of the font's CJK ink, in font units above the
    /// baseline. Glyphs are centred on it instead of sitting on the main
    /// font's baseline, because CJK fonts place their em box differently.
    ink_mid: f32,
};

/// Fonts kept at most. Later paths are not opened once this many are loaded.
pub const max_fonts = 6;

/// Larger files are skipped; the biggest candidates (pan-CJK collections)
/// are around 20 MiB.
const max_font_bytes = 64 * 1024 * 1024;

const paths: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{
        "C:\\Windows\\Fonts\\malgun.ttf", // Malgun Gothic: Hangul
        "C:\\Windows\\Fonts\\msgothic.ttc", // MS Gothic: kana, Han (fixed pitch)
        "C:\\Windows\\Fonts\\YuGothR.ttc", // Yu Gothic
        "C:\\Windows\\Fonts\\msyh.ttc", // Microsoft YaHei: simplified Han
        "C:\\Windows\\Fonts\\msjh.ttc", // Microsoft JhengHei: traditional Han
        "C:\\Windows\\Fonts\\simsun.ttc",
    },
    .macos => &.{
        "/System/Library/Fonts/AppleSDGothicNeo.ttc",
        "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",
        "/System/Library/Fonts/PingFang.ttc",
        "/System/Library/Fonts/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
        "/System/Library/Fonts/Supplemental/AppleGothic.ttf",
    },
    else => &.{
        // Pan-CJK collections (Arch, Debian/Ubuntu, Fedora).
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
        // Hangul.
        "/usr/share/fonts/TTF/IBMPlexSansKR-Regular.ttf",
        "/usr/share/fonts/TTF/NanumGothic.ttf",
        "/usr/share/fonts/truetype/nanum/NanumGothic.ttf",
        // Kana and Han. IPA Gothic first: its fullwidth advance is exactly
        // one em, the best fit for a two-cell box.
        "/usr/share/fonts/OTF/ipag.ttf",
        "/usr/share/fonts/opentype/ipafont-gothic/ipag.ttf",
        "/usr/share/fonts/TTF/IBMPlexSansJP-Regular.ttf",
        "/usr/share/fonts/TTF/IBMPlexSansTC-Regular.ttf",
        "/usr/share/fonts/droid/DroidSansFallbackFull.ttf",
        "/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf",
        "/usr/share/fonts/wenquanyi/wqy-microhei/wqy-microhei.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    },
};

/// Glyphs whose combined bounding box defines a font's `ink_mid`. A font with
/// none of them is not a CJK font and is left out of the chain.
const reference_codepoints = [_]u21{
    0xAC00, 0xD55C, 0xD7A3, 0xAE00, // 가 한 힣 글
    0x4E2D, 0x56FD, 0x9F8D, // 中 国 龍
    0x3042, 0x30A2, // あ ア
    0xFF2D, // Ｍ
};

var fonts: [max_fonts]Font = undefined;
var count: usize = 0;
var probed = false;

/// The loaded fonts, best first. The first call opens and maps the files;
/// call it at startup, not while drawing. Empty when no candidate is
/// installed, in which case uncovered codepoints draw as a placeholder box.
pub fn chain(io: Io) []const Font {
    if (!probed) {
        probed = true;
        for (paths) |path| {
            if (count == max_fonts) break;
            if (load(io, path)) |font| {
                fonts[count] = font;
                count += 1;
            }
        }
    }
    return fonts[0..count];
}

fn load(io: Io, path: []const u8) ?Font {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    const stat = file.stat(io) catch {
        file.close(io);
        return null;
    };
    if (stat.size < 12 or stat.size > max_font_bytes) {
        file.close(io);
        return null;
    }
    const len: usize = @intCast(stat.size);
    var map = file.createMemoryMap(io, .{
        .len = len,
        .protection = .{ .read = true, .write = false },
        .populate = false,
    }) catch {
        file.close(io);
        return null;
    };
    // On success the mapping and the file stay open for the life of the
    // process; `Font.info` points into the mapped bytes.
    if (describe(map.memory[0..len])) |font| return font;
    map.destroy(io);
    file.close(io);
    return null;
}

/// Initialise stb for the first face of `bytes` and measure it. Null when the
/// bytes are not a font stb can read, or the font has no CJK glyphs.
fn describe(bytes: []const u8) ?Font {
    var font: Font = .{ .info = .{}, .em_scale = 0, .ink_mid = 0 };
    const offset = stb.stbtt_GetFontOffsetForIndex(bytes.ptr, 0);
    if (offset < 0) return null;
    if (stb.stbtt_InitFont(&font.info, bytes.ptr, offset) == 0) return null;

    var y_min: c_int = std.math.maxInt(c_int);
    var y_max: c_int = std.math.minInt(c_int);
    for (reference_codepoints) |cp| {
        if (stb.stbtt_FindGlyphIndex(&font.info, cp) == 0) continue;
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        if (stb.stbtt_GetCodepointBox(&font.info, cp, &x0, &y0, &x1, &y1) == 0) continue;
        y_min = @min(y_min, y0);
        y_max = @max(y_max, y1);
    }
    if (y_min > y_max) return null;

    font.em_scale = stb.stbtt_ScaleForMappingEmToPixels(&font.info, 1.0);
    font.ink_mid = (@as(f32, @floatFromInt(y_min)) + @as(f32, @floatFromInt(y_max))) / 2.0;
    return font;
}

test "describe rejects bytes that are not a font" {
    const junk: [64]u8 = @splat(0);
    try std.testing.expect(describe(&junk) == null);
}
