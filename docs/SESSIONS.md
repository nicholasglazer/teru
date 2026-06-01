---
relates_to:
  - src/server/daemon.zig
  - src/modes/daemon.zig
  - src/modes/common.zig
  - src/config/SessionDef.zig
  - examples/claude-power.tsess
last_verified: "2026-06-01"
category: "guides"
audience: "all"
---

# Persistent Sessions (the tmux replacement)

`teru` sessions are a tmux replacement for the remote-agent workflow: ssh into a
box, start a named session, run as many agents as you want, **close your laptop,
and the agents keep running**. Reconnect later and pick up exactly where you left
off. A headless **daemon** owns the PTYs and survives every client disconnect.

## TL;DR

```sh
# On the server, over ssh:
teru -n work                 # start (or attach to) the session named "work"
teru -n work -t claude-power # …starting from a predefined 10-workspace layout

#  …do your work, then just close the laptop. The daemon keeps running.

# Reconnect (new ssh):
teru -n work                 # reattaches to the SAME running session
teru -l                      # list active sessions
```

Detach without killing anything: **Ctrl-\\** (or just drop the connection).

## How it works

`teru -n NAME` does two things:

1. If a daemon for `NAME` is already running, it **attaches** to it.
2. Otherwise it **auto-starts** a headless daemon (forked, `setsid()`-detached
   from your ssh terminal) and then attaches.

The daemon holds the pane PTYs. Your client (the thing rendering in your
terminal) is disposable: when the ssh connection drops, the kernel hangs up your
login session, the *client* goes away — but the daemon is in its own session with
no controlling terminal, so it (and every agent inside it) keeps running. On
reconnect, a fresh client attaches to the same daemon and the daemon replays the
current screen state.

Over ssh (a `tty`, no display server) the client renders as a full-screen ANSI
TUI; on a local display server it renders in a window. Same daemon either way.

The session is also snapshotted to disk (`~/.config/teru/sessions/NAME.bin`,
debounced) so layout can be restored even after a full daemon restart / reboot.

## Predefined layouts (`.tsess` templates)

A `.tsess` file defines workspaces and panes — "as many subwindows as you need",
in fixed positions, optionally auto-starting a command in each. This is the
equivalent of a tmuxinator / tmux `source-file` layout.

```ini
[session]
name = work

[workspace.1]
name = landing
layout = monocle

[workspace.1.pane.1]
role = landing
cmd  = claude --dangerously-skip-permissions -n landing
cwd  = ~/prod
auto_start = false      # pre-type the command but wait for Enter (don't run yet)

[workspace.2]
name   = server
layout = columns        # two panes side by side

[workspace.2.pane.1]
role = server-1
cmd  = claude -n server-1
cwd  = ~/prod

[workspace.2.pane.2]
role = server-2
cmd  = claude -n server-2
cwd  = ~/prod
```

Templates are searched in `~/.config/teru/templates/NAME.tsess`, then
`./examples/NAME.tsess`, or you can pass an absolute path. Apply one on first
start with `-t`:

```sh
teru -n work -t work          # ~/.config/teru/templates/work.tsess
teru -n work -t /path/to.tsess
```

A worked 10-workspace / 34-pane example mirroring a real "claude-power" tmux
setup ships at [`examples/claude-power.tsess`](../examples/claude-power.tsess)
(1:landing 2:server 3:admin 4:dash 5:git 6:qa 7:docs 8:deploy 9:app-heal
0:ops-heal). `layout =` per workspace selects one of the eight tiling layouts
(`master-stack`, `grid`, `monocle`, `columns`, `three-col`, `dishes`, `spiral`,
`accordion`); `ratio =` sets the master split. `auto_start = false` pre-types the
command so you confirm with Enter rather than launching everything at once.

Workspace limits: up to 10 workspaces, 16 panes each. The daemon polls **every**
pane across all workspaces, so there is no practical cap on concurrent agents in
one session beyond that 160-pane ceiling.

## Switching, splitting, detaching

Inside an attached session:

- **Alt+1 … Alt+0** — switch workspace (same muscle memory as tmux `M-1`…`M-9`).
- **Alt+C** — new pane in the current workspace.
- **Ctrl-\\** — detach (leaves everything running).

See [KEYBINDINGS.md](KEYBINDINGS.md) for the full set.

## Commands

| Command | Effect |
|---|---|
| `teru -n NAME` | attach to, or auto-start, session `NAME` |
| `teru -n NAME -t TMPL` | …starting from template `TMPL` on first launch |
| `teru --daemon NAME` | start a headless daemon in the foreground (no attach) |
| `teru --daemon NAME -t TMPL` | …with a template |
| `teru -l` / `teru --list` | list active sessions |
| `Ctrl-\\` | detach the current client |

## Diagnostics

A backgrounded daemon logs to `$XDG_RUNTIME_DIR/teru-session-<name>.log`
(stdout + stderr, including `TERU_LOG=debug` output). Tail it to watch a session
you're not attached to:

```sh
tail -f "$XDG_RUNTIME_DIR/teru-session-work.log"
```

See [DEBUGGING.md](DEBUGGING.md) for the full logging story.

## Known limitations

- **Reattach colour fidelity.** On reattach the daemon replays the visible screen
  as text; an active agent repaints within a frame, but an idle shell prompt can
  briefly show without colour until its next redraw. Scrollback is not replayed.
- **One client per session.** Attaching from a second place detaches the first
  (no shared-view multi-attach yet).
