# Configuration

teru reads `~/.config/teru/teru.conf` on startup. All settings are optional -- defaults use the miozu color scheme.

## Config Format

Simple `key = value` pairs. Lines starting with `#` are comments. Sections use `[section]` headers. Unknown keys are silently ignored.

### Include

Split your config across multiple files:

```conf
include keybindings.conf        # relative to ~/.config/teru/
include themes/custom.conf      # subdirectories work
include /absolute/path.conf     # absolute paths work
```

Includes are recursive (max depth 4). Included files use the same `key = value` format.

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
layouts = master-stack, grid, monocle
master_ratio = 0.6
name = dev

[workspace.2]
layouts = three-col, columns
master_ratio = 0.5
name = wide

[workspace.3]
layout = monocle
name = focus

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
| `attention_color` | hex color | `#EB3137` | Workspace attention indicator (activity in background) |
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
| `alt_workspace_switch` | boolean | `true` | Enable Alt+1-9 workspace switch and Alt+Shift+1-9 move pane |
| `restore_layout` | boolean | `false` | Save layout on exit, restore on launch (fresh shells, no daemon) |
| `persist_session` | boolean | `false` | Keep processes alive between window closes (auto-daemon) |
| `show_status_bar` | boolean | `true` | Show the status bar at the bottom of the window. Toggle at runtime with `Alt+B` |

```conf
prefix_key = ctrl+b
prefix_timeout_ms = 1000
alt_workspace_switch = true
restore_layout = true
persist_session = false
```

#### Session Persistence: `restore_layout` vs `persist_session`

These two options serve different use cases:

**`restore_layout = true`** (lightweight):
- Saves layout state (pane count, workspace, layout type, master ratio, zoom) to `$XDG_STATE_HOME/teru/sessions/default.bin` on every meaningful change (debounced 100ms).
- On next launch, restores pane count and layout -- but shells start fresh (new processes).
- No daemon involved. Quick startup, no background processes.
- Use this if you want your window arrangement preserved but don't need running processes to survive.

**`persist_session = true`** (full persistence):
- Automatically starts a daemon in the background. PTY processes survive window close.
- On next launch, auto-attaches to the running daemon -- all shell sessions, command history, and running processes are exactly where you left them.
- Equivalent to `teru -n default` every time.
- Use this if you want tmux-style session persistence without thinking about it.

Both options save to `$XDG_STATE_HOME/teru/sessions/`. You can enable both simultaneously -- `persist_session` takes priority when a daemon is running, `restore_layout` serves as fallback when no daemon is found.

Named sessions (`teru -n NAME`) always get full daemon persistence regardless of these settings.

#### Prefix Key Bindings

Default prefix: `Ctrl+Space`

| Key | Action |
|-----|--------|
| prefix + `c` or `\` | Spawn pane (vertical split) |
| prefix + `-` | Spawn pane (horizontal split) |
| prefix + `x` | Close pane |
| prefix + `n` / `p` | Focus next / prev pane |
| prefix + `H` / `L` | Shrink / grow master width |
| prefix + `K` / `J` | Shrink / grow master height (dishes) |
| prefix + `Space` | Cycle layout (within workspace layout list) |
| prefix + `z` | Toggle zoom (monocle layout) |
| prefix + `1`-`9` | Switch workspace |
| prefix + `v` | Enter vi/copy mode |
| prefix + `/` | Search in scrollback |
| prefix + `d` | Detach (save session, exit) |

#### Global Shortcuts (no prefix)

| Key | Action |
|-----|--------|
| `Alt+1`-`9` | Switch workspace |
| `RAlt+1`-`9` | Move active pane to workspace |
| `Alt+J` / `Alt+K` | Focus next / prev pane |
| `RAlt+J` / `RAlt+K` | Swap pane down / up |
| `Alt+Enter` | New pane (vertical split) |
| `RAlt+Enter` | New pane (horizontal split) |
| `Alt+C` | New pane (vertical split) |
| `RAlt+C` | New pane (horizontal split) |
| `Alt+X` | Close active pane |
| `Alt+M` | Focus master pane |
| `RAlt+M` | Mark active pane as master |
| `Alt+B` | Toggle status bar |
| `Alt+-` / `Alt+=` | Zoom out / in (font size) |
| `Alt+\` | Reset zoom (restore config font size) |
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
| `layout` | string | (auto) | Default layout: `master-stack`, `grid`, `monocle`, `dishes`, `spiral`, `three-col`, `columns`, or `accordion` |
| `layouts` | string | (all) | Comma-separated layout cycle list. Prefix+Space cycles within this list |
| `master_ratio` | float | `0.6` | Proportion of screen for the master pane (0.15-0.85). Used by `master-stack` and `three-col` |
| `name` | string | (none) | Display name for the workspace |

#### Layout Types

| Layout | Description | Status bar |
|--------|-------------|------------|
| `master-stack` | One master pane on the left, stack of panes on the right | `[M]` |
| `grid` | Equal-sized grid (cols = ceil(sqrt(n))) | `[G]` |
| `monocle` | Fullscreen active pane, others hidden | `[#]` |
| `dishes` | Master on top (full width), stack in columns below | `[D]` |
| `spiral` | Fibonacci spiral: alternates vertical/horizontal splits | `[S]` |
| `three-col` | Master in center, stacks on left and right sides | `[3]` |
| `columns` | Equal-width vertical columns | `[|]` |
| `accordion` | Focused pane tall, others compressed to thin strips | `[A]` |

#### Per-Workspace Layout Lists

Use `layouts` to restrict which layouts Prefix+Space cycles through. This follows the xmonad `|||` pattern -- each workspace can have its own set of available layouts.

```conf
[workspace.1]
layouts = master-stack, grid, monocle
master_ratio = 0.6
name = code

[workspace.2]
layouts = three-col, columns
master_ratio = 0.5
name = wide

[workspace.3]
layout = monocle
name = focus
```

When `layouts` is set, Prefix+Space cycles only within that list. When only `layout` is set (or neither), all layouts are available. `layouts` takes priority over `layout`.

Without any workspace config, teru auto-selects the layout based on pane count: 0-1 = monocle, 2-4 = master-stack, 5+ = grid. This auto-selection is disabled when a layout list is configured.

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

### Behavior

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `mouse_hide_when_typing` | bool | `true` | Hide the mouse cursor while typing, restore on mouse movement |
| `word_delimiters` | string | (none) | Characters that delimit words for double-click selection. If unset, uses a built-in default set |

```conf
mouse_hide_when_typing = false
word_delimiters = " \t@:/.()\"'-"
```

### Status Bar

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `bar_left` | string | (none) | Custom format string for the left section of the status bar |
| `bar_center` | string | (none) | Custom format string for the center section of the status bar |
| `bar_right` | string | (none) | Custom format string for the right section of the status bar |

When unset, the status bar uses its built-in layout (workspace indicators, layout name, pane info, session name).

```conf
bar_left = {workspace}
bar_center = {layout}
bar_right = {session}
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

---

## teruwm Compositor Config

The teruwm compositor reads a **separate** config file from the terminal: `~/.config/teruwm/config`. This file covers window manager concerns only (gaps, borders, bars, window rules). Font, colors, and terminal behavior still come from `~/.config/teru/teru.conf` and are shared with the embedded teru terminal panes.

If `~/.config/teruwm/config` does not exist, all defaults are used.

### File Format

Same `key = value` syntax as `teru.conf`. Lines starting with `#` are comments. Sections use `[section]` headers. Unknown keys are silently ignored. Max file size: 64 KB.

### Global Keys

These keys are set above any section header.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `gap` | integer | `4` | Uniform gap in pixels. Same value applied between panes and between panes and screen edges / bars |
| `border_width` | integer | `2` | Border width in pixels around focused and unfocused windows |
| `bg_color` (or `bg`) | hex color | `0xFF1a1d24` | Compositor background color, visible through gaps. Accepts `#rrggbb`, `0xrrggbb`, `rrggbb` (alpha defaulted to `0xFF`), or full ARGB `0xaarrggbb` |

### `[bar.top]` and `[bar.bottom]`

Each bar has three format-string slots: `left`, `center`, `right`. Omit a slot to leave it empty. Max length per string: 256 bytes.

| Key | Description |
|-----|-------------|
| `left` | Left-aligned bar content |
| `center` | Center-aligned bar content |
| `right` | Right-aligned bar content |

Defaults when unset (match the current build — if you want them
different, just set the slot in your config):

- `[bar.top]` left=`{workspaces}`, center=`{title}`, right=`{keymap} | {battery} {watts} | {clock}`
- `[bar.bottom]` left=`CPU {cpu} {cputemp} | RAM {mem}`, center=(empty), right=`GPU {exec:5:nvidia-smi ...}`

### Bar widget tokens

Format strings are plain text with `{name}` or `{name:arg}` tokens. Any literal
text between tokens renders as-is. Unknown tokens render as literal text.
The parser balances `{`/`}` depth inside tokens, so `awk '{print $1}'` inside
an `{exec:...}` command works without escaping.

**Static / UI:**

| Token | Output |
|-------|--------|
| `{workspaces}` | Workspace tabs (active highlighted) |
| `{title}` | Focused pane/window title |
| `{layout}` | Current layout indicator, e.g. `[M]`, `[G]`, `[#]` |
| `{panes}` | Pane count for the active workspace |
| `{clock}` | Local time in `HH:MM` (shorthand for `{clock:%H:%M}`) |
| `{clock:%FMT}` | Local time via `strftime(3)`, e.g. `{clock:%H:%M:%S}`, `{clock:%a %Y-%m-%d}` |
| literal text | Rendered as-is (e.g. `" | "`, `"cpu: "`) |

**System metrics** (all numeric, color-ramp via `[bar.thresholds]`):

| Token | Output | Source |
|-------|--------|--------|
| `{cpu}` | CPU usage `%` | `/proc/stat` diff between frames |
| `{cputemp}` | CPU temperature `°C` | `/sys/class/hwmon/*/temp1_input` (known CPU sensor names) |
| `{mem}` | RAM used `%` | `/proc/meminfo` |
| `{battery}` / `{bat}` | Battery `%` (`+` prefix when charging) | `/sys/class/power_supply/BAT*/capacity` |
| `{watts}` / `{power}` | Battery power draw in W | `/sys/class/power_supply/BAT*/power_now` |
| `{keymap}` / `{lang}` | Active keyboard layout code, e.g. `Us`, `Ua`, `Dv` | XKB — updates live on layout switch |
| `{perf}` | Compositor frame avg / max time (µs) | Internal `PerfStats` |

**External:**

| Token | Output |
|-------|--------|
| `{exec:N:cmd}` | Output of shell command `cmd`, first line only, refreshed every `N` seconds. 128-byte output cap. |
| `{exec:cmd}` | Same with default 5-second interval |
| `{widget:NAME}` | External push widget, content set via `teruwm_set_widget` MCP tool. [See AI-INTEGRATION.md](AI-INTEGRATION.md#push-widgets-—-event-driven-status-bar-content). |

### `[bar.thresholds]` — color ramps for numeric widgets

Each numeric widget goes green / yellow / red based on its value. The
boundaries are configurable — names follow the waybar / polybar / i3status
convention (`_warning` and `_critical`) rather than `low`/`high`, because
the semantics read identically for widgets where "low" is bad (battery)
and widgets where "high" is bad (CPU).

```ini
[bar.thresholds]
cpu_warning      = 30    # CPU ≥30%  → yellow
cpu_critical     = 70    # CPU ≥70%  → red
cputemp_warning  = 60
cputemp_critical = 80
mem_warning      = 30
mem_critical     = 80
battery_warning  = 50    # battery ≤50% → yellow  (inverted)
battery_critical = 20    # battery ≤20% → red
watts_warning    = 15    # discharge ≥15W → yellow (charging is always green)
watts_critical   = 30
perf_us_warning  = 50
perf_us_critical = 100
```

The older `*_low` / `*_high` names are accepted as aliases. Unknown
keys are silently ignored. The widget `{watts}` is always green when
the battery is charging, regardless of thresholds.

### `[rules]` — Window → Workspace

Map an X11 window class or Wayland `app_id` to a target workspace (1-9). When a matching window maps, the compositor sends it to that workspace. Max 32 rules.

```conf
[rules]
Chromium = 2
Firefox = 1
Steam = 7
```

Key is matched exactly against the window's class / app_id. Value is a 1-based workspace number (internally stored 0-based).

### `[names]` — Human-Readable Window Names

Map a window class or `app_id` to a short display name used by the bar's `{title}` widget and any compositor MCP output. Max 32 name rules. Class max 64 bytes, name max 32 bytes.

```conf
[names]
Chromium = web
org.mozilla.firefox = ff
code-url-handler = vscode
```

### Example `~/.config/teruwm/config`

Drop this in as a starting point:

```conf
# ~/.config/teruwm/config

# ── Window layout ──────────────────────────────
gap = 8
border_width = 2
bg_color = #1a1d24

# ── Top bar ────────────────────────────────────
[bar.top]
left   = {workspaces}
center = {title}
right  = {clock:%a %H:%M}

# ── Bottom bar ─────────────────────────────────
[bar.bottom]
left   = CPU {cpu} {cputemp} | RAM {mem}
center = {widget:mpris}
right  = GPU {exec:5:nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits | awk -F, '{print $1"% "$2"C"}'}

# ── Color thresholds (widget colors adapt to values) ──
[bar.thresholds]
cpu_warning      = 40
cpu_critical     = 85
cputemp_warning  = 70
cputemp_critical = 90
battery_warning  = 50
battery_critical = 15

# ── Workspace assignments ──────────────────────
[rules]
Firefox    = 1
Chromium   = 2
Steam      = 7
Slack      = 8

# ── Friendly window names ──────────────────────
[names]
org.mozilla.firefox = ff
Chromium            = web
code-url-handler    = code
```
