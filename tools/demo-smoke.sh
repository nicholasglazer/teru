#!/usr/bin/env bash
# demo-smoke.sh — pre-presentation confidence check for teru/teruwm.
#
# Phase A runs the automated suites (headless, ~5 min). Phase B is a manual
# hardware checklist you run ONCE on a free VT before the talk — the riskiest
# demo moves (projector hotplug, X11 app, hot-restart, bare-TTY quit) only
# fail on real DRM and cannot be covered headless.
#
# Usage:  bash tools/demo-smoke.sh        # Phase A + print Phase B checklist
set -uo pipefail
cd "$(dirname "$0")/.."

CRT=$([ -f .cache/crt-fix-all/libc.txt ] && echo "--libc .cache/crt-fix-all/libc.txt")
pass=0; fail=0
run() { # run <label> <cmd...>
  local label="$1"; shift
  printf '  %-44s ' "$label"
  if "$@" >/tmp/demo-smoke-last.log 2>&1; then echo "PASS"; ((pass++)); else echo "FAIL  (tail: $(tail -1 /tmp/demo-smoke-last.log))"; ((fail++)); fi
}

echo "── Phase A: automated (headless) ────────────────────────────"
./tools/fix-crt.sh >/dev/null 2>&1
run "lib + compositor inline tests"  bash -c "zig build test -Dcompositor $CRT >/dev/null 2>&1 && b=\$(ls -t \$(find .zig-cache/o -name test -type f -executable)|head -1) && \"\$b\" >/dev/null"
run "build release binaries"         bash -c "zig build -Doptimize=ReleaseSafe -Dcompositor $CRT >/dev/null"
run "teruwm headless E2E"            bash -c "make e2e-wm >/dev/null 2>&1"
run "teruwm MCP tool/keybind sweep"  bash -c "make audit-wm >/dev/null 2>&1"
run "daemon survives SSH disconnect" python3 tests/session_survival_e2e.py
run "daemon uncrashable by resize"   python3 tests/daemon_resize_stress.py
run "40-pane drain (no poll cap)"    python3 tests/many_pane_e2e.py
# interactive_attach leaks TERM_PROGRAM into the child — unset to avoid the deadlock (task #50)
run "interactive multi-pane attach"  env -u TERM_PROGRAM -u TERU_NESTED python3 tests/interactive_attach_e2e.py

echo
echo "  Phase A: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && echo "  ⚠ fix failures before relying on the demo build."

cat <<'CHECKLIST'

── Phase B: real-hardware checklist (run on a free VT, ~5 min) ───
Do these on the actual machine BEFORE the talk — none are headless-testable:

  [ ] 1. startt → compositor up, bar renders; nvidia-smi shows dGPU idle (task #23)
  [ ] 2. $mod+Enter ×3 · $mod+Space cycle 2 layouts · $mod+1/2 + $mod+Esc
  [ ] 3. $mod+T scratchpad on/off · launch the Wayland browser you'll demo
  [ ] 4. launch ONE X11 app (xterm/legacy) — maps, focuses, closes, no crash
  [ ] 5. Ctrl+Shift+C a selection → "Copied" toast → Ctrl+Shift+V into the browser
  [ ] 6. $mod+W screenshot → toast + latest.png written
  [ ] 7. PLUG THE PROJECTOR NOW (not on stage): $mod+O / $mod+Shift+O, unplug, replug
  [ ] 8. $mod+' hot-restart with everything open — panes + scratchpad survive,
         nothing piled at (0,0), claude pane repaints
  [ ] 9. $mod+Shift+Q → VT returns to a usable console (not a frozen graphics mode)
  [ ] 10. ssh localhost → teru -n demo → detach → reattach resumes

Known-fragile-on-stage (avoid or do carefully):
  • drag-selecting text while an agent closes that pane (fixed 7a74503, but verify)
  • Mod+X immediately after spawning a terminal over a focused X11 app (task #43)
  • closing the browser then typing without clicking a pane first (task #44)
CHECKLIST
