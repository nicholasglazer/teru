#!/usr/bin/env python3
"""End-to-end test: does a teru daemon survive an SSH disconnect / laptop close,
and can a new client reattach and resume where the session left off?

Faithful model of the user's workflow:
  ssh -p 2248 ng@server   →   teru -n NAME   (auto-starts a daemon, attaches a TUI)
  …close laptop…          →   SSH PTY master closes → kernel SIGHUPs the login
                              session's foreground process group.

pty.fork() reproduces sshd exactly: the child becomes a *session leader* with the
PTY as its *controlling terminal*. Closing the master fd is the hangup. If the
daemon was forked without setsid(), it shares that session and dies with it — and
every agent dies too. That is the bug this test exists to catch.

Run:  python3 tests/session_survival_e2e.py [session-name]
Exit: 0 = daemon survived hangup AND reattach resumed state; non-zero otherwise.
"""
import os, sys, pty, time, signal, subprocess, glob, fcntl, termios, struct

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TERU = os.path.join(REPO, "zig-out", "bin", "teru")
MARKER = os.path.join(REPO, "tests", "marker.sh")
SESS = sys.argv[1] if len(sys.argv) > 1 else "e2e_survive"
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
SOCK = os.path.join(RUNTIME, f"teru-session-{SESS}.sock")
MARKER_OUT = f"/tmp/teru_e2e_{SESS}.out"
TSESS = f"/tmp/teru_e2e_{SESS}.tsess"

def log(msg): print(f"  {msg}", flush=True)

def pid_alive(pid):
    try:
        os.kill(pid, 0); return True
    except (ProcessLookupError, PermissionError) as e:
        return isinstance(e, PermissionError)

def _scan_proc(pat):
    """Find pids whose cmdline contains `pat`, reading /proc directly. Avoids
    pgrep/pkill -f, which match this script's own shell cmdline (and would kill
    it). Never matches the user's real teru instances — `pat` is session-unique."""
    pids = []
    for d in os.listdir("/proc"):
        if not d.isdigit(): continue
        try:
            cl = open(f"/proc/{d}/cmdline", "rb").read().replace(b"\0", b" ").decode("utf-8", "replace")
        except OSError:
            continue
        if pat in cl:
            pids.append(int(d))
    return pids

def daemon_pid():
    # The daemon is exec'd with argv[0]="/proc/self/exe", so its cmdline is
    # "/proc/self/exe --daemon NAME …" — match on the flag, not the binary name.
    pids = _scan_proc(f"--daemon {SESS}")
    return pids[0] if pids else None

def marker_state():
    """Returns (counter, pid) from the marker state file, or (None, None)."""
    try:
        parts = open(MARKER_OUT).read().split()
        if len(parts) == 2 and parts[0].isdigit():
            return int(parts[0]), int(parts[1])
    except (OSError, ValueError):
        pass
    return None, None

def drain(fd, sink):
    """Read a pty master until EOF; append bytes to sink list."""
    try:
        while True:
            b = os.read(fd, 4096)
            if not b: break
            sink.append(b)
    except OSError:
        pass

def cleanup():
    dp = daemon_pid()
    if dp:
        try: os.kill(dp, signal.SIGKILL)
        except ProcessLookupError: pass
    _, mp = marker_state()
    if mp:
        try: os.kill(mp, signal.SIGKILL)
        except (ProcessLookupError, TypeError): pass
    for p in (SOCK, MARKER_OUT, TSESS):
        try: os.unlink(p)
        except OSError: pass
    # belt-and-suspenders: any stray marker for this session
    subprocess.run(["pkill", "-9", "-f", f"teru_e2e_{SESS}"], capture_output=True)

def spawn_client(args, env_extra=None, rows=40, cols=120):
    """Fork a `teru` client as a controlling-terminal session leader (sshd model)
    with a REAL terminal size set before exec — exactly what sshd does. Returns
    (pid, master_fd). Using openpty()+TIOCSWINSZ rather than pty.fork() so the
    winsize is non-zero before the child reads it (a 0x0 size is unrealistic and
    used to expose unrelated 0-dim panics)."""
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    pid = os.fork()
    if pid == 0:                       # child = new session, slave = controlling tty
        os.setsid()
        try: fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        except OSError: pass
        os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
        if slave > 2: os.close(slave)
        os.close(master)
        env = dict(os.environ)
        env.pop("DISPLAY", None)          # force TTY/TUI tier (the SSH path)
        env.pop("WAYLAND_DISPLAY", None)
        env["TERM"] = "xterm-256color"
        if env_extra: env.update(env_extra)
        try:
            os.execvpe(TERU, [TERU] + args, env)
        except Exception as e:
            os.write(2, f"exec failed: {e}\n".encode()); os._exit(127)
    os.close(slave)
    return pid, master

def main():
    if not os.path.exists(TERU): sys.exit(f"FAIL: {TERU} not built")
    cleanup()
    os.chmod(MARKER, 0o755)
    open(TSESS, "w").write(
        "[session]\nname = %s\n\n"
        "[workspace.1]\nname = main\nlayout = monocle\n\n"
        "[workspace.1.pane.1]\nrole = marker\ncmd = %s %s\nauto_start = true\n"
        % (SESS, MARKER, MARKER_OUT))

    print(f"\n=== teru session-survival E2E (session '{SESS}') ===")
    print(f"binary: {TERU}")
    ver = subprocess.run([TERU, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"version: {ver}\n")

    # ── 1. Connect (sshd model): teru -n SESS -t TEMPLATE ──────────────
    print("[1] Open session over a controlling-terminal PTY (= ssh + teru -n)")
    import threading
    sink1 = []
    pid1, master1 = spawn_client(["-n", SESS, "-t", TSESS])
    t1 = threading.Thread(target=drain, args=(master1, sink1), daemon=True); t1.start()

    # Wait for the daemon socket + the marker to start ticking.
    dp = None; deadline = time.time() + 12
    while time.time() < deadline:
        if dp is None: dp = daemon_pid()
        c, _ = marker_state()
        if dp and os.path.exists(SOCK) and c and c >= 1: break
        time.sleep(0.2)
    c0, mp = marker_state()
    if not (dp and os.path.exists(SOCK) and c0):
        print(f"FAIL: session did not come up (daemon_pid={dp} sock={os.path.exists(SOCK)} counter={c0})")
        try: os.close(master1)
        except OSError: pass
        cleanup(); sys.exit(1)
    log(f"daemon pid    = {dp}  (alive={pid_alive(dp)})")
    log(f"marker pid    = {mp}  (the 'agent' running inside the pane)")
    log(f"socket        = {SOCK}  ✓")
    log(f"counter       = {c0}  (advancing)")

    # ── 2. The hangup: close the PTY master (= SSH drop / laptop close) ──
    print("\n[2] Disconnect: close the controlling-terminal master (SSH drop / laptop close)")
    os.close(master1)                         # kernel SIGHUPs the fg process group
    try: os.waitpid(pid1, 0)                  # reap the `teru -n` client
    except ChildProcessError: pass
    log("controlling terminal hung up; `teru -n` client reaped")
    time.sleep(2.0)                           # let SIGHUP propagate

    # ── 3. Survival check ───────────────────────────────────────────────
    print("\n[3] Did the daemon + agent survive the hangup?")
    d_alive = pid_alive(dp)
    c1, _ = marker_state(); time.sleep(2.0); c2, _ = marker_state()
    m_alive = pid_alive(mp) if mp else False
    advancing = (c1 is not None and c2 is not None and c2 > c1)
    log(f"daemon pid {dp} alive   : {d_alive}")
    log(f"marker pid {mp} alive   : {m_alive}")
    log(f"counter advancing       : {advancing}  ({c1} → {c2})")
    log(f"socket still present     : {os.path.exists(SOCK)}")
    survived = d_alive and m_alive and advancing

    if not survived:
        print("\n  ✗ SYMPTOM REPRODUCED: the daemon died with the SSH session.")
        print("    The agents stopped — exactly 'close laptop → lose everything'.")
        cleanup(); sys.exit(2)
    print("\n  ✓ Daemon and agent SURVIVED the disconnect.")

    # ── 4. Reattach + resume-where-you-left-off ────────────────────────
    print("\n[4] Reconnect: a NEW `teru -n SESS` should attach to the SAME daemon and replay state")
    sink2 = []
    pid2, master2 = spawn_client(["-n", SESS])      # no template: daemon already exists
    t2 = threading.Thread(target=drain, args=(master2, sink2), daemon=True); t2.start()
    time.sleep(3.0)
    dp2 = daemon_pid()
    out2 = b"".join(sink2).decode("utf-8", "replace")
    reused_daemon = (dp2 == dp)
    # The client replays the daemon's grid on attach; the marker echoes "tick N".
    saw_tick = "tick" in out2
    log(f"reattached to same daemon pid {dp}: {reused_daemon}")
    log(f"client received daemon state/grid : {len(out2)} bytes")
    log(f"replayed live agent output ('tick'): {saw_tick}")
    # snapshot
    snap = "\n".join("      | " + ln for ln in out2.splitlines() if ln.strip())[:1200]
    if snap: print("  --- reattach snapshot (what the user sees on reconnect) ---\n" + snap)

    # detach cleanly (Ctrl-\) and confirm the daemon STILL survives
    try:
        os.write(master2, b"\x1c"); time.sleep(0.8)
    except OSError: pass
    try: os.close(master2)
    except OSError: pass
    try: os.waitpid(pid2, 0)
    except ChildProcessError: pass
    time.sleep(1.0)
    still = pid_alive(dp)
    log(f"daemon survived the 2nd detach too: {still}")

    ok = survived and reused_daemon and saw_tick and still
    print("\n=== VERDICT:", "PASS ✓" if ok else "FAIL ✗", "===")
    cleanup()
    sys.exit(0 if ok else 3)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        cleanup(); sys.exit(130)
