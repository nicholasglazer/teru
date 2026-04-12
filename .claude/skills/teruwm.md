---
name: teruwm
description: "teruwm compositor control — MCP tools, screenshots, layout management, restart, diagnostics. Use when running Claude from TTY inside teruwm."
---

# teruwm Compositor Skill

When Claude runs inside teruwm (the Wayland compositor), you have direct control over the window manager via two MCP socket layers and can self-heal issues.

## Detecting teruwm

Check if running inside teruwm:
```bash
# teruwm process running?
pgrep -x teruwm && echo "inside teruwm"
# Find compositor MCP socket
ls /run/user/$(id -u)/teru-wmmcp-*.sock 2>/dev/null
# Find terminal MCP sockets
ls /run/user/$(id -u)/teru-mcp-*.sock 2>/dev/null
```

## MCP Socket Communication

Two socket layers — use the right one:

### Terminal MCP (`teru-mcp-$PID.sock`)
Controls panes WITHIN a single teru terminal window.
```python
python3 -c "
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect('SOCKET_PATH')
msg = json.dumps({'jsonrpc':'2.0','method':'tools/call','params':{'name':'TOOL','arguments':ARGS},'id':1})
sock.sendall(msg.encode() + b'\n')
sock.settimeout(5)
print(sock.recv(4096).decode())
sock.close()
"
```

**Terminal tools:** `teru_list_panes`, `teru_read_output`, `teru_send_input`, `teru_create_pane`, `teru_close_pane`, `teru_focus_pane`, `teru_switch_workspace`, `teru_set_layout`, `teru_set_config`, `teru_get_config`, `teru_screenshot`, `teru_scroll`, `teru_send_keys`, `teru_session_save`, `teru_session_restore`

### Compositor MCP (`teru-wmmcp-$PID.sock`)
Controls the window manager itself — windows, workspaces, global settings.

**Compositor tools:** `teruwm_list_windows`, `teruwm_spawn_terminal`, `teruwm_close_window`, `teruwm_focus_window`, `teruwm_move_to_workspace`, `teruwm_list_workspaces`, `teruwm_switch_workspace`, `teruwm_set_layout`, `teruwm_get_config`, `teruwm_set_config`, `teruwm_screenshot`, `teruwm_notify`, `teruwm_reload_config`

## Common Operations

### Take a screenshot
```python
# Terminal framebuffer (one pane's rendered output)
teru_screenshot(path="/tmp/screenshot.png")

# Full compositor output (requires grim + wlr-screencopy)
teruwm_screenshot(path="/tmp/compositor.png")
```

### Switch layout
```python
# Via terminal MCP (affects teru's internal multiplexer)
teru_set_layout(layout="grid", workspace=0)

# Via compositor MCP (affects teruwm window tiling)
teruwm_set_layout(layout="master-stack", workspace=0)
```

Layouts: `master-stack`, `grid`, `monocle`, `dishes`, `spiral`, `three-col`, `columns`, `accordion`

### Spawn a terminal
```python
teruwm_spawn_terminal(workspace=0)
```

### Change gap live
```python
teruwm_set_config(key="gap", value="8")
```

### Reload config from disk
```python
teruwm_reload_config()
# Or press Mod+Shift+R
```

### Restart compositor (preserves shells)
Press compositor restart keybind, or:
```python
# Saves PTY fds, exec()s new binary, shells survive
# This is like xmonad --restart
```

## Diagnostics

### Performance issues
1. Check if render is throttled: dirty tracking should limit renders to vsync (60fps)
2. Large framebuffers (2560x1600 = 4M pixels) are CPU-intensive
3. Streaming output (claude-code) should NOT trigger per-byte renders

### Gap issues
- Gaps should be uniform: same between panes and between panes and edges
- Pre-inset screen rect by `gap/2`, then each pane inset by `gap/2` = `gap` everywhere
- If gaps look wrong, check `arrangeworkspace()` and `arrangeWorkspaceSmooth()`

### Scroll not working
- Mouse wheel: handled by `cursor_axis` listener in Server.zig
- Keyboard: scroll actions in `executeAction()` 
- Check `focused_terminal` is set correctly

### Bar missing
- Top bar: enabled by default
- Bottom bar: enabled by default with `{mem}` and `{clock}`
- Check `bar.configure()` called after config load
- `Mod+B` toggles top bar, `Mod+Shift+B` toggles bottom bar

## Build & Test

```bash
zig build -Dcompositor=true          # debug build
zig build -Dcompositor=true -Doptimize=ReleaseSafe  # release
zig build test                        # run all tests
```

## Key Files

| File | Purpose |
|------|---------|
| `src/compositor/Server.zig` | Core compositor: tiling, input, keybinds |
| `src/compositor/TerminalPane.zig` | Terminal pane rendering + PTY integration |
| `src/compositor/Output.zig` | Per-output frame callback (vsync render) |
| `src/compositor/WmMcpServer.zig` | Compositor MCP server |
| `src/compositor/Bar.zig` | Status bars (top/bottom) |
| `src/compositor/WmConfig.zig` | ~/.config/teruwm/config parser |
| `src/compositor/main.zig` | Entry point, --restore for restart |
| `src/tiling/layouts.zig` | 8 layout algorithms |
