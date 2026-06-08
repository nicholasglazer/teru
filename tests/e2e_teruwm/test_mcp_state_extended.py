#!/usr/bin/env python3
"""Extended STATE-asserting teruwm MCP tests — deep verification of tools.

Complements test_mcp_state.py with state assertion tests for MCP tools that were
previously only smoke-tested. Verifies actual field names and state mutations.

Focus: set_name, set_widget/list_widgets/delete_widget, zoom (response font_size),
toggle_bar/set_bar, reload_config (with file I/O), session_save.

VERIFIED FIELD NAMES:
- list_windows: entries use id (NOT node_id), name, workspace, kind, title, x, y, w, h
- get_config: gap, border_width, bg_color, output_width, output_height, cell_width,
  cell_height, bar_height, terminal_count, active_workspace, top_bar (bool),
  bottom_bar (bool). NO font_size in get_config — teruwm_zoom returns it separately.
- teruwm_zoom response includes font_size
- teruwm_set_name requires arg new_name
- teruwm_move_to_workspace requires node_id, workspace
- teruwm_toggle_bar{which}, teruwm_set_bar{which,enabled}
- teruwm_set_widget{name,text}, teruwm_delete_widget{name}
- teruwm_toggle_scratchpad{index}

Usage:
    python3 tests/e2e_teruwm/test_mcp_state_extended.py [teruwm_bin]

Exit 0 if all assertions pass; 1 on first failure.
Runnable headless: env WLR_BACKENDS=headless WLR_RENDERER=pixman.
"""
from __future__ import annotations

import contextlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Any, Optional

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")


class Mcp:
    """Self-contained HTTP-over-Unix MCP client."""

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
    """Launch our OWN headless teruwm, wait for ITS MCP socket, return (proc, sock_path).

    Hermetic by design: the socket is keyed to OUR proc.pid
    (teruwm-mcp-{pid}.sock), so the tests never connect to (and never mutate)
    the user's live compositor session. We never unlink sockets we didn't
    create."""
    env = dict(os.environ)
    env.update(WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
               WLR_RENDERER="pixman", TERU_LOG="info", XDG_RUNTIME_DIR=RUNTIME_DIR)
    # Don't nest in a parent compositor's socket
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("DISPLAY", None)
    log = open("/tmp/teruwm-mcp-state-extended-test.log", "w")
    proc = subprocess.Popen([teruwm_bin], env=env, stdout=log, stderr=log,
                            start_new_session=True)
    sock = os.path.join(RUNTIME_DIR, f"teruwm-mcp-{proc.pid}.sock")
    for _ in range(40):
        time.sleep(0.25)
        if os.path.exists(sock):
            time.sleep(0.4)
            return proc, sock
    proc.send_signal(signal.SIGTERM)
    raise RuntimeError("teruwm did not create an MCP socket — see /tmp/teruwm-mcp-state-extended-test.log")


RESULTS = []


def check(cat: str, name: str, cond: bool, detail: str = "") -> bool:
    """Record a test result; print immediately."""
    RESULTS.append((cat, name, bool(cond), detail))
    status = "PASS" if cond else "FAIL"
    msg = f"  [{status}] {cat}/{name}  {detail}"[:160]
    print(msg)
    return bool(cond)


def test_set_name(mcp: Mcp):
    """Spawn pane, set_name to new value, verify list_windows entry.name matches."""
    print("\n== TEST: set_name ==")

    # Spawn a pane
    mcp.call("teruwm_spawn_terminal", {"workspace": 0})
    time.sleep(0.2)
    wins_before = mcp.text(mcp.call("teruwm_list_windows"))
    if not isinstance(wins_before, list) or len(wins_before) == 0:
        check("set_name", "spawn_and_list", False, "no windows after spawn")
        return

    pane_id = wins_before[-1]["id"]
    old_name = wins_before[-1].get("name", "")

    # Set new name
    new_name = "TEST_PANE_CUSTOM"
    r_set = mcp.call("teruwm_set_name", {"node_id": pane_id, "new_name": new_name})
    if "error" in r_set:
        check("set_name", "set_name_call", False, f"error: {r_set.get('error', {}).get('message')}")
        return

    time.sleep(0.15)

    # Verify name changed
    wins_after = mcp.text(mcp.call("teruwm_list_windows"))
    pane_after = [w for w in wins_after if w.get("id") == pane_id]
    if len(pane_after) == 0:
        check("set_name", "find_after_set", False, "pane disappeared after set_name")
        return

    actual_name = pane_after[0].get("name", "")
    name_matches = actual_name == new_name
    check("set_name", "name_changed", name_matches, f"old={old_name}, new={actual_name}, expected={new_name}")

    # Clean up
    mcp.call("teruwm_close_window", {"node_id": pane_id})
    time.sleep(0.1)


def test_widget_lifecycle(mcp: Mcp):
    """set_widget → list_widgets (verify presence) → delete_widget → list_widgets (verify absence)."""
    print("\n== TEST: widget_lifecycle ==")

    widget_name = "test_widget_1"
    widget_text = "hello world"

    # Set widget
    r_set = mcp.call("teruwm_set_widget", {"name": widget_name, "text": widget_text})
    if "error" in r_set:
        check("widget", "set_widget", False, f"error: {r_set.get('error', {}).get('message')}")
        return
    time.sleep(0.15)

    # List widgets and verify presence
    r_list = mcp.call("teruwm_list_widgets")
    widgets_text = mcp.text(r_list)
    if not isinstance(widgets_text, str):
        # Try parsing as JSON array
        try:
            widgets_text = json.dumps(widgets_text)
        except:
            widgets_text = str(widgets_text)

    widget_present = widget_name in widgets_text
    check("widget", "set_and_list_present", widget_present,
          f"widget '{widget_name}' in list_widgets output: {widgets_text[:100]}")

    # Delete widget
    r_del = mcp.call("teruwm_delete_widget", {"name": widget_name})
    if "error" in r_del:
        check("widget", "delete_widget", False, f"error: {r_del.get('error', {}).get('message')}")
        return
    time.sleep(0.15)

    # List widgets again and verify absence
    r_list_after = mcp.call("teruwm_list_widgets")
    widgets_after = mcp.text(r_list_after)
    if not isinstance(widgets_after, str):
        try:
            widgets_after = json.dumps(widgets_after)
        except:
            widgets_after = str(widgets_after)

    widget_absent = widget_name not in widgets_after
    check("widget", "delete_and_list_absent", widget_absent,
          f"widget '{widget_name}' NOT in list_widgets after delete: {widgets_after[:100]}")


def test_zoom_response_field(mcp: Mcp):
    """Call zoom(in), verify response includes font_size field that increments."""
    print("\n== TEST: zoom_response_field ==")

    # Get initial font size via zoom_reset first (to baseline state)
    r_reset = mcp.call("teruwm_zoom", {"direction": "reset"})
    if "error" in r_reset:
        check("zoom", "reset", False, f"error: {r_reset.get('error', {}).get('message')}")
        return
    time.sleep(0.15)
    zoom_data = mcp.text(r_reset)
    if not isinstance(zoom_data, dict):
        check("zoom", "reset_response_shape", False, f"reset returned {type(zoom_data)}, expected dict")
        return

    initial_font_size = zoom_data.get("font_size")
    if initial_font_size is None:
        check("zoom", "reset_has_font_size", False, f"reset response missing font_size: {zoom_data}")
        return
    check("zoom", "reset_has_font_size", True, f"font_size={initial_font_size}")

    # Zoom in
    r_in = mcp.call("teruwm_zoom", {"direction": "in"})
    if "error" in r_in:
        check("zoom", "zoom_in_call", False, f"error: {r_in.get('error', {}).get('message')}")
        return
    time.sleep(0.15)
    zoom_in_data = mcp.text(r_in)
    if not isinstance(zoom_in_data, dict):
        check("zoom", "zoom_in_response_shape", False, f"zoom_in returned {type(zoom_in_data)}")
        return

    after_font_size = zoom_in_data.get("font_size")
    if after_font_size is None:
        check("zoom", "zoom_in_has_font_size", False, f"zoom_in response missing font_size: {zoom_in_data}")
        return

    # Verify font_size incremented
    incremented = after_font_size > initial_font_size
    check("zoom", "font_size_incremented", incremented,
          f"initial={initial_font_size}, after_zoom_in={after_font_size}")


def test_toggle_bar_booleans(mcp: Mcp):
    """toggle_bar(top) twice, verify get_config.top_bar flips."""
    print("\n== TEST: toggle_bar_booleans ==")

    # Get initial state
    cfg_before = mcp.text(mcp.call("teruwm_get_config"))
    if not isinstance(cfg_before, dict):
        check("bar_toggle", "get_config_before", False, f"get_config returned {type(cfg_before)}")
        return

    initial_top_bar = cfg_before.get("top_bar")
    if initial_top_bar is None:
        check("bar_toggle", "top_bar_in_config", False, f"get_config missing top_bar: {cfg_before.keys()}")
        return
    check("bar_toggle", "top_bar_readable", True, f"initial top_bar={initial_top_bar}")

    # Toggle top bar
    r_toggle = mcp.call("teruwm_toggle_bar", {"which": "top"})
    if "error" in r_toggle:
        check("bar_toggle", "toggle_call", False, f"error: {r_toggle.get('error', {}).get('message')}")
        return
    time.sleep(0.15)

    # Get new state
    cfg_after = mcp.text(mcp.call("teruwm_get_config"))
    if not isinstance(cfg_after, dict):
        check("bar_toggle", "get_config_after", False, f"get_config returned {type(cfg_after)}")
        return

    new_top_bar = cfg_after.get("top_bar")
    flipped = new_top_bar != initial_top_bar and new_top_bar is not None
    check("bar_toggle", "top_bar_flipped", flipped,
          f"before={initial_top_bar}, after={new_top_bar}")

    # Toggle back to restore
    mcp.call("teruwm_toggle_bar", {"which": "top"})
    time.sleep(0.1)


def test_set_bar_enabled(mcp: Mcp):
    """set_bar(bottom, enabled=True), verify get_config.bottom_bar == True."""
    print("\n== TEST: set_bar_enabled ==")

    # Get initial state
    cfg_before = mcp.text(mcp.call("teruwm_get_config"))
    if not isinstance(cfg_before, dict):
        check("bar_set", "get_config_before", False, f"get_config returned {type(cfg_before)}")
        return

    initial_bottom = cfg_before.get("bottom_bar")

    # Set bottom_bar to True
    r_set = mcp.call("teruwm_set_bar", {"which": "bottom", "enabled": True})
    if "error" in r_set:
        check("bar_set", "set_bar_call", False, f"error: {r_set.get('error', {}).get('message')}")
        return
    time.sleep(0.15)

    cfg_after = mcp.text(mcp.call("teruwm_get_config"))
    if not isinstance(cfg_after, dict):
        check("bar_set", "get_config_after", False, f"get_config returned {type(cfg_after)}")
        return

    bottom_bar_true = cfg_after.get("bottom_bar") == True
    check("bar_set", "bottom_bar_enabled", bottom_bar_true,
          f"set bottom_bar to True, got {cfg_after.get('bottom_bar')}")

    # Restore to initial state if it was different
    if initial_bottom is not None and initial_bottom != True:
        mcp.call("teruwm_set_bar", {"which": "bottom", "enabled": initial_bottom})
        time.sleep(0.1)


def test_reload_config_with_gap(mcp: Mcp):
    """Write gap value to ~/.config/teruwm/config, call reload_config, verify get_config.gap matches.
    Back up and restore the config file verbatim."""
    print("\n== TEST: reload_config_with_gap ==")

    config_dir = os.path.expanduser("~/.config/teruwm")
    config_file = os.path.join(config_dir, "config")
    backup_file = config_file + ".backup_test"

    # Create config dir if missing
    os.makedirs(config_dir, exist_ok=True)

    # Backup current config (if it exists)
    config_backed_up = False
    if os.path.exists(config_file):
        try:
            shutil.copy2(config_file, backup_file)
            config_backed_up = True
            check("reload_config", "backup_created", True, f"backed up to {backup_file}")
        except Exception as e:
            check("reload_config", "backup_failed", False, f"could not backup: {e}")
            return
    else:
        check("reload_config", "config_exists", False, "config file doesn't exist, creating new")

    try:
        # Write a new gap value
        new_gap = 12
        config_content = f"gap={new_gap}\n"
        try:
            with open(config_file, "w") as f:
                f.write(config_content)
            check("reload_config", "write_config", True, f"wrote gap={new_gap}")
        except Exception as e:
            check("reload_config", "write_config", False, f"could not write: {e}")
            return

        # Call reload_config
        r_reload = mcp.call("teruwm_reload_config", {})
        if "error" in r_reload:
            check("reload_config", "reload_call", False, f"error: {r_reload.get('error', {}).get('message')}")
        else:
            check("reload_config", "reload_call", True)

        time.sleep(0.2)

        # Verify get_config.gap == new_gap
        cfg = mcp.text(mcp.call("teruwm_get_config"))
        if isinstance(cfg, dict):
            actual_gap = cfg.get("gap")
            gap_matches = actual_gap == new_gap
            check("reload_config", "gap_changed", gap_matches,
                  f"expected gap={new_gap}, got gap={actual_gap}")
        else:
            check("reload_config", "gap_changed", False, f"get_config returned {type(cfg)}")

    finally:
        # Restore the original config file
        if config_backed_up:
            try:
                shutil.copy2(backup_file, config_file)
                os.unlink(backup_file)
                check("reload_config", "restore_completed", True, "original config restored")
            except Exception as e:
                check("reload_config", "restore_failed", False, f"could not restore: {e}")
        else:
            # If there was no original, remove the test config
            try:
                os.unlink(config_file)
            except:
                pass


def test_session_save_creates_file(mcp: Mcp):
    """Call session_save(name), verify ~/.config/teru/sessions/<name>.tsess exists."""
    print("\n== TEST: session_save_creates_file ==")

    session_dir = os.path.expanduser("~/.config/teru/sessions")
    os.makedirs(session_dir, exist_ok=True)

    session_name = "test_session_1"
    session_file = os.path.join(session_dir, f"{session_name}.tsess")

    # Remove if exists from prior run
    if os.path.exists(session_file):
        try:
            os.unlink(session_file)
        except:
            pass

    # Call session_save
    r_save = mcp.call("teruwm_session_save", {"name": session_name})
    if "error" in r_save:
        check("session_save", "save_call", False, f"error: {r_save.get('error', {}).get('message')}")
        return

    time.sleep(0.3)

    # Verify file exists
    file_exists = os.path.exists(session_file)
    check("session_save", "file_created", file_exists, f"path={session_file}")

    if file_exists:
        try:
            file_size = os.path.getsize(session_file)
            check("session_save", "file_nonempty", file_size > 0, f"size={file_size} bytes")
        except:
            check("session_save", "file_readable", False, "could not stat file")

        # Clean up test file
        try:
            os.unlink(session_file)
        except:
            pass


def run(mcp: Mcp):
    """Run all extended state-assertion tests."""
    print("\n" + "=" * 60)
    print("teruwm MCP EXTENDED STATE-ASSERTION TESTS")
    print("=" * 60)

    test_set_name(mcp)
    test_widget_lifecycle(mcp)
    test_zoom_response_field(mcp)
    test_toggle_bar_booleans(mcp)
    test_set_bar_enabled(mcp)
    test_reload_config_with_gap(mcp)
    test_session_save_creates_file(mcp)


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
    print(f"teruwm MCP extended state tests: {passed}/{total} passed")
    for c, (t, p) in sorted(bycat.items()):
        print(f"  {c:16s} {p}/{t}")

    fails = [(c, n, d) for c, n, cond, d in RESULTS if not cond]
    if fails:
        print("\nFAILURES:")
        for c, n, d in fails:
            print(f"  {c}/{n}  {d}")

    print(f"\n=== VERDICT: {'PASS ✓' if not fails else 'FAIL ✗'} ===")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
