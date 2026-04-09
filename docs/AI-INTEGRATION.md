# AI Integration

teru's core differentiator is native AI agent orchestration. This guide covers all three integration layers.

## 1. Claude Code Agent Teams (CustomPaneBackend)

When teru starts, it sets `CLAUDE_PANE_BACKEND_SOCKET` automatically. Claude Code detects this and uses teru's native pane management instead of tmux.

**What happens automatically:**
- Claude Code spawns agent teams -> teru creates panes, assigns workspaces
- Agent processes tracked in the process graph with parent-child relationships
- Pane borders color-code by status: cyan=running, green=done, red=failed
- No configuration needed

**Protocol operations** (7 JSON-RPC methods over Unix socket):

| Method | Description |
|--------|-------------|
| `spawn` | Create a pane with argv, env, cwd, group metadata |
| `resize` | Resize a pane |
| `write` | Write to pane stdin |
| `read` | Read pane stdout |
| `close` | Close a pane |
| `list` | List all managed panes |
| `status` | Get pane status (running/exited/signaled) |

## 2. MCP Server (19 tools)

teru exposes an MCP server over IPC for agent-to-agent terminal control. Any MCP client (Claude Code, Claude Desktop, custom agents) can connect.

**Socket location:**
- Linux: `/run/user/<UID>/teru-mcp-<PID>.sock`
- macOS: `/tmp/teru-<UID>-mcp-<PID>.sock`
- Windows: `\\.\pipe\teru-mcp-<PID>`

**Connecting from Claude Code:**

Add to your MCP config (`~/.config/claude-code/mcp.json` or project `.mcp.json`):

```json
{
  "mcpServers": {
    "teru": {
      "command": "socat",
      "args": ["UNIX-CONNECT:/run/user/1000/teru-mcp-<PID>.sock", "STDIO"]
    }
  }
}
```

Replace `PID` with teru's process ID (visible in `teru --list` output or `pgrep teru`).

### Tool Reference

**Pane management:**

| Tool | Args | Description |
|------|------|-------------|
| `teru_list_panes` | -- | Returns JSON array: `[{"id":1,"workspace":0,"name":"shell","status":"running","rows":24,"cols":80}]` |
| `teru_create_pane` | `workspace`, `direction`, `command`, `cwd` | Spawn a new pane. Direction: "vertical" or "horizontal" |
| `teru_close_pane` | `pane_id` | Close pane by ID |
| `teru_focus_pane` | `pane_id` | Switch focus to pane |

**Reading/writing:**

| Tool | Args | Description |
|------|------|-------------|
| `teru_read_output` | `pane_id`, `lines` | Get last N lines from visible grid |
| `teru_send_input` | `pane_id`, `text` | Write text to pane PTY (include `\n` for enter) |
| `teru_send_keys` | `pane_id`, `keys` | Send named keystrokes: `["ctrl+c", "enter", "up", "f1"]` |
| `teru_wait_for` | `pane_id`, `pattern`, `lines` | Check if text pattern exists in visible output |
| `teru_broadcast` | `workspace`, `text` | Send text to all panes in workspace |

**State and config:**

| Tool | Args | Description |
|------|------|-------------|
| `teru_get_state` | `pane_id` | Terminal state JSON: cursor position, size, modes, title |
| `teru_get_config` | -- | Live config: layout, workspace, dimensions |
| `teru_set_config` | `key`, `value` | Set config value (writes to teru.conf, triggers hot-reload) |
| `teru_get_graph` | -- | Full process graph as JSON |

**Navigation:**

| Tool | Args | Description |
|------|------|-------------|
| `teru_switch_workspace` | `workspace` | Switch active workspace (0-8) |
| `teru_set_layout` | `layout`, `workspace` | Set layout: master-stack, grid, monocle, dishes, spiral, three-col, columns, accordion |
| `teru_scroll` | `pane_id`, `direction`, `lines` | Scroll scrollback: up, down, bottom |

**Sessions:**

| Tool | Args | Description |
|------|------|-------------|
| `teru_session_save` | `name` | Save current session to `~/.config/teru/sessions/NAME.tsess` |
| `teru_session_restore` | `name` | Restore session from .tsess file (idempotent, no duplicate panes) |

**Capture:**

| Tool | Args | Description |
|------|------|-------------|
| `teru_screenshot` | `path` | Capture framebuffer as PNG (default: /tmp/teru-screenshot.png). Windowed mode only. |

### MCP Prompts

teru also exposes MCP prompts for AI-guided setup:

- **`workspace_setup`**: Describe your desired workspace layout in natural language and the AI client will compose MCP tool calls to set it up.

## 3. Agent Protocol (OSC 9999)

Any process can self-declare as an AI agent using terminal escape sequences:

```bash
# Declare agent start
printf '\e]9999;agent:start;name=backend-dev;group=team-temporal\a'

# Report progress
printf '\e]9999;agent:status;progress=0.6;task=Building API\a'

# Declare completion
printf '\e]9999;agent:stop;exit=success\a'
```

teru tracks agents in the ProcessGraph, colors pane borders by status, and shows agent counts in the status bar.

**Fields:**
- `name` -- agent identifier
- `group` -- agent team/group name
- `progress` -- 0.0 to 1.0 progress value
- `task` -- current task description
- `exit` -- success, failure, or error message

## Session Persistence

Save and restore workspace state including agent configurations:

```bash
# Save current state
# (via MCP: teru_session_save with name)
# (via CLI: teru --daemon saves automatically)

# Restore
teru --session myproject
```

Session files (`.tsess` format) capture workspaces, layouts, pane commands, CWDs, and restart policies. Stored in `~/.config/teru/sessions/`.
