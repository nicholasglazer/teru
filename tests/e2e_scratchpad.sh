#!/usr/bin/env bash
# Strict scratchpad keybind E2E — drive Mod+T/H chords via teruwm_test_key,
# assert each toggle moves the pane between workspace 0 (visible) and 255
# (HIDDEN_WS). Retries transient MCP connect failures up to 3× each call.

set -euo pipefail

TERUWM="/home/ng/code/foss/teru/zig-out/bin/teruwm"
CTL="/home/ng/code/foss/teru/zig-out/bin/teruwmctl"
SOCK_DIR="/run/user/$(id -u)"

pass=0; fail=0
ok()  { printf '\033[32mOK\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '\033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

# Retry wrapper — `teruwmctl` sometimes sees a transient accept race
# right after a previous call returns. 3 tries with 200ms backoff.
ctl_retry() {
    for i in 1 2 3; do
        if out="$("$CTL" "$@" 2>&1)"; then
            printf '%s' "$out"
            return 0
        fi
        sleep 0.2
    done
    printf 'RETRIES_EXHAUSTED: %s' "$out" >&2
    return 1
}

cleanup() {
    set +e
    [[ -n "${WM_PID:-}" ]] && kill "$WM_PID" 2>/dev/null || true
    rm -f "$SOCK_DIR"/teruwm-mcp-*.sock 2>/dev/null
}
trap cleanup EXIT

rm -f "$SOCK_DIR"/teruwm-mcp-*.sock
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 XDG_RUNTIME_DIR="$SOCK_DIR" \
    "$TERUWM" > /dev/null 2> /tmp/teruwm-strict.stderr &
WM_PID=$!
for _ in $(seq 1 50); do
    ls "$SOCK_DIR"/teruwm-mcp-"$WM_PID".sock >/dev/null 2>&1 && break
    sleep 0.1
done
export TERUWM_MCP_SOCKET="$SOCK_DIR/teruwm-mcp-$WM_PID.sock"
sleep 0.3

ws_of() {
    # Extract workspace for the node whose name matches "$1"
    ctl_retry list-windows | python3 -c "
import sys, json, re
data = sys.stdin.read()
data = data.replace(r'\\\"', '\"')
try:
    arr = json.loads(data)
except Exception:
    print('PARSE_FAIL', file=sys.stderr); sys.exit(2)
for w in arr:
    if w['name'] == '$1':
        print(w['workspace'])
        sys.exit(0)
print('MISSING')
"
}

# ── scratchpad_0 (Mod+T → term) ────────────────────────────────────
# Press 1: spawn + show (ws=0)
ctl_retry call teruwm_test_key '{"action":"scratchpad_0"}' > /dev/null
sleep 0.3
w="$(ws_of scratch-term)"
if [[ "$w" == "0" ]]; then ok "Mod+T press 1 → scratch-term on ws=0"
else bad "Mod+T press 1" "expected ws=0, got $w"
fi

# Press 2: hide (ws=255, HIDDEN_WS)
ctl_retry call teruwm_test_key '{"action":"scratchpad_0"}' > /dev/null
sleep 0.3
w="$(ws_of scratch-term)"
if [[ "$w" == "255" ]]; then ok "Mod+T press 2 → scratch-term hidden (ws=255)"
else bad "Mod+T press 2" "expected ws=255, got $w"
fi

# Press 3: re-show (back to ws=0)
ctl_retry call teruwm_test_key '{"action":"scratchpad_0"}' > /dev/null
sleep 0.3
w="$(ws_of scratch-term)"
if [[ "$w" == "0" ]]; then ok "Mod+T press 3 → scratch-term re-shown (ws=0)"
else bad "Mod+T press 3" "expected ws=0, got $w"
fi

# ── scratchpad_2 (Mod+H → htop) ────────────────────────────────────
ctl_retry call teruwm_test_key '{"action":"scratchpad_2"}' > /dev/null
sleep 0.3
w="$(ws_of scratch-htop)"
if [[ "$w" == "0" ]]; then ok "Mod+H press 1 → scratch-htop on ws=0"
else bad "Mod+H press 1" "expected ws=0, got $w"
fi

ctl_retry call teruwm_test_key '{"action":"scratchpad_2"}' > /dev/null
sleep 0.3
w="$(ws_of scratch-htop)"
if [[ "$w" == "255" ]]; then ok "Mod+H press 2 → scratch-htop hidden"
else bad "Mod+H press 2" "expected ws=255, got $w"
fi

# ── Cross-workspace migration (xmonad follow-me) ───────────────────
# Move to ws 3, then toggle term: it should migrate onto ws 3.
ctl_retry switch-workspace 3 > /dev/null
sleep 0.2
# term is currently on ws=0 (we re-showed it above). Toggling should
# migrate to active ws (3), not toggle visibility.
ctl_retry call teruwm_test_key '{"action":"scratchpad_0"}' > /dev/null
sleep 0.3
w="$(ws_of scratch-term)"
if [[ "$w" == "3" ]]; then ok "Mod+T from ws=3 → term migrated to ws=3"
else bad "follow-me migration" "expected ws=3, got $w"
fi

# ── Screenshot the compositor state to confirm paint (not just state) ─
SHOT=/tmp/scratch-final.png
ctl_retry screenshot "$SHOT" > /dev/null
if [[ -s "$SHOT" ]]; then
    ok "screenshot $SHOT ($(stat -c%s "$SHOT") bytes)"
else
    bad "screenshot" "empty file"
fi

echo
echo "=== compositor stderr (last 15 lines) ==="
tail -15 /tmp/teruwm-strict.stderr
echo
echo "passed: $pass"
echo "failed: $fail"
ctl_retry quit > /dev/null
[[ "$fail" -eq 0 ]]
