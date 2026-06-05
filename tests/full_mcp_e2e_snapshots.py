#!/usr/bin/env python3
"""Full MCP E2E with snapshot evidence — every teru (22) + teruwm (37) tool.

Drives both MCP servers against fresh throwaway instances on the headless
wlroots backend (pixman), so it needs no DRM seat. For every teruwm visual
mutation it saves a real full-output PNG via `teruwm_screenshot` into a
numbered gallery; the renderer-less teru daemon can't framebuffer, so its
evidence is the JSON state each tool produces.

Outputs under /tmp/mcp-e2e-snapshots/:
  NN_<label>.png   full-output framebuffer snapshots (teruwm)
  evidence.jsonl   one record per tool call (server, tool, args, ok, detail)
  report.md        human-readable per-tool table

Config-safe: backs up and restores ~/.config/teru/teru.conf and
~/.config/teruwm/config verbatim. Skips teruwm_quit / teruwm_restart
(destructive — they'd tear down the instance) but records them as skipped.

Usage: python3 tests/full_mcp_e2e_snapshots.py [teru_bin] [teruwm_bin]
"""
import hashlib
import json
import os
import signal
import socket
import subprocess
import sys
import time

RUNTIME = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
GALLERY = "/tmp/mcp-e2e-snapshots"
TERU_CONF = os.path.expanduser("~/.config/teru/teru.conf")
TERUWM_CONF = os.path.expanduser("~/.config/teruwm/config")


# ── transports ────────────────────────────────────────────────────────────
class TeruMCP:
    """teru agent: line-JSON (write <json>\\n, read one line)."""

    def __init__(self, sock):
        self.sock = sock
        self._id = 0

    def call(self, tool, args=None, timeout=3.0):
        self._id += 1
        msg = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": "tools/call",
                          "params": {"name": tool, "arguments": args or {}}})
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.sock)
            s.sendall(msg.encode() + b"\n")
        except OSError as e:
            return None, {"message": f"io: {e}"}
        resp, deadline = b"", time.time() + timeout
        while time.time() < deadline:
            try:
                c = s.recv(65536)
            except socket.timeout:
                break
            if not c:
                break
            resp += c
            if b"\n" in resp:
                break
        s.close()
        line = resp.split(b"\n", 1)[0].decode("utf-8", "replace")
        if not line.strip():
            return None, {"message": "no response"}
        r = json.loads(line)
        if "error" in r:
            return None, r["error"]
        content = r.get("result", {}).get("content", [])
        return (content[0].get("text", "") if content else ""), None


class TeruwmMCP:
    """teruwm compositor: HTTP-over-Unix (POST + Content-Length)."""

    def __init__(self, sock):
        self.sock = sock
        self._id = 0

    def call(self, tool, args=None, timeout=8.0):
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": "tools/call",
                           "params": {"name": tool, "arguments": args or {}}}).encode()
        req = (b"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
               b"Content-Length: " + str(len(body)).encode() +
               b"\r\nConnection: close\r\n\r\n" + body)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.sock)
            s.sendall(req)
        except OSError as e:
            return None, {"message": f"io: {e}"}
        resp = b""
        while True:
            try:
                c = s.recv(65536)
            except socket.timeout:
                break
            if not c:
                break
            resp += c
        s.close()
        _, _, payload = resp.partition(b"\r\n\r\n")
        if not payload.strip():
            return None, {"message": "empty payload"}
        r = json.loads(payload)
        if "error" in r:
            return None, r["error"]
        content = r.get("result", {}).get("content", [])
        return (content[0].get("text", "") if content else ""), None


def parse(text):
    try:
        return json.loads(text)
    except (json.JSONDecodeError, TypeError):
        return text


# ── evidence recorder ──────────────────────────────────────────────────────
class Recorder:
    def __init__(self):
        self.rows = []
        self.shot_n = 0
        self.evidence = open(os.path.join(GALLERY, "evidence.jsonl"), "w")

    def rec(self, server, tool, args, text, err, *, expect_err=False, shot=None, note=""):
        ok = (err is None) if not expect_err else (err is not None)
        detail = note
        if err is not None:
            detail = (detail + " | " if detail else "") + f"err={err.get('message')}"
        elif text:
            detail = (detail + " | " if detail else "") + f"resp={str(text)[:120]}"
        row = {"server": server, "tool": tool, "args": args, "ok": ok,
               "expect_err": expect_err, "shot": shot, "detail": detail}
        self.rows.append(row)
        self.evidence.write(json.dumps(row) + "\n")
        self.evidence.flush()
        flag = "ok " if ok else "FAIL"
        s = f"  [{flag}] {server:6} {tool:28} {detail}"
        print(s if ok else f"\033[33m{s}\033[0m")
        return ok

    def shot(self, mcp, label):
        """Save a full-output teruwm screenshot into the gallery."""
        self.shot_n += 1
        path = os.path.join(GALLERY, f"{self.shot_n:02d}_{label}.png")
        text, err = mcp.call("teruwm_screenshot", {"path": path})
        if err is None and os.path.exists(path):
            data = open(path, "rb").read()
            md5 = hashlib.md5(data).hexdigest()[:8]
            print(f"        📸 {os.path.basename(path)}  {len(data)} bytes  md5={md5}")
            return f"{os.path.basename(path)} ({len(data)}B md5={md5})"
        print(f"        ✗ screenshot {label} failed: {err}")
        return None

    def finish(self):
        self.evidence.close()
        passed = sum(1 for r in self.rows if r["ok"])
        skipped = [r for r in self.rows if r.get("detail", "").startswith("SKIPPED")]
        with open(os.path.join(GALLERY, "report.md"), "w") as f:
            f.write("# Full MCP E2E — snapshot evidence\n\n")
            f.write(f"{passed}/{len(self.rows)} tool calls ok. "
                    f"Gallery: `{GALLERY}`\n\n")
            for srv in ("teru", "teruwm"):
                f.write(f"## {srv} MCP\n\n| tool | ok | shot | detail |\n|---|---|---|---|\n")
                for r in self.rows:
                    if r["server"] != srv:
                        continue
                    f.write(f"| {r['tool']} | {'✓' if r['ok'] else '✗'} | "
                            f"{r['shot'] or ''} | {r['detail'].replace('|','/')[:90]} |\n")
                f.write("\n")
        return passed, len(self.rows)


# ── launchers ───────────────────────────────────────────────────────────────
def launch_teru(teru_bin):
    proc = subprocess.Popen([teru_bin, "--daemon", "e2e_snap"],
                            stdout=open("/tmp/e2e-snap-teru.log", "w"),
                            stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                            start_new_session=True)
    sock = os.path.join(RUNTIME, f"teru-mcp-{proc.pid}.sock")
    for _ in range(50):
        time.sleep(0.2)
        if os.path.exists(sock):
            time.sleep(0.4)
            return proc, sock
    proc.kill()
    raise RuntimeError("teru daemon socket never appeared")


def launch_teruwm(teruwm_bin):
    env = dict(os.environ)
    env.update(WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
               WLR_RENDERER="pixman", XDG_RUNTIME_DIR=RUNTIME)
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("DISPLAY", None)
    proc = subprocess.Popen([teruwm_bin], env=env,
                            stdout=open("/tmp/e2e-snap-teruwm.log", "w"),
                            stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                            start_new_session=True)
    for _ in range(60):
        time.sleep(0.2)
        for n in os.listdir(RUNTIME):
            if n.startswith(f"teruwm-mcp-{proc.pid}") and "events" not in n:
                time.sleep(0.6)
                return proc, os.path.join(RUNTIME, n)
    proc.kill()
    raise RuntimeError("teruwm MCP socket never appeared — see /tmp/e2e-snap-teruwm.log")


# ── teru phase: all 22 agent tools ──────────────────────────────────────────
def drive_teru(mcp, rec):
    print("\n=== teru agent MCP — 22 tools ===")
    rec.rec("teru", "teru_list_panes", {}, *mcp.call("teru_list_panes"))
    rec.rec("teru", "teru_get_state", {"pane_id": 1}, *mcp.call("teru_get_state", {"pane_id": 1}))
    rec.rec("teru", "teru_read_output", {"pane_id": 1, "lines": 20},
            *mcp.call("teru_read_output", {"pane_id": 1, "lines": 20}))
    cfg_text, cfg_err = mcp.call("teru_get_config")
    rec.rec("teru", "teru_get_config", {}, cfg_text, cfg_err)
    rec.rec("teru", "teru_get_graph", {}, *mcp.call("teru_get_graph"))
    rec.rec("teru", "teru_create_pane", {"direction": "vertical"},
            *mcp.call("teru_create_pane", {"direction": "vertical"}))
    time.sleep(0.4)
    panes = parse(mcp.call("teru_list_panes")[0])
    ids = sorted(p["id"] for p in panes) if isinstance(panes, list) else [1]
    p2 = ids[-1]
    rec.rec("teru", "teru_send_input", {"pane_id": 1, "text": "echo TERU_E2E_MARK"},
            *mcp.call("teru_send_input", {"pane_id": 1, "text": "echo TERU_E2E_MARK\n"}))
    time.sleep(0.6)
    rec.rec("teru", "teru_wait_for", {"pane_id": 1, "pattern": "TERU_E2E_MARK"},
            *mcp.call("teru_wait_for", {"pane_id": 1, "pattern": "TERU_E2E_MARK", "lines": 40}))
    out_text, out_err = mcp.call("teru_read_output", {"pane_id": 1, "lines": 10})
    rec.rec("teru", "teru_read_output(after marker)", {"pane_id": 1},
            out_text, out_err, note="marker visible" if "TERU_E2E_MARK" in (out_text or "") else "")
    rec.rec("teru", "teru_send_keys", {"pane_id": 1, "keys": ["ctrl+l"]},
            *mcp.call("teru_send_keys", {"pane_id": 1, "keys": ["ctrl+l"]}))
    rec.rec("teru", "teru_switch_workspace", {"workspace": 1},
            *mcp.call("teru_switch_workspace", {"workspace": 1}))
    mcp.call("teru_switch_workspace", {"workspace": 0})
    rec.rec("teru", "teru_set_layout", {"layout": "grid", "workspace": 0},
            *mcp.call("teru_set_layout", {"layout": "grid", "workspace": 0}))
    mcp.call("teru_set_layout", {"layout": "master_stack", "workspace": 0})
    rec.rec("teru", "teru_focus_pane", {"pane_id": p2},
            *mcp.call("teru_focus_pane", {"pane_id": p2}))
    rec.rec("teru", "teru_swap_pane", {"pane_id": p2, "direction": "next"},
            *mcp.call("teru_swap_pane", {"pane_id": p2, "direction": "next"}))
    rec.rec("teru", "teru_move_pane", {"pane_id": p2, "workspace": 2},
            *mcp.call("teru_move_pane", {"pane_id": p2, "workspace": 2}))
    rec.rec("teru", "teru_broadcast", {"workspace": 0, "text": "# bc\\n"},
            *mcp.call("teru_broadcast", {"workspace": 0, "text": "# broadcast_e2e\n"}))
    # set_config: write the existing padding value back (no real change), file restored at end anyway
    pad = (parse(cfg_text) or {}).get("padding", 8) if cfg_text else 8
    rec.rec("teru", "teru_set_config", {"key": "padding", "value": str(pad)},
            *mcp.call("teru_set_config", {"key": "padding", "value": str(pad)}))
    rec.rec("teru", "teru_session_save", {"name": "e2e_snap_session"},
            *mcp.call("teru_session_save", {"name": "e2e_snap_session"}))
    rec.rec("teru", "teru_session_restore", {"name": "e2e_snap_session"},
            *mcp.call("teru_session_restore", {"name": "e2e_snap_session"}))
    sub_text, sub_err = mcp.call("teru_subscribe_events", {})
    rec.rec("teru", "teru_subscribe_events", {}, sub_text, sub_err)
    # teru daemon has no renderer → screenshot is expected to fail -32603.
    sc_text, sc_err = mcp.call("teru_screenshot", {"path": "/tmp/teru-e2e.png"})
    rec.rec("teru", "teru_screenshot (daemon→no renderer)", {}, sc_text, sc_err,
            expect_err=True, note="-32603 expected: daemon has no framebuffer")
    rec.rec("teru", "teru_close_pane", {"pane_id": p2},
            *mcp.call("teru_close_pane", {"pane_id": p2}))


# ── teruwm phase: all 37 compositor tools, with snapshot gallery ────────────
LAYOUTS = ["master_stack", "grid", "monocle", "dishes", "spiral",
           "three_col", "columns", "accordion"]


def drive_teruwm(mcp, rec):
    print("\n=== teruwm compositor MCP — 37 tools (with snapshots) ===")
    rec.rec("teruwm", "teruwm_list_workspaces", {}, *mcp.call("teruwm_list_workspaces"))
    rec.rec("teruwm", "teruwm_list_windows", {}, *mcp.call("teruwm_list_windows"))

    for i in range(3):
        rec.rec("teruwm", f"teruwm_spawn_terminal[{i}]", {"workspace": 0},
                *mcp.call("teruwm_spawn_terminal", {"workspace": 0}))
        time.sleep(0.6)
    shot = rec.shot(mcp, "spawned_3_panes")
    rec.rows[-1]["shot"] = shot

    wins = parse(mcp.call("teruwm_list_windows")[0])
    wins = wins if isinstance(wins, list) else []
    nid1 = wins[0]["id"] if wins else 1
    nid2 = wins[1]["id"] if len(wins) > 1 else nid1
    w0 = wins[0] if wins else {"x": 10, "y": 40, "w": 600, "h": 400, "name": "term-0-1"}

    rec.rec("teruwm", "teruwm_type", {"text": "echo TERUWM_E2E && ls /"},
            *mcp.call("teruwm_type", {"text": "echo TERUWM_E2E && ls /"}))
    rec.rec("teruwm", "teruwm_press", {"key": "Return"},
            *mcp.call("teruwm_press", {"key": "Return"}))
    time.sleep(0.8)
    rec.rows[-1]["shot"] = rec.shot(mcp, "typed_command_output")

    for lay in LAYOUTS:
        ok = rec.rec("teruwm", f"teruwm_set_layout:{lay}", {"layout": lay},
                     *mcp.call("teruwm_set_layout", {"layout": lay}))
        time.sleep(0.4)
        rec.rows[-1]["shot"] = rec.shot(mcp, f"layout_{lay}")

    rec.rec("teruwm", "teruwm_zoom:in", {"direction": "in"}, *mcp.call("teruwm_zoom", {"direction": "in"}))
    rec.rec("teruwm", "teruwm_zoom:out", {"direction": "out"}, *mcp.call("teruwm_zoom", {"direction": "out"}))
    rec.rec("teruwm", "teruwm_zoom:reset", {"direction": "reset"}, *mcp.call("teruwm_zoom", {"direction": "reset"}))
    rec.rows[-1]["shot"] = rec.shot(mcp, "zoom_reset")

    rec.rec("teruwm", "teruwm_set_widget", {"name": "e2e_w", "text": "E2E OK", "class": "success"},
            *mcp.call("teruwm_set_widget", {"name": "e2e_w", "text": "E2E OK", "class": "success"}))
    time.sleep(0.3)
    rec.rows[-1]["shot"] = rec.shot(mcp, "widget_on_bar")
    rec.rec("teruwm", "teruwm_list_widgets", {}, *mcp.call("teruwm_list_widgets"))
    rec.rec("teruwm", "teruwm_delete_widget", {"name": "e2e_w"},
            *mcp.call("teruwm_delete_widget", {"name": "e2e_w"}))

    rec.rec("teruwm", "teruwm_toggle_bar", {"which": "top"},
            *mcp.call("teruwm_toggle_bar", {"which": "top"}))
    time.sleep(0.3)
    rec.rows[-1]["shot"] = rec.shot(mcp, "bar_toggled_off")
    mcp.call("teruwm_toggle_bar", {"which": "top"})  # back on
    rec.rec("teruwm", "teruwm_set_bar", {"which": "bottom", "enabled": True},
            *mcp.call("teruwm_set_bar", {"which": "bottom", "enabled": True}))
    time.sleep(0.3)
    rec.rows[-1]["shot"] = rec.shot(mcp, "bottom_bar_on")
    mcp.call("teruwm_set_bar", {"which": "bottom", "enabled": False})

    rec.rec("teruwm", "teruwm_focus_window", {"node_id": nid2},
            *mcp.call("teruwm_focus_window", {"node_id": nid2}))
    rec.rows[-1]["shot"] = rec.shot(mcp, "focus_second")
    rec.rec("teruwm", "teruwm_set_name", {"node_id": nid1, "new_name": "E2E_PANE"},
            *mcp.call("teruwm_set_name", {"node_id": nid1, "new_name": "E2E_PANE"}))

    rec.rec("teruwm", "teruwm_move_to_workspace", {"node_id": nid1, "workspace": 3},
            *mcp.call("teruwm_move_to_workspace", {"node_id": nid1, "workspace": 3}))
    rec.rec("teruwm", "teruwm_switch_workspace", {"workspace": 3},
            *mcp.call("teruwm_switch_workspace", {"workspace": 3}))
    time.sleep(0.3)
    rec.rows[-1]["shot"] = rec.shot(mcp, "workspace_3")
    mcp.call("teruwm_switch_workspace", {"workspace": 0})

    # mouse / pointer family — re-fetch CURRENT windows on the active ws so
    # coords + the screenshot target reflect the live layout (earlier ops moved
    # and renamed nid1, so w0's original rect/name are stale).
    cur = parse(mcp.call("teruwm_list_windows")[0])
    cur = [w for w in cur if w.get("workspace") == 0] if isinstance(cur, list) else []
    tgt = cur[0] if cur else {"id": nid2, "x": 10, "y": 40, "w": 600, "h": 400}
    tgt_id = tgt["id"]
    cx, cy = tgt["x"] + tgt["w"] // 2, tgt["y"] + tgt["h"] // 2
    rec.rec("teruwm", "teruwm_test_move", {"x": cx, "y": cy},
            *mcp.call("teruwm_test_move", {"x": cx, "y": cy}))
    rec.rec("teruwm", "teruwm_test_drag",
            {"from_x": tgt["x"] + 10, "from_y": cy, "to_x": tgt["x"] + tgt["w"] - 20, "to_y": cy, "button": 272},
            *mcp.call("teruwm_test_drag",
                      {"from_x": tgt["x"] + 10, "from_y": cy, "to_x": tgt["x"] + tgt["w"] - 20, "to_y": cy, "button": 272}))
    time.sleep(0.3)
    ppath = os.path.join(GALLERY, "pane_with_selection.png")
    ptext, perr = mcp.call("teruwm_screenshot_pane", {"node_id": tgt_id, "path": ppath})
    rec.rec("teruwm", "teruwm_screenshot_pane", {"node_id": tgt_id},
            ptext, perr, shot=(f"pane_with_selection.png ({os.path.getsize(ppath)}B)"
                               if perr is None and os.path.exists(ppath) else None))
    rec.rec("teruwm", "teruwm_click", {"x": cx, "y": cy, "button": "left"},
            *mcp.call("teruwm_click", {"x": cx, "y": cy, "button": "left"}))
    rec.rec("teruwm", "teruwm_mouse_path",
            {"from_x": w0["x"] + 5, "from_y": cy, "to_x": cx, "to_y": cy, "humanize": True},
            *mcp.call("teruwm_mouse_path",
                      {"from_x": w0["x"] + 5, "from_y": cy, "to_x": cx, "to_y": cy, "humanize": True}))
    rec.rec("teruwm", "teruwm_scroll", {"x": cx, "y": cy, "dy": -3.0},
            *mcp.call("teruwm_scroll", {"x": cx, "y": cy, "dy": -3.0}))
    rec.rec("teruwm", "teruwm_test_key", {"action": "layout_cycle"},
            *mcp.call("teruwm_test_key", {"action": "layout_cycle"}))
    mcp.call("teruwm_set_layout", {"layout": "master_stack"})

    rec.rec("teruwm", "teruwm_scratchpad", {"name": "e2e_scratch", "cmd": "echo scratch"},
            *mcp.call("teruwm_scratchpad", {"name": "e2e_scratch", "cmd": "echo scratch"}))
    time.sleep(0.5)
    rec.rec("teruwm", "teruwm_toggle_scratchpad", {"index": 0},
            *mcp.call("teruwm_toggle_scratchpad", {"index": 0}))
    time.sleep(0.3)
    rec.rows[-1]["shot"] = rec.shot(mcp, "scratchpad_toggled")

    rec.rec("teruwm", "teruwm_notify", {"message": "e2e notification"},
            *mcp.call("teruwm_notify", {"message": "e2e notification"}))
    rec.rec("teruwm", "teruwm_perf", {}, *mcp.call("teruwm_perf"))
    gcfg_text, gcfg_err = mcp.call("teruwm_get_config")
    rec.rec("teruwm", "teruwm_get_config", {}, gcfg_text, gcfg_err)
    rec.rec("teruwm", "teruwm_set_config", {"key": "gap", "value": "16"},
            *mcp.call("teruwm_set_config", {"key": "gap", "value": "16"}))
    time.sleep(0.3)
    rec.rows[-1]["shot"] = rec.shot(mcp, "gap_16")
    # restore gap to original
    orig_gap = (parse(gcfg_text) or {}).get("gap", 8) if gcfg_text else 8
    mcp.call("teruwm_set_config", {"key": "gap", "value": str(orig_gap)})
    rec.rec("teruwm", "teruwm_reload_config", {}, *mcp.call("teruwm_reload_config"))

    rec.rec("teruwm", "teruwm_session_save", {"name": "e2e_wm_session"},
            *mcp.call("teruwm_session_save", {"name": "e2e_wm_session"}))
    rec.rec("teruwm", "teruwm_session_restore", {"name": "e2e_wm_session"},
            *mcp.call("teruwm_session_restore", {"name": "e2e_wm_session"}))
    rec.rec("teruwm", "teruwm_subscribe_events", {}, *mcp.call("teruwm_subscribe_events"))

    fpath = os.path.join(GALLERY, "99_full_output_via_screenshot_tool.png")
    ftext, ferr = mcp.call("teruwm_screenshot", {"path": fpath})
    rec.rec("teruwm", "teruwm_screenshot (full output)", {"path": "..."},
            ftext, ferr, shot=(f"99_full_output_via_screenshot_tool.png "
                               f"({os.path.getsize(fpath)}B)" if ferr is None and os.path.exists(fpath) else None))

    rec.rec("teruwm", "teruwm_close_window", {"node_id": nid2},
            *mcp.call("teruwm_close_window", {"node_id": nid2}))
    time.sleep(0.3)
    rec.rows[-1]["shot"] = rec.shot(mcp, "after_close_window")

    # Destructive — would terminate this instance. Record as deliberately skipped.
    for t in ("teruwm_quit", "teruwm_restart"):
        rec.rec("teruwm", t, {}, "", None, note="SKIPPED (destructive — tears down the instance)")


def main():
    teru_bin = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/teru"
    teruwm_bin = sys.argv[2] if len(sys.argv) > 2 else "zig-out/bin/teruwm"
    os.makedirs(GALLERY, exist_ok=True)
    # wipe old gallery PNGs for a clean run
    for f in os.listdir(GALLERY):
        if f.endswith(".png"):
            os.remove(os.path.join(GALLERY, f))

    backups = {}
    for p in (TERU_CONF, TERUWM_CONF):
        try:
            backups[p] = open(p).read()
        except OSError:
            pass

    tp = wp = None
    rec = Recorder()
    try:
        tp, tsock = launch_teru(teru_bin)
        print(f"teru daemon pid {tp.pid}  {tsock}")
        drive_teru(TeruMCP(tsock), rec)

        wp, wsock = launch_teruwm(teruwm_bin)
        print(f"teruwm pid {wp.pid}  {wsock}")
        drive_teruwm(TeruwmMCP(wsock), rec)
    finally:
        for p, content in backups.items():
            try:
                with open(p, "w") as fh:
                    fh.write(content)
            except OSError:
                pass
        for proc in (tp, wp):
            if proc and proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    proc.kill()

    passed, total = rec.finish()
    pngs = sorted(f for f in os.listdir(GALLERY) if f.endswith(".png"))
    print("\n" + "=" * 64)
    print(f"  {passed}/{total} tool calls ok · {len(pngs)} snapshots in {GALLERY}")
    print("=" * 64)
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
