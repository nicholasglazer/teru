#!/usr/bin/env python3
"""End-to-end test: does a reattaching client receive the daemon's SCROLLBACK
history, not just the visible screen?

The bug this guards: the daemon used to send only `dumpReplaySnapshot` (the
visible grid) on attach. The nested `teru -n` client rebuilds its own scrollback
purely by feeding `.output` through its VT parser and letting lines scroll off —
so on every reattach its scrollback started EMPTY and scrolling up showed nothing
above the current screen. Scroll only worked for output produced while attached.

The fix streams the daemon's scrollback (dumpReplayStream) + `rows` newlines of
padding BEFORE the visible snapshot on the initial attach, so the client's
scrollback is repopulated with pre-attach history.

Model:
  1. start a headless daemon (spawns one shell pane)
  2. client #1 attaches, resizes to 24x80, runs `seq 1 500` (≈477 lines scroll off)
  3. client #1 detaches
  4. client #2 attaches → daemon replays scrollback + snapshot
  5. assert the received bytes contain an OLD line that is only in scrollback
     (e.g. "100"), AND the newest visible line ("500")

Run:  python3 tests/scrollback_attach_e2e.py
Exit: 0 = scrollback history arrived on reattach; non-zero otherwise.
"""
import os, sys, time, socket, struct, subprocess, signal

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TERU = os.path.join(REPO, "zig-out", "bin", "teru")
SESS = "e2e_scrollback"
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
SOCK = os.path.join(RUNTIME, f"teru-session-{SESS}.sock")

# Wire protocol (src/server/protocol.zig)
TAG_OUTPUT, TAG_RESIZE, TAG_DETACH, TAG_STATE_SYNC, TAG_ACTIVE_INPUT = 1, 2, 3, 4, 7
HDR = 5  # 1 byte tag + 4 LE len


def log(m): print(f"  {m}", flush=True)


def _scan_proc(pat):
    pids = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            cl = open(f"/proc/{d}/cmdline", "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if pat in cl:
            pids.append(int(d))
    return pids


def daemon_pids():
    return _scan_proc(f"--daemon {SESS}")


def send(sock, tag, payload=b""):
    sock.sendall(bytes([tag]) + struct.pack("<I", len(payload)) + payload)


def recv_all(sock, duration):
    """Collect (tag, payload) messages for `duration` seconds."""
    sock.setblocking(False)
    buf = bytearray()
    msgs = []
    deadline = time.time() + duration
    while time.time() < deadline:
        try:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
        except BlockingIOError:
            time.sleep(0.02)
            continue
        # drain complete frames
        while len(buf) >= HDR:
            tag = buf[0]
            ln = struct.unpack("<I", buf[1:5])[0]
            if len(buf) < HDR + ln:
                break
            payload = bytes(buf[HDR:HDR + ln])
            msgs.append((tag, payload))
            del buf[:HDR + ln]
    return msgs


def connect(retries=50):
    for _ in range(retries):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(SOCK)
            return s
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.1)
    raise RuntimeError(f"could not connect to {SOCK}")


def cleanup():
    for pid in daemon_pids():
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.3)
    for pid in daemon_pids():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass


def main():
    if not os.path.exists(TERU):
        log(f"FAIL: {TERU} not built (run `make release`)")
        return 1

    cleanup()  # no stale daemon from a previous run

    env = dict(os.environ)
    env["SHELL"] = "/bin/sh"           # deterministic, prompt-light
    env["XDG_RUNTIME_DIR"] = RUNTIME

    log("starting headless daemon")
    daemon = subprocess.Popen(
        [TERU, "--daemon", SESS],
        env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    try:
        # ── client #1: attach, size, generate scrollback ──────────────
        c1 = connect()
        # daemon sends state_sync + gridsync on attach; drain briefly
        recv_all(c1, 0.4)
        # normalize the pane geometry to 24x80 so "500" lines pushes ~477 off
        send(c1, TAG_RESIZE, struct.pack("<HH", 24, 80))
        time.sleep(0.3)
        recv_all(c1, 0.3)
        # produce 500 numbered lines
        send(c1, TAG_ACTIVE_INPUT, b"seq 1 500\r")
        time.sleep(1.2)
        recv_all(c1, 0.8)  # drain the live output so it isn't confused with replay
        send(c1, TAG_DETACH)
        c1.close()
        time.sleep(0.3)

        # ── client #2: reattach, capture the replay ───────────────────
        log("reattaching (fresh client) — capturing replay")
        c2 = connect()
        msgs = recv_all(c2, 1.5)
        send(c2, TAG_DETACH)
        c2.close()

        out = b"".join(p[8:] for (t, p) in msgs if t == TAG_OUTPUT)  # strip 8B pane_id
        text = out.decode("utf-8", "replace")

        # The visible 24-row screen after `seq 1 500` shows only ~478..500.
        # An old line like 100 (or 50) can ONLY be present if scrollback replayed.
        got_new = "500" in text
        old_markers = [m for m in ("50", "100", "150", "200") if f"\x1b[0m{m}\r\n" in text or f"\n{m}\r" in text or f">{m}<" in text]
        # dumpReplayStream emits each line as ESC[0m<bytes>\r\n
        got_old = any(f"\x1b[0m{m}\r\n" in text for m in ("50", "100", "150", "200", "250"))

        log(f"replay bytes: {len(out)}  contains '500' (visible): {got_new}  "
            f"contains scrollback lines: {got_old}")

        if not got_new:
            log("FAIL: visible snapshot missing (no '500' in replay)")
            return 1
        if not got_old:
            log("FAIL: scrollback history NOT replayed on attach "
                "(no old lines found — client scrollback would be empty)")
            # show a small sample for debugging
            sample = text[:400].replace("\x1b", "\\x1b")
            log(f"sample: {sample!r}")
            return 1

        log("PASS: reattach replayed scrollback history + visible snapshot")
        return 0
    finally:
        cleanup()
        if daemon.poll() is None:
            daemon.terminate()


if __name__ == "__main__":
    sys.exit(main())
