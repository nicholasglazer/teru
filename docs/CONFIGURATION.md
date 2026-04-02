# Configuration

teru reads `~/.config/teru/teru.conf` on startup. All settings are optional — defaults are the miozu color scheme.

## Config Format

Simple `key = value` pairs. Lines starting with `#` are comments.

```conf
# ~/.config/teru/teru.conf

# Font
font_path = /usr/share/fonts/TTF/JetBrainsMono-Regular.ttf
font_size = 16

# Colors (base16 — any scheme works)
bg = #232733
fg = #D0D2DB
cursor_color = #FF9837
selection_bg = #3E4359
border_active = #FF9837
border_inactive = #3E4359

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

# Terminal
shell = /usr/bin/fish
scrollback_lines = 10000

# Prefix key (multiplexer commands)
# Options: ctrl+space (default), ctrl+a, ctrl+b
prefix_key = ctrl+space

# Window
initial_width = 960
initial_height = 640

# Hooks (shell commands run on events)
hook_on_spawn = notify-send "pane spawned"
hook_on_close = notify-send "pane closed"
```

## Using a Custom Base16 Theme

teru uses base16 for its color system. To use any base16 scheme:

1. Set `color0` through `color15` to the scheme's 16 colors
2. Set `bg` to color0 (or a variant)
3. Set `fg` to color5 or color7

Example with Dracula:
```conf
bg = #282A36
fg = #F8F8F2
color0 = #282A36
color1 = #FF5555
color2 = #50FA7B
color3 = #F1FA8C
color4 = #BD93F9
color5 = #FF79C6
color6 = #8BE9FD
color7 = #F8F8F2
color8 = #6272A4
color9 = #FF6E6E
color10 = #69FF94
color11 = #FFFFA5
color12 = #D6ACFF
color13 = #FF92DF
color14 = #A4FFFF
color15 = #FFFFFF
```

## Keybindings

Default prefix: `Ctrl+Space`

| Key | Action |
|-----|--------|
| prefix + c | New pane |
| prefix + x | Close pane |
| prefix + h/j/k/l | Navigate panes |
| prefix + H/J/K/L | Resize panes |
| prefix + z | Zoom (toggle monocle) |
| prefix + 1-9 | Switch workspace |
| prefix + / | Search in scrollback |
| prefix + ? | Help |
