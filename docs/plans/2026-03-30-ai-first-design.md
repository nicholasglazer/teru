# teru AI-First Architecture Design

**Date:** 2026-03-30
**Status:** Approved

## Problem

teru has AI data structures (process graph, OSC 9999, hook handler) but nothing acts on them visually or enables cross-agent communication. 20+ Claude instances across 10 workspaces can't see each other.

## Design

### 1. MCP Server (built in Zig, inside teru binary)

HTTP server on Unix socket `/run/user/$UID/teru.sock`. All Claude instances connect via .mcp.json.

Tools:
- teru_list_panes: list all panes with workspace, agent name, status, cwd
- teru_read_output(pane_id, lines): recent N lines from any pane
- teru_get_graph: full process graph as JSON
- teru_send_input(pane_id, text): type into another pane's PTY
- teru_create_pane(workspace, cmd): spawn new pane
- teru_get_workspace(name): panes in a workspace
- teru_broadcast(workspace, text): send to all panes in workspace

### 2. Agent Lifecycle Rendering

OSC 9999 events → visual response:
- agent:start → cyan border, header label, optional auto-workspace
- agent:status → progress bar in border, task text
- agent:stop;exit=success → green border, auto-collapse after 5s
- agent:stop;exit=error → red border, stays visible

### 3. Status Bar

Bottom bar per workspace showing agent status. Global view via Ctrl+Space,g.

### 4. Full OSC 9999 Event Handling

Wire all events (not just start): stop, status, task, group, message.
Agent messages routed between panes via process graph.

### 5. Claude Code Hook Integration

Wire HookHandler.zig into the event loop. Register teru as hook handler.
SubagentStart → create agent node + auto-workspace.
