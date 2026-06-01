#!/usr/bin/env python3
"""Regression test: a client must never be able to crash the session daemon.

Before the 0-dimension guards, a client that sent resize(0,0) drove every pane
grid to 0 cols; the next byte of PTY output fed VtParser an empty cell slice and
panicked the daemon — killing every agent it owned. This test drives the raw
daemon wire protocol to send that exact malicious frame, then confirms the
daemon stays alive and keeps serving.

Run:  python3 tests/daemon_resize_stress.py
Exit: 0 = daemon survived the hostile resize; non-zero otherwise.
"""
import os, socket, struct, time, subprocess, sys, pty

REPO = "/home/ng/code/workbench/foss/teru"
TERU = REPO + "/zig-out/bin/teru"
NAME = "rstress"
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
SOCK = os.path.join(RUNTIME, f"teru-session-{NAME}.sock")

# Wire protocol (src/server/protocol.zig): header = tag(1) + len(u32 LE), payload.
TAG_RESIZE, TAG_ACTIVE_INPUT = 2, 7
def frame(tag, payload=b""):
    return bytes([tag]) + struct.pack("<I", len(payload)) + payload
def resize(rows, cols):     # encodeResize: u16 rows LE + u16 cols LE
    return frame(TAG_RESIZE, struct.pack("<HH", rows, cols))
def active_input(data):
    return frame(TAG_ACTIVE_INPUT, data)

def alive(pid): return pid is not None and os.path.exists(f"/proc/{pid}")
def scan(pat):
    for d in os.listdir("/proc"):
        if not d.isdigit(): continue
        try: cl = open(f"/proc/{d}/cmdline","rb").read().replace(b"\0",b" ").decode("utf-8","replace")
        except OSError: continue
        if pat in cl: return int(d)
    return None

def main():
    if not os.path.exists(TERU): sys.exit(f"FAIL: {TERU} not built")
    try: os.unlink(SOCK)
    except OSError: pass

    # Start the daemon directly in a pty (it spawns a default shell pane).
    pid, master = pty.fork()
    if pid == 0:
        e = dict(os.environ); e.pop("DISPLAY",None); e.pop("WAYLAND_DISPLAY",None)
        e["TERM"]="xterm-256color"
        os.execvpe(TERU, [TERU, "--daemon", NAME], e)
    import threading
    def drain():
        try:
            while os.read(master, 4096): pass
        except OSError: pass
    threading.Thread(target=drain, daemon=True).start()

    dl = time.time() + 8
    while time.time() < dl and not os.path.exists(SOCK): time.sleep(0.1)
    dpid = scan(f"--daemon {NAME}")
    if not (os.path.exists(SOCK) and alive(dpid)):
        print(f"FAIL: daemon did not start (sock={os.path.exists(SOCK)} pid={dpid})")
        sys.exit(1)
    print(f"daemon up: pid={dpid} sock=✓")

    # Connect and send the hostile sequence: resize to 0x0, then input that makes
    # the shell emit output (which the daemon feeds into the now-0-dim grid).
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.connect(SOCK)
    time.sleep(0.3)
    print("sending resize(0,0) …")
    c.sendall(resize(0, 0))
    time.sleep(0.3)
    print("sending input 'echo STRESS_OK' (forces PTY output into the grid) …")
    c.sendall(active_input(b"echo STRESS_OK\n"))
    time.sleep(0.5)
    # also hammer a few more 0x0 resizes interleaved with input
    for _ in range(5):
        c.sendall(resize(0, 0)); c.sendall(active_input(b"echo x\n")); time.sleep(0.1)
    time.sleep(1.0)

    survived = alive(dpid)
    print(f"\ndaemon pid {dpid} alive after hostile resize: {survived}")
    # A second client should still be able to attach (daemon still serving).
    serving = False
    try:
        c2 = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c2.connect(SOCK)
        c2.close(); serving = True
    except OSError: pass
    print(f"daemon still accepting connections: {serving}")

    try: c.close()
    except OSError: pass
    # cleanup (specific pid only)
    try:
        os.close(master)
    except OSError: pass
    if alive(dpid): os.kill(dpid, 9)
    try: os.unlink(SOCK)
    except OSError: pass

    ok = survived and serving
    print("\nVERDICT:", "PASS ✓" if ok else "FAIL ✗ (daemon crashed on client resize)")
    sys.exit(0 if ok else 2)

if __name__ == "__main__":
    main()
