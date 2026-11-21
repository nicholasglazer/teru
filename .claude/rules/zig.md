---
paths:
  - "**/*.zig"
---
# Zig in this codebase

These are the shapes the code already uses. When unsure of a signature, grep the standard library of the compiler you are running (`zig env` prints `std_dir`) instead of relying on memory.

Entry point and I/O:

- `pub fn main(init: std.process.Init) !void`. Take `init.io`, `init.gpa` and `init.minimal.args` from it.
- Files go through `std.Io.Dir.cwd().openFile(io, path, .{})`, `file.readPositionalAll(io, buf, 0)` and `file.close(io)`. Sleep with `io.sleep`.
- Tests use `std.testing.io` and `std.testing.allocator`, and live as `test` blocks inside the module they cover.

libc and POSIX. Most `std.posix` wrappers no longer exist (`fork`, `close`, `write`, `dup2`, `pipe2`, `waitpid`, `getenv`, `fcntl`, `accept`). The code uses:

| Need | Call |
|---|---|
| close a descriptor | `_ = std.posix.system.close(fd)` |
| write to a descriptor | `std.c.write` |
| fork | `std.os.linux.fork()` |
| dup2, waitpid, fcntl, pipe | `std.c.dup2`, `std.c.waitpid`, `std.c.fcntl`, `std.c.pipe` |
| read an environment variable | `compat.getenv` |
| read from a descriptor | `std.posix.read` (still present) |

`src/compat.zig` holds what has no `Io` equivalent or runs where no `io` is reachable: `getenv`, clocks (`monotonicNow`, `nanoTimestamp`), `sleepNs`, the `forkExec*` family, and two things with a reason attached:

- `MemWriter`, `MemReader` and `DynWriter` are the binary codepath for the session and scrollback formats. Keep using them there so the on-disk format does not change.
- `memsetU32` is the single place every `[]u32` framebuffer fill goes through. It exists because `@memset` once miscompiled this case, so keep routing fills through it.

Memory:

- Use `init.gpa`. Reach for `std.heap.smp_allocator` only where `Init` is out of reach, such as C callbacks and signal handlers.
- `std.heap.page_allocator` costs one `mmap` per allocation, so use it only as the backing of an arena.
- `std.ArrayList(T)` starts as `.empty` and takes the allocator on each call.

C interop:

- `@cImport` is not used. Declare C functions by hand as `extern` with `callconv(.c)`, and C structs as `extern struct` or `opaque {}`.
- wlroots struct fields are read through accessor functions in `vendor/miozu-wlr-glue.c`, declared in `src/compositor/wlr.zig`.

Rendering:

- No allocation in the render loop. Buffers are allocated at init or on resize.
- SIMD paths use `@Vector` and end with a scalar loop for the tail.

Do not add a new `catch {}` that hides an error. Propagate it or log it.
