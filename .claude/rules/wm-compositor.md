# Wayland Compositor Development Rules

Rules for developing teruwm, the tiling Wayland compositor built on wlroots + libteru.

## Architecture

teruwm is a wlroots-based compositor that embeds libteru terminal panes as scene buffers.
It is NOT a standalone window manager — it IS the display server.

### Two MCP Layers
- **Terminal MCP** (`teru-mcp-*.sock`): controls panes within a teru terminal instance
- **Compositor MCP** (`teru-wmmcp-*.sock`): controls the window manager (windows, workspaces, layouts)

Never confuse these. Terminal MCP screenshots show one terminal's framebuffer. Compositor MCP controls the global state.

### Event Loop
- wlroots owns the event loop (`wl_display_run`)
- PTY output: `wl_event_loop_add_fd` fires `ptyReadable` on data → just reads, does NOT render
- Rendering: `Output.handleFrame` fires on vsync → renders dirty panes → commits scene
- MCP: `wl_event_loop_add_fd` on socket fd for non-blocking accept
- NEVER block the event loop — all I/O must be non-blocking

### Render Pipeline
```
PTY byte → ptyReadable() → readAndProcess() → grid.dirty = true
vsync → handleFrame() → renderIfDirty() → SoftwareRenderer.render() → wlr_scene_buffer_set_buffer_with_damage
```
- NEVER render from ptyReadable — rendering happens ONLY in frame callback
- This coalesces 100+ PTY reads into 1 render per vsync (60fps)

## Gap System

Uniform gaps: same between panes and between panes and screen edges.

```
Screen pre-inset by gap/2 → layout divides inset area → each pane post-inset by gap/2
Edge total: gap/2 + gap/2 = gap
Between panes: gap/2 + gap/2 = gap
```

Both `arrangeworkspace()` and `arrangeWorkspaceSmooth()` must use identical gap logic.

## Compositor Restart (exec)

teruwm supports xmonad-style restart:
1. Serialize pane state + PTY master fds to `/tmp/teruwm-restart.bin`
2. Clear FD_CLOEXEC on PTY fds
3. Re-resolve the binary path (`readlink /proc/self/exe`, strip a trailing
   `" (deleted)"`) and `exec(<resolved path>, "--restore")`
4. New binary reads state, attaches to existing PTY fds via `Pty.attach()`
5. Shells never notice — zero downtime for terminals

**Critical**: NEVER set O_CLOEXEC on PTY master fds. They must survive exec().

**Why re-resolve instead of exec'ing `/proc/self/exe` directly**: after a
rebuild + `install`, the running process's `/proc/self/exe` symlink points at
the *deleted old inode* (`readlink` returns `…/teruwm (deleted)`). exec'ing the
symlink would re-run the OLD code, so a restart could never pick up a new build.
Resolving to the on-disk path and exec'ing that loads the rebuilt binary —
this is what makes `teruwm_restart` / `$mod+'` an actual
`xmonad --restart`. See `resolveSelfExe` in `ServerRestart.zig`.

## wlroots Patterns

### C Glue
wlroots is C. Access struct fields through glue functions in `vendor/miozu-wlr-glue.c`:
```c
double miozu_pointer_axis_delta(struct wlr_pointer_axis_event *e) { return e->delta; }
```
Declare in `src/compositor/wlr.zig`:
```zig
pub extern "c" fn miozu_pointer_axis_delta(event: *wlr_pointer_axis_event) callconv(.c) f64;
```

### Listeners
```zig
cursor_axis: wlr.wl_listener = makeListener(handleCursorAxis),
// Register:
wlr.wl_signal_add(wlr.miozu_cursor_axis(self.cursor), &self.cursor_axis);
```

### Scene Graph
- Terminal panes are `wlr_scene_buffer` nodes with pixel buffers
- Position via `wlr_scene_node_set_position`
- Update via `wlr_scene_buffer_set_buffer_with_damage`
- Visibility via `wlr_scene_node_set_enabled`

## Anti-Patterns

1. **DON'T render from ptyReadable** — render only in frame callback
2. **DON'T pass NULL damage to wlr_scene_buffer_set_buffer_with_damage** unless the whole buffer changed
3. **DON'T allocate in the render loop** — pre-allocate everything
4. **DON'T use grim for compositor screenshots** until wlr-screencopy is implemented
5. **DON'T close PTY fds before exec()** on restart — they must survive
6. **DON'T add teruwm_exec MCP tool** — arbitrary shell exec from MCP is a security risk
7. **DON'T block the wl_display event loop** — all socket/file ops must be non-blocking
8. **DON'T confuse terminal MCP with compositor MCP** — different sockets, different tools
