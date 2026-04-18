# Compositor + MCP testing playbook

Instructions for verifying teruwm changes that affect user-visible behaviour
(selection, keyboard, mouse, rendering, workspaces, windows). Follow this
when the user says "test" or when you're about to cut a release.

## Rule 0 — Verify before pushing

Never ship a fix you haven't reproduced against the actual symptom. If Xorg
is holding DRM and you can't launch teruwm here, **say so and wait** rather
than pushing a tag + release. Static analysis has misled prior iterations.
See `memory/feedback_verify_before_release.md`.

## Launch teruwm (Claude-driven, not the user's TTY session)

- Kill any existing instance: `pkill -f "^/home/ng/code/foss/teru/zig-out/bin/teruwm"`
- Clean stale sockets: `rm -f /run/user/1000/wayland-*.lock`
- Start detached with captured output:
  ```
  setsid /home/ng/code/foss/teru/zig-out/bin/teruwm >/tmp/teruwm-live.log 2>&1 < /dev/null &
  disown
  ```
- Wait 2–3 s, then confirm PID + socket:
  ```
  pgrep -af "^/home/ng/code/foss/teru/zig-out/bin/teruwm"
  ls /run/user/1000/teru-wmmcp-*.sock
  ```
- If the log shows `Timeout waiting session to become active`, the user's
  Xorg session owns the DRM seat — tell the user and wait. Don't retry.

## Drive via MCP

Use the small HTTP-over-Unix-socket helper at `/tmp/teruwm-probe/mcp.py`
(create if missing — see `mcp.py` template in tests/ or the conversation
history). Command shape:

```
python3 /tmp/teruwm-probe/mcp.py /run/user/1000/teru-wmmcp-$PID.sock \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"<TOOL>","arguments":{...}}}'
```

### Typing into native terminal panes

`teruwm_type` / `teruwm_press` route through two paths:
- `focused_terminal != null` → bytes written directly to the pane's PTY
  (same path as real keyboard for teruwm-native panes).
- otherwise → `wlr_seat_keyboard_notify_key` to the focused Wayland client
  (xdg / xwayland).

When testing selection / keyboard on native panes, spawn a terminal FIRST
so `focused_terminal` is set:

```
teruwm_spawn_terminal     # focused_terminal = new pane
teruwm_type  {"text":"echo hello"}    # routes to PTY ✓
teruwm_press {"key":"Return"}         # routes to PTY ✓
teruwm_screenshot_pane {"name":"term-0-1","path":"/tmp/..."}
```

### Mouse / selection on native panes

Native terminals are `wlr_scene_buffer` nodes without a wl_surface.
Pointer events go through a teruwm-internal path in
`src/compositor/ServerCursor.zig`:

- `terminalMousePress` — records anchor cell, sets `drag_terminal`
- `terminalMouseMotion` — begins + updates `Selection` on drag
- `terminalMouseRelease` — clears `drag_terminal`, selection remains visible

Drive a drag via `teruwm_test_drag`:
```json
{"from_x":12,"from_y":48,"to_x":80,"to_y":48,"button":272}
```

Coordinate space is output-global (not pane-local). `from_x`/`from_y` must
land inside the pane's node rect (`teruwm_list_windows` returns `x`,`y`,
`w`,`h`).

### Verifying what actually rendered

`teruwm_screenshot_pane` calls `TerminalPane.render()` on demand, which
re-paints the full pane including the selection highlight overlay.
Compare MD5 between screenshots before and after the action to confirm a
pixel change happened. Byte-identical screenshots mean nothing changed on
that pane's framebuffer — which is meaningful (e.g. hover should NOT
change the grid; only cursor overlay which isn't in pane buffers).

### What `teruwm_screenshot_pane` does NOT capture

- The wlroots mouse cursor layer (software/hardware cursor plane).
- Cross-pane compositing (cursor overlay near pane edges, scene-rect
  borders from `WmConfig.border_color_*`, bg_rect behind gaps).
- Visual flicker — a static snapshot can't show animation. Suspected
  flicker must be verified on real hardware by the user, or diagnosed
  by static analysis (e.g. look for `wlr_cursor_set_xcursor` being
  called on every motion — that re-damages the cursor plane).

## Shutting down cleanly

The user will Mod+Shift+Q on their display. If you need to stop teruwm
from this side: `pkill -f "^/home/ng/code/foss/teru/zig-out/bin/teruwm"`.
Never force-kill with SIGKILL unless it's unresponsive — SIGTERM fires
the defer chain (wl_display_destroy_clients first, then wl_display_destroy,
then server.deinit), which is what we test for shutdown-crash regressions.

## Gotchas

- Running `cd homebrew-teru && ...` leaves the shell in that dir on the
  next bash call; always use absolute `cd /home/ng/code/foss/teru` at the
  start of any top-level repo operation.
- `zig build test` exit code is currently misleading — the test binary
  runs all 488 tests and reports "All tests passed" but the wrapper
  returns non-zero. Exit code of the test binary is the source of truth:
  `./.zig-cache/o/*/test >/dev/null 2>&1; echo $?`.
- `teruwm_spawn_terminal` focuses the new pane synchronously. After
  spawn, `focused_terminal` is set and PTY-direct input works. Do not
  assume focus from external window managers / taskbars.
- Output cursor position accumulates across calls — `teruwm_test_move`
  warps the hardware cursor, and subsequent `teruwm_test_drag` from_x
  is independent. Warp explicitly rather than relying on state.

## Release checklist (see `skills/release` for the full pipeline)

Before bumping the version tag:
1. Build + run the test binary directly, not `zig build test`.
2. Launch teruwm, reproduce the symptom the fix is supposed to address.
3. Apply the fix, relaunch, verify symptom is gone.
4. Only then: bump, CHANGELOG, tag, release, package manifests.
