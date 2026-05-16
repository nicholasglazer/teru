#!/usr/bin/env python3
"""teruwm compositor end-to-end test harness.

Launches teruwm on the headless wlroots backend (no DRM seat needed, so it
runs safely in CI or alongside a desktop session), drives it over the
compositor MCP socket, and asserts real behaviour.

It exists because the v0.6.10 audit found two CPU-spin blockers that the
inline test suite could not see — a leaked bar-exec event source, and a
broken shell-exit path. Both pegged a core at 100%. The decisive checks
here are `assert_not_spinning()` calls after a bar refresh and after a
shell exits: a regression of either blocker fails this script.

Usage:
    python3 tests/teruwm_e2e.py [path/to/teruwm]

Exit code 0 = all checks passed; non-zero = a check failed.
"""
import json
import os
import signal
import socket
import subprocess
import sys
import time

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())


# ── MCP client (HTTP-over-Unix-socket, line-JSON-RPC body) ──────────────
class Mcp:
    def __init__(self, sock_path):
        self.sock_path = sock_path
        self._id = 0

    def call(self, tool, args=None):
        self._id += 1
        body = json.dumps({
            "jsonrpc": "2.0", "id": self._id, "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}},
        }).encode()
        req = (b"POST / HTTP/1.1\r\nHost: localhost\r\n"
               b"Content-Type: application/json\r\n"
               b"Content-Length: " + str(len(body)).encode() +
               b"\r\nConnection: close\r\n\r\n" + body)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(15)
        s.connect(self.sock_path)
        s.sendall(req)
        resp = b""
        while True:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            resp += chunk
        s.close()
        _, _, payload = resp.partition(b"\r\n\r\n")
        doc = json.loads(payload)
        if "error" in doc:
            raise RuntimeError("MCP error: %s" % doc["error"])
        return doc["result"]["content"][0]["text"]

    def call_json(self, tool, args=None):
        return json.loads(self.call(tool, args))


# ── process / spin probes ───────────────────────────────────────────────
def proc_state(pid):
    """Return the single-char scheduler state from /proc/pid/stat."""
    with open("/proc/%d/stat" % pid) as f:
        return f.read().rsplit(")", 1)[1].split()[0]


def voluntary_ctxt(pid):
    with open("/proc/%d/status" % pid) as f:
        for line in f:
            if line.startswith("voluntary_ctxt_switches:"):
                return int(line.split()[1])
    return -1


def fd_count(pid):
    try:
        return len(os.listdir("/proc/%d/fd" % pid))
    except OSError:
        return -1


def assert_not_spinning(pid, label):
    """A spinning teruwm never blocks: voluntary_ctxt_switches stays flat
    and the scheduler state stays R. A healthy idle compositor sleeps in
    epoll_wait (state S, voluntary switches tick up on each real event)."""
    v0 = voluntary_ctxt(pid)
    running = 0
    for _ in range(8):
        time.sleep(0.2)
        if proc_state(pid) == "R":
            running += 1
    v1 = voluntary_ctxt(pid)
    # Spinning ⇔ pegged R the whole window AND never voluntarily yielded.
    if running >= 8 and v1 == v0:
        raise AssertionError(
            "%s: teruwm is SPINNING (state R x8, voluntary_ctxt %d→%d)"
            % (label, v0, v1))
    print("  ok  %s — not spinning (R %d/8, voluntary_ctxt +%d)"
          % (label, running, v1 - v0))


# ── harness ─────────────────────────────────────────────────────────────
def launch(teruwm_bin):
    env = dict(os.environ)
    env.update(WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
               WLR_RENDERER="pixman", XDG_RUNTIME_DIR=RUNTIME_DIR)
    log = open("/tmp/teruwm-e2e.log", "w")
    proc = subprocess.Popen([teruwm_bin], env=env, stdout=log, stderr=log,
                            stdin=subprocess.DEVNULL, start_new_session=True)
    sock = None
    for _ in range(50):
        time.sleep(0.2)
        for name in os.listdir(RUNTIME_DIR):
            if name.startswith("teruwm-mcp-%d" % proc.pid) and "events" not in name:
                sock = os.path.join(RUNTIME_DIR, name)
                break
        if sock:
            break
    if not sock:
        proc.kill()
        raise RuntimeError("teruwm did not create an MCP socket — see "
                           "/tmp/teruwm-e2e.log (DRM seat held elsewhere?)")
    time.sleep(0.5)
    return proc, sock


def main():
    teruwm = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/teruwm"
    if not os.path.exists(teruwm):
        print("teruwm binary not found: %s" % teruwm, file=sys.stderr)
        return 2

    proc, sock_path = launch(teruwm)
    mcp = Mcp(sock_path)
    failures = []

    def check(label, fn):
        try:
            fn()
        except Exception as e:  # noqa: BLE001 — harness reports every failure
            failures.append(label)
            print("  FAIL %s — %s" % (label, e))

    try:
        # The bar's default exec widgets refresh on a TTL; let a couple of
        # cycles run, then confirm the compositor still idles (blocker #2).
        time.sleep(6)
        check("idle bar exec", lambda: assert_not_spinning(proc.pid, "idle bar exec"))

        check("spawn terminal", lambda: _spawn_and_render(mcp))
        check("tiling", lambda: _tiling(mcp))
        check("font zoom", lambda: _zoom(mcp))
        check("shell exit reaps pane without spinning",
              lambda: _shell_exit(mcp, proc.pid))

        fds = fd_count(proc.pid)
        if fds > 64:
            failures.append("fd leak")
            print("  FAIL fd count — %d open fds (leak suspected)" % fds)
        else:
            print("  ok  fd count — %d open fds, stable" % fds)
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
            print("  ok  clean SIGTERM shutdown (exit %d)" % proc.returncode)
        except subprocess.TimeoutExpired:
            failures.append("shutdown hang")
            print("  FAIL shutdown — teruwm did not exit on SIGTERM")
            proc.kill()

    print()
    if failures:
        print("FAILED: %s" % ", ".join(failures))
        return 1
    print("PASS — all teruwm E2E checks green")
    return 0


def _spawn_and_render(mcp):
    mcp.call("teruwm_spawn_terminal")
    time.sleep(1.2)
    wins = mcp.call_json("teruwm_list_windows")
    assert len(wins) == 1, "expected 1 window, got %d" % len(wins)
    mcp.call("teruwm_type", {"text": "echo teruwm-e2e"})
    mcp.call("teruwm_press", {"key": "Return"})
    time.sleep(0.8)
    name = wins[0]["name"]
    out = mcp.call("teruwm_screenshot_pane",
                   {"name": name, "path": "/tmp/teruwm-e2e-shot.png"})
    assert "saved" in out, "screenshot failed: %s" % out
    size = os.path.getsize("/tmp/teruwm-e2e-shot.png")
    assert size > 4096, "screenshot suspiciously small: %d bytes" % size
    print("  ok  spawn terminal — pane rendered, screenshot %d bytes" % size)


def _tiling(mcp):
    mcp.call("teruwm_spawn_terminal")
    time.sleep(0.9)
    mcp.call("teruwm_set_layout", {"layout": "grid"})
    time.sleep(0.5)
    wins = mcp.call_json("teruwm_list_windows")
    assert len(wins) == 2, "expected 2 tiled windows, got %d" % len(wins)
    xs = sorted(w["x"] for w in wins)
    assert xs[0] != xs[1], "tiled panes share an x — not tiled"
    print("  ok  tiling — 2 panes side by side (x=%d, x=%d)" % (xs[0], xs[1]))


def _zoom(mcp):
    """teruwm_zoom is the MCP-reachable entry to the Alt+scroll font-zoom
    path — re-rasterizes the shared atlas and re-fonts every pane + bar."""
    z_in = mcp.call_json("teruwm_zoom", {"direction": "in"})
    assert z_in["changed"], "zoom in reported no change"
    z_out = mcp.call_json("teruwm_zoom", {"direction": "out"})
    assert z_out["changed"], "zoom out reported no change"
    assert z_out["font_size"] < z_in["font_size"], (
        "zoom out did not shrink the font (%d !< %d)"
        % (z_out["font_size"], z_in["font_size"]))
    mcp.call("teruwm_zoom", {"direction": "reset"})
    print("  ok  font zoom — in %dpx, out %dpx, reset"
          % (z_in["font_size"], z_out["font_size"]))


def _shell_exit(mcp, pid):
    """The blocker-#3 regression guard: exit a shell, assert the pane is
    reaped and the compositor does not spin."""
    before = mcp.call_json("teruwm_list_windows")
    assert len(before) >= 1, "no panes to exit"
    mcp.call("teruwm_type", {"text": "exit"})
    mcp.call("teruwm_press", {"key": "Return"})
    time.sleep(2.5)
    after = mcp.call_json("teruwm_list_windows")
    assert len(after) == len(before) - 1, (
        "shell exit did not reap the pane: %d → %d windows"
        % (len(before), len(after)))
    assert_not_spinning(pid, "after shell exit")
    print("  ok  shell exit — pane reaped (%d → %d windows)"
          % (len(before), len(after)))


if __name__ == "__main__":
    sys.exit(main())
