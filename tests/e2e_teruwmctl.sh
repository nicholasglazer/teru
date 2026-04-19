#!/usr/bin/env bash
# End-to-end smoke test for teruwmctl.
#
# Spawns a headless teruwm, drives it exclusively through teruwmctl's
# positional verbs, streams events via `teruwmctl watch`, and confirms
# `teruwmctl quit` cleanly shuts the compositor down.
#
# Runs with WLR_BACKENDS=headless so it can't touch the user's live
# session; requires zig-out/bin/{teruwm,teruwmctl} to be built.

set -euo pipefail

TERUWM="${TERUWM:-$PWD/zig-out/bin/teruwm}"
TERUWMCTL="${TERUWMCTL:-$PWD/zig-out/bin/teruwmctl}"
UID_NUM="$(id -u)"
SOCK_DIR="/run/user/$UID_NUM"
SHOT_DIR="/tmp/teruwmctl-e2e-shots"
LOG="/tmp/teruwmctl-e2e-teruwm.stderr"
WATCH_LOG="/tmp/teruwmctl-e2e-watch.out"

pass=0; fail=0
ok()   { printf '\033[32mOK\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '\033[31mFAIL\033[0m %s — %s\n' "$1" "$2"; fail=$((fail+1)); }

cleanup() {
    set +e
    [[ -n "${WATCH_PID:-}" ]] && kill "$WATCH_PID" 2>/dev/null || true
    [[ -n "${WM_PID:-}" ]] && kill "$WM_PID" 2>/dev/null || true
    wait 2>/dev/null
    rm -f "$SOCK_DIR"/teruwm-mcp-*.sock 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$SHOT_DIR"; mkdir -p "$SHOT_DIR"
: > "$LOG"; : > "$WATCH_LOG"

# ── boot ───────────────────────────────────────────────────────────
echo "== starting headless teruwm ==" >&2
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 XDG_RUNTIME_DIR="$SOCK_DIR" \
    "$TERUWM" >/dev/null 2>"$LOG" &
WM_PID=$!

# Wait up to 10s for the socket.
for _ in $(seq 1 100); do
    if ls "$SOCK_DIR"/teruwm-mcp-"$WM_PID".sock >/dev/null 2>&1; then break; fi
    sleep 0.1
done
if ! ls "$SOCK_DIR"/teruwm-mcp-"$WM_PID".sock >/dev/null 2>&1; then
    echo "FAIL: teruwm socket never appeared. stderr:"; cat "$LOG"; exit 1
fi
export TERUWM_MCP_SOCKET="$SOCK_DIR/teruwm-mcp-$WM_PID.sock"
echo "socket=$TERUWM_MCP_SOCKET" >&2
sleep 0.3  # settle for initial terminal spawn

# ── 1) list-tools ──────────────────────────────────────────────────
if "$TERUWMCTL" list-tools | grep -q teruwm_quit; then
    ok "list-tools includes teruwm_quit"
else
    bad "list-tools" "missing teruwm_quit"
fi

# ── 2) positional verbs ────────────────────────────────────────────
# switch-workspace (response is plain text "switched to workspace N")
if "$TERUWMCTL" switch-workspace 3 | grep -q "switched to workspace 3"; then
    ok "switch-workspace 3"
else
    bad "switch-workspace" "did not confirm switch"
fi

# notify (response is "notification logged")
if "$TERUWMCTL" notify "hello from e2e" | grep -q "notification logged"; then
    ok 'notify "hello from e2e"'
else
    bad "notify" "did not confirm notification"
fi

# list-workspaces — JSON array of workspace records, now single-escaped
if "$TERUWMCTL" list-workspaces | grep -q '"id":3,"layout":'; then
    ok "list-workspaces shows id:3"
else
    bad "list-workspaces" "expected single-escaped JSON"
fi

# spawn-terminal [WS] — returns node id as text (e.g. "spawned terminal pane (node 1)")
SPAWN_OUT="$("$TERUWMCTL" spawn-terminal 2)"
if [[ "$SPAWN_OUT" == *"spawned"* ]] || [[ "$SPAWN_OUT" == *"node"* ]]; then
    ok "spawn-terminal 2 → $SPAWN_OUT"
else
    bad "spawn-terminal" "unexpected: $SPAWN_OUT"
fi
sleep 0.3

# list-windows (should include a "terminal" kind)
WINDOWS="$("$TERUWMCTL" list-windows)"
if [[ "$WINDOWS" == *'"kind":"terminal"'* ]]; then
    ok "list-windows returns a terminal"
else
    bad "list-windows" "no terminal kind in output: $WINDOWS"
fi
# Pull first node_id (now single-escaped: "id":N)
NODE_ID="$(echo "$WINDOWS" | grep -oE '"id":[0-9]+' | head -1 | grep -oE '[0-9]+')"
if [[ -z "$NODE_ID" ]]; then
    bad "list-windows parse" "couldn't extract node_id"
    NODE_ID=1
fi

# focus-window ID (response is text)
if "$TERUWMCTL" focus-window "$NODE_ID" 2>&1 | grep -qE "focused|Node"; then
    ok "focus-window $NODE_ID"
else
    bad "focus-window" "unexpected response"
fi

# set-layout LAYOUT (compositor returns plain "ok")
SET_LAYOUT_OUT="$("$TERUWMCTL" set-layout grid)"
if [[ "$SET_LAYOUT_OUT" == "ok" ]] || [[ "$SET_LAYOUT_OUT" == *"grid"* ]]; then
    ok "set-layout grid"
else
    bad "set-layout" "unexpected: $SET_LAYOUT_OUT"
fi

# toggle-bar WHICH
if "$TERUWMCTL" toggle-bar top | grep -qE "bar|top|enabled"; then
    ok "toggle-bar top"
else
    bad "toggle-bar" "no bar confirmation"
fi

# set-config KEY VALUE
if "$TERUWMCTL" set-config gap 12 | grep -qE "gap|set|applied"; then
    ok "set-config gap 12"
else
    bad "set-config" "did not apply"
fi

# get-config (0-arg)
if "$TERUWMCTL" get-config | grep -q '"gap":12'; then
    ok "get-config reports gap:12"
else
    bad "get-config" "gap did not persist"
fi

# move-to-workspace ID WS
if "$TERUWMCTL" move-to-workspace "$NODE_ID" 1 | grep -qE "moved|Moved|workspace"; then
    ok "move-to-workspace $NODE_ID 1"
else
    bad "move-to-workspace" "unexpected response"
fi

# screenshot [PATH]
SHOT="$SHOT_DIR/test.png"
if "$TERUWMCTL" screenshot "$SHOT" | grep -q "$SHOT"; then
    if [[ -s "$SHOT" ]]; then
        ok "screenshot $SHOT ($(stat -c%s "$SHOT") bytes)"
    else
        bad "screenshot" "file empty"
    fi
else
    bad "screenshot" "did not report output path"
fi

# click X Y — headless compositor has a real input seat, safe to fire.
if "$TERUWMCTL" click 100 200 | grep -qE '"kind":|cx|cy|none'; then
    ok "click 100 200"
else
    bad "click" "unexpected response"
fi

# scratchpad NAME — xmonad-style named toggle. First call creates +
# shows (created=true, visible=true); second call hides it on the
# same workspace (visible=false). Validates both the verb and the
# idempotent-by-name semantics the tool documents.
SP1="$("$TERUWMCTL" scratchpad term)"
if [[ "$SP1" == *"visible=true"* ]] && [[ "$SP1" == *"created=true"* ]]; then
    ok "scratchpad term (first call shows + creates)"
else
    bad "scratchpad term" "unexpected first call: $SP1"
fi
SP2="$("$TERUWMCTL" scratchpad term)"
if [[ "$SP2" == *"visible=false"* ]] && [[ "$SP2" == *"created=true"* ]]; then
    ok "scratchpad term (second call hides)"
else
    bad "scratchpad term" "unexpected second call: $SP2"
fi

# toggle-scratchpad N — numbered compat shim → name=padN+1.
SP_NUM="$("$TERUWMCTL" toggle-scratchpad 0)"
if [[ "$SP_NUM" == *"pad1"* ]] && [[ "$SP_NUM" == *"visible="* ]]; then
    ok "toggle-scratchpad 0 → pad1"
else
    bad "toggle-scratchpad" "unexpected: $SP_NUM"
fi

# The scratchpad panes register as terminals prefixed with "scratch-".
if "$TERUWMCTL" list-windows | grep -q '"name":"scratch-term"'; then
    ok "list-windows shows the scratchpad pane"
else
    bad "list-windows scratchpad" "no scratch-term pane"
fi

# Scratchpad KEYBIND path — dispatch via action name (bypasses xkb).
# scratchpad_0 must resolve to the default "term" name and toggle
# exactly like `teruwmctl scratchpad term` did above.
KB_SP0="$("$TERUWMCTL" call teruwm_test_key '{"action":"scratchpad_0"}')"
if [[ "$KB_SP0" == *"handled=true"* ]]; then
    ok "keybind scratchpad_0 dispatches (Mod+T default)"
else
    bad "scratchpad_0 keybind" "unexpected: $KB_SP0"
fi
KB_SP2="$("$TERUWMCTL" call teruwm_test_key '{"action":"scratchpad_2"}')"
if [[ "$KB_SP2" == *"handled=true"* ]]; then
    ok "keybind scratchpad_2 dispatches (Mod+H default)"
else
    bad "scratchpad_2 keybind" "unexpected: $KB_SP2"
fi
# scratchpad_2 uses the default name "htop" — verify a scratch-htop
# pane got created.
if "$TERUWMCTL" list-windows | grep -q '"name":"scratch-htop"'; then
    ok "scratchpad_2 spawned scratch-htop pane"
else
    bad "scratchpad_2 spawn" "no scratch-htop pane in list-windows"
fi

# ── 3) JSON escape hatch still works ──────────────────────────────
if "$TERUWMCTL" switch-workspace '{"workspace":4}' | grep -q "switched to workspace 4"; then
    ok "JSON escape hatch for switch-workspace"
else
    bad "JSON escape hatch" "did not apply"
fi

# ── 4) bad input rejection ────────────────────────────────────────
# Both cases exit non-zero, so capture via `|| true` to disarm pipefail.
BAD_INT_OUT="$("$TERUWMCTL" switch-workspace abc 2>&1 || true)"
if echo "$BAD_INT_OUT" | grep -q "expects an integer"; then
    ok "bad int rejected with clear message"
else
    bad "bad int" "unexpected output: $BAD_INT_OUT"
fi

BOGUS_OUT="$("$TERUWMCTL" nonexistent-verb 2>&1 || true)"
if echo "$BOGUS_OUT" | grep -qE "Unknown tool|Method not found|Invalid"; then
    ok "bogus verb rejected by server"
else
    bad "bogus verb" "unexpected output: $BOGUS_OUT"
fi

# ── 5) watch subcommand ────────────────────────────────────────────
echo "== launching teruwmctl watch ==" >&2
"$TERUWMCTL" watch > "$WATCH_LOG" 2>&1 &
WATCH_PID=$!
sleep 0.3

# Fire two events and a workspace switch.
"$TERUWMCTL" notify "watch-tick-1" >/dev/null
"$TERUWMCTL" switch-workspace 5 >/dev/null
"$TERUWMCTL" switch-workspace 6 >/dev/null
sleep 0.3

if grep -q '"event":"workspace_switched"' "$WATCH_LOG"; then
    ok "watch received workspace_switched event"
else
    bad "watch" "no workspace_switched event in log: $(cat "$WATCH_LOG" | head -3)"
fi

if grep -qE '"to":5|"to":6' "$WATCH_LOG"; then
    ok "watch captured workspace switch to 5 or 6"
else
    bad "watch" "no workspace transition to 5 or 6"
fi

kill "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""

# ── 6) teruwm_quit tool (shuts compositor cleanly) ─────────────────
QUIT_OUT="$("$TERUWMCTL" quit)"
if [[ "$QUIT_OUT" == *"quit scheduled"* ]]; then
    ok "teruwm_quit returned scheduled message"
else
    bad "teruwm_quit" "unexpected: $QUIT_OUT"
fi

# Give the compositor ~2 s to exit.
sleep 1.0
if kill -0 "$WM_PID" 2>/dev/null; then
    bad "teruwm_quit" "teruwm still alive after quit (pid $WM_PID)"
    kill "$WM_PID" || true
else
    ok "teruwm exited cleanly after quit"
fi

# Socket removed?
if ls "$SOCK_DIR"/teruwm-mcp-"$WM_PID".sock >/dev/null 2>&1; then
    bad "socket cleanup" "socket file persisted after shutdown"
else
    ok "socket file cleaned up after shutdown"
fi
WM_PID=""

# ── summary ────────────────────────────────────────────────────────
echo
echo "passed: $pass"
echo "failed: $fail"
[[ "$fail" -eq 0 ]]
