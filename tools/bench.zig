//! teru / teruwm benchmark harness.
//!
//! Drives teru's VT pipeline with pre-captured vtebench payloads and
//! reports apples-to-apples throughput plus frame timing for the
//! SoftwareRenderer. Produces JSON on stdout for downstream tooling.
//!
//! What each number means, and what it does NOT mean, is spelled out
//! in docs/BENCHMARKS.md — read before quoting any of this in a blog
//! post. Short version: these numbers measure teru's *internal* VT
//! processing speed, not end-to-end keypress-to-photon latency. We
//! deliberately do not publish a latency number because a software-only
//! latency measurement (no phototransistor) is more misleading than
//! useful.
//!
//! Usage:
//!   zig build bench              # runs the full suite
//!   tools/bench <payload.bin>    # runs one payload, prints JSON

const std = @import("std");
const posix = std.posix;
const teru = @import("teru");

const VtParser = teru.VtParser;
const Grid = teru.Grid;
const SoftwareRenderer = teru.render.SoftwareRenderer;

// Simple stdout / stderr writers for Zig 0.16 (std.io was removed).
fn out(msg: []const u8) void {
    _ = std.c.write(posix.STDOUT_FILENO, msg.ptr, msg.len);
}
fn err(msg: []const u8) void {
    _ = std.c.write(posix.STDERR_FILENO, msg.ptr, msg.len);
}
fn outf(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    out(s);
}

const COLS: u16 = 200;
const ROWS: u16 = 50;
const CELL_W: u32 = 8;
const CELL_H: u32 = 16;

/// One benchmark result. Emitted as a JSON object; consumers in docs/
/// BENCHMARKS.md concatenate these into an array.
const Result = struct {
    name: []const u8,
    bytes: usize,
    // Parse-only pass: VtParser → Grid, no rendering. Isolates VT parsing.
    parse_ns_p50: u64,
    parse_ns_p95: u64,
    parse_ns_p99: u64,
    parse_mb_s: f64,
    // Full pipeline: VtParser → Grid → SoftwareRenderer.renderDirty (dirty-row path).
    render_ns_p50: u64,
    render_ns_p95: u64,
    render_ns_p99: u64,
    render_mb_s: f64,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args_iter.deinit();
    _ = args_iter.next(); // argv[0]
    const payload_dir_path = args_iter.next() orelse {
        err("usage: teru-bench <payload-dir>\n");
        std.process.exit(2);
    };

    const io = init.io;
    var dir = std.Io.Dir.cwd().openDir(io, payload_dir_path, .{ .iterate = true }) catch |e| {
        outf("cannot open {s}: {s}\n", .{ payload_dir_path, @errorName(e) });
        std.process.exit(1);
    };
    defer dir.close(io);

    out("[\n");
    var first = true;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;

        const file = try dir.openFile(io, entry.name, .{});
        const stat = try file.stat(io);
        const payload = try alloc.alloc(u8, @intCast(stat.size));
        defer alloc.free(payload);
        _ = try file.readPositionalAll(io, payload, 0);
        file.close(io);

        // Skip tiny / empty payloads — they're artifacts of benchmarks
        // whose scripts are just "printf 'y\n'" (loop-expanded by vtebench's
        // harness; we don't have the harness here).
        if (payload.len < 4096) continue;

        const bench_name = entry.name[0 .. entry.name.len - 4]; // strip ".bin"
        const res = try runBench(alloc, bench_name, payload);

        if (!first) out(",\n");
        first = false;
        emitJson(res);
    }
    out("\n]\n");
}

/// Run one benchmark: parse-only N times, full-render N times.
fn runBench(alloc: std.mem.Allocator, name: []const u8, payload: []const u8) !Result {
    const iters: u32 = 30;

    // ── Parse-only pass ──
    var parse_samples = try alloc.alloc(u64, iters);
    defer alloc.free(parse_samples);
    {
        // Warmup
        var grid = try Grid.init(alloc, ROWS, COLS);
        defer grid.deinit(alloc);
        var parser = VtParser.init(alloc, &grid);
        _ = &parser;
        parser.feed(payload);
    }
    for (0..iters) |i| {
        var grid = try Grid.init(alloc, ROWS, COLS);
        defer grid.deinit(alloc);
        var parser = VtParser.init(alloc, &grid);
        _ = &parser;
        const t0 = teru.compat.monotonicNow();
        parser.feed(payload);
        const t1 = teru.compat.monotonicNow();
        parse_samples[i] = @intCast(t1 - t0);
    }

    // ── Full-pipeline pass (parse + render) ──
    var render_samples = try alloc.alloc(u64, iters);
    defer alloc.free(render_samples);
    const fb_w: u32 = @as(u32, COLS) * CELL_W;
    const fb_h: u32 = @as(u32, ROWS) * CELL_H;
    for (0..iters) |i| {
        var grid = try Grid.init(alloc, ROWS, COLS);
        defer grid.deinit(alloc);
        var parser = VtParser.init(alloc, &grid);
        _ = &parser;

        var renderer = try SoftwareRenderer.init(alloc, fb_w, fb_h, CELL_W, CELL_H);
        renderer.padding = 0;
        defer renderer.deinit();

        const t0 = teru.compat.monotonicNow();
        parser.feed(payload);
        renderer.renderDirty(&grid);
        const t1 = teru.compat.monotonicNow();
        render_samples[i] = @intCast(t1 - t0);
    }

    return .{
        .name = try alloc.dupe(u8, name),
        .bytes = payload.len,
        .parse_ns_p50 = percentile(parse_samples, 50),
        .parse_ns_p95 = percentile(parse_samples, 95),
        .parse_ns_p99 = percentile(parse_samples, 99),
        .parse_mb_s = mbPerSec(payload.len, percentile(parse_samples, 50)),
        .render_ns_p50 = percentile(render_samples, 50),
        .render_ns_p95 = percentile(render_samples, 95),
        .render_ns_p99 = percentile(render_samples, 99),
        .render_mb_s = mbPerSec(payload.len, percentile(render_samples, 50)),
    };
}

fn percentile(samples: []u64, p: u8) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const idx = (samples.len - 1) * @as(usize, p) / 100;
    return samples[idx];
}

fn mbPerSec(bytes: usize, ns: u64) f64 {
    if (ns == 0) return 0;
    const seconds = @as(f64, @floatFromInt(ns)) / 1e9;
    const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    return mb / seconds;
}

fn emitJson(r: Result) void {
    outf(
        \\  {{"name":"{s}","bytes":{d},
        \\   "parse_ns":{{"p50":{d},"p95":{d},"p99":{d}}},"parse_mb_s":{d:.1},
        \\   "render_ns":{{"p50":{d},"p95":{d},"p99":{d}}},"render_mb_s":{d:.1}}}
    , .{
        r.name,             r.bytes,
        r.parse_ns_p50,     r.parse_ns_p95, r.parse_ns_p99,
        r.parse_mb_s,
        r.render_ns_p50,    r.render_ns_p95, r.render_ns_p99,
        r.render_mb_s,
    });
}
