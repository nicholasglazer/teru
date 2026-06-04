#!/bin/bash
# recompile-restart.sh — xmonad-style "recompile + hot-restart" for teruwm,
# in one keypress. Bind it in ~/.config/teruwm/config:
#
#   [keybind]
#   mod+q = spawn:foot -e /home/ng/code/workbench/foss/teru/tools/recompile-restart.sh
#
# It runs a fast DEBUG build (`make dev-install` → ~/.local/bin) and, ONLY on
# success, triggers the teruwm_restart MCP tool — which serializes PTY state
# and re-execs the freshly-installed binary with terminal sessions intact.
# On build failure it stops, leaves the compiler error on screen, and never
# restarts (a broken build can't replace the running compositor).
#
# Why bash (not /bin/sh): we pipe the build through `tee` to a log AND need
# the build's real exit code — `${PIPESTATUS[0]}` is bash-only. The shebang
# wins regardless of how teruwm's `spawn:` launches us (/bin/sh -c …).
#
# Requires teruwm to have been launched from ~/.local/bin/teruwm (which is
# what `startt` does), so the restart's deleted-inode re-resolve picks up the
# binary `make dev-install` just wrote. See resolveSelfExe in ServerRestart.zig.
set -uo pipefail

REPO="${TERUWM_REPO:-/home/ng/code/workbench/foss/teru}"
LOG="${XDG_RUNTIME_DIR:-/tmp}/teruwm-rebuild.log"
LOCK="${XDG_RUNTIME_DIR:-/tmp}/teruwm-recompile.lock"

# Single-flight: a second keypress while a build is running no-ops instead of
# racing the zig cache / the install of ~/.local/bin/teruwm.
exec 9>"$LOCK"
if ! flock -n 9; then
    printf '\033[33m== a teruwm recompile is already running — ignoring ==\033[0m\n'
    sleep 1
    exit 1
fi

cd "$REPO" || { printf '\033[31mcannot cd to %s\033[0m\n' "$REPO"; sleep 2; exit 1; }

printf '\033[1m== teruwm recompile (make dev-install) ==\033[0m\n'

# Build, mirroring output to the screen and to $LOG (recoverable if this
# window is gone). PIPESTATUS[0] is make's real exit code, not tee's.
make dev-install 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}

if [ "$rc" -ne 0 ]; then
    printf '\033[31m== build FAILED (rc=%s) — NOT restarting ==\033[0m\n' "$rc"
    printf 'Error above (also in %s). Fix it, then press the recompile key again.\n' "$LOG"
    printf 'Press Enter to close…'; read -r _ || true
    exit "$rc"
fi

printf '\033[32m== build OK — hot-restarting teruwm ==\033[0m\n'
# teruwm_restart takes no args; mcp-probe auto-discovers teruwm-mcp-*.sock via
# $XDG_RUNTIME_DIR (inherited from the compositor environment).
if ! python3 "$REPO/tools/mcp-probe.py" teruwm_restart; then
    printf '\033[31m== restart trigger failed (teruwm socket not found?) ==\033[0m\n'
    printf 'The new binary IS installed at ~/.local/bin/teruwm — press $mod+'"'"' to restart manually.\n'
    printf 'Press Enter to close…'; read -r _ || true
    exit 1
fi
# Success: teruwm exec()s on its next frame. This window goes away with the
# restart; nothing more to do here.
