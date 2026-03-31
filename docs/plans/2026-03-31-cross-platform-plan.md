# Cross-Platform Plan

Internal roadmap for macOS and Windows support. Linux is the only distributable target in v0.1.x.

## macOS (target: v0.2.0)

### Blockers

1. **Fix `@compileError` in `MsgSendType`** — `@Type` removed in Zig 0.16
   - Replace generic `MsgSendType` with explicit function pointer casts per call site
   - Each objc_msgSend call gets its own `*const fn(id, SEL, ...) callconv(.c) T` cast
   - Pattern: `const f: *const fn(id, c.SEL, i64) callconv(.c) void = @ptrCast(&objc_msgSend_fn);`
   - Test: `zig build -Dtarget=aarch64-macos` must compile clean

2. **PTY implementation** — `src/pty/Pty.zig`
   - macOS uses `posix_openpt()` + `grantpt()` + `unlockpt()` + `ptsname()`
   - Current Linux impl uses `posix.openatZ` for `/dev/ptmx` — similar but needs macOS path
   - Alternative: `forkpty()` from `<util.h>` (simpler, available on macOS)
   - Need `TIOCSWINSZ` for window resize (same ioctl, different header)
   - Conditional compilation: `if (builtin.os.tag == .macos)` blocks in Pty.zig

3. **Keyboard translation** — `src/platform/linux/keyboard.zig`
   - Option A: xkbcommon via Homebrew (works but adds dep)
   - Option B: Carbon `UCKeyTranslate` + `TISCopyCurrentKeyboardInputSource` (native, no dep)
   - Recommendation: Option B for zero-dep macOS, fall back to raw keycodes
   - File: `src/platform/macos/keyboard.zig` (new)

4. **Clipboard** — `src/core/Clipboard.zig`
   - Use `NSPasteboard` via ObjC runtime (same pattern as window code)
   - Or simpler: fork `pbcopy`/`pbpaste` (macOS built-in)
   - Recommendation: `pbcopy`/`pbpaste` for v0.2.0, native NSPasteboard later

### Non-blockers (nice to have)

5. **App bundle** — `.app` directory structure for Finder/Dock
   - `teru.app/Contents/MacOS/teru` + `Info.plist` + icon
   - Not needed for Homebrew (CLI install is fine)

6. **Retina / HiDPI** — `NSScreen backingScaleFactor`
   - CPU renderer needs to render at 2x and downsample, or render at native res
   - Important for text clarity on Retina displays

7. **Metal rendering** (future) — replace CPU SIMD with Metal compute shader
   - Not needed for v0.2.0, CPU renderer works fine

### Distribution

- Homebrew tap: `nicholasglazer/homebrew-tap`
- Formula ready at `pkg/homebrew/teru.rb`
- `brew install nicholasglazer/teru/teru`
- Universal binary (x86_64 + aarch64) via `lipo` in CI

### Testing

- Need macOS CI runner (GitHub Actions `macos-latest`)
- Test on: Apple Silicon (M1+) + Intel Mac
- Minimum macOS version: 11.0 (Big Sur) — for AppKit API compatibility

---

## Windows (target: v0.3.0)

### Blockers

1. **ConPTY** — `src/pty/Pty.zig`
   - `CreatePseudoConsole()` — Windows 10 1809+ (October 2018)
   - `InitializeProcThreadAttributeList` + `UpdateProcThreadAttribute`
   - `CreateProcess` with `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`
   - Read via `ReadFile` on pipe, write via `WriteFile`
   - Resize via `ResizePseudoConsole()`
   - File: `src/pty/ConPty.zig` (new)
   - This is the single biggest piece of work (~200-300 lines)

2. **Keyboard** — Win32 virtual key translation
   - `MapVirtualKeyW` for scancode → VK mapping
   - `ToUnicode` / `ToUnicodeEx` for VK → character
   - `GetKeyboardState` for modifier tracking
   - File: `src/platform/windows/keyboard.zig` (new)

3. **Clipboard** — Win32 clipboard API
   - `OpenClipboard` + `GetClipboardData(CF_UNICODETEXT)` for paste
   - `OpenClipboard` + `EmptyClipboard` + `SetClipboardData` for copy
   - GlobalAlloc/GlobalLock for clipboard memory management
   - File: update `src/core/Clipboard.zig` with Windows branch

4. **Process management** — Windows doesn't have fork()
   - Current `compat.forkExec*` all use `linux.fork()`
   - Windows: `CreateProcess` API
   - ProcessGraph needs Windows PID handling
   - Signal handling: no SIGCHLD, use `WaitForSingleObject` or Job Objects

5. **File I/O** — paths and fs differences
   - Config: `%APPDATA%\teru\teru.conf` instead of `~/.config/teru/`
   - Session: `%LOCALAPPDATA%\teru\` instead of `/tmp/`
   - Socket paths: named pipes instead of Unix sockets (MCP, PaneBackend)

### Non-blockers

6. **Font discovery** — Windows font paths
   - `C:\Windows\Fonts\` is standard
   - Registry: `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`
   - Or bundle a default font

7. **DPI awareness** — `SetProcessDpiAwarenessContext`
   - Important for HiDPI displays on Windows

8. **Terminal integration** — Windows Terminal compatibility
   - Decide: standalone window OR embed in Windows Terminal
   - ConPTY works with both approaches

### Distribution

- **Scoop** bucket (recommended for CLI tools): `scoop install teru`
- **WinGet** manifest: `winget install teru`
- **MSI installer** (optional, for non-dev users)
- GitHub release with `.zip` containing `teru.exe`

### Testing

- GitHub Actions `windows-latest`
- Test on: Windows 10 21H2+, Windows 11
- MinGW cross-compilation from Linux: `zig build -Dtarget=x86_64-windows`

---

## Priority Order

1. Linux distribution (v0.1.0) — DONE
2. macOS (v0.2.0) — 4 blockers, ~1-2 days focused work
3. Windows (v0.3.0) — 5 blockers, ~3-4 days, ConPTY is the hard part

## Shared Work (benefits all platforms)

- [ ] Display-aware clipboard (X11/Wayland/macOS/Windows)
- [ ] Platform-agnostic config paths (`XDG_CONFIG_HOME` / `%APPDATA%` / `~/Library/`)
- [ ] Cross-platform font discovery
- [ ] CI matrix: Linux + macOS + Windows
