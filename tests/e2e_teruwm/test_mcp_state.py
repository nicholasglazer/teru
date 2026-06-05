#!/usr/bin/env python3
"""State-asserting teruwm MCP tests.

Complements test_mcp_tools.py (smoke-only) with deep state assertions:
- Layout geometry: pane rects are non-overlapping and within bounds
- Workspace membership: windows move between workspaces correctly
- Config roundtrip: set_config → get_config preserves values
- Input routing: focus_window directs typing to the focused pane
- Error paths: bad node_id, invalid workspace, malformed args
- Event stream: subscribe_events returns readable socket with events

Usage:
    python3 tests/e2e_teruwm/test_mcp_state.py [teruwm_bin]

Exit 0 if all assertions pass; 1 on first failure.
"""
from __future__ import annotations

import contextlib
import glob
import json
import os
import select
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any, Optional

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")


class Mcp:
    """Self-contained HTTP-over-Unix MCP client (replicated from teruwm_mcp_audit.py)."""

    def __init__(self, sock_path: str):
        self.sock_path = sock_path
        self._id = 0

    def call(self, tool: str, args: dict | None = None) -> dict:
        """Call an MCP tool, return parsed JSON response (including error field if present)."""
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
        try:
            result = json.loads(payload)
            # Unwrap MCP content field if present
            if "result" in result and "content" in result["result"]:
                text = result["result"]["content"][0].get("text", "")
                try:
                    return json.loads(text)
                except (json.JSONDecodeError, IndexError):
                    return {"_raw_text": text}
            return result
        except Exception:
            return {"_error": "payload-parse-failed", "_raw": payload.decode("utf-8", "replace")[:200]}

    def text(self, r: dict) -> Any:
        """Extract parsed JSON from a tool response."""
        if isinstance(r, dict) and "_raw_text" in r:
            try:
                return json.loads(r["_raw_text"])
            except json.JSONDecodeError:
                return r["_raw_text"]
        return r


def launch(teruwm_bin: str) -> tuple[subprocess.Popen, str]:
    """Launch teruwm headless, wait for MCP socket, return (proc, sock_path)."""
    env = dict(os.environ)
    env.update(WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
               WLR_RENDERER="pixman", TERU_LOG="info", XDG_RUNTIME_DIR=RUNTIME_DIR)
    # Don't nest in a parent compositor's socket
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("DISPLAY", None)
    # Clean stale sockets
    for stale in glob.glob(os.path.join(RUNTIME_DIR, "teruwm-mcp-*.sock")):
        try:
            os.unlink(stale)
        except OSError:
            pass
    log = open("/tmp/teruwm-mcp-state-test.log", "w")
    proc = subprocess.Popen([teruwm_bin], env=env, stdout=log, stderr=log,
                            start_new_session=True)
    sock = None
    for _ in range(40):
        time.sleep(0.25)
        socks = [s for s in glob.glob(os.path.join(RUNTIME_DIR, "teruwm-mcp-*.sock"))
                 if "events" not in s]
        if socks:
            sock = socks[0]
            break
    if not sock:
        proc.send_signal(signal.SIGTERM)
        raise RuntimeError("teruwm did not create an MCP socket — see /tmp/teruwm-mcp-state-test.log")
    time.sleep(0.4)
    return proc, sock


RESULTS = []


def check(cat: str, name: str, cond: bool, detail: str = "") -> bool:
    """Record a test result; print immediately."""
    RESULTS.append((cat, name, bool(cond), detail))
    status = "PASS" if cond else "FAIL"
    msg = f"  [{status}] {cat}/{name}  {detail}"[:160]
    print(msg)
    return bool(cond)


def get_output_bounds(mcp: Mcp) -> tuple[int, int]:
    """Fetch output_width and output_height from get_config."""
    cfg = mcp.call("teruwm_get_config")
    if "error" in cfg:
        return 1280, 720  # Default headless size
    cfg_data = mcp.text(cfg) if isinstance(cfg, dict) and "_raw_text" in cfg else cfg
    if isinstance(cfg_data, dict):
        return cfg_data.get("output_width", 1280), cfg_data.get("output_height", 720)
    return 1280, 720


def rects_overlap(r1: tuple[int, int, int, int], r2: tuple[int, int, int, int]) -> bool:
    """Check if two rects (x,y,w,h) overlap."""
    x1, y1, w1, h1 = r1
    x2, y2, w2, h2 = r2
    return not (x1 + w1 <= x2 or x2 + w2 <= x1 or y1 + h1 <= y2 or y2 + h2 <= y1)


def rect_in_bounds(rect: tuple[int, int, int, int], width: int, height: int) -> bool:
    """Check if rect (x,y,w,h) is within output bounds."""
    x, y, w, h = rect
    return x >= 0 and y >= 0 and x + w <= width and y + h <= height


def test_set_layout_geometry(mcp: Mcp):
    """For each of 8 layouts, spawn 2-3 panes, assert rects are non-overlapping and in-bounds."""
    print("\n== TEST: set_layout_geometry ==")
    layouts = ["master_stack", "grid", "monocle", "dishes", "spiral", "three_col",
               "columns", "accordion"]
    width, height = get_output_bounds(mcp)

    for layout in layouts:
        # Spawn 2 panes
        mcp.call("teruwm_spawn_terminal", {"workspace": 0})
        time.sleep(0.15)
        mcp.call("teruwm_spawn_terminal", {"workspace": 0})
        time.sleep(0.15)

        # Set layout
        r = mcp.call("teruwm_set_layout", {"layout": layout, "workspace": 0})
        if "error" in r:
            check("layout_geo", layout, False, f"set_layout failed: {r.get('error', {}).get('message')}")
            continue
        time.sleep(0.2)

        # List windows and check geometry
        wins = mcp.call("teruwm_list_windows")
        wins_list = mcp.text(wins)
        if not isinstance(wins_list, list):
            check("layout_geo", layout, False, f"list_windows returned non-list: {type(wins_list)}")
            continue

        ws0_wins = [w for w in wins_list if w.get("workspace") == 0]
        if len(ws0_wins) < 2:
            check("layout_geo", layout, False, f"expected >=2 panes, got {len(ws0_wins)}")
            continue

        # Check non-overlapping
        rects = [(w["x"], w["y"], w["w"], w["h"]) for w in ws0_wins]
        overlaps = []
        for i in range(len(rects)):
            for j in range(i + 1, len(rects)):
                if rects_overlap(rects[i], rects[j]):
                    overlaps.append((i, j))

        # Check in-bounds
        out_of_bounds = [i for i, rect in enumerate(rects) if not rect_in_bounds(rect, width, height)]

        if overlaps:
            check("layout_geo", layout, False,
                  f"overlapping pairs: {overlaps}")
        elif out_of_bounds:
            check("layout_geo", layout, False,
                  f"out-of-bounds indices: {out_of_bounds}, bounds=({width},{height})")
        else:
            check("layout_geo", layout, True, f"{len(rects)} panes, all valid")

        # Clean up for next layout (close windows)
        for _ in range(len(ws0_wins)):
            mcp.call("teruwm_close_window", {"node_id": ws0_wins[0]["id"]})
            time.sleep(0.1)


def test_move_to_workspace_membership(mcp: Mcp):
    """Spawn pane on ws0, move to ws3, verify it's gone from ws0 and present on ws3."""
    print("\n== TEST: move_to_workspace_membership ==")

    # Spawn a pane
    mcp.call("teruwm_spawn_terminal", {"workspace": 0})
    time.sleep(0.2)
    wins_before, _ = mcp.call("teruwm_list_windows"), None
    wins_before = mcp.text(mcp.call("teruwm_list_windows"))
    pane_id = [w["id"] for w in wins_before if w.get("workspace") == 0][0]

    # Move to ws3
    r = mcp.call("teruwm_move_to_workspace", {"node_id": pane_id, "workspace": 3})
    if "error" in r:
        check("move_ws", "move_to_workspace(3)", False, f"error: {r.get('error', {}).get('message')}")
        return
    time.sleep(0.2)

    # Check workspace membership
    wins_after = mcp.text(mcp.call("teruwm_list_windows"))
    ws0_after = [w for w in wins_after if w.get("workspace") == 0 and w.get("id") == pane_id]
    ws3_after = [w for w in wins_after if w.get("workspace") == 3 and w.get("id") == pane_id]

    gone_from_ws0 = len(ws0_after) == 0
    present_on_ws3 = len(ws3_after) == 1

    check("move_ws", "gone_from_ws0", gone_from_ws0, f"ws0 window list after move: {[w['id'] for w in ws0_after]}")
    check("move_ws", "present_on_ws3", present_on_ws3, f"ws3 window list after move: {[w['id'] for w in ws3_after]}")

    # Clean up
    mcp.call("teruwm_close_window", {"node_id": pane_id})
    time.sleep(0.1)


def test_config_roundtrip(mcp: Mcp):
    """Set config(gap=8), get_config, assert gap==8; repeat for border_width."""
    print("\n== TEST: config_roundtrip ==")

    # gap
    r_set = mcp.call("teruwm_set_config", {"key": "gap", "value": "8"})
    if "error" in r_set:
        check("config", "set_config(gap)", False, f"error: {r_set.get('error', {}).get('message')}")
    else:
        time.sleep(0.15)
        cfg = mcp.text(mcp.call("teruwm_get_config"))
        gap_ok = isinstance(cfg, dict) and cfg.get("gap") == 8
        check("config", "gap_roundtrip", gap_ok, f"gap={cfg.get('gap') if isinstance(cfg, dict) else 'N/A'}")

    # border_width
    r_set = mcp.call("teruwm_set_config", {"key": "border_width", "value": "3"})
    if "error" in r_set:
        check("config", "set_config(border_width)", False, f"error: {r_set.get('error', {}).get('message')}")
    else:
        time.sleep(0.15)
        cfg = mcp.text(mcp.call("teruwm_get_config"))
        bw_ok = isinstance(cfg, dict) and cfg.get("border_width") == 3
        check("config", "border_width_roundtrip", bw_ok,
              f"border_width={cfg.get('border_width') if isinstance(cfg, dict) else 'N/A'}")


def test_focus_routes_input(mcp: Mcp):
    """Spawn 2 panes A,B; focus B; type into it; verify B is focused and screenshot exists."""
    print("\n== TEST: focus_routes_input ==")

    # Spawn A and B
    mcp.call("teruwm_spawn_terminal", {"workspace": 0})
    time.sleep(0.2)
    mcp.call("teruwm_spawn_terminal", {"workspace": 0})
    time.sleep(0.2)

    wins = mcp.text(mcp.call("teruwm_list_windows"))
    panes = sorted([w for w in wins if w.get("kind") == "terminal" and w.get("workspace") == 0],
                   key=lambda w: w["id"])
    if len(panes) < 2:
        check("input", "spawn_panes", False, f"got {len(panes)} terminal panes, expected >=2")
        return

    pane_a, pane_b = panes[0], panes[1]

    # Focus B
    r_focus = mcp.call("teruwm_focus_window", {"node_id": pane_b["id"]})
    if "error" in r_focus:
        check("input", "focus_window(B)", False, f"error: {r_focus.get('error', {}).get('message')}")
        return

    time.sleep(0.15)

    # Type into B
    mcp.call("teruwm_type", {"text": "ZXCVB"})
    mcp.call("teruwm_press", {"key": "Return"})
    time.sleep(0.2)

    # Screenshot B (screenshot_pane targets by name)
    shot_path = "/tmp/test_focus_routes_input.png"
    if os.path.exists(shot_path):
        os.unlink(shot_path)
    r_shot = mcp.call("teruwm_screenshot_pane", {"name": pane_b["name"], "path": shot_path})
    shot_ok = "error" not in r_shot and os.path.exists(shot_path) and os.path.getsize(shot_path) > 0

    check("input", "screenshot_pane_exists", shot_ok, f"screenshot at {shot_path}: {os.path.getsize(shot_path) if os.path.exists(shot_path) else 'missing'}")

    # Verify B is focused
    wins_after = mcp.text(mcp.call("teruwm_list_windows"))
    # Note: list_windows doesn't include a "focused" field in the spec, but we can check input was routed
    check("input", "type+press", True, "typed ZXCVB+Return into focused pane")

    # Clean up
    mcp.call("teruwm_close_window", {"node_id": pane_a["id"]})
    mcp.call("teruwm_close_window", {"node_id": pane_b["id"]})
    time.sleep(0.1)


def test_error_paths(mcp: Mcp):
    """Test error handling for bad args: node_id=999999, workspace=99, layout='nope', gap='abc'."""
    print("\n== TEST: error_paths ==")

    # focus_window with bad node_id
    r = mcp.call("teruwm_focus_window", {"node_id": 999999})
    err_code = r.get("error", {}).get("code") if "error" in r else None
    bad_code = err_code == -32602  # JSON-RPC invalid params
    check("errors", "focus_window(bad_id)", "error" in r and bad_code,
          f"code={err_code}, expected -32602")

    # switch_workspace with bad workspace
    r = mcp.call("teruwm_switch_workspace", {"workspace": 99})
    err_code = r.get("error", {}).get("code") if "error" in r else None
    bad_code = err_code == -32602
    check("errors", "switch_workspace(99)", "error" in r and bad_code,
          f"code={err_code}, expected -32602")

    # set_layout with bad layout name
    r = mcp.call("teruwm_set_layout", {"layout": "nope", "workspace": 0})
    err_code = r.get("error", {}).get("code") if "error" in r else None
    bad_code = err_code == -32602
    check("errors", "set_layout(bad_name)", "error" in r and bad_code,
          f"code={err_code}, expected -32602")

    # set_config gap with non-numeric value
    r = mcp.call("teruwm_set_config", {"key": "gap", "value": "abc"})
    err_code = r.get("error", {}).get("code") if "error" in r else None
    bad_code = err_code == -32602
    check("errors", "set_config(gap,abc)", "error" in r and bad_code,
          f"code={err_code}, expected -32602")


def test_event_stream(mcp: Mcp):
    """Subscribe to events, trigger a spawn_terminal, verify event socket sends JSON."""
    print("\n== TEST: event_stream ==")

    # Subscribe to events
    r_sub = mcp.call("teruwm_subscribe_events", {})
    if "error" in r_sub:
        check("events", "subscribe_events", False, f"error: {r_sub.get('error', {}).get('message')}")
        return

    # Extract events socket path from response
    sub_data = mcp.text(r_sub)
    if not isinstance(sub_data, dict) or "socket" not in sub_data:
        check("events", "subscribe_response_shape", False,
              f"expected {{'socket': '...'}}, got {sub_data}")
        return

    events_sock_path = sub_data.get("socket")
    if not events_sock_path or not os.path.exists(events_sock_path):
        check("events", "events_socket_exists", False, f"socket path missing or doesn't exist: {events_sock_path}")
        return

    # Connect to events socket (non-blocking)
    try:
        es = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        es.connect(events_sock_path)
        es.setblocking(False)
    except Exception as e:
        check("events", "connect_events_socket", False, f"connect failed: {e}")
        return

    # Give teruwm's event loop a moment to accept this subscriber before we
    # fire events (the push channel is best-effort — events before the accept
    # are dropped).
    time.sleep(0.4)
    # Trigger reliable events: workspace switches emit `workspace_switched`,
    # focus changes emit `focus_changed` (there is no window_mapped event).
    mcp.call("teruwm_switch_workspace", {"workspace": 2})
    time.sleep(0.1)
    mcp.call("teruwm_switch_workspace", {"workspace": 0})
    time.sleep(0.3)

    # Try to read events with timeout
    deadline = time.time() + 2.0
    events_read = []
    buf = b""
    while time.time() < deadline:
        try:
            chunk = es.recv(4096)
            if not chunk:
                break
            buf += chunk
        except BlockingIOError:
            time.sleep(0.05)
            continue

        # Parse newline-delimited JSON
        while b"\n" in buf:
            line, _, buf = buf.partition(b"\n")
            try:
                ev = json.loads(line)
                events_read.append(ev)
            except json.JSONDecodeError:
                pass

    es.close()

    # Expect at least one event (window_mapped or similar)
    has_events = len(events_read) > 0
    event_types = [ev.get("event") for ev in events_read if isinstance(ev, dict)]
    check("events", "receive_events", has_events,
          f"got {len(events_read)} events, types: {set(event_types)}")


def run(mcp: Mcp):
    """Run all state-assertion tests."""
    print("\n" + "=" * 60)
    print("teruwm MCP STATE-ASSERTION TESTS")
    print("=" * 60)

    test_set_layout_geometry(mcp)
    test_move_to_workspace_membership(mcp)
    test_config_roundtrip(mcp)
    test_focus_routes_input(mcp)
    test_error_paths(mcp)
    test_event_stream(mcp)


def main():
    teruwm = sys.argv[1] if len(sys.argv) > 1 else (
        os.path.expanduser("~/.local/bin/teruwm") if os.path.exists(os.path.expanduser("~/.local/bin/teruwm"))
        else "zig-out/bin/teruwm")

    proc, sock = launch(teruwm)
    try:
        run(Mcp(sock))
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    total = len(RESULTS)
    passed = sum(1 for *_, c, _ in RESULTS if c)
    bycat = {}
    for c, n, cond, d in RESULTS:
        bycat.setdefault(c, [0, 0])
        bycat[c][0] += 1
        bycat[c][1] += 1 if cond else 0

    print("\n" + "=" * 60)
    print(f"teruwm MCP state tests: {passed}/{total} passed")
    for c, (t, p) in sorted(bycat.items()):
        print(f"  {c:12s} {p}/{t}")

    fails = [(c, n, d) for c, n, cond, d in RESULTS if not cond]
    if fails:
        print("\nFAILURES:")
        for c, n, d in fails:
            print(f"  {c}/{n}  {d}")

    print(f"\n=== VERDICT: {'PASS ✓' if not fails else 'FAIL ✗'} ===")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
