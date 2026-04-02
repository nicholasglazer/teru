# Installing teru

## From Source (recommended)

Requires Zig 0.16+ and a C compiler (for libc).

```bash
git clone https://github.com/nicholasglazer/teru.git
cd teru
zig build -Doptimize=ReleaseSafe
strip zig-out/bin/teru          # optional, ~1.3MB
sudo cp zig-out/bin/teru /usr/local/bin/
```

### Build Options

```bash
zig build -Dwayland=false       # X11-only (no libwayland dep)
zig build -Dx11=false           # Wayland-only (no libxcb dep)
```

### Dependencies

**Runtime** (linked dynamically):
- `libxcb` + `libxcb-shm` — X11 display (skip with `-Dx11=false`)
- `libxkbcommon` — keyboard translation
- `libwayland-client` — Wayland display (skip with `-Dwayland=false`)

**Build-time** (vendored, no downloads):
- `stb_truetype.h` — font rasterization
- `xdg-shell-protocol.h` — Wayland protocol

## Arch Linux (AUR)

```bash
yay -S teru        # stable release
yay -S teru-git    # latest main branch
```

## Homebrew (macOS + Linux)

```bash
brew tap nicholasglazer/homebrew-tap
brew install teru
```

## Nix

```bash
nix-shell -p teru
```
