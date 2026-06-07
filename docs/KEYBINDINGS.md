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
| `$mod+Shift+C` | **Close focused pane or window** (xmonad `mod-shift-c`) |
| `$mod+J` / `$mod+K` | Focus next / previous pane |
| `$mod+Tab` / `$mod+Shift+Tab` | Focus next / previous (XMonad-style) |
| `$mod+Shift+J` / `$mod+Shift+K` | Swap focused pane with next / previous |
| `$mod+M` | Focus the master pane (no swap) |
| `$mod+Shift+M` | Swap focused pane ↔ master (xmonad `W.swapMaster`) |
| `$mod+Z` | Same as `$mod+Shift+M` (xmonad-muscle-memory alias) |
| `$mod+H` / `$mod+L` | Shrink / grow master width |
| `$mod+/` / `$mod+=` | Shrink / grow master width — dvorak alternates (physical `[` / `]` positions) |
| `$mod+Ctrl+J` / `$mod+Ctrl+K` | Rotate slaves down / up (keeps master + focus in place; xmonad `rotSlaves`) |
| `$mod+,` / `$mod+.` | Inc / dec **master count** — master-stack supports N masters stacked vertically |
| `$mod+Ctrl+S` | Sink *all* floating windows back into tiling |

## Layout

| Key | Action |
|-----|--------|
| `$mod+Space` | Cycle through this workspace's layouts |
| `$mod+Shift+Space` | Reset layout to `master-stack` (and `master_count` to 1) |
| `$mod+F` | Toggle fullscreen |
| `$mod+S` | Toggle floating for focused window |

In **teru standalone** only, `$mod+Z` toggles monocle. In **teruwm** it's a
swap-master alias (see the pane table above) because a compositor-wide
monocle would stomp xmonad muscle memory.

Workspaces have an ordered list of layouts. `$mod+Space` cycles. Available
layouts: `master-stack`, `grid`, `monocle`, `dishes`, `spiral`, `three-col`,
`columns`, `accordion`.

## Workspaces

| Key | Action |
|-----|--------|
| `$mod+1` … `$mod+9`, `$mod+0` | Switch to workspace 1–9, 0 |
| `$mod+Shift+1` … `$mod+Shift+0` | Move focused window to workspace N |
| `$mod+Escape` | Toggle **last visited** workspace (xmonad `toggleWS`) |
| `$mod+`` ` | Same — xmonad-familiar grave alias |
| `$mod+Ctrl+`` ` | Jump to next **non-empty** workspace (skips empties) |
| `$mod+O` | Cycle focus to the next **output** (multi-monitor) |
| `$mod+Shift+O` | Move focused window across outputs |

## Scratchpads (teruwm)

Named floating panes with stable identity, modeled after xmonad's
`NamedScratchpad`. A scratchpad parks on a hidden-workspace sentinel
when toggled off and moves onto the focused workspace when toggled
on. Since v0.4.18 scratchpads live in the node registry — they're
visible to `teruwm_list_windows`, composited at the correct z-order
by screenshots, and survive hot-restart.

### Default bindings (v0.6.4)

Four named scratchpads are pre-registered with xmonad-parity geometry
(`src/compositor/Server.applyDefaultScratchpadRules`). Only two have
default chords; `terminalBL` / `terminalSL` are reachable via MCP
(`teruwmctl scratchpad terminalBL`) or by adding your own chord.

| Key | Scratchpad | Geometry |
|-----|------------|----------|
| `$mod+T` | `terminalBR` | big right — x=42%, y=3%, w=57%, h=78% |
| `$mod+Shift+T` | `terminalSR` | small right — x=42%, y=83%, w=57%, h=15% |
| *(unbound)* | `terminalBL` | big left — x=1%, y=3%, w=40%, h=62% |
| *(unbound)* | `terminalSL` | small left — x=1%, y=67%, w=40%, h=31% |

Also still available: the hardcoded `Alt+RAlt+1..9` chord toggles the
numbered compat pads `pad1..pad9`. That chord isn't rebindable today;
the named four are.

### Rebinding

Any `[keybind]` entry with a `scratchpad:NAME` value assigns a chord
to a named pad. Up to 8 named scratchpad chords at once.

```ini
# ~/.config/teruwm/config
[keybind]
super+shift+h = scratchpad:terminalSL   # xmonad-default left-small
super+h       = scratchpad:terminalBL   # xmonad-default left-big
super+n       = scratchpad:notes        # custom named pad
```

### Per-name geometry overrides

New in v0.6.4 — `[scratchpad.NAME]` sections accept `x/y/w/h` as
fractions (`0.42`) or percent (`42%`). Evaluated at each show() against
the active output's dimensions, so the same config works at 1080p and
4K without edits.

```ini
[scratchpad.notes]
x = 5%
y = 60%
w = 40%
h = 35%
```

**MCP:** `teruwm_scratchpad { name }` — toggle a scratchpad by name.
First call spawns a floating terminal tagged with `name`; subsequent
calls flip visibility or migrate between workspaces (xmonad follow-me).

```sh
# Two independent scratchpads kept warm across a session:
teruwmctl scratchpad term       # spawn + show
teruwmctl scratchpad notes      # spawn + show a second one
teruwmctl scratchpad term       # hide 'term'; 'notes' stays
teruwmctl scratchpad term       # show 'term' again
```

## UI / compositor (teruwm)

| Key | Action |
|-----|--------|
| `$mod+B` | Toggle **top** status bar |
| `$mod+Shift+B` | Toggle **bottom** status bar |
| `$mod+D` | Open launcher (rofi-like) |
| `$mod+W` | Screenshot full output (native, no deps) → `<dir>/teru-<ts>.png` + a stable `<dir>/latest.png`. `<dir>` defaults to `$HOME/Pictures/teru`, set via `screenshot_dir` (must resolve under `$HOME` or `/tmp`). |
| `$mod+Shift+W` | Screenshot focused pane |
| `$mod+Ctrl+W` | Screenshot area (drag to select; uses `slurp` + `grim`) |

> The native `$mod+W` path composites teruwm's own panes + bars and copies
> nothing to the clipboard — pasting an image needs a Wayland clipboard
> source (`wl-copy`, or a future native `image/png` data source). Reference
> the file directly (e.g. `<dir>/latest.png`) to feed it to an assistant.
| `$mod+Shift+R` | Reload config from `~/.config/teruwm/config` |
| `$mod+'` | **Hot-restart** compositor — PTYs survive, picks up a rebuilt binary (xmonad `mod-'`) |
| `$mod+Shift+'` | **Quit** compositor (xmonad `mod-Shift-'`) |
| `$mod+Shift+Q` | Quit compositor (layout-independent fallback) |

> **Optional — one-key recompile + hot-restart** (xmonad's `mod-q`). Not a
> built-in default; wire it yourself with a spawn chord in
> `~/.config/teruwm/config`:
> ```conf
> [keybind]
> mod+q = spawn:foot -e /path/to/teru/tools/recompile-restart.sh
> ```
> The helper runs `make dev-install` and, only on success, triggers
> `teruwm_restart` over MCP — so one press rebuilds your latest source and
> hot-restarts into it, PTYs intact. Build errors stay on screen in the
> spawned terminal. This is the in-compositor equivalent of `$mod+'` after a
> manual `make dev-install`. See [INSTALLING.md](INSTALLING.md#inner-loop-refresh-while-developing-teruwm).

## Font zoom

### Keyboard (teru standalone)

| Key | Action |
|-----|--------|
| `$mod+-` | Zoom out (-1 px) |
| `$mod+_` | Zoom in (+1 px) — shift + minus, same key |
| `$mod+\` | Reset zoom |

In **teruwm** these chords are unbound — `$mod+=` is master resize
instead (see the pane table). The compositor has no keyboard font-zoom
chord; use the mouse wheel below.

### Mouse wheel (teru standalone + teruwm)

| Input | Action |
|-------|--------|
| `Alt` + scroll up | Zoom in (+1 px) |
| `Alt` + scroll down | Zoom out (-1 px) |

Works in both binaries while a terminal is focused. In teruwm the zoom is
**per-pane**: only the focused terminal's font size changes — other panes
and the bars are untouched (and only that pane's atlas is re-rasterized, so
there's no whole-compositor re-raster lag). `teruwm_zoom` (MCP) still zooms
the whole compositor; `teruwm_zoom_focused` (MCP) matches the per-pane
Alt+scroll gesture. Disable with `alt_scroll_zoom = false` (`teru.conf` for
standalone, the teruwm config file for the compositor). Bound the range with
`font_zoom_min` / `font_zoom_max` (defaults `6` / `72`; min is floored at 6
for legibility, a max of `0` means no maximum).

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
| `s` | Save teruwm session → `~/.config/teru/sessions/default.tsess` |
| `r` | Restore teruwm session from `default.tsess` |
| `Esc` | Leave prefix mode |

## Remote / TUI session (`teru -n` over SSH)

When you attach a session over SSH (`teru -n NAME`), teru renders as a full-screen
ANSI **TUI client** talking to a headless daemon (see [SESSIONS.md](SESSIONS.md)).
This client has its **own** key handling, distinct from the windowed/compositor
bindings above:

- **`$mod` is Alt**, same as standalone teru.
- **The prefix is `Ctrl+B`** here (not `Ctrl+Space`) — tmux muscle memory — and
  becomes **`Ctrl+A`** when nested (a teru inside another teru; see below).

| Key | Action |
|-----|--------|
| `Alt+1` … `Alt+0` | Switch to workspace 1–9, 0 |
| `Alt+J` / `Alt+K` | Focus next / previous pane |
| `Alt+M` | Focus the master pane |
| `Alt+N` / `Alt+P` | Swap focused pane with next / previous |
| `Alt+Shift+J` / `Alt+Shift+K` | Swap focused pane with next / previous (xmonad parity) |
| `Alt+Shift+M` | Swap focused pane with the master |
| `Alt+,` / `Alt+.` | Increase / decrease panes in the master area (IncMasterN) |
| `Alt+Shift+1` … `Alt+Shift+0` | Move focused pane to workspace 1–9, 0 |
| `Alt+H` / `Alt+L` | Shrink / grow the master area |
| `Alt+Enter` | New pane (split) |
| `Alt+X` | Close focused pane |
| `Alt+Space` | Cycle layout |
| `Alt+Z` | Zoom (monocle) toggle |
| `Alt+D` | Detach session |
| **Click** a pane | Focus that pane (input then routes to it) |
| `Ctrl+B` (or `Ctrl+A` when nested) then … | Prefix command (table below) |
| `Ctrl-\` | Detach immediately (everything keeps running) |

### Prefix commands (`Ctrl+B`, then …)

| Key | Action |
|-----|--------|
| `c` or `\` | Spawn pane (vertical split) |
| `-` | Spawn pane (horizontal split) |
| `x` | Close focused pane |
| `n` / `p` (or `j` / `k`) | Focus next / previous pane |
| `1` … `9`, `0` | Switch to workspace N |
| `Space` | Cycle layout |
| `z` | Zoom toggle |
| `Shift+J` / `Shift+K` | Swap focused pane with next / previous |
| `m` / `Shift+M` | Focus master / swap focused with master |
| `,` / `.` | Increase / decrease master count (IncMasterN) |
| `o` / `Shift+O` | Rotate the non-master panes down / up |
| `r` | Reset layout to master-stack |
| `d` | Detach session |
| `Esc` | Leave prefix mode |

### Nested (teru inside teru)

When the TUI client runs **inside another teru** — typically a local teru → `ssh`
→ remote `TERU_NESTED=1 teru -n NAME` — the inner client:

- **drops its own status bar** (the outer already draws one), and
- **announces itself** (OSC 9998) so the outer teru **forwards `Alt`+key to it**.
  The result: the remote multiplexer is driven with the **same `Alt` shortcuts as
  your local one** while focused on the nested pane — `Alt+1/2/3`, `Alt+J/K`,
  `Alt+H/L`, etc. all reach the remote.

Key ownership while focused on a nested pane:

| Keys | Go to | Why |
|------|-------|-----|
| `Alt`+key | **inner** (remote) | forwarded by the outer (OSC 9998 handshake) |
| `RAlt`+key | **outer** (local) | rearrange the nested pane within your local layout |
| `Ctrl+B` / `Ctrl+Space` prefix | **outer** (local) | escape hatch — always controls the local teru |
| `Ctrl+A` prefix | **inner** (remote) | fallback prefix for the remote, still available |

Set `TERU_NESTED=1` on the remote (the `TERM_PROGRAM=teru` auto-detect doesn't
survive SSH). Full workflow: [SESSIONS.md → Nested sessions](SESSIONS.md#nested-sessions-a-local-teru--ssh--remote-teru).

The inner status bar is dropped by default (the outer owns one). Under **teruwm**
or a plain terminal there is no outer bar, so set **`TERU_NESTED_BAR=1`** to keep
the inner multiplexer's bar (workspace tabs + layout + pane count) visible.

> Older outer teru (pre-Alt-forwarding) or a non-teru terminal: `Alt` won't be
> forwarded, so drive the remote with the `Ctrl+A` prefix instead.

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

**Smart borders** *(since v0.4.13)* — teruwm hides the focus outline when
the pane is the only window on its workspace. A border around the sole
visible window carries no information. The border re-appears automatically
the moment a second window joins the workspace.

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
`/run/user/$UID/teruwm-mcp-$PID.sock` — see `teruwm_list_windows`,
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
