# Zig Terminal Development Rules (CRITICAL)

Rules for developing teru, the AI-first terminal emulator in Zig 0.17.0-dev.135+.

## Zig 0.17 API (MUST KNOW)

### std.process.Init signature
```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
}
```
`main()` does NOT accept `[]const u8` args. Use `init.minimal.args` iterator.

### std.Io threading
Every function that does file/network/timer I/O MUST accept `io: std.Io`. Thread it from main through every call chain.

- File open: `Io.Dir.cwd().openFile(io, path, .{})` -- NOT raw openat
- File read: `file.readPositionalAll(io, buf, 0)` -- NOT linux read()
- File write: `file.writeStreamingAll(io, bytes)` -- NOT std.c.write() for regular files
- File stat: `file.stat(io)` returns `.size: u64`
- File close: `file.close(io)` -- io param required
- Sleep: `io.sleep(.fromMilliseconds(n), .awake)` -- NOT nanosleep
- Access check: `Io.Dir.cwd().access(io, path, .{ .read = true })`
- Tests: use `std.testing.io` to get an Io instance

### Removed from std.posix (use replacements)
| Old | New |
|-----|-----|
| `std.posix.fork()` | `std.os.linux.fork()` (returns usize, check with @bitCast) |
| `std.posix.close()` | `std.posix.system.close()` (returns c_int, assign to _) |
| `std.posix.write()` | `std.c.write()` |
| `std.posix.dup2()` | `std.c.dup2()` |
| `std.posix.pipe2()` | `std.c.pipe()` |
| `std.posix.waitpid()` | `std.c.waitpid()` |
| `std.posix.getenv()` | `std.c.getenv()` (returns `?[*:0]u8`, use `std.mem.sliceTo`) |
| `std.posix.fcntl()` | `std.c.fcntl()` |
| `std.posix.ftruncate()` | `std.c.ftruncate()` |
| `std.posix.exit()` | `std.os.linux.exit()` |
| `std.fs.cwd()` | `Io.Dir.cwd()` (requires io) |

### Other 0.17 changes
- `ArrayListUnmanaged` is a **deprecated alias** for `ArrayList` — write `std.ArrayList(T)` and initialize with `.empty`. The unmanaged distinction was merged.
- PROT flags: `PROT.READ|PROT.WRITE` is now `.{ .READ = true, .WRITE = true }` (packed struct)
- Sigaction handler: `fn(c_int)` is now `fn(posix.SIG)`
- Calling convention: `callconv(.c)` not `.C`
- winsize fields: `.row`, `.col` (no `ws_` prefix)
- termios flags: direct bool fields (`raw.iflag.ICRNL = false`)
- cflag.CSIZE: `.CS8` (not `cflag.CS8`)
- pollfd events/revents: raw `i16`
- Build system: `b.createModule()` + `addExecutable(.{ .root_module = mod })`. `strip` is a `Module.CreateOptions` field; `lto` is set on the Compile step (`exe.lto = .full`).
- `@cImport` still works but hand-declared C externs are preferred

### std.heap (0.17 allocator landscape)

| Old | New |
|-----|-----|
| `std.heap.GeneralPurposeAllocator` | `std.heap.DebugAllocator` (Debug) / `std.heap.smp_allocator` (Release) |
| `std.heap.page_allocator.create(SmallStruct)` | `std.heap.smp_allocator.create(...)` — `page_allocator` does an `mmap` per allocation in 0.17 |

**Always prefer `init.gpa`** from `std.process.Init` — it's already wired to `DebugAllocator` in Debug and `smp_allocator` in Release. Manual `DebugAllocator{}` instantiation is forbidden. Only fall back to `std.heap.smp_allocator` directly in callbacks/global state where `Init` isn't reachable (Win32 WndProc, signal handlers).

### @memset codegen bug

`@memset(slice_u32, runtime_scalar)` used to mis-codegen in Debug builds on x86_64 — the rep-stosd lowering swapped source/dest and faulted at the value's address (present through Zig 0.17.0-dev.304). **FIXED as of 0.17.0-dev.420** (verified: routing `compat.memsetU32` through bare `@memset` runs the full Debug suite — incl. the `Renderer CPU tier init and render` repro in `tier.zig` — clean). `compat.memsetU32(buf, value)` (in `src/compat.zig`) now just calls `@memset`; it's **kept as the single point of control** so all `[]u32` framebuffer fills still route through one place, revertible if the bug ever resurfaces on another arch/version.

### compat.zig (minimal -- only 4 things)
Only these belong in compat.zig (no io needed):
1. `compat.nanoTimestamp()` -- libc clock_gettime(REALTIME) (may route via vDSO)
2. `compat.getenv()` -- libc wrapper
3. `compat.forkExec*()` -- complex fork+dup2+exec for PTY/clipboard
4. `compat.MemWriter/MemReader/DynWriter` -- in-memory serialization

Everything else: use native std.Io.

## Terminal Emulator Patterns

### VT State Machine
- VtParser is a byte-at-a-time state machine: ground, escape, csi_entry, csi_param, csi_intermediate, osc_string, dcs_entry, dcs_passthrough
- Every state transition must be exhaustive -- no default catch-all that silently drops bytes
- CSI params are collected into a fixed-size array (max 16 params). Overflow silently stops collecting, does NOT crash
- OSC strings are collected into a bounded buffer. Overflow truncates, does NOT crash
- The parser drives a Grid -- it never allocates, never does I/O. Pure computation

### Cell Grid Invariants
- Grid is a flat `[]Cell` array, `rows * cols` elements
- Cursor position is ALWAYS `0 <= cursor_row < rows` and `0 <= cursor_col < cols`
- After any cursor movement, clamp to bounds. NEVER assert on cursor position from external input
- Scroll region: `scroll_top <= cursor_row <= scroll_bottom`. Default: full screen
- Alt screen is a separate Grid instance. `ESC[?1049h` swaps, `ESC[?1049l` restores
- Cell char is `u21` (Unicode codepoint). Default: space (0x20)

### PTY Lifecycle
1. `posix_openpt()` or `/dev/ptmx` open -> get master fd
2. `grantpt()` + `unlockpt()` + `ptsname()` -> get slave path
3. `fork()` -> child: `setsid()`, open slave, `dup2()` to stdin/stdout/stderr, `execve(shell)`
4. Parent: read master fd in event loop, write user input to master fd
5. Resize: `TIOCSWINSZ` ioctl on master fd
6. Child exit: `SIGCHLD` or `waitpid()` -> clean up pane

## Performance Rules

### Render Loop (<50us target)
- The SIMD renderer MUST complete a full frame in under 50 microseconds for a 200x50 grid
- ZERO allocations in the render hot path. All buffers pre-allocated at init or resize
- Use `@Vector(4, u32)` for 4-pixel-at-a-time ARGB blitting
- Font atlas lookup is O(1) by codepoint index. No hash maps in render
- No branching per-pixel in the SIMD path. Use select/masks instead
- Dirty tracking: only re-render cells that changed since last frame

### No GPU
teru is a CPU-only renderer. No OpenGL, no Vulkan, no Metal, no GPU compute.
Platform layer handles display (X11 SHM, Wayland SHM). The renderer produces a raw ARGB pixel buffer.

### Memory
- Pre-allocate all grid/scrollback buffers at startup or resize
- Scrollback uses keyframe+delta compression. Never store full grid copies per line
- Session serialization uses compat.MemWriter (stack buffer, no heap)

## Testing Rules

### Inline Tests
Every `.zig` module MUST have inline `test` blocks. No separate test files.

```zig
test "VtParser: CSI cursor movement" {
    var grid = Grid.init(std.testing.allocator, 80, 24);
    defer grid.deinit(std.testing.allocator);
    var parser = VtParser.init(&grid);
    parser.feed("\x1b[5;10H"); // move to row 5, col 10
    try std.testing.expectEqual(@as(u16, 4), grid.cursor_row); // 0-indexed
    try std.testing.expectEqual(@as(u16, 9), grid.cursor_col);
}
```

### Leak Detection
Always use `std.testing.allocator` in tests. It catches leaks and double-frees automatically. For tests needing io, use `std.testing.io`.

### Build and Run Tests
```bash
zig build test       # run all inline tests
zig build test 2>&1 | head -50  # check for failures
```

## Dependencies

### System libraries (linked via build.zig)
- `xcb` + `xcb-shm` -- X11 display (optional, `-Dx11=false` to skip)
- `xkbcommon` -- keyboard translation on Linux
- `wayland-client` -- Wayland display (optional, `-Dwayland=false` to skip)

### Vendored (in-tree, no downloads)
- `stb_truetype.h` -- font rasterization (single-header C library)
- `xdg-shell-protocol.h` -- Wayland xdg-shell protocol (generated, checked in)

### NO new dependencies without discussion
This project has ZERO Zig package dependencies (no build.zig.zon deps). Any new dependency -- system lib, vendored C, or Zig package -- requires explicit approval. The answer is almost always "implement it yourself" or "use what's in std".

## Version Bumping

Single source of truth: `build.zig` line 10 (`const version = "X.Y.Z"`).
Propagated to `main.zig` and `McpServer.zig` via `build_options.version` at compile time.

Bump with: `make bump-version V=x.y.z` (updates `build.zig` + `build.zig.zon`).

Convention: `0.1.x` = patch (small features/fixes), `0.x.0` = minor (major features).

## Build Commands

```bash
# Development
zig build              # debug build (4MB, safety + debug symbols)
zig build test         # run all 194+ inline tests
zig build run          # windowed mode (X11 or Wayland)
zig build run -- --raw # TTY/raw mode (no window)

# Release
make release           # ReleaseSafe + strip (1.3MB)
make release-small     # ReleaseSmall + strip (~800KB)
make release-x11       # X11-only (no wayland-client dep)
make release-wayland   # Wayland-only (no libxcb dep)

# Info
make deps              # check runtime dependencies
make size              # show binary size for all profiles
make help              # list all make targets

# Install
make install           # install to /usr/local/bin
make install PREFIX=/usr  # custom prefix
```

## Anti-Patterns

1. **DON'T use compat.* for file I/O** -- use `Io.Dir.cwd().openFile(io, ...)`
2. **DON'T use linux.nanosleep** -- use `io.sleep(duration, clock)`
3. **DON'T use std.c.socket/bind/listen** -- use `Io.net.*`
4. **NEVER manually instantiate `DebugAllocator`** -- use `init.gpa` from process Init (it's already DebugAllocator in Debug, smp_allocator in Release)
5. **DON'T use std.process.argsAlloc** -- use `init.minimal.args` iterator
6. **DON'T add `catch {}` silently** -- propagate errors or log with meaningful message
7. **DON'T allocate in render loop** -- pre-allocate everything
8. **DON'T use GPU APIs** -- CPU SIMD only
9. **DON'T add external Zig packages** -- use std or implement it
10. **DON'T use `@cImport` for new C bindings** -- hand-declare externs
11. **`compat.MemWriter`/`MemReader`/`DynWriter` are the binary-serialization codepath** for the session / scrollback formats. As of 0.17.0-dev.420 native `std.Io.Writer`/`Reader` DO expose `writeInt`/`takeInt` and `.fixed`/`.Allocating` (so the "native lacks the API" rationale is outdated) — they're retained as one stable format codepath, not migrated to avoid churning the on-disk binary format. For text or streaming output, use native `std.Io.Writer.fixed(buf)` / `std.Io.Writer.Allocating.init(gpa)`.
12. **DON'T use `std.heap.page_allocator` for small allocs** -- it's one mmap per allocation in 0.17. Use `init.gpa` or `std.heap.smp_allocator`.
13. **Route `[]u32` framebuffer fills through `compat.memsetU32`** -- the codegen bug that required a hand loop is fixed on 0.17.0-dev.420 (the helper now just calls `@memset`), but keep using the helper as the single revert point.
