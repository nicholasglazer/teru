//! Minimal PNG encoder for ARGB framebuffer screenshots.
//!
//! Writes valid PNG files using stored (uncompressed) deflate blocks.
//! No external dependencies — uses std CRC32 and Adler-32 only.
//! Typical output: ~6MB for 1920x1080 (uncompressed RGB scanlines).

const std = @import("std");
const Allocator = std.mem.Allocator;

const signature = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

pub const Error = error{ FileOpenFailed, OutOfMemory };

/// Write an ARGB framebuffer as a PNG file.
/// Pixel format: 0xAARRGGBB (alpha ignored, written as RGB).
pub fn write(
    allocator: Allocator,
    path: [*:0]const u8,
    pixels: []const u32,
    width: u32,
    height: u32,
) Error!void {
    const file = fopen(path, "wb") orelse return error.FileOpenFailed;
    defer _ = fclose(file);

    const row_size: usize = 1 + @as(usize, width) * 3;
    const row_buf = allocator.alloc(u8, row_size) catch return error.OutOfMemory;
    defer allocator.free(row_buf);

    // PNG signature
    fileWrite(file, &signature);

    // IHDR chunk (13 bytes: width, height, bit depth, color type, etc.)
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // color type: RGB
    ihdr[10] = 0; // compression: deflate
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // interlace: none
    writeChunk(file, "IHDR", &ihdr);

    // IDAT chunk (zlib header + stored deflate blocks + adler-32)
    writeIdat(file, pixels, width, height, row_buf);

    // IEND chunk
    writeChunk(file, "IEND", &.{});
}

fn writeChunk(file: *anyopaque, chunk_type: *const [4]u8, data: []const u8) void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    fileWrite(file, &len_buf);
    fileWrite(file, chunk_type);

    var crc = std.hash.crc.Crc32.init();
    crc.update(chunk_type);
    if (data.len > 0) {
        fileWrite(file, data);
        crc.update(data);
    }

    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    fileWrite(file, &crc_buf);
}

fn writeIdat(file: *anyopaque, pixels: []const u32, width: u32, height: u32, row_buf: []u8) void {
    const row_size: usize = 1 + @as(usize, width) * 3;
    const h: usize = height;

    // IDAT data = zlib header (2) + stored blocks (5 + row_size) * h + adler-32 (4)
    const idat_len: u32 = @intCast(2 + (5 + row_size) * h + 4);

    // Chunk header: length + "IDAT"
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, idat_len, .big);
    fileWrite(file, &len_buf);

    const idat_tag = "IDAT";
    fileWrite(file, idat_tag);

    var crc = std.hash.crc.Crc32.init();
    crc.update(idat_tag);

    // Zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (level 0, checksum ok)
    const zlib_hdr = [_]u8{ 0x78, 0x01 };
    fileWrite(file, &zlib_hdr);
    crc.update(&zlib_hdr);

    var adler = std.hash.Adler32{};

    // One stored deflate block per scanline row
    for (0..h) |y| {
        const is_last: u8 = if (y == h - 1) 0x01 else 0x00;
        const len: u16 = @intCast(row_size);
        const nlen: u16 = ~len;

        var block_hdr: [5]u8 = undefined;
        block_hdr[0] = is_last;
        std.mem.writeInt(u16, block_hdr[1..3], len, .little);
        std.mem.writeInt(u16, block_hdr[3..5], nlen, .little);
        fileWrite(file, &block_hdr);
        crc.update(&block_hdr);

        // Build row: filter=0 (None) + ARGB→RGB conversion
        row_buf[0] = 0;
        const row_start = y * @as(usize, width);
        const row_pixels = pixels[row_start..][0..width];
        for (row_pixels, 0..) |px, i| {
            row_buf[1 + i * 3 + 0] = @intCast((px >> 16) & 0xFF); // R
            row_buf[1 + i * 3 + 1] = @intCast((px >> 8) & 0xFF); // G
            row_buf[1 + i * 3 + 2] = @intCast(px & 0xFF); // B
        }

        fileWrite(file, row_buf[0..row_size]);
        crc.update(row_buf[0..row_size]);
        adler.update(row_buf[0..row_size]);
    }

    // Adler-32 (big-endian per zlib RFC 1950)
    var adler_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler_buf, adler.adler, .big);
    fileWrite(file, &adler_buf);
    crc.update(&adler_buf);

    // Chunk CRC
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    fileWrite(file, &crc_buf);
}

fn fileWrite(file: *anyopaque, data: []const u8) void {
    _ = fwrite(data.ptr, 1, data.len, file);
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, count: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;

// ── Tests ─────────────────────────────────────────────────────────

test "PNG: write minimal 2x2 image" {
    const allocator = std.testing.allocator;

    // 2x2 red/green/blue/white
    const pixels = [_]u32{
        0xFFFF0000, 0xFF00FF00, // red, green
        0xFF0000FF, 0xFFFFFFFF, // blue, white
    };

    const path = "/tmp/teru-test-screenshot.png";
    try write(allocator, path, &pixels, 2, 2);

    // Verify file starts with PNG signature
    const file = fopen(path, "rb") orelse return error.FileOpenFailed;
    defer _ = fclose(file);
    var header: [8]u8 = undefined;
    _ = fread(&header, 1, 8, file);
    try std.testing.expectEqualSlices(u8, &signature, &header);
}

test "PNG: write 80x24 terminal-sized image" {
    const allocator = std.testing.allocator;

    // Simulated terminal: dark background with some "text" pixels
    const w: u32 = 80;
    const h: u32 = 24;
    var pixels: [w * h]u32 = undefined;
    for (&pixels) |*p| p.* = 0xFF1A1B26; // dark bg

    // Write a few bright pixels (simulating text)
    pixels[0] = 0xFFC0CAF5;
    pixels[w + 1] = 0xFF7AA2F7;

    const path = "/tmp/teru-test-terminal.png";
    try write(allocator, path, &pixels, w, h);

    // Verify file exists and has reasonable size
    // 80x24 RGB uncompressed = ~5.8KB + overhead
    const file = fopen(path, "rb") orelse return error.FileOpenFailed;
    defer _ = fclose(file);
    _ = fseek(file, 0, 2); // SEEK_END
    const size = ftell(file);
    try std.testing.expect(size > 100); // at least headers
    try std.testing.expect(size < 100000); // not absurdly large
}

extern "c" fn fread(ptr: [*]u8, size: usize, count: usize, stream: *anyopaque) usize;
extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *anyopaque) c_long;
