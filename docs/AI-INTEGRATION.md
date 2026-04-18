# AI integration

teru ships three mechanisms that let AI agents, external daemons, and
automation scripts drive a terminal or a whole Wayland session without
screen scraping or synthetic input. Each layer is self-contained — pick
the one that matches your use case.

For the full tool-by-tool reference (inputs, outputs, examples) see
[MCP-API.md](MCP-API.md).

## Overview

| Layer | What it's for | Protocol | File |
|---|---|---|---|
| **teru MCP** (19 tools) | Script a running terminal: panes, scrollback, sessions, broadcast, config live-edit | JSON-RPC 2.0 over Unix socket | `src/agent/McpServer.zig` |
| **teruwm MCP** (24 tools) | Script a running compositor: windows, workspaces, bars, push widgets, hot-restart | JSON-RPC 2.0 over Unix socket | `src/compositor/WmMcpServer.zig` |
| **CustomPaneBackend** | Let Claude Code spawn/manage panes natively (no tmux) | 7-op JSON-RPC | `src/agent/PaneBackend.zig` |
| **OSC 9999** | Let any running process declare itself an AI agent (border color, status bar) | VT escape sequences | `src/agent/protocol.zig` |

## 1. Claude Code — CustomPaneBackend

When teru starts, it exports `CLAUDE_PANE_BACKEND_SOCKET` into the
environment. Claude Code detects this and uses teru's native pane
management — spawn an agent team and the panes appear in teru's tiling
layout, with the right workspace, with process-graph metadata. No
configuration, no tmux glue.

7 JSON-RPC methods over the backend socket:

| Method | Description |
|---|---|
| `spawn` | Create a pane with argv, env, cwd, and group metadata |
| `resize` | Resize a pane |
| `write` | Write to pane stdin |
| `read` | Read pane stdout |
| `close` | Close a pane |
| `list` | List all backend-owned panes |
| `status` | Per-pane status (running / exited / signaled) |

Pane borders color-code by status: cyan = running, green = done,
red = failed. Status-bar shows agent counts.

## 2. teru MCP — script a terminal

19 tools. Socket `$XDG_RUNTIME_DIR/teru-mcp-$PID.sock`.

Use when you want to read another pane's scrollback, type into a pane,
ask "is the build done yet?", move a pane between workspaces, or save a
session to a `.tsess` template.

Minimal Claude Code / Cursor hookup (uses the built-in stdio adapters
— no PID juggling, no socat):

```jsonc
// ~/.config/claude-code/mcp.json, ~/.cursor/mcp.json, or .mcp.json
{
  "mcpServers": {
    "teru":   { "command": "teru",      "args": ["--mcp-server"] },
    "teruwm": { "command": "teruwmctl", "args": ["--mcp-stdio"] }
  }
}
```

`teru --mcp-server` discovers `teru-mcp-*.sock` in `$XDG_RUNTIME_DIR`
(or pin via `TERU_MCP_SOCKET`). `teruwmctl --mcp-stdio` discovers
`teruwm-mcp-*.sock` (or pin via `TERUWM_MCP_SOCKET`). Either end
tolerates the target being down — the first tool call returns a clean
JSON-RPC error instead of hanging.

Every tool documented with params and behavior in
[MCP-API.md](MCP-API.md#teru-terminal-mcp--19-tools). Categories:

- **Panes**: list / create / close / focus / read / send_input / send_keys / wait_for / scroll / get_state / broadcast
- **Workspaces & layouts**: switch_workspace / set_layout
- **Process graph**: get_graph
- **Config**: get_config / set_config  *(writes `teru.conf` and hot-reloads)*
- **Sessions**: session_save / session_restore
- **Screenshots**: screenshot

## 3. teruwm MCP — script the compositor

24 tools. Socket `$XDG_RUNTIME_DIR/teruwm-mcp-$PID.sock`. Separate
process, separate socket.

Use when you want to spawn windows, switch workspaces, change layouts,
toggle bars, push widgets to the status bar, take screenshots, or
trigger a hot-restart.

See [MCP-API.md](MCP-API.md#teruwm-compositor-mcp--24-tools). Categories:

- **Windows**: list_windows / spawn_terminal / close_window / focus_window / move_to_workspace / set_name
- **Workspaces & layouts**: list_workspaces / switch_workspace / set_layout
- **Bars**: toggle_bar / set_bar
- **Push widgets**: set_widget / delete_widget / list_widgets
- **Config**: get_config / set_config / reload_config
- **Introspection / control**: perf / notify / restart
- **Screenshots**: screenshot / screenshot_pane
- **E2E test hooks**: test_drag / test_key  *(use in tests, not production)*

## Push widgets — event-driven status bar content

The compositor bar normally uses polling widgets (`{clock}`, `{cpu}`,
`{exec:5:cmd}`). For event-driven data (MPRIS songs, IRC mentions, CI
status, build progress) polling wastes wake-ups. Push widgets let an
external daemon `teruwm_set_widget` into a named slot; the bar reads it
on next render.

### Bar config

Reference the widget in your bar format string:

```ini
# ~/.config/teruwm/config
[bar.top]
right = {widget:mpris} | {battery} {watts} | {clock}

[bar.bottom]
left  = {widget:build} | CPU {cpu} {cputemp} | RAM {mem}
```

Missing widgets render as empty string. Class-based coloring (`muted`,
`info`, `success`, `warning`, `critical`, `accent`) maps to the theme
palette — switch themes, the colors follow.

### Example daemon — build status pushed by Claude Code

```python
#!/usr/bin/env python3
import glob, json, os, socket, subprocess, sys

SOCK = glob.glob("/run/user/1000/teruwm-mcp-*.sock")[0]

def push(name, text, cls="none"):
    body = json.dumps({"jsonrpc":"2.0","method":"tools/call","params":{
        "name":"teruwm_set_widget",
        "arguments":{"name":name,"text":text,"class":cls}},"id":1},
        separators=(",", ":"))
    req = f"POST / HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n{body}"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK); s.sendall(req.encode()); s.close()

# Invoke from a makefile, CI hook, or Claude Code tool call:
push("build", sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "none")
```

```sh
# Usage
push-build "building 72%" warning
push-build "green" success
push-build "failed: tests" critical
```

### Lifecycle

Push widgets are **transient state**. They die on compositor hot-restart
and whenever the compositor process exits. Daemons should:

1. Call `teruwm_set_widget` idempotently — calling it again with the
   same name is a no-op-equivalent upsert.
2. Re-register on reconnect if the call fails (socket missing: the
   compositor isn't running; socket exists but call fails: try again).
3. Not worry about cleanup — `teruwm_delete_widget` is for removing a
   widget you don't want anymore, not for shutdown.

## 4. OSC 9999 — agents self-declare

Any process can claim "I am an AI agent" to any teru terminal (or teruwm
pane) by writing VT escape sequences to stdout. teru's VtParser
recognizes them, teruwm does too via the shared libteru.

```bash
# Declare start
printf '\e]9999;agent:start;name=backend-dev;group=team-temporal\a'

# Progress update
printf '\e]9999;agent:status;progress=0.6;task=Building API\a'

# Done
printf '\e]9999;agent:stop;exit=success\a'
```

Effects:
- Pane border colors by status (cyan running, green done, red failed).
- `ProcessGraph` records the agent with its metadata.
- Status bar's `{panes}` count includes agent count.
- The `teru_get_graph` MCP tool returns the full DAG.

Fields:

| Key | Meaning |
|---|---|
| `name` | Agent identifier (free-form) |
| `group` | Team / group name (for batch operations) |
| `progress` | Float 0.0 – 1.0 |
| `task` | Current task description |
| `exit` | `success`, `failure`, or a free-form error message |

## In-band MCP over OSC 9999

*(Since v0.4.14.)* An agent running **inside a teru pane** can call MCP
tools through the PTY teru is already parsing — **no socket, no
subprocess, no extra process hop**. The same mechanism every terminal
already uses to answer `ESC[6n` (cursor-position report), just with a
wider vocabulary.

```
Request (agent stdout):
  ESC ] 9999 ; query ; id=<N> ; tool=<NAME> [ ; k=v ]* BEL

Reply (teru → agent stdin):
  ESC P 9999 ; id=<N> ; <json-body> ESC \
```

`ST` can be `BEL` (`\x07`) or `ESC \`. Arguments are flat `key=value`
pairs; integer-typed values are forwarded as JSON numbers, bare
`true`/`false` as booleans, everything else as escaped strings. For
complex inputs (arrays, nested objects) use the socket path instead.

### The `teru-query` shell helper

```sh
teru-query teru_list_panes
teru-query teru_read_output pane_id=1 lines=30
teru-query teru_broadcast workspace=0 text='hello agents'
```

Under the hood: writes the OSC request to `/dev/tty`, reads the DCS
reply, extracts the JSON body, prints to stdout. `~/.local/bin/teru-query`
or `tools/teru-query` from this repo.

### Shell one-liner (no helper)

```sh
printf '\e]9999;query;id=1;tool=teru_list_panes\x07' > /dev/tty
# then read reply from /dev/tty, strip DCS envelope ESC P 9999;id=1; ... ESC \
```

### Why this exists

- **Zero-process** inside the compositor/daemon. One PTY write, one
  McpServer.dispatch, one PTY write back.
- **Works in every mode** teru supports — windowed, `--raw` over SSH,
  inside a `--daemon` session — because it's just bytes on the PTY.
- **No auth surface.** The PTY is already the trust boundary; only teru
  has the master fd.

### Current scope

Tools exposed: all 45 tools. As of v0.4.19, teru's MCP transparently
forwards `teruwm_*` tool calls to the running teruwm socket. Agents
running inside a teru pane under teruwm can use the same `teru-query`
helper for compositor control:

```sh
teru-query teru_list_panes              # local to this teru
teru-query teruwm_list_windows          # forwarded to teruwm
teru-query teruwm_focus_window node_id=5
teru-query teruwm_scratchpad name=notes
```

If no teruwm is running, `teruwm_*` calls come back with JSON-RPC
error code `-32002`. Local `teru_*` calls work regardless.

## Session persistence — `.tsess` templates

`.tsess` files are declarative session layouts: workspaces, panes,
commands, working dirs. They give deterministic multi-workspace setups
that Claude Code can invoke, or that you can commit to your dotfiles.

```ini
# ~/.config/teru/templates/claude-power.tsess
[session]
name = claude-power
description = Multi-agent Claude Code workspace

[workspace.1]
name = code
layout = master-stack
master_ratio = 0.6

[workspace.1.pane.1]
command = nvim .

[workspace.1.pane.2]
command = fish

[workspace.2]
name = agents
layout = grid

[workspace.2.pane.1]
command = claude --agent backend
[workspace.2.pane.2]
command = claude --agent frontend
[workspace.2.pane.3]
command = claude --agent tests
```

Apply:

```bash
teru -n proj -t claude-power      # first run: applies template. subsequent: reattaches.
```

Export live state:

```sh
# From any MCP client
mcp teru_session_save name=proj
# Writes ~/.config/teru/sessions/proj.tsess
```

Templates live in `~/.config/teru/templates/` then `./examples/`. See
`examples/claude-power.tsess` for a 10-workspace 34-pane example.

## Pattern summary — when to use what

| If you want to… | Use |
|---|---|
| Spawn a pane with a specific command and read its output from another agent | teru MCP (`teru_create_pane` + `teru_read_output`) |
| Watch for build completion from a CI daemon | teru MCP (`teru_wait_for`) |
| Show live status text in the top bar, event-driven | teruwm push widget (`teruwm_set_widget`) |
| Let Claude Code manage agent panes without tmux | CustomPaneBackend (automatic; just `export CLAUDE_PANE_BACKEND_SOCKET=$teru_socket`) |
| Tell the terminal "I'm an agent, here's my progress" from a shell script | OSC 9999 escape sequences |
| Open a browser on workspace 3, focus it, screenshot | teruwm MCP (`spawn_terminal` into a workspace, `screenshot`) |
| Reload your compositor after a rebuild without losing shell state | teruwm MCP (`teruwm_restart`) |
| Save / restore a multi-workspace agent team | `.tsess` template + `teru_session_restore` |

For the full protocol details and code samples, go to
[MCP-API.md](MCP-API.md).
