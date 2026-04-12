# Installing teru

Two binaries exist. `teru` is the terminal emulator / multiplexer — it
runs on Linux (X11 + Wayland), macOS, and Windows. `teruwm` is a
Wayland compositor built on wlroots and runs as the root display
server; Linux only, requires wlroots 0.18.

See also: [teru.sh](https://teru.sh), [ARCHITECTURE.md](ARCHITECTURE.md).

## Pre-built Binaries

Download from [GitHub Releases](https://github.com/nicholasglazer/teru/releases):

| Platform | File | Notes |
|----------|------|-------|
| Linux x86_64 | `teru-linux-x86_64.tar.gz` | X11 + Wayland |
| Linux x86_64 (X11 only) | `teru-linux-x86_64-x11.tar.gz` | No wayland dep |
| Linux x86_64 (Wayland only) | `teru-linux-x86_64-wayland.tar.gz` | No xcb dep |
| Windows x86_64 | `teru-windows-x86_64.zip` | Win10+ (ConPTY) |
| macOS aarch64 | `teru-macos-aarch64.tar.gz` | Apple Silicon |

## Arch Linux (AUR)

```bash
paru -S teru        # stable release
paru -S teru-git    # latest main branch
```

Optional clipboard support: `paru -S xclip` (X11) or `paru -S wl-clipboard` (Wayland).

## macOS

### Homebrew (recommended)

```bash
brew install nicholasglazer/teru/teru
```

Builds from source via Zig. No Gatekeeper warnings since the binary is built locally.

### Manual

```bash
curl -L https://github.com/nicholasglazer/teru/releases/latest/download/teru-macos-aarch64.tar.gz | tar xz
xattr -cr teru    # remove Gatekeeper quarantine
sudo mv teru /usr/local/bin/
```

## Windows

### Scoop (recommended)

```powershell
scoop bucket add teru https://github.com/nicholasglazer/scoop-teru
scoop install teru
```

Scoop handles extraction and PATH setup automatically. No SmartScreen warnings.

### Manual

Download `teru-windows-x86_64.zip` from [Releases](https://github.com/nicholasglazer/teru/releases), extract, and run `teru.exe`. Requires Windows 10 1809+ (ConPTY support).

**Windows SmartScreen:** Downloaded executables are blocked by default. Right-click `teru.exe` > Properties > check "Unblock" > OK. Or run `Unblock-File teru.exe` in PowerShell.

## Build from Source

Requires **Zig 0.16+**. Linux builds need system libraries.

### Linux dependencies

| Package | Arch Linux | Debian/Ubuntu | Fedora |
|---------|------------|---------------|--------|
| libxcb | `libxcb` | `libxcb1-dev` | `libxcb-devel` |
| libxkbcommon | `libxkbcommon` | `libxkbcommon-dev` | `libxkbcommon-devel` |
| wayland | `wayland` | `libwayland-dev` | `wayland-devel` |

```bash
git clone https://github.com/nicholasglazer/teru.git
cd teru

# Terminal binary → zig-out/bin/teru (≈6.6 MB ReleaseFast)
zig build -Doptimize=ReleaseFast
sudo install -m755 zig-out/bin/teru /usr/local/bin/teru

# Compositor binary → zig-out/bin/teruwm (≈5.6 MB). Linux + wlroots only.
zig build -Doptimize=ReleaseFast -Dcompositor
sudo install -m755 zig-out/bin/teruwm /usr/local/bin/teruwm
```

### Compositor extra dependencies

| Package | Arch Linux | Debian/Ubuntu | Fedora |
|---------|------------|---------------|--------|
| wlroots 0.18 | `wlroots0.18` | `libwlroots-0.18-dev` | `wlroots-devel` |
| wayland-server | `wayland` | `libwayland-dev` | `wayland-devel` |

Verify with `pkg-config --exists wlroots-0.18 && echo ok`.

### Minimal builds (fewer dependencies)

```bash
make release-x11          # X11-only (no wayland-client dep)
make release-wayland      # Wayland-only (no libxcb dep)
```

### macOS (no system deps needed)

```bash
zig build -Doptimize=ReleaseSafe
```

### Windows (cross-compile from Linux)

```bash
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu
```

## Running `teruwm` (compositor)

Unlike `teru`, which runs inside your existing desktop, `teruwm` **is
the desktop** — a root Wayland compositor. Launch it from a TTY:

```
# Switch to a spare TTY: Ctrl+Alt+F3 (or similar)
# Log in, then:
exec teruwm
```

Don't run `teruwm` inside another compositor (sway, GNOME, KDE, …) —
it requires DRM + libinput access. Nested execution isn't supported.

Config goes in `~/.config/teruwm/config`. See
[CONFIGURATION.md](CONFIGURATION.md#teruwm-compositor-config) and
[KEYBINDINGS.md](KEYBINDINGS.md).
