# Debugging teru & teruwm

How to get logs (including the full MCP trace) out of both binaries, and the
plan for making the project's logging better.

## Quick start — get all the logs

Both binaries route diagnostics through `std.log`, gated at **runtime** by the
`TERU_LOG` environment variable (no rebuild):

| `TERU_LOG` | shows |
|---|---|
| `err` | errors only |
| `warn` | errors + warnings |
| `info` *(default)* | + lifecycle events (spawn / exit / connect …) |
| `debug` | **+ the full MCP request/response trace** + verbose diagnostics |

Output goes to **stderr**, formatted `[level] (scope) message`. Redirect stderr
to capture it.

### teruwm (compositor)
```sh
# From a free TTY (Ctrl+Alt+F2). The `trace` mode builds, sets TERU_LOG=debug,
# and captures everything to ~/.miozu/logs/teruwm-<timestamp>.log:
~/.miozu/bin/run-teruwm.sh trace

# …then from another TTY / ssh, watch it live:
tail -f ~/.miozu/logs/teruwm-*.log

# …and drive it over MCP (auto-discovers the socket):
~/code/workbench/foss/teru/tools/mcp-probe.py teruwm_list_windows
~/code/workbench/foss/teru/tools/mcp-probe.py teruwm_spawn_terminal
~/code/workbench/foss/teru/tools/mcp-probe.py teruwm_type '{"text":"echo hi"}'
```

### teru (terminal)
```sh
TERU_LOG=debug teru 2>/tmp/teru.log        # or `teru --raw` over SSH
tools/mcp-probe.py --teru teru_list_panes  # drive the terminal MCP server
```

### Headless teruwm (no DRM — safe alongside your session)
```sh
WLR_BACKENDS=headless WLR_RENDERER=pixman TERU_LOG=debug \
  teruwm 2>/tmp/teruwm.log &
# then mcp-probe.py as above. This is exactly what tests/teruwm_e2e.py does.
```

## The MCP trace

Every JSON-RPC call through `McpFramework.dispatch` is logged at `mcp` debug
level — request and response:

```
[debug] (mcp) → {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"teruwm_spawn_terminal",…}}
[debug] (mcp) ← {"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"spawned terminal on workspace 0"}]},"id":1}
```

The teru socket, the teruwm socket, **and** the OSC-9999 in-band channel all go
through that one dispatch, so `TERU_LOG=debug` captures *all* MCP traffic for
both binaries. Bodies over 800 bytes are clipped in the trace.

`grep '(mcp)'` the log to isolate it; `grep '(mcp) →'` for requests only.

## Daemon session log

A session daemon auto-started by `teru -n NAME` is detached from your terminal
(`setsid`), so its stdout/stderr — including any `TERU_LOG` output — are
redirected to a per-session log file instead of a dead PTY:

```sh
tail -f "$XDG_RUNTIME_DIR/teru-session-<name>.log"
```

To capture the full MCP trace from a backgrounded daemon, start the session with
`TERU_LOG=debug teru -n NAME` (the env var is inherited by the forked daemon),
then tail the log above. A *foreground* `teru --daemon NAME` logs to its terminal
as usual (no redirect). See [SESSIONS.md](SESSIONS.md) for the session model.

## Sockets (canonical names)

| | request socket | event push socket |
|---|---|---|
| teru | `$XDG_RUNTIME_DIR/teru-mcp-<PID>.sock` | `teru-mcp-events-<PID>.sock` |
| teruwm | `$XDG_RUNTIME_DIR/teruwm-mcp-<PID>.sock` | `teruwm-mcp-events-<PID>.sock` |

(`mcp-probe.py` skips the `*-events-*` sockets automatically.)

## Adding a log line

Use `std.log` with a scope, never a bare `std.debug.print` (which is
unconditional and untagged):

```zig
std.log.scoped(.compositor).info("output added: {s}", .{name});
std.log.scoped(.pty).err("spawn failed: {s}", .{@errorName(e)});
std.log.scoped(.mcp).debug("→ {s}", .{request});
```

Level convention:
- **err** — a real failure (a syscall/alloc/protocol error you handled).
- **warn** — a recovered-but-suspicious condition.
- **info** — a lifecycle event a user might want to see by default (pane spawn /
  exit, output connect/disconnect, config reload, restart).
- **debug** — anything verbose / per-event / per-frame. **Never in the render
  hot path** (the zero-alloc rule still applies).

Suggested scopes: `.compositor`, `.mcp`, `.pty`, `.vt`, `.render`, `.config`,
`.input`, `.daemon`, `.agent`, `.session`.

## Improvement plan (logging for the whole project)

1. **Migrate `std.debug.print` → `std.log.scoped`. — DONE (0.7.x).** All 80
   ad-hoc prints across teru/teruwm now route through `std.log` with a scope +
   level, so the default (`info`) is quiet and `TERU_LOG` controls everything.
   Only the `panic` handler's `std.debug.print` in `compositor/main.zig` remains
   (a panic must print regardless of `TERU_LOG`).
2. **Per-scope verbosity** (future): `TERU_LOG=info,mcp=debug` to trace only MCP
   while keeping the rest quiet. `std.Options.log_scope_levels` supports this; a
   small parse in `log.zig` would wire it up.
3. **Shutdown deinit pass.** The debug allocator reports several heap blocks
   *leaked at exit* on teruwm shutdown (Server, FontAtlas, Bar, the bar/pane
   SoftwareRenderer framebuffers). Harmless (the OS reclaims them) but they
   bury real leaks in the noise — give `Server.deinit` / `Bar.deinit` /
   `FontAtlas.deinit` a pass so a clean shutdown reports zero leaks, which then
   becomes a regression signal.
4. **MCP trace polish** (optional): a dedicated `TERU_MCP_TRACE=1` for full,
   un-clipped bodies; a request-id correlation column; timing per call.
5. **Structured option**: the format is greppable plain text by design. If
   machine parsing is ever needed, a `TERU_LOG_JSON=1` branch in the logFn can
   emit one JSON object per line without touching call sites.

The facility (`src/log.zig`), the MCP trace, `tools/mcp-probe.py`, the
`run-teruwm.sh trace` mode, and the print migration (step 1) are in place;
steps 2–3 (per-scope verbosity, the shutdown deinit pass) are the remaining work.
