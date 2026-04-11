---
name: tui-test
description: Build, deploy, and E2E test teru TUI mode on the remote server via SSH pane. Automates binary upload, daemon management, and visual verification.
---

# TUI Mode E2E Test

## Prerequisites
- User has a teru window open with an SSH pane connected to `167.235.2.216:2248`
- The SSH pane is on a workspace (user will tell you which pane ID)

## Protocol

### Step 1: Find the SSH pane
```python
# Scan all teru MCP sockets, find the one with an SSH connection
# Look for pane output containing "selify-prod" or "@167.235"
```

### Step 2: Build + Upload
```bash
zig build test 2>&1 | tail -3        # verify tests pass
make release 2>&1 | tail -2          # build release binary
# Kill old teru on server (carefully — only --daemon, not all teru)
# via MCP: send 'pkill -f "teru --daemon" 2>/dev/null' to SSH pane
scp -P 2248 zig-out/bin/teru ng@167.235.2.216:~/bin/teru2
# via MCP: send 'mv ~/bin/teru2 ~/bin/teru; chmod +x ~/bin/teru'
```

### Step 3: Launch TUI
```
# via MCP: send '~/bin/teru -n e2e-test' to SSH pane
# Wait 3 seconds for daemon auto-start + TUI attach
```

### Step 4: Snapshot + Verify
```
# Read pane grid (lines 0-5 and last 5 lines)
# Check:
#   - Prompt at line 0 (not middle) → grid sizing correct
#   - Status bar at last line → TUI rendering works
#   - Only 1 prompt visible → no duplicate
```

### Step 5: Test Commands
```
# Send 'echo "TUI_TEST_OK"' via MCP
# Read grid, verify output appears at correct position
```

### Step 6: Report
```
Format:
  TUI E2E Test Results:
  ✓/✗ Binary uploaded and runs
  ✓/✗ Daemon auto-started
  ✓/✗ TUI mode entered (status bar visible)
  ✓/✗ Prompt at correct position (top, not middle)
  ✓/✗ Command input works
  ✓/✗ No duplicate prompts
  
  Issues found: [list]
  
  Manual tests needed:
  - Ctrl+B then c (split) — check border colors
  - Ctrl+B then j/k (focus) — check active pane highlight
  - Ctrl+B then d (detach) — check clean exit
```

### Cleanup
```
# via MCP: send 'pkill -f "teru --daemon e2e" 2>/dev/null'
# Do NOT pkill -f "teru" — that kills the outer teru!
```

## Important
- NEVER run `pkill -f "teru"` — this kills the user's outer teru window
- Always use `pkill -f "teru --daemon SPECIFIC_NAME"` for cleanup
- The MCP `teru_send_input` cannot reliably send control characters (0x00-0x1F) through SSH — keybind testing must be done manually by the user
