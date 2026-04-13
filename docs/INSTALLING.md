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
| XWayland (optional, for X11 clients) | `xorg-xwayland` | `xwayland` | `xorg-x11-server-Xwayland` |

Verify with `pkg-config --exists wlroots-0.18 && echo ok`. XWayland is
optional at runtime — teruwm lazy-starts it the first time an X11 client
connects; without the package installed, teruwm runs fine for pure
Wayland clients (firefox, chromium --ozone-platform=wayland, foot,
teru, …).

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

## Troubleshooting crashes

If `teruwm` aborts, systemd-coredump captures the process image. To
inspect and file a useful report:

```sh
coredumpctl list                       # find the PID
coredumpctl info <pid>                 # backtrace + threads
coredumpctl debug <pid>                # drop into gdb on the core
```

The backtrace is usually enough — the top non-libc frame is a `Server.*`
or wlroots function. If you're reporting, include:

1. The full `coredumpctl info` stack.
2. The exact action that triggered it (e.g. "pressed Shift+Alt after
   opening chromium").
3. `git log -1 --oneline` from your teru checkout — so we know which
   commit you're on.

### Known defensive guards (v0.4.19..v0.4.25)

Six coredump-grade crashes were triaged in the 0.4.x polish pass:

| Symptom | Trigger | Root cause | Fix tag |
|---|---|---|---|
| `Bar.buildBarData` SIGSEGV | Close last pane (`$mod+X`) | `focused_terminal` pointed at freed TerminalPane during `bar.render` | v0.4.19 |
| `wl_resource_post_event` assert | Close an external window (chromium) via MCP | `focused_view` + grab state dangled past unmap → destroy | v0.4.19 / v0.4.22 |
| `update_node_update_outputs` assert (scene) | Any motion on an XDG client during unmap race | Scene buffer out-lives its surface briefly | v0.4.24 |
| `update_node_update_outputs` assert (scene) | Defocused client set_cursor after modifier (Shift+Alt on chromium) | Cursor-set accepted from any client, not just focused | v0.4.25 |
| DCS → CSI state leak | `ESC[` inside a DCS body | `dcs_passthrough` reused the general `.escape` state | v0.4.22 |
| `Workspace.removeNode` stale `active_node` | Close last pane on a workspace | `active_node` not cleared on node remove | v0.4.22 |

If you see a crash that doesn't match one of these signatures with a
recent enough build, it's new — please file it.
