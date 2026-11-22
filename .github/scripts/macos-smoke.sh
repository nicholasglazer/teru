#!/usr/bin/env bash
# macOS smoke test for CI. Starts teru in the runner's GUI session, checks
# that it stays up and opens a window, that its event loop answers an MCP
# request, types into it and quits it with Cmd+Q if macOS lets osascript
# send keystrokes, and takes screenshots along the way. Fails when teru
# exits early, dies from a signal, exits with an error, stops answering, or
# ignores keystrokes that macOS confirms reached it while it was frontmost.
# Every wait is bounded, so it cannot hang the job.
#
# Usage: macos-smoke.sh <teru binary> <output dir>
set -u

bin=${1:?teru binary}
out=${2:?output dir}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
summary="$out/summary.txt"
: > "$summary"
failed=0

note() { echo "$*" | tee -a "$summary"; }
fail() { note "FAIL: $*"; failed=1; }
# macOS has no timeout(1): perl's alarm kills the command after $1 seconds.
limit() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$secs" "$@"; }
shot() { limit 20 screencapture -x "$out/$1.png" || note "screencapture $1 failed"; }

describe_status() {
    local rc=$1
    if [ "$rc" -gt 128 ]; then
        local sig=$((rc - 128))
        echo "killed by signal $sig ($(kill -l "$sig" 2>/dev/null || echo '?'))"
    else
        echo "exit status $rc"
    fi
}

note "binary: $bin"
vtool -show-build "$bin" > "$out/build-info.txt" 2>&1 || otool -l "$bin" | grep -A4 LC_BUILD_VERSION > "$out/build-info.txt"
note "minos: $(grep -m1 -i minos "$out/build-info.txt" || echo unknown)"
if ! limit 10 "$bin" --version >> "$summary" 2>&1; then
    fail "teru --version"
    exit 1
fi

rm -f /tmp/teru-smoke-typed
shot 0-before
TERU_LOG=debug "$bin" > "$out/teru.log" 2>&1 &
pid=$!
note "started teru, pid $pid"

alive() { kill -0 "$pid" 2>/dev/null; }

# Bring teru to the front and check that it got there. Sets front_pid.
front_pid=
is_front() {
    limit 15 osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >> "$out/osascript.txt" 2>&1 || return 1
    sleep 1
    front_pid=$(limit 15 osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>> "$out/osascript.txt")
    [ "$front_pid" = "$pid" ]
}

# Wait for it to settle (font load, shell start). It must still be running.
for _ in $(seq 1 20); do alive || break; sleep 0.5; done
if ! alive; then
    wait "$pid"
    rc=$?
    fail "teru exited during startup: $(describe_status $rc)"
fi

if [ "$failed" = 0 ]; then
    shot 1-started

    if limit 180 swift "$here/macos-windows.swift" "$pid" > "$out/windows.txt" 2>&1; then
        note "window: $(head -n1 "$out/windows.txt")"
    else
        note "WARN: no on-screen window owned by teru (see windows.txt)"
        echo "::warning::macOS smoke test: no on-screen window owned by teru"
    fi

    # The main loop serves teru's MCP socket, so an answer proves it is
    # still turning. Needs no Accessibility permission.
    # ipc.buildPath on macOS: $TMPDIR/teru-$UID-mcp-$PID.sock.
    sock="${TMPDIR:-/tmp}"
    sock="${sock%/}/teru-$(id -u)-mcp-$pid.sock"
    if [ -S "$sock" ]; then
        req='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"teru_list_panes","arguments":{}}}'
        printf '%s\n' "$req" | TERU_MCP_SOCKET="$sock" limit 15 "$bin" --mcp-server > "$out/mcp.txt" 2>&1
        if grep -q '"result"' "$out/mcp.txt"; then
            note "mcp: teru answered teru_list_panes"
        else
            fail "teru did not answer an MCP request on $sock: $(head -c 300 "$out/mcp.txt")"
        fi
    else
        note "WARN: no MCP socket at $sock"
        echo "::warning::macOS smoke test: teru's MCP socket was not found"
    fi

    # Typing needs Accessibility permission for osascript, which a runner
    # may not grant. A keystroke counts as delivered only when osascript
    # succeeded and teru was the frontmost process at the time; teru must
    # then act on it. Otherwise only liveness and screenshots are checked.
    if is_front && limit 20 osascript \
        -e 'tell application "System Events" to keystroke "echo teru-smoke-ok > /tmp/teru-smoke-typed"' \
        -e 'tell application "System Events" to key code 36' >> "$out/osascript.txt" 2>&1; then
        for _ in $(seq 1 10); do [ -f /tmp/teru-smoke-typed ] && break; sleep 0.5; done
        if [ -f /tmp/teru-smoke-typed ]; then
            note "typing: the shell in teru ran a typed command"
        else
            fail "keystrokes reached teru while it was frontmost, but the typed command did not run"
        fi
    else
        note "keystrokes: not delivered to teru (frontmost: ${front_pid:-?}; $(tail -c 200 "$out/osascript.txt"))"
    fi
    shot 2-after-typing

    if ! alive; then
        wait "$pid"
        rc=$?
        fail "teru died while running: $(describe_status $rc)"
    fi
fi

if alive; then
    # Quit the way a user would (Cmd+Q, which runs teru's own shutdown).
    # SIGTERM only when the keystroke could not be delivered: teru has no
    # SIGTERM handler, so that ends even a hung teru with 143 and proves
    # nothing. SIGKILL as the last resort.
    quit_by=sigterm
    if is_front && limit 15 osascript -e 'tell application "System Events" to keystroke "q" using command down' >> "$out/osascript.txt" 2>&1; then
        quit_by=cmd-q
        for _ in $(seq 1 20); do alive || break; sleep 0.5; done
        alive && fail "Cmd+Q reached teru while it was frontmost, but teru did not quit"
    else
        note "Cmd+Q: not delivered to teru (frontmost: ${front_pid:-?})"
    fi
    if alive; then
        kill -TERM "$pid" 2>/dev/null
        for _ in $(seq 1 20); do alive || break; sleep 0.5; done
    fi
    if alive; then
        kill -KILL "$pid" 2>/dev/null
        fail "teru did not exit after SIGTERM"
    fi
    wait "$pid"
    rc=$?
    note "quit by $quit_by: $(describe_status $rc)"
    case "$quit_by:$rc" in
        cmd-q:0 | sigterm:143 | sigterm:0) ;;
        *) [ "$failed" = 1 ] || fail "unexpected end: $(describe_status $rc)" ;;
    esac
fi

# Crash reports written by macOS, if any. ReportCrash writes them a few
# seconds after the process dies, so wait for one after a signal.
if [ "${rc:-0}" -gt 128 ]; then
    for _ in $(seq 1 30); do
        find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'teru*.ips' -mmin -30 2>/dev/null | grep -q . && break
        sleep 0.5
    done
fi
find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'teru*' -mmin -30 -exec cp {} "$out/" \; 2>/dev/null
if ls "$out"/teru*.ips > /dev/null 2>&1; then
    fail "macOS wrote a crash report for teru"
fi

echo "--- teru log (last 50 lines) ---"
tail -n 50 "$out/teru.log"
echo "--- summary ---"
cat "$summary"
exit "$failed"
