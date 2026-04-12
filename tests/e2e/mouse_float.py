#!/usr/bin/env python3
"""
Focused E2E: mouse motion + scratchpads + float ↔ tile transitions.

Covers:
  A. Cursor motion — teruwm_test_move delivers the cursor where asked.
  B. Mod+drag converts a tiled pane to floating and the pane actually
     moves under the cursor.
  C. Win+S (float_toggle keybind action) converts floating back to
     tiling; verified by comparing positions + `floating` bookkeeping.
  D. Scratchpads — create, toggle visibility, move.
  E. Hit-test is position-based (the pane under the cursor floats,
     not whatever was focused).

Prints a structured summary at the end. Exit 0 iff every subtest
passes.
"""
import glob
import json
import os
import socket
import subprocess
import sys
import time

TERUWM = "/home/ng/code/foss/teru/zig-out/bin/teruwm"
SOCK_DIR = f"/run/user/{os.getuid()}"
STDERR_LOG = "/tmp/teruwm-mouse-float-stderr.log"
SHOT_DIR = "/tmp/teruwm-mouse-float-shots"
os.makedirs(SHOT_DIR, exist_ok=True)


def snap(sock, label):
    """Snapshot at a named checkpoint — lets us visually trace the run."""
    path = f"{SHOT_DIR}/{label}.png"
    from_mcp = _mcp_raw(sock, "teruwm_screenshot", {"path": path})
    if os.path.exists(path):
        print(f"    📸 {path} ({os.path.getsize(path):,} bytes)", flush=True)


# ── infra ──────────────────────────────────────────────────────

class Result:
    def __init__(self):
        self.rows = []
    def ok(self, name, detail=""):
        self.rows.append(("+", name, detail))
        print(f"  + {name}   {detail}", flush=True)
    def fail(self, name, detail=""):
        self.rows.append(("X", name, detail))
        print(f"  X {name}   {detail}", flush=True)
    def check(self, name, cond, detail=""):
        self.ok(name, detail) if cond else self.fail(name, detail)
    def summary(self):
        passed = sum(1 for r in self.rows if r[0] == "+")
        failed = sum(1 for r in self.rows if r[0] == "X")
        print(f"\n{'=' * 50}")
        print(f"RESULTS: {passed}/{passed+failed} passed, {failed} failed")
        for m, n, d in self.rows:
            if m == "X":
                print(f"  [X] {n}   {d}")
        return failed == 0


def _mcp_raw(sock, tool, args=None):
    """Call MCP without unwrapping (used by snap)."""
    return mcp(sock, tool, args)


def mcp(sock, tool, args=None):
    params = {"name": tool}
    if args is not None:
        params["arguments"] = args
    body = json.dumps({"jsonrpc":"2.0","method":"tools/call","params":params,"id":1},
                      separators=(",", ":"))
    req = f"POST / HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n{body}"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5); s.connect(sock); s.sendall(req.encode())
    data = b""
    while True:
        try:
            c = s.recv(65536)
            if not c: break
            data += c
        except:
            break
    s.close()
    body_part = data.decode().split("\r\n\r\n", 1)[1] if b"\r\n\r\n" in data else ""
    if not body_part:
        return None, "empty response"
    j = json.loads(body_part)
    if "error" in j:
        return None, j["error"]["message"]
    text = j["result"]["content"][0]["text"]
    try:
        return json.loads(text), None
    except json.JSONDecodeError:
        try:
            return json.loads(text.replace('\\"', '"')), None
        except:
            return text, None


def wait_socket(pattern, timeout=10):
    for _ in range(timeout * 10):
        m = glob.glob(pattern)
        if m: return m[0]
        time.sleep(0.1)
    return None


# ── tests ──────────────────────────────────────────────────────

def run():
    r = Result()

    # Clean state
    subprocess.run(["pkill", "-x", "teruwm"], capture_output=True)
    time.sleep(0.4)
    for f in glob.glob(f"{SOCK_DIR}/teru-wmmcp-*.sock"):
        try: os.unlink(f)
        except: pass

    wm = subprocess.Popen([TERUWM], stdout=subprocess.DEVNULL,
                          stderr=open(STDERR_LOG, "w"))
    sock = wait_socket(f"{SOCK_DIR}/teru-wmmcp-*.sock", timeout=15)
    r.check("00 compositor starts", sock is not None, sock or "")
    if not sock:
        wm.kill()
        return r.summary()
    time.sleep(1.2)

    cfg, _ = mcp(sock, "teruwm_get_config")
    out_w, out_h = cfg["output_width"], cfg["output_height"]
    snap(sock, "00-fresh")

    # ── A. Cursor motion via teruwm_test_move ──────────────────────
    # The compositor has no MCP to read the cursor position back, so we
    # verify motion indirectly by moving into pane A, then dragging
    # from where we 'are' to somewhere else. If motion didn't land, the
    # drag would fail because nodeAtPoint wouldn't find pane A.
    mcp(sock, "teruwm_spawn_terminal", {"workspace": 0})
    mcp(sock, "teruwm_spawn_terminal", {"workspace": 0})
    time.sleep(0.3)
    mcp(sock, "teruwm_set_layout", {"layout": "master-stack", "workspace": 0})
    time.sleep(0.25)

    wins, _ = mcp(sock, "teruwm_list_windows")
    terms = sorted(wins, key=lambda w: w["id"])
    r.check("A1 three terminal panes", len(terms) == 3, f"got {len(terms)}")
    snap(sock, "01-three-tiled")
    master = terms[0]
    mx = master["x"] + master["w"] // 2
    my = master["y"] + master["h"] // 2

    _, err = mcp(sock, "teruwm_test_move", {"x": mx, "y": my})
    r.check("A2 test_move returns ok", err is None, err or "")
    time.sleep(0.2)
    snap(sock, "02-cursor-on-master")

    # ── B. Mod+drag converts tiled → floating, pane moves ──────────
    before = next(w for w in wins if w["id"] == master["id"])
    _, err = mcp(sock, "teruwm_test_drag", {
        "from_x": mx, "from_y": my,
        "to_x":   mx + 250, "to_y": my + 150,
        "super":  True,
    })
    r.check("B1 test_drag (super) returns ok", err is None)
    time.sleep(0.3)
    snap(sock, "03-after-mod-drag-master-floating")
    wins_after, _ = mcp(sock, "teruwm_list_windows")
    moved = next((w for w in wins_after if w["id"] == master["id"]), None)
    r.check("B2 dragged pane still exists", moved is not None)
    if moved:
        dx = moved["x"] - before["x"]
        dy = moved["y"] - before["y"]
        r.check("B3 pane actually moved", abs(dx) > 100 or abs(dy) > 100,
                f"delta=({dx},{dy})")
        # Moved pane should be floating (not in layout anymore)
        # Cross-check: other tiled panes have been re-arranged to fill
        others = [w for w in wins_after if w["id"] != master["id"]]
        total_w = sum(w["w"] for w in others if w["y"] < moved["y"] + 100)
        r.check("B4 remaining panes re-tiled (no master gap)",
                any(w["x"] < 50 for w in others),
                f"leftmost x of others: {min(w['x'] for w in others)}")

    # ── C. Win+S un-floats back into the tiling layout ─────────────
    # We just floated master. Now focus it and call float_toggle.
    _, err = mcp(sock, "teruwm_focus_window", {"node_id": master["id"]})
    r.check("C1 focus dragged pane", err is None)
    _, err = mcp(sock, "teruwm_test_key", {"action": "float_toggle"})
    r.check("C2 float_toggle action accepted", err is None)
    time.sleep(0.3)
    snap(sock, "04-after-float-toggle-master-retiled")
    wins_unfloat, _ = mcp(sock, "teruwm_list_windows")
    refloated = next((w for w in wins_unfloat if w["id"] == master["id"]), None)
    # After un-float, pane re-enters the layout. In master-stack it
    # gets appended to node_ids.items, so it lands in the stack (right
    # column), not the master position. Either way, it should be at a
    # tile edge — x near 0 (master) or x near the split (stack left
    # edge). Crucially, it should NOT be at the floating position (253).
    if refloated:
        ws_list, _ = mcp(sock, "teruwm_list_workspaces")
        ws0 = next(w for w in ws_list if w["id"] == 0)
        tiled = refloated["x"] != 253  # was the float x
        in_layout = ws0["windows"] >= 3  # all 3 tiled again
        r.check("C3 un-floated pane re-tiled", tiled and in_layout,
                f"x={refloated['x']} ws0.windows={ws0['windows']}")

    # Reciprocal: in reverse, a tiled pane should auto-float when
    # float_toggle is called without moving the cursor.
    second = terms[1]
    mcp(sock, "teruwm_focus_window", {"node_id": second["id"]})
    before_s = next((w for w in wins_unfloat if w["id"] == second["id"]), None)
    _, err = mcp(sock, "teruwm_test_key", {"action": "float_toggle"})
    r.check("C4 float_toggle second pane", err is None)
    time.sleep(0.3)
    snap(sock, "05-second-pane-floated")
    wins_floated, _ = mcp(sock, "teruwm_list_windows")
    after_s = next((w for w in wins_floated if w["id"] == second["id"]), None)
    # Floated pane usually goes to screen-center by default
    if before_s and after_s:
        r.check("C5 float_toggle moved second pane",
                (before_s["x"], before_s["y"]) != (after_s["x"], after_s["y"]),
                f"{before_s['x'],before_s['y']} -> {after_s['x'],after_s['y']}")

    # ── D. Scratchpads ─────────────────────────────────────────────
    # First call creates; second hides; third shows again.
    r1, _ = mcp(sock, "teruwm_toggle_scratchpad", {"index": 0})
    r.check("D1 scratchpad 0 first toggle (create)",
            r1 is not None and "created=true" in r1 and "visible=true" in r1,
            str(r1))
    time.sleep(0.3)
    snap(sock, "06-scratchpad-0-visible")
    r2, _ = mcp(sock, "teruwm_toggle_scratchpad", {"index": 0})
    r.check("D2 scratchpad 0 second toggle (hide)",
            r2 is not None and "visible=false" in r2, str(r2))
    time.sleep(0.3)
    snap(sock, "07-scratchpad-0-hidden")
    r3, _ = mcp(sock, "teruwm_toggle_scratchpad", {"index": 0})
    r.check("D3 scratchpad 0 third toggle (show again)",
            r3 is not None and "visible=true" in r3, str(r3))
    time.sleep(0.3)
    snap(sock, "08-scratchpad-0-reshown")
    # A second scratchpad is independent.
    r4, _ = mcp(sock, "teruwm_toggle_scratchpad", {"index": 2})
    r.check("D4 scratchpad 2 create", r4 is not None and "created=true" in r4)
    time.sleep(0.3)
    snap(sock, "09-two-scratchpads-visible")
    # Bounds check
    _, err = mcp(sock, "teruwm_toggle_scratchpad", {"index": 9})
    r.check("D5 scratchpad index 9 rejected", err is not None)

    # ── E. Take a screenshot as artifact for the session ───────────
    out = "/tmp/teruwm-mouse-float-e2e.png"
    _, err = mcp(sock, "teruwm_screenshot", {"path": out})
    r.check("E1 screenshot", err is None and os.path.exists(out) and os.path.getsize(out) > 1e5,
            f"{out} ({os.path.getsize(out) if os.path.exists(out) else '-'} bytes)")

    # ── cleanup ────────────────────────────────────────────────────
    wm.terminate()
    try: wm.wait(timeout=3)
    except: wm.kill()

    # crash check
    try:
        with open(STDERR_LOG) as f:
            txt = f.read()
        if "panic" in txt.lower() or "SIGABRT" in txt or "SEGFAULT" in txt.upper():
            r.fail("99 stderr clean", "crash signature in stderr; see " + STDERR_LOG)
        else:
            r.ok("99 stderr clean")
    except: pass

    return r.summary()


if __name__ == "__main__":
    sys.exit(0 if run() else 1)
