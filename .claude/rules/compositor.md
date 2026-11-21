---
paths:
  - "src/compositor/**"
  - "vendor/miozu-wlr-glue.c"
---
# teruwm compositor

teruwm is the display server, not a client of one. wlroots owns the event loop, so nothing here may block it: every socket and file operation is non-blocking.

Rendering:

- PTY output only reads and marks the grid dirty (`ptyReadable` in `TerminalPane.zig`). Drawing happens in the frame callback (`handleFrame` in `Output.zig`), which renders the dirty panes once per vsync. Never render from the PTY path.
- An MCP call that changes state calls `scheduleRender` so the change paints on the next frame.
- Gaps are uniform. The screen is inset by half a gap, then each pane is inset by half a gap. `arrangeWorkspace` and `arrangeWorkspaceSmooth` in `ServerLayout.zig` must use the same arithmetic.

Restart (`teruwm_restart`, the xmonad-style in-place restart):

- Pane state and PTY master descriptors are written to `teruwm-restart.bin`, `FD_CLOEXEC` is cleared on the PTY masters, and the new binary reattaches to them. PTY masters must survive `exec`.
- Exec the path from `resolveSelfExe` in `ServerRestart.zig`, not `/proc/self/exe`. After an install that link points at the deleted old binary, and a restart would run the old code.

wlroots:

- Read C struct fields through an accessor in `vendor/miozu-wlr-glue.c` and declare it in `wlr.zig`. Add an accessor when a new field is needed.
- There is no MCP tool that runs a shell command, and none should be added. That is a deliberate security boundary.
- Never delete `wayland-*` or its `.lock` file from `$XDG_RUNTIME_DIR`. Doing so strands a running session, and `ServerSocketGuard.zig` exists because it happened.

Each of these guards fixed a crash or a wrong-target bug. Keep them when changing nearby code:

- Check `miozu_surface_is_live` before any seat notify or cursor-surface call. Scene buffers briefly outlive their surface between unmap and destroy.
- Accept `request_set_cursor` only from the client that has pointer focus (`miozu_set_cursor_event_from_focused`).
- Every close path clears `focused_terminal`, `focused_view` and `grab_node_id` before freeing the pane or view.
- `Workspace.removeNode` clears `active_node` and `master_id` when they name the removed node.
- Every scene raise of an Xwayland window is mirrored into the X server's stacking with `wlr_xwayland_surface_restack` (done in `ServerFocus.raiseNode`). Xwayland picks click targets from its own stacking order, so a window that is raised only in the scene shows on top while its clicks go to the window beneath. Restack only windows whose scene node is enabled.
