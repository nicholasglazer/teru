# MCP API reference

teru exposes two independent Model Context Protocol (MCP) servers.
Both speak JSON-RPC 2.0 over a Unix socket (or Windows named pipe).

| Server | Socket | Tools | Purpose |
|---|---|---:|---|
| **teru agent** | `$XDG_RUNTIME_DIR/teru-mcp-$PID.sock` | 19 | Control any running teru instance — panes, workspaces, scrollback, sessions, broadcast, config live-edit |
| **teruwm compositor** | `$XDG_RUNTIME_DIR/teru-wmmcp-$PID.sock` | 26 | Control the Wayland compositor — windows (terminal + XDG), workspaces, layouts, bars, push widgets, named scratchpads (v0.4.18), event push stream, hot-restart, E2E test hooks |

If you write a daemon that needs to push data to the bar, you want the
compositor server. If you want an AI agent to read another pane's output
or type into it, you want the agent server. They can be used together;
they're completely separate processes.

**Why two.** The agent MCP lives inside the teru process (one socket per
terminal/daemon). The compositor MCP lives inside teruwm. A machine can
have many teru terminals (each with its own agent MCP) and at most one
teruwm (one compositor-wide MCP).

## Protocol

Every call is a single JSON-RPC 2.0 request/response. The two servers
use different transports on the wire — same JSON-RPC envelope, different
framing:

| Server | Transport | Request shape |
|---|---|---|
| **teru agent** | Line-delimited JSON-RPC (since v0.4.14) | `<json>\n` |
| **teruwm compositor** | HTTP-framed JSON-RPC | `POST / HTTP/1.1\r\nContent-Length: N\r\n\r\n<json>` |

Connections are short-lived. No session, no auth beyond filesystem
permissions on the socket (`0700` under `/run/user/$UID/`).

Responses wrap the tool output:

```json
{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"[{…}]"}]},"id":1}
```

Most tools that return structured data double-encode JSON into the
`text` field (MCP spec). Your client unwraps with `json.loads` twice.

### Calling the teru agent MCP (line-delimited JSON)

```python
import json, socket

def teru_mcp(sock_path, tool, args=None):
    params = {"name": tool}
    if args: params["arguments"] = args
    body = json.dumps({"jsonrpc":"2.0","method":"tools/call","params":params,"id":1})
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path); s.sendall((body + "\n").encode())
    resp = b""
    while True:
        c = s.recv(65536)
        if not c: break
        resp += c
    s.close()
    j = json.loads(resp.decode().rstrip())
    if "error" in j: raise RuntimeError(j["error"]["message"])
    text = j["result"]["content"][0]["text"]
    try: return json.loads(text)
    except json.JSONDecodeError: return text

print(teru_mcp("/run/user/1000/teru-mcp-12345.sock", "teru_list_panes"))
```

### Calling the teruwm compositor MCP (HTTP-framed)

```python
import json, socket

def teruwm_mcp(sock_path, tool, args=None):
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

print(teruwm_mcp("/run/user/1000/teru-wmmcp-12345.sock", "teruwm_list_windows"))
```

### Alternative transport: stdio proxy (`teru --mcp-server`)

For clients that speak MCP-stdio (Claude Code, Cursor, anything following
the MCP SDK's stdio convention), run `teru --mcp-server` as a subprocess.
It proxies stdin/stdout line-JSON to a running teru's socket. The legacy
flag `--mcp-bridge` is kept as an alias for older `.mcp.json` files.

### Unified event subscription (v0.4.21)

Both servers push newline-delimited JSON events on companion sockets.
`teru_subscribe_events` (on the teru side) returns a single
`{teru, teruwm}` object with both paths — agents connect once and
read from both. `teruwm_subscribe_events` (on the teruwm side)
returns just teruwm's path.

```sh
$ teru-query teru_subscribe_events
{"teru":"/run/user/1000/teru-mcp-events-12345.sock",
 "teruwm":"/run/user/1000/teru-wmmcp-events-67890.sock"}
```

Minimum consumer:

```python
import json, os, select, socket

paths = call_mcp("teru_subscribe_events")
sockets = []
for key in ("teru", "teruwm"):
    path = paths.get(key)
    if not path: continue
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.setblocking(False)
    sockets.append((key, s))

# Multiplex both channels.
bufs = {s.fileno(): b"" for _, s in sockets}
fdmap = {s.fileno(): (label, s) for label, s in sockets}
while True:
    ready, _, _ = select.select(list(fdmap), [], [])
    for fd in ready:
        label, s = fdmap[fd]
        data = s.recv(65536)
        if not data:
            del fdmap[fd]; continue
        bufs[fd] += data
        while b"\n" in bufs[fd]:
            line, _, bufs[fd] = bufs[fd].partition(b"\n")
            ev = json.loads(line)
            ev["_source"] = label
            handle(ev)
```

Override discovery with `TERU_WMMCP_EVENTS_SOCKET`. Events are
best-effort (O_NONBLOCK on the server side); slow consumers drop.

### Cross-MCP forwarding (v0.4.19)

Since v0.4.19, **teru's MCP transparently forwards `teruwm_*` tools**
to the running teruwm compositor's socket. Agents see one unified
45-tool surface regardless of which binary they're connected to:

```
agent ──→ teru-mcp-$PID.sock
           │
           ├── teru_list_panes     (local dispatch)
           ├── teru_send_input     (local)
           │     …
           └── teruwm_list_windows ──forward──→ teru-wmmcp-*.sock
                                                 │
                                                 └── compositor handles
```

The forwarding is transparent at every transport: the line-JSON
socket, the `--mcp-server` stdio proxy, and the in-band OSC 9999
path (below) all get the same unified surface. Set
`TERU_WMMCP_SOCKET=/path/to/sock` to pin a specific teruwm instance
when multiple run on the same host.

`tools/list` today returns only teru's 19 tools — the forwarded
tools aren't merged into the listing. Clients that want the full
surface should also query teruwm's socket directly for its
`tools/list`, or rely on documentation (this file). Unified
`tools/list` across servers is a future enhancement.

If no teruwm is running, a `teruwm_*` call returns error code
`-32002` with message "teruwm not running or socket unreachable" —
callers can treat that as "WM not present, skip." Local `teru_*`
calls are unaffected.

### Alternative transport: in-band OSC 9999 (inside a teru pane)

An agent running *inside* a teru pane can call tools through the PTY it's
already connected to — no socket, no subprocess. Request is OSC 9999,
reply is DCS 9999:

```
Request:  ESC ] 9999 ; query ; id=<N> ; tool=<NAME> [ ; k=v ]* ST
Reply:    ESC P 9999 ; id=<N> ; <json-body> ESC \
```

Use the `tools/teru-query` helper:

```sh
teru-query teru_list_panes
teru-query teru_read_output pane_id=1 lines=30
```

Teruwm tool forwarding over the in-band path is planned for a later
release — today, `teruwm_*` tools must still go through the compositor
socket. See [AI-INTEGRATION.md](AI-INTEGRATION.md#in-band-mcp-over-osc-9999)
for the full protocol spec.

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

## teruwm (compositor) MCP — 28 tools

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

### Scratchpads (v0.4.18)

| Tool | Params | Description |
|---|---|---|
| `teruwm_scratchpad` | `name` (string, max 15 chars), `cmd` (string, reserved) | Toggle a named scratchpad using xmonad's NamedScratchpad semantics. First call spawns a floating terminal tagged with `name`; subsequent calls flip visibility. If called while the pad is on a non-active workspace, migrates to the focused one (follow-me). |
| `teruwm_toggle_scratchpad` | `index` (int 0..8) | **Compat shim** — delegates to `teruwm_scratchpad` with name=`pad<N+1>`. Prefer the named form. |

### Event push stream (v0.4.18)

| Tool | Params | Description |
|---|---|---|
| `teruwm_subscribe_events` | — | Returns the Unix-socket path of the event push channel. Connect raw to that path to receive newline-delimited JSON events. One subscriber at a time (last-connect wins). |

Emitted events (non-exhaustive):

```json
{"event":"urgent",            "node_id":42, "workspace":3}
{"event":"focus_changed",     "node_id":42}
{"event":"workspace_switched","from":0, "to":3}
{"event":"window_mapped",     "node_id":42, "workspace":3}
```

Shape: every event is a single JSON object terminated by `\n`.
Callers parse line-by-line. Slow subscribers drop events silently
(the channel is O_NONBLOCK on the server side). Typical use:

```python
import json, os, socket

path = json.loads(call_mcp("teruwm_subscribe_events"))["socket"]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(path)
f = s.makefile("rb")
for line in f:
    ev = json.loads(line)
    if ev["event"] == "urgent":
        os.system(f"notify-send 'window {ev[\"node_id\"]} wants attention'")
```

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
