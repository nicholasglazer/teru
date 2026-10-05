#!/usr/bin/env python3
"""End-to-end test: does the `teru -n` client hand the mouse wheel to a pane
app that owns it, instead of scrolling its own scrollback?

The bug this guards: the client's wheel handler unconditionally scrolled the
pane's local scrollback. Claude Code's fullscreen TUI runs on the alt screen
with mouse tracking and scrolls its own transcript — so over SSH the wheel
showed pre-launch shell history glued above the live alt-screen viewport, and
never scrolled the transcript at all. The fix routes the wheel through
`mouse_report.classifyWheel`, the same decision teruwm makes locally.

Model (one single-pane session per case, the pane runs a tiny raw-mode app that
sets terminal modes then logs every stdin byte to a file):
  track     ?1049h ?1000h ?1006h  → wheel arrives as SGR `ESC[<64;…M` / `<65`
  altscroll ?1049h ?1007h         → wheel arrives as cursor keys (ESC[A / ESC[B)
  plain     no modes              → wheel stays local (scrollback); app gets nothing

Run:  python3 tests/tui_wheel_forward_e2e.py
Exit: 0 = all cases routed correctly; non-zero otherwise.
"""
import os, sys, time, struct, fcntl, termios, signal, threading, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TERU = os.environ.get("TERU") or os.path.join(REPO, "zig-out", "bin", "teru")
ROWS, COLS = 24, 80

APP = r'''
import os, sys, tty
mode, log = sys.argv[1], sys.argv[2]
tty.setraw(0)
seq = {"track": "\x1b[?1049h\x1b[?1000h\x1b[?1006h",
       "altscroll": "\x1b[?1049h\x1b[?1007h",
       "plain": ""}[mode]
os.write(1, (seq + "READY-" + mode).encode())
with open(log, "ab", buffering=0) as f:
    while True:
        b = os.read(0, 1024)
        if not b: break
        f.write(b)
'''


def scan_daemons(sess):
    out = []
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            cl = open(f"/proc/{d}/cmdline", "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if f"--daemon {sess}" in cl:
            out.append(int(d))
    return out


def kill_session(sess):
    for pid in scan_daemons(sess):
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass


def spawn(args):
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.setsid()
        try: fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        except OSError: pass
        os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
        if slave > 2: os.close(slave)
        os.close(master)
        env = dict(os.environ); env.pop("DISPLAY", None); env.pop("WAYLAND_DISPLAY", None)
        env["TERM"] = "xterm-256color"
        try: os.execvpe(TERU, [TERU] + args, env)
        except Exception as e:
            os.write(2, f"exec failed: {e}\n".encode()); os._exit(127)
    os.close(slave)
    return pid, master


def drain(fd, sink):
    try:
        while True:
            b = os.read(fd, 4096)
            if not b: break
            sink.append(b)
    except OSError:
        pass


def run_case(mode, tmp):
    sess = f"e2e_wheel_{mode}_{os.getpid()}"
    log = os.path.join(tmp, f"{mode}.log")
    app = os.path.join(tmp, "app.py")
    wrapper = os.path.join(tmp, f"run_{mode}.sh")
    open(log, "wb").close()
    with open(wrapper, "w") as f:
        f.write(f"#!/bin/sh\nexec python3 {app} {mode} {log}\n")
    os.chmod(wrapper, 0o755)
    tsess = os.path.join(tmp, f"{mode}.tsess")
    with open(tsess, "w") as f:
        f.write("\n".join(["[session]", f"name={sess}", "", "[workspace.1]", "name=main", "",
                           "[workspace.1.pane.1]", "role=app", f"cmd={wrapper}", "auto_start=true", ""]))

    kill_session(sess)
    sink = []
    pid, master = spawn(["-n", sess, "-t", tsess])
    threading.Thread(target=drain, args=(master, sink), daemon=True).start()
    try:
        deadline = time.time() + 8
        while time.time() < deadline and f"READY-{mode}".encode() not in b"".join(sink):
            time.sleep(0.1)
        if f"READY-{mode}".encode() not in b"".join(sink):
            return f"{mode}: pane app never rendered READY (session did not start)"
        time.sleep(0.5)
        # Two wheel-ups then one wheel-down at the pane centre, separate writes
        # like a real mouse (the client queues them, but don't rely on it).
        for btn in (64, 64, 65):
            os.write(master, f"\x1b[<{btn};40;12M".encode())
            time.sleep(0.3)
        time.sleep(1.0)
        got = open(log, "rb").read()
    finally:
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
        try: os.waitpid(pid, 0)
        except OSError: pass
        os.close(master)
        kill_session(sess)

    if mode == "track":
        ups, downs = got.count(b"\x1b[<64;"), got.count(b"\x1b[<65;")
        if ups == 2 and downs == 1 and got.endswith(b"M"):
            return None
        return f"track: expected 2× ESC[<64 + 1× ESC[<65 at the app, got {got!r}"
    if mode == "altscroll":
        ups, downs = got.count(b"\x1b[A"), got.count(b"\x1b[B")
        if ups == 6 and downs == 3:  # 3 lines per notch
            return None
        return f"altscroll: expected 6× ESC[A + 3× ESC[B, got {got!r}"
    if got == b"":
        return None
    return f"plain: wheel leaked into a non-mouse app as {got!r} (should scroll scrollback)"


def main():
    if not os.path.exists(TERU):
        sys.exit(f"FAIL: {TERU} not built (run `zig build`)")
    print(f"\n=== teru -n wheel-forwarding E2E ({os.popen(TERU + ' --version').read().strip()}) ===")
    fails = []
    with tempfile.TemporaryDirectory(prefix="teru-wheel-") as tmp:
        open(os.path.join(tmp, "app.py"), "w").write(APP)
        for mode in ("track", "altscroll", "plain"):
            err = run_case(mode, tmp)
            print(f"  [{mode:9}] {'PASS' if err is None else 'FAIL: ' + err}")
            if err: fails.append(err)
    print("\nALL PASS" if not fails else f"\n{len(fails)} FAILED")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
