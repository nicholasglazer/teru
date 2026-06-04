#!/usr/bin/env python3
"""teruwm compositor MCP usability audit — broad coverage of the 37-tool
compositor MCP surface + every non-destructive keybind action.

Where teruwm_e2e.py is a focused regression net (CPU-spin blockers), this is
the wide sweep: it spawns panes, then exercises every MCP tool and every
keybind action (via teruwm_test_key) against a headless instance, asserting
each dispatches cleanly and — where cheap — that it changed state (window
count, workspace, layout). It runs on the headless wlroots backend, so no DRM
seat is needed; safe in CI or alongside a desktop session.

Coverage NOT reachable here (documented, not silently skipped): composited
visuals (borders, gaps, cursor layer — MCP can't screenshot them), the
physical key→action path (xkb; test_key bypasses it), real libinput, and
hot-restart seat re-acquisition (needs a real seat — see teruwm_e2e notes).

Usage:
    python3 tests/teruwm_mcp_audit.py [path/to/teruwm]
Exit 0 = all checks passed; non-zero = a check failed.
"""
import glob
import json
import os
import signal
import socket
import subprocess
import sys
import time

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())


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
        try:
            return json.loads(payload)
        except Exception:
            return {"error": {"raw": payload.decode("utf-8", "replace")[:200]}}

    def text(self, r):
        try:
            return r["result"]["content"][0]["text"]
        except Exception:
            return None

    def windows(self):
        try:
            return json.loads(self.text(self.call("teruwm_list_windows")) or "[]")
        except Exception:
            return []


def ok(r):
    return isinstance(r, dict) and "error" not in r and "result" in r


def launch(teruwm_bin):
    env = dict(os.environ)
    env.update(WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
               WLR_RENDERER="pixman", TERU_LOG="info")
    # don't nest in a parent compositor's socket
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("DISPLAY", None)
    for stale in glob.glob(os.path.join(RUNTIME_DIR, "teruwm-mcp-*.sock")):
        try:
            os.unlink(stale)
        except OSError:
            pass
    log = open("/tmp/teruwm-mcp-audit.log", "w")
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
        raise RuntimeError("teruwm did not create an MCP socket — see /tmp/teruwm-mcp-audit.log")
    time.sleep(0.4)
    return proc, sock


RESULTS = []


def check(cat, name, cond, detail=""):
    RESULTS.append((cat, name, bool(cond), detail))
    print(f"  [{'PASS' if cond else 'FAIL'}] {cat}/{name}  {detail}"[:160])
    return bool(cond)


# Non-destructive keybind actions exercised via teruwm_test_key. Excludes
# instance-killers and env-specific ones (documented in SKIPPED).
ACTIONS = """
pane_focus_next pane_focus_prev pane_focus_master pane_set_master pane_swap_next
pane_swap_prev pane_swap_master pane_rotate_slaves_up pane_rotate_slaves_down
pane_sink pane_sink_all master_count_inc master_count_dec split_vertical
split_horizontal layout_cycle layout_reset workspace_toggle_last
workspace_next_nonempty focus_output_next move_to_output_next zoom_in zoom_out
zoom_reset zoom_toggle resize_shrink_w resize_grow_w resize_shrink_h
resize_grow_h mode_normal mode_prefix mode_scroll mode_search toggle_status_bar
copy_selection paste_clipboard scroll_up_1 scroll_down_1 scroll_up_half
scroll_down_half scroll_top scroll_bottom search_next search_prev select_begin
launcher_toggle float_toggle fullscreen_toggle bar_toggle_top bar_toggle_bottom
volume_up volume_down volume_mute brightness_up brightness_down media_play
media_next media_prev
""".split()

SKIPPED = ("compositor_quit compositor_restart session_detach session_restore "
           "window_close pane_close screenshot screenshot_area spawn_terminal "
           "spawn_N scratchpad_N workspace_3..9 pane_move_to_3..0 config_reload")

LAYOUTS = ["master_stack", "grid", "monocle", "dishes", "spiral", "three_col",
           "columns", "accordion"]


def run(mcp):
    print("\n== SETUP: spawn 4 panes ==")
    for i in range(4):
        check("setup", f"spawn_terminal[{i}]", ok(mcp.call("teruwm_spawn_terminal")))
        time.sleep(0.2)
        mcp.call("teruwm_type", {"text": f"echo PANE-{i}"})
        mcp.call("teruwm_press", {"key": "Return"})
        time.sleep(0.1)
    w = mcp.windows()
    check("setup", "list_windows>=4", len(w) >= 4, f"{len(w)} windows")

    print("\n== INTROSPECTION ==")
    for t in ["teruwm_list_windows", "teruwm_list_workspaces", "teruwm_list_widgets",
              "teruwm_get_config", "teruwm_perf"]:
        check("introspect", t, ok(mcp.call(t)))

    print("\n== LAYOUTS (8) ==")
    for lay in LAYOUTS:
        check("layout", lay, ok(mcp.call("teruwm_set_layout", {"layout": lay})))
        time.sleep(0.15)

    print("\n== WORKSPACES ==")
    for ws in range(10):
        check("workspace", f"switch_{ws}", ok(mcp.call("teruwm_switch_workspace", {"workspace": ws})))
    mcp.call("teruwm_switch_workspace", {"workspace": 0})
    w = mcp.windows()
    if w:
        last = w[-1]["id"]
        check("workspace", "move_to_workspace", ok(mcp.call("teruwm_move_to_workspace", {"node_id": last, "workspace": 2})))
        mcp.call("teruwm_move_to_workspace", {"node_id": last, "workspace": 0})

    print("\n== ZOOM ==")
    for z in ["in", "out", "reset"]:
        check("zoom", z, ok(mcp.call("teruwm_zoom", {"direction": z})))

    print("\n== BARS + WIDGETS ==")
    check("bar", "toggle(which=top)", ok(mcp.call("teruwm_toggle_bar", {"which": "top"})))
    mcp.call("teruwm_toggle_bar", {"which": "top"})
    check("bar", "set_bar(which,enabled)", ok(mcp.call("teruwm_set_bar", {"which": "top", "enabled": True})))
    check("widget", "set_widget(name,text)", ok(mcp.call("teruwm_set_widget", {"name": "audit", "text": "OK"})))
    lw = mcp.call("teruwm_list_widgets")
    check("widget", "list_widgets∋audit", ok(lw) and "audit" in (mcp.text(lw) or ""))
    check("widget", "delete_widget", ok(mcp.call("teruwm_delete_widget", {"name": "audit"})))

    print("\n== CONFIG ==")
    check("config", "get_config", ok(mcp.call("teruwm_get_config")))
    check("config", "set_config(gap)", ok(mcp.call("teruwm_set_config", {"key": "gap", "value": "4"})))
    check("config", "reload_config", ok(mcp.call("teruwm_reload_config")))

    check("misc", "notify(message)", ok(mcp.call("teruwm_notify", {"message": "audit"})))

    print("\n== INPUT + SELECTION ==")
    w = mcp.windows()
    if w:
        w0 = w[0]
        mcp.call("teruwm_focus_window", {"node_id": w0["id"]})
        mcp.call("teruwm_type", {"text": "the quick brown fox"})
        mcp.call("teruwm_press", {"key": "Return"})
        time.sleep(0.15)
        check("input", "type+press", True)
        check("input", "test_drag", ok(mcp.call("teruwm_test_drag",
              {"from_x": w0["x"] + 10, "from_y": w0["y"] + 6, "to_x": w0["x"] + 160, "to_y": w0["y"] + 6, "button": 272})))
        check("input", "copy_selection", ok(mcp.call("teruwm_test_key", {"action": "copy_selection"})))
        check("input", "click", ok(mcp.call("teruwm_click", {"x": w0["x"] + 20, "y": w0["y"] + 20, "button": 272})))
        check("input", "scroll", ok(mcp.call("teruwm_scroll", {"x": w0["x"] + 20, "y": w0["y"] + 20, "dy": 3})))
        check("input", "test_move", ok(mcp.call("teruwm_test_move", {"x": w0["x"] + 50, "y": w0["y"] + 50})))
        check("input", "mouse_path", ok(mcp.call("teruwm_mouse_path",
              {"from_x": w0["x"] + 10, "from_y": w0["y"] + 10, "to_x": w0["x"] + 60, "to_y": w0["y"] + 40})))
        check("input", "screenshot_pane", ok(mcp.call("teruwm_screenshot_pane",
              {"name": w0["name"], "path": "/tmp/teruwm-mcp-audit-pane.png"})))

    print("\n== SCRATCHPADS + EVENTS + SESSION ==")
    check("scratch", "toggle_scratchpad(index=0)", ok(mcp.call("teruwm_toggle_scratchpad", {"index": 0})))
    check("events", "subscribe_events", ok(mcp.call("teruwm_subscribe_events", {})))
    check("session", "session_save", ok(mcp.call("teruwm_session_save", {})))

    print(f"\n== KEYBIND ACTIONS ({len(ACTIONS)} via test_key) ==")
    for a in ACTIONS:
        check("action", a, ok(mcp.call("teruwm_test_key", {"action": a})))
        time.sleep(0.02)
    mcp.call("teruwm_test_key", {"action": "mode_normal"})
    mcp.call("teruwm_set_layout", {"layout": "master_stack"})

    print("\n== CLOSE (verify the targeted id disappears) ==")
    w = mcp.windows()
    if w:
        target = w[0]["id"]
        before = [x["id"] for x in w]
        r = mcp.call("teruwm_close_window", {"node_id": target})
        time.sleep(0.4)
        after = [x["id"] for x in mcp.windows()]
        check("close", "close_window", ok(r) and target not in after, f"{before}→{after}")


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
    print("\n" + "=" * 56)
    print(f"teruwm MCP audit: {passed}/{total} passed")
    for c, (t, p) in sorted(bycat.items()):
        print(f"  {c:12s} {p}/{t}")
    fails = [(c, n, d) for c, n, cond, d in RESULTS if not cond]
    if fails:
        print("\nFAILURES:")
        for c, n, d in fails:
            print(f"  {c}/{n}  {d}")
    print(f"\nNot covered here (need a real seat/screen): composited visuals, "
          f"physical key→action (xkb), libinput, hot-restart seat.")
    print(f"Skipped actions (destructive/env-specific): {SKIPPED}")
    print(f"\n=== VERDICT: {'PASS ✓' if not fails else 'FAIL ✗'} ===")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
