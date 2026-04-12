# MCP API reference

teru exposes two independent Model Context Protocol (MCP) servers.
Both speak JSON-RPC 2.0 over a Unix socket (or Windows named pipe).

| Server | Socket | Tools | Purpose |
|---|---|---:|---|
| **teru agent** | `$XDG_RUNTIME_DIR/teru-mcp-$PID.sock` | 19 | Control any running teru instance — panes, workspaces, scrollback, sessions, broadcast, config live-edit |
| **teruwm compositor** | `$XDG_RUNTIME_DIR/teru-wmmcp-$PID.sock` | 24 | Control the Wayland compositor — windows (terminal + XDG), workspaces, layouts, bars, push widgets, hot-restart, E2E test hooks |

If you write a daemon that needs to push data to the bar, you want the
compositor server. If you want an AI agent to read another pane's output
or type into it, you want the agent server. They can be used together;
they're completely separate processes.

**Why two.** The agent MCP lives inside the teru process (one socket per
terminal/daemon). The compositor MCP lives inside teruwm. A machine can
have many teru terminals (each with its own agent MCP) and at most one
teruwm (one compositor-wide MCP).

## Protocol

Every call is a single JSON-RPC 2.0 request/response. HTTP framing with
`Content-Length` is used for chunking:

```
POST / HTTP/1.1
Content-Length: 74

{"jsonrpc":"2.0","method":"tools/call","params":{"name":"teru_list_panes"},"id":1}
```

Connections are short-lived (`Connection: close`). No session, no auth
beyond filesystem permissions on the socket (which is `0700` under
`/run/user/$UID/`).

Responses wrap the tool output:

```json
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"[{…}]"}]},"id":1}
```

Most tools that return structured data double-encode JSON into the
`text` field (MCP spec). Your client unwraps with `json.loads` twice.

### Minimal Python client

```python
import json, socket

def mcp(sock_path, tool, args=None):
    params = {"name": tool}
    if args: params["arguments"] = args
    body = json.dumps({"jsonrpc":"2.0","method":"tools/call","params":params,"id":1},
                      separators=(",", ":"))
    req = f"POST / HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n{body}"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path); s.sendall(req.encode())
    data = b""
    while True:
        c = s.recv(65536)
        if not c: break
        data += c
    s.close()
    body = data.decode().split("\r\n\r\n", 1)[1]
    j = json.loads(body)
    if "error" in j: raise RuntimeError(j["error"]["message"])
    text = j["result"]["content"][0]["text"]
    try: return json.loads(text)
    except json.JSONDecodeError:
        try: return json.loads(text.replace('\\"', '"'))
        except: return text

print(mcp("/run/user/1000/teru-wmmcp-12345.sock", "teruwm_list_windows"))
```

## teru (terminal) MCP — 19 tools

Socket: `$XDG_RUNTIME_DIR/teru-mcp-$PID.sock`. Implementation: `src/agent/McpServer.zig`.

### Panes

| Tool | Params | Description |
|---|---|---|
| `teru_list_panes` | — | Every pane's `id`, `workspace`, agent metadata, status. |
| `teru_focus_pane` | `pane_id` | Switch focus to pane. |
| `teru_close_pane` | `pane_id` | Close pane by id. |
| `teru_create_pane` | `workspace` (int, default 0), `direction` (`vertical`/`horizontal`), `command` (string), `cwd` (string) | Spawn new pane in workspace. |
| `teru_read_output` | `pane_id`, `lines` (int, default 50) | Get the last N lines of scrollback as plain text. |
| `teru_send_input` | `pane_id`, `text` | Write `text` to the pane's PTY stdin. |
| `teru_send_keys` | `pane_id`, `keys` (array of named keys: `"enter"`, `"ctrl+c"`, `"up"`, etc.) | Dispatch keystrokes as if typed. |
| `teru_broadcast` | `workspace`, `text` | Send `text` to every pane in the workspace. |
| `teru_wait_for` | `pane_id`, `pattern` (string), `lines` (int, default 20) | Return whether `pattern` appears in the last N lines. Non-blocking. |
| `teru_get_state` | `pane_id` | Query terminal state — cursor position, grid size, alt screen, title. |
| `teru_scroll` | `pane_id`, `direction` (`up`/`down`/`bottom`), `lines` (int, default 10) | Scroll the pane's scrollback. |

### Workspaces & layouts

| Tool | Params | Description |
|---|---|---|
| `teru_switch_workspace` | `workspace` (0..9) | Switch the active workspace. |
| `teru_set_layout` | `workspace`, `layout` (enum: see below) | Set workspace layout. |

Layouts: `master-stack`, `grid`, `monocle`, `dishes`, `spiral`, `three-col`,
`columns`, `accordion`.

### Process graph

| Tool | Params | Description |
|---|---|---|
| `teru_get_graph` | — | Full process DAG (nodes, edges, agent metadata). |

### Config

| Tool | Params | Description |
|---|---|---|
| `teru_get_config` | — | Current live config as JSON. |
| `teru_set_config` | `key`, `value` | Set a config key; writes to `teru.conf` and triggers hot-reload. |

### Sessions

| Tool | Params | Description |
|---|---|---|
| `teru_session_save` | `name` | Save current session to `~/.config/teru/sessions/<name>.tsess`. |
| `teru_session_restore` | `name` | Restore session from `.tsess`. Idempotent. |

### Screenshots

| Tool | Params | Description |
|---|---|---|
| `teru_screenshot` | `path` (string, default `/tmp/teru-screenshot.png`) | Capture current framebuffer as PNG. X11/Wayland only. |

## teruwm (compositor) MCP — 24 tools

Socket: `$XDG_RUNTIME_DIR/teru-wmmcp-$PID.sock`. Implementation: `src/compositor/WmMcpServer.zig`.

### Windows

| Tool | Params | Description |
|---|---|---|
| `teruwm_list_windows` | — | All managed windows — terminal panes AND XDG/XWayland clients — with `id`, `workspace`, `kind` (`terminal`/`wayland`), `title`, `x`, `y`, `w`, `h`. |
| `teruwm_spawn_terminal` | `workspace` (int, default 0) | Spawn a new terminal pane. |
| `teruwm_close_window` | `node_id` | Close window by id (works for both terminal panes and XDG clients). |
| `teruwm_focus_window` | `node_id` | Focus a specific window. |
| `teruwm_move_to_workspace` | `node_id`, `workspace` | Move window between workspaces. |
| `teruwm_set_name` | `node_id`, `new_name` (string) | Assign a human-readable name to a window. |

### Workspaces & layouts

| Tool | Params | Description |
|---|---|---|
| `teruwm_list_workspaces` | — | 10 workspaces with `id`, `layout`, `windows` (count), `active` (bool). |
| `teruwm_switch_workspace` | `workspace` (0..9) | Switch the visible workspace. |
| `teruwm_set_layout` | `workspace`, `layout` | Set a workspace's tiling layout. |

### Bars

| Tool | Params | Description |
|---|---|---|
| `teruwm_toggle_bar` | `which` (`top`/`bottom`) | Toggle visibility of top or bottom status bar. |
| `teruwm_set_bar` | `which`, `enabled` (bool) | Explicit on/off instead of toggle. |

### Push widgets

| Tool | Params | Description |
|---|---|---|
| `teruwm_set_widget` | `name` (≤32 chars), `text` (≤128 chars), `class` (enum: `none`/`muted`/`info`/`success`/`warning`/`critical`/`accent`, default `none`) | Register or update a push widget. Idempotent upsert. Referenced in bar format strings as `{widget:name}`. |
| `teruwm_delete_widget` | `name` | Remove a push widget. |
| `teruwm_list_widgets` | — | Currently-registered widgets with `text`, `class`, `age_ms`. |

### Config

| Tool | Params | Description |
|---|---|---|
| `teruwm_get_config` | — | Current config as JSON: `gap`, `border_width`, `bg_color`, `cell_width`, `cell_height`, `bar_height`, `output_width`, `output_height`, `top_bar`, `bottom_bar`, `terminal_count`, `active_workspace`. |
| `teruwm_set_config` | `key` (`gap`/`border_width`/`bg_color`), `value` | Set a config key live. `bg_color` accepts `#rrggbb` or `0xaarrggbb`. |
| `teruwm_reload_config` | — | Re-read `~/.config/teruwm/config` and apply. |

### Introspection & control

| Tool | Params | Description |
|---|---|---|
| `teruwm_perf` | — | Frame timing stats: `frames`, `avg_us`, `max_us`, `min_us`, `pty_reads`, `pty_bytes`, `terminals`. |
| `teruwm_notify` | `message` | Show a notification overlay. |
| `teruwm_restart` | — | Hot-restart: serialize PTY fds, `exec()` the current binary. Shells survive. Use after rebuild. |

### Screenshots

| Tool | Params | Description |
|---|---|---|
| `teruwm_screenshot` | `path` (string, default `/tmp/teruwm-screenshot.png`) | Capture full compositor output as PNG. |
| `teruwm_screenshot_pane` | `name` (string) OR `node_id` (int); `path` (default `/tmp/teruwm-pane-<name>.png`) | Capture one pane's framebuffer as PNG. Terminal panes only. |

### E2E test hooks (normally not used)

| Tool | Params | Description |
|---|---|---|
| `teruwm_test_drag` | `from_x`, `from_y`, `to_x`, `to_y`, `super` (bool, default false), `button` (int, default 272=BTN_LEFT) | Synthesize a pointer drag. Used by the E2E test suite to verify Mod+drag-to-float, resize handles, etc. |
| `teruwm_test_key` | `action` (string, e.g. `layout_cycle`) | Dispatch a `Keybinds.Action` by name through the compositor's action handler, bypassing xkb. For testing keybind actions from scripts. |

## Writing a push-widget daemon

Push widgets are teruwm's event-driven alternative to polling `{exec:N:cmd}`.
Example: an MPRIS listener that pushes "now playing" only when the song
changes.

```python
# ~/.local/bin/teruwm-mpris-widget
import dbus, dbus.mainloop.glib, glib, json, socket

SOCK = "/run/user/1000/" + next(f for f in os.listdir("/run/user/1000")
                                if f.startswith("teru-wmmcp-"))

def push(name, text, cls="none"):
    body = json.dumps({"jsonrpc":"2.0","method":"tools/call","params":{
        "name":"teruwm_set_widget",
        "arguments":{"name":name,"text":text,"class":cls}},"id":1},
        separators=(",", ":"))
    req = f"POST / HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n{body}"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK); s.sendall(req.encode()); s.close()

def on_properties_changed(_iface, changed, _inv):
    meta = changed.get("Metadata", {})
    status = changed.get("PlaybackStatus", "")
    title = meta.get("xesam:title", "")
    cls = "success" if status == "Playing" else "muted"
    push("mpris", title, cls)

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()
proxy = bus.get_object("org.mpris.MediaPlayer2.playerctld", "/org/mpris/MediaPlayer2")
proxy.connect_to_signal("PropertiesChanged", on_properties_changed,
                        dbus_interface="org.freedesktop.DBus.Properties")
glib.MainLoop().run()
```

Then in `~/.config/teruwm/config`:

```ini
[bar.top]
right = {widget:mpris} | {battery} {watts} | {clock}
```

Start the daemon at login (systemd user unit, sway-style autostart, or
just `&` in `.xprofile`). If teruwm hot-restarts or the daemon crashes,
widgets become empty until re-registered — idempotent upsert means the
daemon just calls `teruwm_set_widget` again.

## E2E scripting

The compositor MCP plus the test-only `teruwm_test_drag` and
`teruwm_test_key` tools let you drive teruwm entirely from a Python
test harness. The suite in this repo lives at `/tmp/teruwm-full-e2e.py`
and covers every tool.

```python
# Simulate Mod+drag on the pane at (1000, 500), move it +200/+150:
mcp(SOCK, "teruwm_test_drag", {
    "from_x": 1000, "from_y": 500,
    "to_x":   1200, "to_y":   650,
    "super":  True,
})
# Then read back:
wins = mcp(SOCK, "teruwm_list_windows")
```

## Connecting from Claude Code

```jsonc
// ~/.config/claude/mcp-servers.json
{
  "mcpServers": {
    "teru": {
      "command": "socat",
      "args": ["UNIX-CONNECT:/run/user/1000/teru-mcp-PID.sock", "STDIO"]
    },
    "teruwm": {
      "command": "socat",
      "args": ["UNIX-CONNECT:/run/user/1000/teru-wmmcp-PID.sock", "STDIO"]
    }
  }
}
```

Replace `PID` with the running process ID — or use `$(pgrep teru)` /
`$(pgrep teruwm)` in a wrapper script.

---

For discussion of the broader MCP-driven architecture, see
[AI-INTEGRATION.md](AI-INTEGRATION.md). For protocol-level details of
the process-graph and OSC 9999 agent sequences, see the same doc.
