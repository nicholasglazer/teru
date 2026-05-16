# teru / teruwm — Production-Readiness Audit (2026-05-16)

Audit of the full codebase: **101 `.zig` files, 52,075 lines**, Zig `0.17.0-dev.304`,
version `0.6.10`. Three phases: a static full-codebase pass, a live tty3
end-to-end MCP test, and a double-check re-audit. **Each phase that ran the
compositor found a blocker the static pass had missed.**

## ⚠ Headline — three BLOCKERs found, all fixed

1. **The codebase did not build on the installed Zig (`0.17.0-dev.304`).**
   `dev.304` removed `std.fmt.bufPrintZ` and `Allocator.dupeZ`; teru used both
   (11 sites). Surfaced by a build gate. **FIXED** — migrated to
   `bufPrintSentinel` / `dupeSentinel`.

2. **teruwm spun at 100% CPU and leaked a pipe fd per bar-exec tick.**
   `Bar.cleanupExec` closed the exec-widget pipe fd but never called
   `wl_event_source_remove` — the wlroots event source leaked, sat in epoll at
   permanent EOF/HUP, and re-fired every dispatch. Surfaced by the tty3 E2E run
   (99% CPU, 77 leaked pipe fds climbing toward exhaustion). Hits every user on
   the default config. **FIXED** — `cleanupExec` removes the source; exec pipes
   are `FD_CLOEXEC`. Re-verified: idle CPU 99% → 0.5%.

3. **Exiting a shell in a teruwm pane hung the compositor.** `ptyReadable`
   tested `mask & 0x10` for hang-up, but `WL_EVENT_HANGUP` is `0x04` — the
   branch was dead, so `handleTerminalExit` (its only caller) was unreachable.
   When a shell exited, the dead pane was never reaped, the PTY master fd
   re-fired forever, and the compositor spun at 100% CPU with a zombie pane on
   screen. Surfaced by the double-check re-audit and confirmed live (`exit` →
   `Rs`, zero voluntary context switches). **FIXED** — see below.

## Fixed this pass

| Item | Detail |
|------|--------|
| **BLOCKER — dev.304 build break** | `bufPrintZ`→`bufPrintSentinel`, `dupeZ`→`dupeSentinel` (11 sites). |
| **BLOCKER — bar-exec CPU spin / fd leak** | `Bar.zig`: `cleanupExec` now `wl_event_source_remove`s the source; exec pipes `FD_CLOEXEC`; broken `0x10` HANGUP branch dropped. Found by the E2E run, verified fixed live. |
| **BLOCKER — shell-exit CPU spin / zombie pane / leak** | `ptyReadable` (TerminalPane.zig): correct dead-PTY detection — HANGUP/ERROR mask **plus** a `waitpid(WNOHANG)` liveness probe after a no-data read, because a Linux PTY master never raises HANGUP when its slave closes. `handleTerminalExit` (Server.zig): completed the teardown — was leaking the pane + PTY fd on every exit; now does the full `tp.deinit` + `destroy` and re-seats keyboard focus on a surviving pane. `WL_EVENT_HANGUP`/`WRITABLE`/`ERROR` added to `wlr.zig`. Verified fixed live. |
| **MEDIUM — shutdown crash on held key** | `Server.deinit` tore down 2 of 3 event-loop timers; `terminal_repeat_src` is now removed alongside `keybind_repeat_src` + `bar_tick_src`. |
| **5 latent `@memset` bugs** | `Compositor.zig` ×4 + `windowed.zig:1391` did bare `@memset([]u32, runtime)`. The codegen bug is **still live on dev.304** (verified). All now route through `compat.memsetU32`. |
| **H1/H2 — silent error swallows** | 6 `catch {}` on `grid.resize` / SHM recreate now log via `std.log.warn`. |
| M1 (reverted) | Removing `compat.memsetU32` was attempted on a false-negative test result; reverted — the helper is load-bearing. |

## tty3 end-to-end MCP test (teruwm, headless wlroots backend)

Driven via the compositor MCP (HTTP-over-Unix-socket) against a live debug
build. Headless backend (`WLR_BACKENDS=headless`) — does not contend for the
DRM seat, so it runs safely alongside the user's session and exercises the
exact MCP screenshot path used on real hardware.

| Check | Result |
|-------|--------|
| Launch (headless, pixman) | ✅ clean — `HEADLESS-1` output, MCP sockets up |
| Runtime exercise of the dev.304 + `@memset` fixes | ✅ no crash — pane spawn / render hit every fixed site |
| `spawn_terminal`, `type`, `press`, `screenshot_pane` | ✅ shell prompt + typed cmd + output rendered (verified visually) |
| `set_layout grid` + 2nd terminal | ✅ tiled columns, both panes render |
| Shell exit (`exit` in a pane) | ✅ pane reaped, workspace re-tiled, focus follows to survivor, CPU idle — **after fix #3** |
| `list_workspaces`, `get_config`, `perf` | ✅ |
| Idle CPU after fixes #2 + #3 | ✅ ~0%, `wchan=ep_poll` (properly blocked) |
| Clean SIGTERM shutdown | ✅ defer chain runs, no hang/crash. (Stale `teruwm-mcp-*.sock` files are not unlinked — cosmetic; see TODO.) |

**Alt+scroll font-zoom — not reachable via MCP.** The feature lives in
`ServerCursor.handleCursorAxis` (the physical cursor-device axis listener).
`teruwm_scroll` calls `wlr_seat_pointer_notify_axis` directly, bypassing that
listener; there is no font/zoom keybind action; and no "hold modifier" MCP
primitive exists to satisfy `readAltHeld`. The zoom *logic* is covered by
inline tests (`FontAtlas.zoomedFontSize`, `mouse.zoomRequestFor`, `WmConfig`
`alt_scroll_zoom` parse). End-to-end input→render zoom can only be verified on
real hardware by the user.

## Double-check / re-audit — resource-lifecycle sweep

After the E2E run found blocker #2, every `wl_event_loop_add_fd`,
`wl_event_loop_add_timer`, `pipe()` and `fork()` site was audited for
matched cleanup. This found blocker #3 and the shutdown medium.

| Site | Verdict |
|------|---------|
| `wl_event_loop_add_fd` — `TerminalPane.ptyReadable` ×2 paths | one source per pane; removed in `deinit` + `handleTerminalExit`. Detection fixed (blocker #3). |
| `wl_event_loop_add_fd` — `WmMcpServer` (request + event sockets) | paired with `wl_event_source_remove`; E2E exercised it heavily with stable fd count. ✓ |
| `wl_event_loop_add_fd` — `Bar.execReadable` | fixed (blocker #2). ✓ |
| `wl_event_loop_add_timer` — `keybind_repeat`, `bar_tick` | torn down in `deinit`. ✓ |
| `wl_event_loop_add_timer` — `terminal_repeat_src` | **was not torn down** — fixed (medium). |
| `pipe()` — `tui.zig` SIGWINCH self-pipe | both ends `defer`-closed; raw `poll(2)` correctly uses `POLLHUP=0x010`. ✓ |
| `pipe()` — `compat.forkExec*` ×3 | both ends closed on every path; double-fork reaps the middle child. ✓ |
| `fork()` — `Server.spawnProcess` double-fork | grandchild reparents to init, middle child reaped — no zombies. ✓ |

Note: `tui.zig`'s correct `POLLHUP = 0x010` for the raw `poll(2)` syscall is
almost certainly where the wrong `0x10` was copy-pasted into the two
`wl_event_loop` fd handlers (`Bar`, `TerminalPane`), where `WL_EVENT_HANGUP` is
`0x04`.

## Verified good

| Area | Finding |
|------|---------|
| Zig 0.17 alignment | No `**`, `callconv(.C)`, `fs.cwd()`, `GeneralPurposeAllocator`, `page_allocator` misuse, `@cImport`, removed `posix.*`, `@Type`, `Thread.Mutex`. Builds clean on dev.304. |
| Render hot path | `software.zig` `renderRangeSel` — zero-allocation, confirmed. |
| Untrusted input | `VtParser` bounds-safe; `in_band.zig` MCP path opt-in + allowlisted + cross-pane-exfil guarded + tested. |
| Compositor | All 5 documented crash-guards intact. |
| Tests | 517 lib + 15 compositor inline tests pass (532 total). |

## Remaining TODO

| Tier | Item |
|------|------|
| LOW | **Stale socket cleanup** — teruwm does not unlink `teruwm-mcp-*.sock` / `-events-*.sock` on shutdown. Add an `unlink` to the MCP server deinit. |
| LOW | **Bar exec on shutdown** — no `Bar` deinit drains `pending_execs`; in-flight execs leak their source at process exit (OS reclaims it — harmless, untidy). |
| ~~M2~~ | **Dropped.** Native `std.Io.Writer`/`Reader` lack `writeInt`/`readInt` — migrating `Session.zig` off `compat.MemWriter` would mean hand-rolling integer (de)serialization for zero benefit. `zig-terminal.md` rule #11 corrected. |
| MEDIUM | **M3** — ~48 remaining `catch {}` reviewed: overwhelmingly defensible. No silent swallow of a *recoverable* error remains after H1/H2. |
| MEDIUM | **M4** — split 6 god-files (`VtParser` 2246, `Server` 2161, `McpServer` 1676, `WmMcpServer` 1669, `windowed` 1486, `Grid` 1405). High-risk refactor — its own focused effort. |
| MEDIUM→**HIGH** | **M5** — 41/101 modules have no `test` block. This is now the priority debt: **all three blockers + the shutdown medium were invisible to the 532-test suite** and to static analysis. The bar exec-widget lifecycle and `handleTerminalExit` in particular had zero coverage. A compositor harness that spawns a pane, exits its shell, and asserts CPU/fd state would have caught blockers #2 and #3. |
| LOW | Docs refresh; `catch unreachable` in tests. |

## Verdict

Three production blockers were found — one by the build gate, one by the tty3
E2E run, one by the double-check re-audit. All are **fixed and verified live**,
plus a shutdown-crash medium, 5 latent `@memset` bugs, and 2 silent
error-swallows. After the fixes the tree is in a **green, shippable state**:
builds on dev.304, 532 tests pass, the live E2E run is clean — teruwm idles at
~0% CPU, spawns and reaps panes correctly, and shuts down cleanly.

The lesson of this audit: **static analysis and the unit suite passed a
compositor that pegged a CPU core on two of its most common operations** — a
default bar-widget refresh, and closing a terminal. Only running teruwm
surfaced them. M5 is no longer "coverage debt" — it is the systemic fix, and
it is the one item that should block the *next* release, not this one.
