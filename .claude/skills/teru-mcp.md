---
name: teru-mcp
description: Use teru's MCP tools to create/manage panes, send commands, and orchestrate multi-agent workflows. Use when working with multiple panes or agent teams.
---

# teru MCP — Terminal Pane Control

teru exposes an MCP server over Unix socket for full terminal control.
Socket: `/run/user/$UID/teru-$PID.sock` (HTTP JSON-RPC 2.0)

## Available Tools

### teru_list_panes
List all panes with their ID, workspace, status, and dimensions.

### teru_create_pane
Create a new pane with split direction.
```json
{"workspace": 0, "direction": "vertical", "command": "fish", "cwd": "/path/to/dir"}
```
- `direction`: `"vertical"` (side-by-side) or `"horizontal"` (top/bottom)
- `command`: optional, defaults to user's shell
- `cwd`: optional, defaults to active pane's CWD (reads `/proc/<pid>/cwd`)
- New panes inherit the active pane's working directory by default

### teru_send_input
Type text into a pane's PTY. Use for typing commands.
```json
{"pane_id": 2, "text": "echo hello"}
```
**Important**: `\n` is unescaped to newline. For shell commands, append `\n`.
For Claude Code input, use `teru_send_keys` with `["enter"]` instead.

### teru_send_keys
Send named keystrokes. Use for Enter, Ctrl+C, arrow keys, etc.
```json
{"pane_id": 2, "keys": ["enter"]}
{"pane_id": 2, "keys": ["ctrl+c"]}
{"pane_id": 2, "keys": ["up", "enter"]}
```
Supported keys: `enter`, `tab`, `escape`, `backspace`, `delete`,
`up`, `down`, `left`, `right`, `home`, `end`, `page_up`, `page_down`,
`f1`-`f12`, `ctrl+a`-`ctrl+z`

### teru_read_output
Read recent lines from a pane's grid.
```json
{"pane_id": 2, "lines": 10}
```

### teru_focus_pane
Switch focus to a specific pane by ID.
```json
{"pane_id": 2}
```

### teru_close_pane
Close a pane by ID.
```json
{"pane_id": 2}
```

### teru_broadcast
Send text to all panes in a workspace.
```json
{"workspace": 0, "text": "exit\n"}
```

### teru_set_layout
Set the tiling layout for a workspace.
```json
{"workspace": 0, "layout": "spiral"}
```
Available layouts: `master-stack`, `grid`, `monocle`, `floating`, `spiral`, `three-col`, `columns`

### teru_get_graph
Get the process graph (DAG of all processes/agents) as JSON.

### teru_scroll
Scroll a pane's scrollback.
```json
{"pane_id": 2, "direction": "up", "lines": 10}
```

## Common Patterns

### Launch Claude in a new pane
```python
mcp('teru_create_pane', {'direction': 'vertical'})
mcp('teru_send_input', {'pane_id': 2, 'text': 'claude --dangerously-skip-permissions --verbose\n'})
# Wait for Claude to start...
mcp('teru_send_input', {'pane_id': 2, 'text': 'hello'})
mcp('teru_send_keys', {'pane_id': 2, 'keys': ['enter']})
```

### Create a 3-pane layout: [main | [top / bottom]]
```python
mcp('teru_create_pane', {'direction': 'vertical'})      # pane 2 right
mcp('teru_focus_pane', {'pane_id': 2})
mcp('teru_create_pane', {'direction': 'horizontal'})     # pane 3 below 2
```

### Switch to a layout appropriate for the task
```python
# For wide code review: 3 equal columns
mcp('teru_set_layout', {'layout': 'columns'})

# For focus mode: one pane fullscreen
mcp('teru_set_layout', {'layout': 'monocle'})

# For Fibonacci spiral with many panes
mcp('teru_set_layout', {'layout': 'spiral'})

# For center-focused editing: master center + stacks on sides
mcp('teru_set_layout', {'layout': 'three-col'})

# Classic master-stack (default for 2-4 panes)
mcp('teru_set_layout', {'layout': 'master-stack'})
```

### Stop a running process
```python
mcp('teru_send_keys', {'pane_id': 2, 'keys': ['ctrl+c']})
```

### Run a command in a specific directory
```python
mcp('teru_create_pane', {'direction': 'vertical', 'cwd': '/home/user/project'})
mcp('teru_send_input', {'pane_id': 2, 'text': 'npm run dev\n'})
```

## MCP Protocol

The socket uses HTTP POST with JSON-RPC 2.0:
```
POST / HTTP/1.1
Content-Type: application/json
Content-Length: ...
Connection: close

{"jsonrpc":"2.0","method":"tools/call","params":{"name":"teru_create_pane","arguments":{"workspace":0}},"id":1}
```

## Keyboard Shortcuts (prefix = Ctrl+Space)

- `prefix + \` or `prefix + c` — vertical split
- `prefix + -` — horizontal split
- `prefix + x` — close pane
- `prefix + n/p` — next/prev pane
- `prefix + v` — vi/copy mode
- `prefix + /` — search
- `prefix + 1-9` — switch workspace
- `prefix + Space` — cycle layout
- `prefix + z` — zoom (monocle toggle)
- Drag pane borders to resize
