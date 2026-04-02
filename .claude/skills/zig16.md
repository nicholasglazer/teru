---
name: zig16
description: Zig 0.16 API reference — native std.Io patterns, C interop, SIMD, collections, removed APIs, migration guide. Use when writing Zig 0.16 code or debugging compilation errors.
---

# Zig 0.16 API Reference

## std.Io — The Core Pattern

`io: std.Io` is passed from `main(init: std.process.Init)` through the entire codebase. Every I/O operation takes `io` as a parameter.

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    // Pass io to everything that does I/O
}
```

## Process Init

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;           // Io instance
    const allocator = init.gpa;   // GPA (leak-checked in debug)
    const arena = init.arena;     // Process-lifetime arena

    // Args
    var args = init.minimal.args;
    _ = args.next(); // skip argv[0]
    const first_arg = args.next();

    // Environment
    const home = init.environ_map.get("HOME");
}
```

## File I/O (replaces std.fs.cwd)

```zig
const Dir = std.Io.Dir;

// Open/create files
const file = try Dir.cwd().openFile(io, "path/to/file", .{});
defer file.close(io);
const file2 = try Dir.cwd().createFile(io, "path/to/file", .{});

// Read
const stat = try file.stat(io);
var buf = try allocator.alloc(u8, stat.size);
_ = try file.readPositionalAll(io, buf, 0);

// Write
try file.writeStreamingAll(io, data);

// Access check
Dir.cwd().access(io, path, .{ .read = true }) catch { /* not accessible */ };

// Delete
try Dir.cwd().deleteFile(io, path);
```

## Sleep/Timers

```zig
// Sleep (cancelable)
io.sleep(.fromMilliseconds(100), .awake) catch {};

// Timestamp
const now = std.Io.Clock.real.now(io);

// Timeout
const timeout = std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } };
timeout.sleep(io) catch {};
```

## Networking (Unix sockets)

```zig
const addr = try std.Io.net.UnixAddress.init("/run/user/1000/teru.sock");
var server = try addr.listen(io, .{});
defer server.close(io);

// Accept (in event loop)
if (server.accept(io)) |stream| {
    defer stream.close(io);
    var reader = stream.reader(io, &buf);
    // ...
}
```

## Concurrency

```zig
// Async (may run inline or on worker)
var future = io.async(doWork, .{io, arg1});
defer future.cancel(io) catch {};
const result = try future.await(io);

// Batch (submit multiple I/O ops at once — io_uring on Linux)
var batch: std.Io.Batch = .{};
batch.add(.{ .file_read_streaming = .{ .fd = pty1_fd, ... } });
batch.add(.{ .file_read_streaming = .{ .fd = pty2_fd, ... } });
try batch.awaitAsync(io);

// Select (await first of N futures)
var sel = std.Io.Select(enum { pty, window, timer }).init;
// ...
```

## C Interop (No @cImport)

Zig 0.16 in teru declares all C interfaces manually — no `@cImport`.

```zig
// Opaque types for C pointers
const wl_display = opaque {};
const wl_registry = opaque {};

// Function externs with library name and calling convention
extern "wayland-client" fn wl_display_connect(name: ?[*:0]const u8) callconv(.c) ?*wl_display;
extern "wayland-client" fn wl_display_disconnect(display: *wl_display) callconv(.c) void;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// Const externs (C global variables)
extern const wl_registry_interface: wl_interface;

// Listener structs (C callback tables)
const wl_registry_listener = extern struct {
    global: ?*const fn (?*anyopaque, ?*wl_registry, u32, ?[*:0]const u8, u32) callconv(.c) void,
    global_remove: ?*const fn (?*anyopaque, ?*wl_registry, u32) callconv(.c) void,
};
```

Key rules:
- `callconv(.c)` not `.C` (lowercase)
- `?[*:0]const u8` for nullable C strings
- `*anyopaque` for `void*`
- `opaque {}` for forward-declared C structs

## Build Options

```zig
// In build.zig:
const build_options = b.addOptions();
build_options.addOption(bool, "enable_x11", enable_x11);
exe_mod.addOptions("build_options", build_options);

// In source:
const build_options = @import("build_options");

const Keyboard = if (build_options.enable_x11 or build_options.enable_wayland)
    @import("platform/linux/keyboard.zig").Keyboard
else
    void;
```

## SIMD / @Vector

```zig
// Define vector types (4-wide for 128-bit universal support)
const Vec4u32 = @Vector(4, u32);
const Vec4u16 = @Vector(4, u16);
const Vec16 = @Vector(16, u8);

// Splat a scalar to all lanes
const lo: Vec16 = @splat(0x20);

// Load from slice
const chunk: Vec16 = input[i..][0..16].*;

// Store to slice
dst[i..][0..4].* = result;

// Vector arithmetic
const inv_alphas = @as(Vec4u16, @splat(255)) - alphas;
const blended = (fg_vec * alphas + bg_vec * inv_alphas) / @as(Vec4u16, @splat(255));

// Comparison → bitmask
const below = chunk < lo;
const mask: u16 = @bitCast(below);
if (mask != 0) return i + @ctz(mask);

// Bit shifts (vector of shift amounts)
const result = (a32 << @splat(24)) | (r32 << @splat(16)) | (g32 << @splat(8)) | b32;
```

Always provide a scalar fallback after the SIMD loop for the tail bytes.

## Collections (0.16 init syntax)

```zig
// ArrayListUnmanaged — init with .empty (NOT .{})
var panes: std.ArrayListUnmanaged(Pane) = .empty;
try panes.append(allocator, new_pane);
defer panes.deinit(allocator);

// AutoHashMapUnmanaged — same pattern
var nodes: std.AutoHashMapUnmanaged(u64, Node) = .empty;
try nodes.put(allocator, id, node);
defer nodes.deinit(allocator);

// String duplication
const copy = try allocator.dupe(u8, value);
defer allocator.free(copy);
```

## Non-blocking I/O (event loop)

```zig
// Set non-blocking
const flags = std.c.fcntl(fd, posix.F.GETFL, @as(c_int, 0));
_ = std.c.fcntl(fd, posix.F.SETFL, flags | O_NONBLOCK);

// Read with WouldBlock handling
const n = posix.read(fd, buf) catch |err| switch (err) {
    error.WouldBlock => return 0,
    else => return err,
};

// Non-blocking accept
const conn = posix.accept(self.listen_fd, null, null, std.posix.SOCK.NONBLOCK) catch |err| switch (err) {
    error.WouldBlock => return,
    else => return err,
};
```

## What's Removed (use these instead)

| Removed | Replacement |
|---|---|
| std.fs.cwd().* | std.Io.Dir.cwd().* with io param |
| std.io.fixedBufferStream | compat.MemWriter/MemReader or std.Io.Writer.fixed() |
| std.Thread.sleep(ns) | io.sleep(duration, clock) |
| std.posix.fork/close/write/open/getenv/dup2/pipe2/waitpid | std.os.linux.* or std.c.* |
| std.time.nanoTimestamp | Io.Clock.real.now(io) or raw clock_gettime |
| GeneralPurposeAllocator | init.gpa from process Init |
| std.process.argsAlloc | init.minimal.args iterator |
| ArrayListUnmanaged = .{} | .empty |
| @cImport | Hand-declare externs with callconv(.c) |
| .C (calling convention) | .c (lowercase) |
| PROT.READ\|PROT.WRITE | .{ .READ = true, .WRITE = true } (packed struct) |
| Sigaction handler: fn(c_int) | fn(posix.SIG) |
| winsize ws_row/ws_col | .row / .col |
| cflag.CS8 | cflag.CSIZE = .CS8 |

## Terminal Detection

```zig
// Detect terminal capabilities (respects NO_COLOR, CLICOLOR_FORCE)
const term = try Io.Terminal.Mode.detect(io, stdout_file, no_color_env, clicolor_env);
var term_writer: Io.Terminal = .{ .writer = &my_writer, .mode = term };
try term_writer.setColor(.red);
try term_writer.setColor(.reset);
```

## Batch I/O (io_uring on Linux)

```zig
// Submit multiple reads in one syscall (falls back to sequential on non-Linux)
var batch: std.Io.Batch = .{};
batch.add(.{ .file_read_streaming = .{ .fd = pty1_fd, .buffer = buf1 } });
batch.add(.{ .file_read_streaming = .{ .fd = pty2_fd, .buffer = buf2 } });
try batch.awaitAsync(io);
```

## Reader/Writer (zero-copy)

```zig
// Fixed buffer reader — no allocation, ideal for parsing
var reader = Io.Reader.fixed(data[0..n]);
while (!reader.atEnd()) {
    const byte = try reader.readByte();
}

// Fixed buffer writer — stack-allocated output
var writer = Io.Writer.fixed(&buf);
try writer.print("CSI {d};{d}R", .{row, col});
```

## Arena Allocators (per-frame)

```zig
// Allocate scratch memory for a render frame, free all at once
var frame_arena = std.heap.ArenaAllocator.init(gpa);
defer frame_arena.deinit();
const frame = frame_arena.allocator();
const scratch = try frame.alloc(Cell, grid_size);
// All freed when frame_arena.deinit() runs — zero individual frees
```

## Testing with Io

```zig
test "something with io" {
    const io = std.testing.io;  // Test Io instance
    const allocator = std.testing.allocator;  // Leak-checked allocator

    var obj = try SomeType.init(allocator, 24, 80);
    defer obj.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 24), obj.rows);
    try std.testing.expect(obj.is_valid);
}
```
