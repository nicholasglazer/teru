# Daemon / Session Audit — 2026-06-01

Goal: make `teru` a drop-in tmux replacement for the remote-agent workflow —
ssh in, start a session, run many agents, **close the laptop, and have the
agents keep running**; reconnect and resume where you left off. Plus predefined
multi-pane layouts ("as many subwindows as I need"). This audit reviews the
session daemon for correctness, robustness, and elegance, and records the bugs
found + fixed, each reproduced with an end-to-end test before the fix.

Scope read line-by-line: `src/server/daemon.zig`, `src/server/protocol.zig`,
`src/server/ipc.zig`, `src/modes/daemon.zig`, `src/modes/tui.zig`,
`src/modes/common.zig`, `src/persist/Session.zig`, `src/config/SessionDef.zig`.

## Verdict

The architecture is sound and the event loop is genuinely good — a single
deadline-driven `poll()` over listen + client + PTYs + MCP fds, no idle spin,
a pane-set-stability guard against stale `fds[]`, a throttled dead-pane sweep.
But four defects made it **unfit for the stated purpose**, two of them
fatal. All four are now fixed and covered by tests. Defect 4 was caught during
the live install on the deploy server (`teru -n agents` against a 9-pane layout)
— exactly the path the python E2E tests had under-exercised by only spawning one
pane per session on the attach path.

| # | Severity | Defect | Status |
|---|----------|--------|--------|
| 1 | **Critical** | Daemon dies on SSH disconnect / laptop close | Fixed + tested |
| 2 | High | Any client can crash the daemon with `resize(0,0)` | Fixed + tested |
| 3 | High | Fixed 36-slot poll set silently drops panes past ~32 | Fixed + tested |
| 4 | **Critical** | Attaching a ≥2-pane session segfaults the client | Fixed + tested |

## 1. Daemon dies on disconnect (the headline bug)

**Symptom (reproduced):** `tests/session_survival_e2e.py` starts `teru -n NAME`
over a controlling-terminal PTY (sshd's exact model: child is a session leader
with the PTY as controlling terminal), confirms the daemon + a marker "agent"
are running, then closes the PTY master (= SSH drop / laptop close). Before the
fix:

```
[3] daemon alive: False   marker alive: False   counter 2→2 frozen
    ✗ the daemon died with the SSH session — agents stopped.
```

**Root cause:** `autoStartNamedDaemon` (`src/modes/common.zig`) forked the daemon
with a bare `fork()` + `execve()` — **no `setsid()`**. The daemon stayed in the
ssh login session's process group with the PTY as its controlling terminal, so
the kernel's hangup SIGHUP on master-close reached it (default disposition:
terminate). Every pane PTY it owned went down with it. This is precisely "I
close my laptop and the sessions stop."

**Fix:** in the forked child, before `execve`, `setsid()` to move the daemon
into a fresh session with no controlling terminal, and re-point std{in,out,err}
off the dying PTY (stdin ← `/dev/null`; stdout/stderr ← a per-session log file,
`$XDG_RUNTIME_DIR/teru-session-<name>.log`, which also makes a backgrounded
daemon's `TERU_LOG=debug` output tailable). After the fix the same test reports
`VERDICT: PASS ✓` — daemon + agent survive, a new `teru -n NAME` reattaches to
the *same* daemon, live output is replayed, and the daemon survives a second
detach.

## 2. A client can crash the daemon (`resize(0,0)`)

**Symptom (reproduced):** with a 0×0 terminal the TUI client sends `resize(0,0)`;
the daemon resizes every pane grid to 0 columns; the next byte of PTY output
feeds `VtParser` an empty cell slice and panics — `VtParser.zig:265 index out of
bounds: index 0, len 0` — killing the daemon (and the client panics too:
`TuiRenderer.zig:255 integer overflow` on `w - 1`). A real SSH session has a
non-zero size, but **no client should be able to kill the daemon**, and 0×0 is
reported transiently by some terminals on first connect. `tests/daemon_resize_stress.py`
drives the raw wire protocol to send the hostile frame.

**Fix (defence in depth):**
- `Daemon.resizeAllPanes` and the pane-tagged resize branch ignore a 0 dimension
  (the daemon — the must-never-crash process — is the authoritative guard).
- `VtParser.feed` early-returns on a 0-dimension grid.
- `TuiRenderer.renderWithOpts` early-returns on a 0×0 screen; `w - 1` → `w -| 1`.
- The TUI client clamps a 0 winsize to 24×80 at the source (initial read + SIGWINCH).

After the fix `tests/daemon_resize_stress.py` reports `PASS ✓` — the daemon
survives a barrage of `resize(0,0)` interleaved with input and keeps serving.

## 3. Fixed poll set drops panes past ~32

**Symptom (reproduced):** the run loop built its poll set into `var fds: [36]`
and stopped enumerating PTYs at `fds.len - 2`, i.e. ~32 PTYs with a client
attached. The user's `claude-power` layout is **34 panes in one session**; the
2 over the cap were never polled, so their PTY output was never drained, their
kernel buffers filled, and those agents blocked. Directly contradicts "as many
subwindows as I need." `tests/many_pane_e2e.py` spawns 40 marker panes.

**Fix:** the poll set is now a heap buffer on the `Daemon` struct, seeded to 16
in `init` and grown on demand to `panes + 4` (`ensurePollCapacity`), freed in
`deinit`. After the fix `tests/many_pane_e2e.py` reports `40/40 draining`.

## 4. Attaching a multi-pane session segfaults the client

Found during the live server install, not static analysis. `teru -n agents`
(a 9-pane, 3-workspace layout) died instantly with
`Segmentation fault at address 0x…062` and a stripped-build "stack tracing is
disabled" — while the single-pane `teru -n e2etest` attached fine. A debug
build pinned it to `VtParser.feed` (`src/core/VtParser.zig:159`, the
`self.grid.cols` guard) called from the state-sync replay loop
(`src/modes/tui.zig:107`).

Root cause in `parseDaemonStateSync` (`src/modes/common.zig`): each remote pane
was `append`ed to `mux.panes` (an `ArrayList(Pane)`) and then **only the
newly-added pane** was re-linked (`items[idx].linkVt`). A `Pane` carries
self-pointers — `vt.grid → &self.grid`, `vt.response_ctx → self`,
`grid.scrollback` — so a reallocating `append` (capacity grows 0→1→2→4→8→16)
moves every earlier `Pane` and dangles those pointers. The next `vt.feed` on a
moved pane dereferenced freed memory → `SIGSEGV`. One pane never reallocates,
which is precisely why single-pane attaches (and the python attach E2E) missed
it.

`Multiplexer.addPane` already guarded this exact hazard by re-linking **all**
panes after every append; `parseDaemonStateSync` simply didn't follow suit. Fix
is the one-line invariant restored: `for (mux.panes.items) |*p| p.linkVt(...)`.

Reproduced (debug build, server, 9-pane attach → segfault), fixed, re-verified
(no crash, full grid render), then locked down with an inline regression test
that builds a 9-pane state-sync payload and asserts every `pane.vt.grid ==
&pane.grid` — confirmed to FAIL on the pre-fix code (1 failed) and pass after.

## What was already good

- **Event loop**: deadline-driven `poll()`, no busy-wait; MCP fds folded into the
  same poll set (no 100 Hz `mcp.poll()` spin); a `pane_set_stable` guard so a
  spawn/close mid-iteration can't mis-tag output against a stale `fds[]`.
- **Stale-socket recovery**: `ipc.listen` unlinks before bind, and
  `connectToSession` verifies by connecting — a crash/reboot never blocks
  restart under the same name.
- **Dead-pane reaping**: `checkPaneAlive` clears the dead id from every workspace
  flat list *and* split tree before freeing (the v0.4.x invariant), throttled to
  a 5 s sweep except on POLLHUP/POLLERR.
- **Wire protocol**: small, framed, well-tested (44 protocol tests), with correct
  partial-frame handling on non-blocking sockets (`recvMessage`'s bounded poll).
- **Predefined layouts already exist**: `examples/claude-power.tsess` is a
  10-workspace / 34-pane definition that mirrors the user's tmux `claude-power`
  config (1:landing … 0:ops-heal). `teru -n NAME -t claude-power` is the
  predefined-positions feature.

## Remaining gaps (not fixed — recommended follow-ups)

- **Reattach fidelity (medium).** `Daemon.sendGridSync` replays the visible grid
  as **plain ASCII 32–126 only** — it drops SGR colours/attributes, wide/Unicode
  characters (box-drawing → spaces), the cursor position, and all scrollback. For
  an active TUI agent (Claude Code) the next frame repaints and it self-heals; for
  an idle shell the prompt loses colour until the next command. tmux replays a
  full attributed cell grid. Recommend faithful grid serialization (emit SGR runs
  + full codepoints), or — cheaper — a forced repaint nudge on attach.
- **Single client per session (low).** `tryAcceptClient` disconnects the previous
  client. Fine for one laptop; tmux allows multiple concurrent attachments to one
  session (shared view). Note as a known limitation.
- **`teru --daemon` (direct) does not daemonize (low).** Only the `teru -n`
  auto-start path detaches; a directly-run `teru --daemon NAME` stays foreground.
  Arguably correct (explicit foreground), but inconsistent. If direct-run should
  background, give `runHeadless` the same fork→setsid→stdio-redirect.

## Tests added

- `tests/session_survival_e2e.py` — disconnect-survival + reattach-resume (the
  headline guarantee), with snapshots.
- `tests/daemon_resize_stress.py` — daemon is uncrashable by client `resize(0,0)`.
- `tests/many_pane_e2e.py` — every pane drained at 40 panes (no poll-set cap).
- `tests/marker.sh` — the long-running "agent" stand-in used by the above.
- `modes/common.zig` inline test `parseDaemonStateSync: multi-pane attach
  re-links every pane's vt.grid` — the defect-4 regression guard (first inline
  test in `modes/common.zig`; wired into the test graph via `src/lib.zig`).

All three python E2Es pass; the inline unit suite is now **527** (was 526) and
passes (test-binary exit 0). Verified end-to-end on the deploy server: install,
9-pane attach (no crash), disconnect-survival (heartbeat advanced across an SSH
drop), reattach-resume.
