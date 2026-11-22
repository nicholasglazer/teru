#!/usr/bin/env bash
# macOS smoke test for CI. Starts teru in the runner's GUI session, checks
# that it stays up and opens a window, types into it if macOS lets
# osascript send keystrokes, quits it, and takes screenshots along the
# way. Fails when teru exits early, dies from a signal, or exits with an
# error. Every wait is bounded, so it cannot hang the job.
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

# Wait for it to settle (font load, shell start). It must still be running.
for _ in $(seq 1 20); do alive || break; sleep 0.5; done
if ! alive; then
    wait "$pid"
    fail "teru exited during startup: $(describe_status $?)"
fi

if [ "$failed" = 0 ]; then
    shot 1-started

    if limit 180 swift "$here/macos-windows.swift" "$pid" > "$out/windows.txt" 2>&1; then
        note "window: $(head -n1 "$out/windows.txt")"
    else
        note "WARN: no on-screen window owned by teru (see windows.txt)"
        echo "::warning::macOS smoke test: no on-screen window owned by teru"
    fi

    # Typing needs Accessibility permission for osascript, which a runner
    # may not grant. Without it, only liveness and screenshots are checked.
    limit 15 osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" > /dev/null 2>&1
    if limit 20 osascript \
        -e 'tell application "System Events" to keystroke "echo teru-smoke-ok > /tmp/teru-smoke-typed"' \
        -e 'tell application "System Events" to key code 36' > "$out/osascript.txt" 2>&1; then
        sleep 3
        if [ -f /tmp/teru-smoke-typed ]; then
            note "typing: the shell in teru ran a typed command"
        else
            note "WARN: keystrokes were sent but the typed command did not run"
            echo "::warning::macOS smoke test: typed command did not run in teru"
        fi
    else
        note "keystrokes: not permitted on this runner ($(head -c 200 "$out/osascript.txt"))"
    fi
    shot 2-after-typing

    if ! alive; then
        wait "$pid"
        fail "teru died while running: $(describe_status $?)"
    fi
fi

if alive; then
    # Quit the way a user would (Cmd+Q, which runs teru's own shutdown);
    # SIGTERM if keystrokes are not permitted; SIGKILL as the last resort.
    limit 15 osascript -e 'tell application "System Events" to keystroke "q" using command down' > /dev/null 2>&1
    for _ in $(seq 1 20); do alive || break; sleep 0.5; done
    quit_by=cmd-q
    if alive; then
        quit_by=sigterm
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

# Crash reports written by macOS, if any.
find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name 'teru*' -mmin -30 -exec cp {} "$out/" \; 2>/dev/null
if ls "$out"/teru*.ips > /dev/null 2>&1; then
    fail "macOS wrote a crash report for teru"
fi

echo "--- teru log (last 50 lines) ---"
tail -n 50 "$out/teru.log"
echo "--- summary ---"
cat "$summary"
exit "$failed"
