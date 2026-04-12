# Keybindings

teru ships two binaries that share the same keybinding definitions but use
different modifier keys:

| Binary | `$mod` (default) | Notes |
|--------|------------------|-------|
| **teru** (standalone terminal) | **Alt** | tiling inside one window |
| **teruwm** (Wayland compositor) | **Super** (Win) | tiling the whole screen |

The `$mod` key can be overridden in config (`mod_key = alt|super|ctrl`). Every
keybind below uses `$mod` — swap in the modifier for whichever binary you're
running. When this page says "Super" it means Super by default in teruwm; in
teru the same action is bound to Alt.

There are three keyboard modes:

- **Normal** — default. All `$mod+key` shortcuts live here.
- **Prefix** — entered with `Ctrl+Space`, next key triggers a prefix command
  (tmux-style).
- **Scroll / Vi copy** — entered with `$mod+V`. Use vi motions to navigate
  scrollback and copy text.

---

## Pane / window management

| Key | Action |
|-----|--------|
| `$mod+Enter` | Spawn new terminal pane |
| `$mod+C` | Spawn new pane (vertical split) |
| `$mod+X` | **Close focused pane or window** |
| `$mod+Shift+C` | Close focused window (alias) |
| `$mod+J` / `$mod+K` | Focus next / previous pane |
| `$mod+Tab` / `$mod+Shift+Tab` | Focus next / previous (XMonad-style) |
| `$mod+Shift+J` / `$mod+Shift+K` | Swap focused pane with next / previous |
| `$mod+M` | Focus the master pane |
| `$mod+Shift+M` | Mark focused pane as master |
| `$mod+H` / `$mod+L` | Shrink / grow master width |

## Layout

| Key | Action |
|-----|--------|
| `$mod+Space` | Cycle through this workspace's layouts |
| `$mod+Z` | Toggle zoom (monocle) on focused pane |
| `$mod+F` | Toggle fullscreen |
| `$mod+S` | Toggle floating for focused window |

Workspaces have an ordered list of layouts. `$mod+Space` cycles. Available
layouts: `master-stack`, `grid`, `monocle`, `dishes`, `spiral`, `three-col`,
`columns`, `accordion`.

## Workspaces

| Key | Action |
|-----|--------|
| `$mod+1` … `$mod+9`, `$mod+0` | Switch to workspace 1–9, 0 |
| `$mod+Shift+1` … `$mod+Shift+0` | Move focused window to workspace N |

## Scratchpads (teruwm)

Nine floating terminal panes, independent of any workspace. Useful for
always-available scratch shells — the pane holds its state when
toggled off.

| Key | Action |
|-----|--------|
| `Alt+RAlt+1` … `Alt+RAlt+9` | Toggle scratchpad 1–9 (create on first call; show/hide thereafter) |

The chord is explicitly Alt + Right-Alt + digit: both Alt keys must be
held. This avoids collision with the single-Alt or single-Super
workspace shortcuts.

## UI / compositor (teruwm)

| Key | Action |
|-----|--------|
| `$mod+B` | Toggle **top** status bar |
| `$mod+Shift+B` | Toggle **bottom** status bar |
| `$mod+D` | Open launcher (rofi-like) |
| `$mod+W` | Screenshot full output → `/tmp/teruwm-screenshot.png` |
| `$mod+Shift+W` | Screenshot focused pane |
| `$mod+Shift+R` | Reload config from `~/.config/teruwm/config` |
| `$mod+Ctrl+Shift+R` | **Hot-restart** compositor (PTYs survive) |
| `$mod+Shift+Q` | Quit compositor |

## Font zoom (teru standalone)

| Key | Action |
|-----|--------|
| `$mod+=` | Zoom in (+1 px) |
| `$mod+-` | Zoom out (-1 px) |
| `$mod+\` | Reset zoom |

## Modes

| Key | Action |
|-----|--------|
| `$mod+/` | Enter search mode in scrollback |
| `$mod+V` | Enter vi / copy / scroll mode |
| `Ctrl+Space` | Enter prefix mode (next key is a prefix command) |

## Prefix commands (`Ctrl+Space`, then …)

| Key | Action |
|-----|--------|
| `c` or `\` | Spawn pane (vertical split) |
| `-` | Spawn pane (horizontal split) |
| `x` | Close focused pane |
| `n` / `p` | Focus next / previous pane |
| `1` … `9`, `0` | Switch to workspace N |
| `Space` | Cycle layout |
| `z` | Zoom toggle |
| `Shift+H` / `Shift+L` | Shrink / grow master width |
| `Shift+K` / `Shift+J` | Shrink / grow master height |
| `/` | Search |
| `v` | Vi / copy mode |
| `d` | Detach session (teru only) |
| `Esc` | Leave prefix mode |

## Scroll mode (`$mod+V`)

| Key | Action |
|-----|--------|
| `j` / `k` | Scroll one line down / up |
| `Ctrl+D` / `Ctrl+U` | Scroll half page down / up |
| `g` / `Shift+G` | Jump to top / bottom of scrollback |
| `/` | Enter search |
| `v` | Start visual selection |
| `y` | Yank selection to clipboard |
| `q` / `Esc` | Return to normal mode |

## Vi / copy mode (inside scroll mode, after `v`)

| Key | Action |
|-----|--------|
| `h j k l` / arrows | Move cursor |
| `w` `b` `e` | Word motion |
| `H` `M` `L` | Viewport top / middle / bottom |
| `v` | Character selection |
| `V` | Line selection |
| `o` | Swap selection endpoints |
| `y` | Yank to clipboard |

## Media keys (teruwm only)

These require `loadMediaDefaults()` at startup (on by default in compositor):

| Key | Action |
|-----|--------|
| `XF86AudioRaiseVolume` | `wpctl set-volume @DEFAULT_SINK@ 5%+` |
| `XF86AudioLowerVolume` | `wpctl set-volume @DEFAULT_SINK@ 5%-` |
| `XF86AudioMute` | Mute / unmute |
| `XF86AudioPlay` / `Next` / `Prev` | MPRIS media control |
| `XF86MonBrightnessUp` / `Down` | `brightnessctl set 5%+/-` |
| `Print` | Screenshot |

## Clipboard / selection

| Key | Action |
|-----|--------|
| `Ctrl+Shift+C` | Copy selection |
| `Ctrl+Shift+V` | Paste |

Or set `copy_on_select = true` in config for auto-copy on mouse release.

## Mouse

| Action | Effect |
|--------|--------|
| Click | Focus window under cursor |
| Drag | Select text |
| Double-click | Select word |
| `Shift+Click` | Open URL under cursor |
| `Shift+Hover` | Underline URL under cursor |
| Drag pane border | Resize master ratio (teruwm) |
| `$mod+Click` drag on **tiled** pane | Detach from layout → becomes floating under the cursor (teruwm) |
| `$mod+Click` drag on floating | Move floating window (teruwm) |
| `$mod+Right-click` drag | Resize floating window (teruwm) |
| Wheel | Smooth pixel scroll |

---

## Customizing

Keybinds are parsed at compositor / terminal startup from config files.
See `~/.config/teru/teru.conf` or `~/.config/teruwm/config`. Every default
binding above comes from `src/config/Keybinds.zig:loadDefaults`. Custom
bindings use this syntax:

```ini
# teruwm example
[keybinds]
super+e     = spawn:thunar
super+p     = launcher_toggle
super+grave = mode_scroll
```

Action names match the identifiers in `Keybinds.Action` (e.g. `pane_close`,
`workspace_3`, `bar_toggle_top`).

## MCP control (teruwm)

The compositor exposes its window-manager controls over MCP at
`/run/user/$UID/teru-wmmcp-$PID.sock` — see `teruwm_list_windows`,
`teruwm_close_window`, `teruwm_switch_workspace`, `teruwm_set_layout`,
`teruwm_toggle_bar`, `teruwm_set_config`, etc. Any keybind action can be
scripted from outside.

See [ARCHITECTURE.md](ARCHITECTURE.md#compositor-mcp) for the full tool list.

---

## Claude Code compatibility

teruwm uses Super by default; teru standalone uses Alt. Claude Code's Alt
shortcuts (`Alt+T`, `Alt+P`, `Alt+O`, `Alt+F`) don't conflict with teruwm.
Inside the standalone terminal, `Alt+B` toggles the bar — if you use Claude
Code's `Alt+B` (word back), either rebind `bar_toggle_top` or switch
`mod_key = super` in `teru.conf`.
