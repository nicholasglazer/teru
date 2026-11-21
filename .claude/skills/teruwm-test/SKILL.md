---
name: teruwm-test
description: Launch an isolated headless teruwm and drive it over MCP to reproduce a bug or verify a compositor change, without touching a teruwm session that is running as the desktop. Use for any teruwm behaviour check that the unit tests cannot cover.
---

# Testing teruwm against a throwaway instance

The developer's desktop may itself be teruwm. A test that picks its target by process name, by pattern, or by sorting the sockets in the shared runtime directory will sooner or later hit the live session instead. So the test instance gets its own runtime directory, and everything about it (socket, PID) is read from that directory.

## Existing harnesses first

```sh
make e2e-wm      # spawn, tiling, shell exit, clean shutdown, no CPU spin
make audit-wm    # every MCP tool and keybind action
XDG_RUNTIME_DIR=$(mktemp -d) python3 tests/teruwm_e2e.py zig-out/bin/teruwm   # same harness, fully isolated
```

The harnesses launch headless, find the socket by their own child's PID, and stop that child. Extend them when the check is worth keeping.

## Ad-hoc instance

Build first (`zig build -Dcompositor`), then:

```sh
RT=$(mktemp -d /tmp/teruwm-test.XXXXXX); mkdir -p "$RT/home"
env XDG_RUNTIME_DIR="$RT" HOME="$RT/home" \
    WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 \
    setsid zig-out/bin/teruwm >"$RT/log" 2>&1 </dev/null &

# The only socket in $RT belongs to this instance; its name carries the PID.
SOCK=$(find "$RT" -maxdepth 1 -name 'teruwm-mcp-[0-9]*.sock' ! -name '*events*' | head -1)
WPID=${SOCK##*teruwm-mcp-}; WPID=${WPID%.sock}
```

The socket appears within a second or two; retry the `find` until it does. Do not take the PID from `$!`, which can be a wrapper shell.

Drive it with `teruwmctl`, always naming the socket. Without `TERUWM_MCP_SOCKET` it scans the real runtime directory and can reach the live session.

```sh
export TERUWM_MCP_SOCKET="$SOCK"
zig-out/bin/teruwmctl list-tools
zig-out/bin/teruwmctl call teruwm_spawn_terminal '{}'
zig-out/bin/teruwmctl list-windows
```

Stop it only after confirming the PID is the test instance:

```sh
tr '\0' '\n' </proc/$WPID/environ | grep -qx "XDG_RUNTIME_DIR=$RT" && kill "$WPID"
```

Use plain `kill` (SIGTERM). It runs the normal shutdown path, which is itself worth watching: the end of `$RT/log` shows leaks and teardown crashes.

## What works headless and what does not

- Native terminal panes work fully. Spawn one first so there is a focused terminal; `teruwm_type` and `teruwm_press` then write straight to its PTY.
- Input to Wayland or X11 client windows does not work. The headless backend has no input devices, so clients never receive a usable keyboard or pointer. Menus, clicks into GTK or Qt widgets and typing into client fields need a real backend and the developer's eyes.
- `teruwm_test_drag` takes output-global coordinates. Read the pane's rectangle from `list-windows` first.
- `teruwm_screenshot_pane` re-renders one pane, including its selection highlight. It does not capture the cursor layer, borders or anything composited across panes. Compare file hashes before and after an action to tell whether the pane changed.
- Flicker and anything timing-dependent cannot be shown by a screenshot. Say so and ask for a check on real hardware.

## Before reporting a result

- Confirm the instance runs the build under test: `readlink /proc/$WPID/exe`, and the binary's modification time.
- Reproduce the symptom before the fix and show it gone after. If the symptom needs a real display, say that it was not reproduced here.
- `TERU_LOG=debug` in the launch environment gives the full trace. `docs/DEBUGGING.md` has the details.
