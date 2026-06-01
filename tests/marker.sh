#!/bin/sh
# E2E marker process: stands in for a long-running agent inside a teru pane.
# Writes "<counter> <pid>" to a state file AND echoes a visible tick to its
# own stdout (so the daemon's grid captures it and a reattaching client can
# replay "where you left off"). If this keeps counting after the controlling
# terminal hangs up, the daemon (and the agent it owns) survived the SSH drop.
out="${1:-/tmp/teru_e2e_marker.out}"
i=0
printf 'START %d\n' "$$" > "$out"
while true; do
  i=$((i + 1))
  printf '%d %d\n' "$i" "$$" > "$out"
  printf 'tick %d (pid %d)\n' "$i" "$$"
  sleep 0.4
done
