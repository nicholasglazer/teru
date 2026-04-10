# Keybindings

teru has two layers of keyboard shortcuts: **prefix commands** (Ctrl+Space + key) and **global shortcuts** (Alt+key, no prefix needed).

All global shortcuts can be disabled with `alt_workspace_switch = false` in `teru.conf`.

---

## Global Shortcuts (Alt+key)

No prefix required. These work instantly from any state.

### Workspace

| Key | Action |
|-----|--------|
| `Alt+1`-`9` | Switch to workspace 1-9 |
| `RAlt+1`-`9` | Move active pane to workspace 1-9 |

### Pane Navigation

| Key | Action |
|-----|--------|
| `Alt+J` | Focus next pane |
| `Alt+K` | Focus previous pane |
| `RAlt+J` | Swap pane with next (move down in layout order) |
| `RAlt+K` | Swap pane with previous (move up in layout order) |

### Pane Management

| Key | Action |
|-----|--------|
| `Alt+Enter` | New pane (vertical split) |
| `RAlt+Enter` | New pane (horizontal split) |
| `Alt+C` | New pane (vertical split) |
| `RAlt+C` | New pane (horizontal split) |
| `Alt+X` | Close active pane |

### Master Pane

| Key | Action |
|-----|--------|
| `Alt+M` | Focus the master pane |
| `RAlt+M` | Mark active pane as master |

Mark any pane as "master" per workspace. Press `Alt+M` from anywhere to jump back to it. The master designation persists until you mark a different pane or close it.

### Font Zoom

| Key | Action |
|-----|--------|
| `Alt+-` | Zoom out (decrease font size by 1px) |
| `Alt+=` | Zoom in (increase font size by 1px) |
| `Alt+\` | Reset zoom (restore config font size) |

### UI

| Key | Action |
|-----|--------|
| `Alt+B` | Toggle status bar visibility |

Font zoom re-rasterizes glyphs from memory (no disk I/O). Grid resize and SIGWINCH are deferred 150ms after the last zoom event, so rapid zooming is smooth.

### Right Alt (RAlt)

Right Alt is used as a modifier for pane manipulation shortcuts. It's tracked by physical keycode, independent of keyboard layout. The distinction:

- **Alt+key** = navigation / read-only actions (focus, switch workspace)
- **RAlt+key** = mutation actions (move pane, swap, mark master, horizontal split)

---

## Prefix Commands (Ctrl+Space + key)

Press the prefix key (default: `Ctrl+Space`), then press a command key within the timeout (default: 500ms).

### Pane Management

| Key | Action |
|-----|--------|
| prefix + `c` or `\` | Spawn pane (vertical split) |
| prefix + `-` | Spawn pane (horizontal split) |
| prefix + `x` | Close active pane |

### Navigation

| Key | Action |
|-----|--------|
| prefix + `n` | Focus next pane |
| prefix + `p` | Focus previous pane |
| prefix + `1`-`9` | Switch workspace |

### Layout

| Key | Action |
|-----|--------|
| prefix + `Space` | Cycle layout (within workspace layout list) |
| prefix + `z` | Toggle zoom (monocle layout) |
| prefix + `H` / `L` | Shrink / grow master width |
| prefix + `K` / `J` | Shrink / grow master height (dishes layout) |

### Modes

| Key | Action |
|-----|--------|
| prefix + `v` | Enter vi/copy mode |
| prefix + `/` | Search in terminal output |

### Session

| Key | Action |
|-----|--------|
| prefix + `d` | Detach (save session, exit) |

---

## Scrolling

| Key | Action |
|-----|--------|
| `Shift+PageUp` / `PageUp` | Scroll up |
| `Shift+PageDown` / `PageDown` | Scroll down |
| Mouse wheel | Smooth pixel scroll |
| Any printable key | Exit scroll mode |

---

## Vi/Copy Mode (prefix + v)

| Key | Action |
|-----|--------|
| `h` `j` `k` `l` / arrows | Move cursor |
| `w` `b` `e` | Word motion |
| `g` / `G` | Top / bottom of scrollback |
| `Ctrl+U` / `Ctrl+D` | Half-page up / down |
| `H` `M` `L` | Viewport top / middle / bottom |
| `v` | Start character selection |
| `V` | Start line selection |
| `o` | Swap selection endpoint |
| `y` | Yank to clipboard |
| `q` / `ESC` | Exit vi mode |

---

## Mouse

| Action | Effect |
|--------|--------|
| Click | Focus pane under cursor |
| Drag | Select text |
| Double-click | Select word |
| Shift+click | Open URL under cursor |
| Shift+hover | Underline URL under cursor |
| Drag border | Resize master ratio |

---

## Clipboard

| Key | Action |
|-----|--------|
| `Ctrl+Shift+C` | Copy selection to clipboard |
| `Ctrl+Shift+V` | Paste from clipboard |
| Select text | Auto-copy (when `copy_on_select = true`) |

---

## Configuration

The prefix key and timeout are configurable in `~/.config/teru/teru.conf`:

```conf
prefix_key = ctrl+space    # default
prefix_timeout_ms = 500    # milliseconds to wait for command key
alt_workspace_switch = true # enable Alt+key global shortcuts
```

See [CONFIGURATION.md](CONFIGURATION.md) for all options.

---

## Claude Code Compatibility

teru's Alt+key shortcuts are designed to avoid conflicts with Claude Code's keybindings:

| Claude Code | teru | Conflict |
|---|---|---|
| `Alt+T` (thinking) | unused | none |
| `Alt+P` (model switch) | unused | none |
| `Alt+O` (fast mode) | unused | none |
| `Alt+B` (word back) | toggle status bar | conflict — remap if needed |
| `Alt+F` (word forward) | unused | none |
| `Shift+Tab` (permissions) | unused | none |

All shortcuts are safe to use with Claude Code running inside teru.
