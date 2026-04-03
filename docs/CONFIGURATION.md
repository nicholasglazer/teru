# Configuration

teru reads `~/.config/teru/teru.conf` on startup. All settings are optional -- defaults use the miozu color scheme.

## Config Format

Simple `key = value` pairs. Lines starting with `#` are comments. Sections use `[section]` headers. Unknown keys are silently ignored.

## Complete Example

```conf
# ~/.config/teru/teru.conf

# ── Appearance ──────────────────────────────────────────
font_path = /usr/share/fonts/TTF/JetBrainsMono-Regular.ttf
font_bold = /usr/share/fonts/TTF/JetBrainsMono-Bold.ttf
font_italic = /usr/share/fonts/TTF/JetBrainsMono-Italic.ttf
font_bold_italic = /usr/share/fonts/TTF/JetBrainsMono-BoldItalic.ttf
font_size = 16
padding = 8
opacity = 1.0

# ── Colors ──────────────────────────────────────────────
theme = miozu
bg = #232733
fg = #D0D2DB
cursor_color = #FF9837
selection_bg = #3E4359
border_active = #FF9837
border_inactive = #3E4359
bold_is_bright = false

# ANSI palette (color0-color15)
color0 = #232733
color1 = #EB3137
color2 = #6DD672
color3 = #E8D176
color4 = #83D2FC
color5 = #C974E6
color6 = #40FFE2
color7 = #D0D2DB
color8 = #565E78
color9 = #EB3137
color10 = #6DD672
color11 = #E8D176
color12 = #83D2FC
color13 = #C974E6
color14 = #40FFE2
color15 = #F3F4F7

# ── Terminal ────────────────────────────────────────────
shell = /usr/bin/fish
term = xterm-256color
scrollback_lines = 10000
tab_width = 8
bell = visual
copy_on_select = true
dynamic_title = true

# ── Cursor ──────────────────────────────────────────────
cursor_shape = block
cursor_blink = false

# ── Scrolling ───────────────────────────────────────────
scroll_speed = 3

# ── Keybindings ─────────────────────────────────────────
prefix_key = ctrl+space
prefix_timeout_ms = 500

# ── Window ──────────────────────────────────────────────
initial_width = 960
initial_height = 640

# ── Workspaces ──────────────────────────────────────────
[workspace.1]
layout = master-stack
master_ratio = 0.55
name = dev

[workspace.2]
layout = grid
name = logs

# ── Hooks ───────────────────────────────────────────────
hook_on_spawn = notify-send "pane spawned"
hook_on_close = notify-send "pane closed"
hook_on_agent_start = notify-send "agent started"
hook_on_session_save = notify-send "session saved"
```

---

## Option Reference

### Appearance

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `font_path` | string | (system default) | Path to a `.ttf` font file |
| `font_bold` | string | (none) | Path to bold variant `.ttf` |
| `font_italic` | string | (none) | Path to italic variant `.ttf` |
| `font_bold_italic` | string | (none) | Path to bold+italic variant `.ttf` |
| `font_size` | integer | `16` | Font size in pixels |
| `padding` | integer | `8` | Content padding around the terminal area in pixels |
| `opacity` | float | `1.0` | Window opacity, `0.0` (transparent) to `1.0` (opaque). X11: sets `_NET_WM_WINDOW_OPACITY`. macOS: sets `NSWindow.alphaValue` |

```conf
font_path = /usr/share/fonts/TTF/IosevkaTerm-Regular.ttf
font_size = 14
padding = 4
opacity = 0.95
```

### Colors and Themes

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `theme` | string | (none) | Built-in theme name or external theme file name |
| `bg` | hex color | `#232733` | Background color |
| `fg` | hex color | `#D0D2DB` | Foreground (text) color |
| `cursor_color` | hex color | `#FF9837` | Cursor color |
| `selection_bg` | hex color | `#3E4359` | Selection highlight background |
| `border_active` | hex color | `#FF9837` | Active pane border color |
| `border_inactive` | hex color | `#3E4359` | Inactive pane border color |
| `bold_is_bright` | bool | `false` | Shift ANSI colors 0-7 to bright 8-15 when bold |
| `color0`-`color15` | hex color | (miozu palette) | Override individual ANSI palette colors |

Colors are specified as `#RRGGBB` hex values. The `#` prefix is optional.

#### Built-in Themes

- `miozu` -- warm orange accent on dark blue-gray (the default)

#### External Theme Files

Set `theme = <name>` and place a file at `~/.config/teru/themes/<name>.conf`. The theme file uses the same `key = value` format and supports:

- **Direct color keys**: `bg`, `fg`, `cursor_color`, `selection_bg`, `border_active`, `border_inactive`, `color0`-`color15`
- **Base16 keys**: `base00` through `base0F`, mapped to standard slots:

| Base16 Key | Maps to |
|------------|---------|
| `base00` | `bg`, `color0` |
| `base01` | `selection_bg` |
| `base02` | `border_inactive` |
| `base03` | `color8` (comments / bright black) |
| `base05` | `fg`, `color7` |
| `base06` | `color15` (bright white) |
| `base07` | `border_active` |
| `base08` | `color1`, `color9` (red) |
| `base09` | `cursor_color` (orange accent) |
| `base0A` | `color3`, `color11` (yellow) |
| `base0B` | `color2`, `color10` (green) |
| `base0C` | `color6`, `color14` (cyan) |
| `base0D` | `color4`, `color12` (blue) |
| `base0E` | `color5`, `color13` (magenta) |

Color keys set in `teru.conf` after the `theme` line override the theme.

#### Example: Dracula Theme File

Create `~/.config/teru/themes/dracula.conf`:

```conf
base00 = #282A36
base01 = #44475A
base02 = #44475A
base03 = #6272A4
base05 = #F8F8F2
base06 = #F8F8F2
base07 = #F8F8F2
base08 = #FF5555
base09 = #FFB86C
base0A = #F1FA8C
base0B = #50FA7B
base0C = #8BE9FD
base0D = #BD93F9
base0E = #FF79C6
```

Then in `teru.conf`:

```conf
theme = dracula
```

### Terminal

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `shell` | string | `$SHELL` | Shell to launch in new panes. Falls back to `$SHELL` if unset |
| `term` | string | `xterm-256color` | Value of `$TERM` set in the PTY environment |
| `scrollback_lines` | integer | `10000` | Number of scrollback lines per pane |
| `tab_width` | integer | `8` | Tab stop width in columns |
| `bell` | `visual` or `none` | `visual` | Bell behavior. `visual` flashes the framebuffer, `none` disables |
| `copy_on_select` | bool | `true` | Automatically copy selected text to clipboard |
| `dynamic_title` | bool | `true` | Allow programs to set the window title via OSC sequences |

```conf
shell = /usr/bin/zsh
term = xterm-256color
scrollback_lines = 50000
tab_width = 4
bell = none
copy_on_select = false
```

### Cursor

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `cursor_shape` | `block`, `underline`, or `bar` | `block` | Cursor appearance |
| `cursor_blink` | bool | `false` | Enable cursor blinking (530ms interval) |

```conf
cursor_shape = bar
cursor_blink = true
```

### Scrolling

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `scroll_speed` | integer | `3` | Scroll wheel speed multiplier (pixels per scroll event) |

```conf
scroll_speed = 5
```

### Keybindings

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `prefix_key` | string | `ctrl+space` | Prefix key for multiplexer commands. Accepts `ctrl+a` through `ctrl+z`, `ctrl+space`, or raw integer 0-31 |
| `prefix_timeout_ms` | integer | `500` | Milliseconds to wait for a command after pressing the prefix key |

```conf
prefix_key = ctrl+b
prefix_timeout_ms = 1000
```

#### Prefix Key Bindings

Default prefix: `Ctrl+Space`

| Key | Action |
|-----|--------|
| prefix + `c` | New pane |
| prefix + `x` | Close pane |
| prefix + `h`/`j`/`k`/`l` | Navigate panes (left/down/up/right) |
| prefix + `H`/`L` | Resize master ratio |
| prefix + `z` | Zoom (toggle monocle layout) |
| prefix + `1`-`9` | Switch workspace |
| prefix + `/` | Search in scrollback |
| prefix + `?` | Help |
| `Ctrl+Shift+C` | Copy selection |
| `Ctrl+Shift+V` | Paste from clipboard |
| `Shift+PageUp/Down` | Scroll through scrollback |
| `PageUp/Down` | Scroll through scrollback |

### Window

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `initial_width` | integer | `960` | Initial window width in pixels |
| `initial_height` | integer | `640` | Initial window height in pixels |

```conf
initial_width = 1280
initial_height = 800
```

### Workspaces

Workspace sections use `[workspace.N]` headers where N is 1-9.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `layout` | string | `master-stack` | Tiling layout: `master-stack`, `grid`, `monocle`, or `floating` |
| `master_ratio` | float | `0.55` | Proportion of screen for the master pane (0.15-0.85) |
| `name` | string | (none) | Display name for the workspace |

```conf
[workspace.1]
layout = master-stack
master_ratio = 0.6
name = code

[workspace.2]
layout = grid
name = terminals

[workspace.3]
layout = monocle
name = focus
```

### Hooks

Shell commands executed on lifecycle events. The command is run via the system shell.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `hook_on_spawn` | string | (none) | Run when a new pane is spawned |
| `hook_on_close` | string | (none) | Run when a pane is closed |
| `hook_on_agent_start` | string | (none) | Run when an AI agent starts (via OSC 9999) |
| `hook_on_session_save` | string | (none) | Run when a session is saved |

```conf
hook_on_spawn = notify-send "teru" "pane spawned"
hook_on_close = notify-send "teru" "pane closed"
hook_on_agent_start = echo "agent started" >> ~/.local/share/teru/agents.log
```

### Advanced

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `notification_duration_ms` | integer | `5000` | How long status bar notifications are displayed (milliseconds) |

---

## Config File Location

teru looks for `~/.config/teru/teru.conf`. If the file does not exist, all defaults are used.

Theme files are loaded from `~/.config/teru/themes/<name>.conf`.

## Boolean Values

Boolean options accept: `true`, `yes`, `1` for true; `false`, `no`, `0` for false.
