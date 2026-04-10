# Installing teru

See also: [teru.sh](https://teru.sh)

## Pre-built Binaries

Download from [GitHub Releases](https://github.com/nicholasglazer/teru/releases):

| Platform | File | Notes |
|----------|------|-------|
| Linux x86_64 | `teru-linux-x86_64.tar.gz` | X11 + Wayland |
| Linux x86_64 (X11 only) | `teru-linux-x86_64-x11.tar.gz` | No wayland dep |
| Linux x86_64 (Wayland only) | `teru-linux-x86_64-wayland.tar.gz` | No xcb dep |
| Windows x86_64 | `teru-windows-x86_64.zip` | Win10+ (ConPTY) |
| macOS x86_64 | `teru-macos-x86_64.tar.gz` | Intel Mac |
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
make release              # 1.4MB binary at zig-out/bin/teru
sudo make install         # /usr/local/bin/teru
```

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
