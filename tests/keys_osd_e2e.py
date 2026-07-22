#!/usr/bin/env python3
"""Keystroke-OSD end-to-end test (headless).

Drives the KeysOsd + vendored klava engine over MCP: on/off/toggle, the
privacy filter, repeat collapse, screenshot compositing of the overlay, and
— crucially — the one-shot expiry timer (entries must prune themselves and
the compositor must NOT spin while idle with the OSD on).

Feeding goes through `teruwm_keys_osd_feed`, which enters the same
KeysOsd.feed path as the live keyboard tap minus the xkb decode — headless
has no input devices (same rationale as teruwm_test_scroll).

Usage: python3 tests/keys_osd_e2e.py [path/to/teruwm]
Exit 0 = pass.
"""
import hashlib
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from teruwm_e2e import Mcp, launch, assert_not_spinning  # noqa: E402

XK_RETURN = 0xFF0D


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


def check(cond, label):
    if not cond:
        raise AssertionError("FAIL: %s" % label)
    print("  ok  %s" % label)


def main():
    teruwm = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/teruwm"
    if not os.path.exists(teruwm):
        print("teruwm binary not found: %s" % teruwm, file=sys.stderr)
        return 2

    proc, sock = launch(teruwm)
    mcp = Mcp(sock)
    failures = 0
    try:
        # A pane on screen so screenshots have real content behind the OSD.
        mcp.call("teruwm_spawn_terminal")
        time.sleep(0.5)

        st = mcp.call_json("teruwm_keys_osd", {"op": "status"})
        check(st == {"active": False, "entries": 0}, "OSD starts off")

        # Feeding while off is an explicit error, not a silent no-op.
        try:
            mcp.call("teruwm_keys_osd_feed", {"key": "a", "ctrl": True})
            check(False, "feed while off is rejected")
        except RuntimeError:
            check(True, "feed while off is rejected")

        st = mcp.call_json("teruwm_keys_osd", {"op": "on"})
        check(st["active"] is True, "op=on activates")

        shot0 = "/tmp/keys-osd-e2e-0.png"
        mcp.call("teruwm_screenshot", {"path": shot0})

        # Super+Enter — a combo must land and show.
        r = mcp.call_json("teruwm_keys_osd_feed",
                          {"keysym": XK_RETURN, "super": True})
        check(r == {"entries": 1, "shown": True}, "Super+Enter lands (entries=1, shown)")
        # Its release must not add anything.
        r = mcp.call_json("teruwm_keys_osd_feed",
                          {"keysym": XK_RETURN, "super": True, "released": True})
        check(r["entries"] == 1, "release is ignored")

        # Privacy: plain and shift-only typing never display.
        r = mcp.call_json("teruwm_keys_osd_feed", {"key": "a"})
        check(r["entries"] == 1, "plain 'a' suppressed (combos_only)")
        r = mcp.call_json("teruwm_keys_osd_feed", {"key": "A", "shift": True})
        check(r["entries"] == 1, "Shift+A suppressed (combos_only)")

        # Repeat collapse: 3x Ctrl+V is one entry.
        for _ in range(3):
            r = mcp.call_json("teruwm_keys_osd_feed", {"key": "v", "ctrl": True})
        check(r["entries"] == 2, "Ctrl+V x3 collapses into one entry")

        # The overlay must be composited into screenshots.
        shot1 = "/tmp/keys-osd-e2e-1.png"
        mcp.call("teruwm_screenshot", {"path": shot1})
        check(md5(shot0) != md5(shot1), "screenshot changes when OSD shows combos")

        assert_not_spinning(proc.pid, "while OSD visible")

        # Expiry: the one-shot timer must prune everything without polling.
        time.sleep(3.4)  # default keys_osd_linger_ms=2500 (+timer slack)
        st = mcp.call_json("teruwm_keys_osd", {"op": "status"})
        check(st == {"active": True, "entries": 0}, "entries expire via timer")
        shot2 = "/tmp/keys-osd-e2e-2.png"
        mcp.call("teruwm_screenshot", {"path": shot2})
        check(md5(shot2) != md5(shot1), "overlay gone from screenshot after expiry")

        assert_not_spinning(proc.pid, "idle with OSD on (timer disarmed)")

        # Keybind action path (dispatch by name, same as a bound chord).
        mcp.call("teruwm_test_key", {"action": "keys_osd_toggle"})
        st = mcp.call_json("teruwm_keys_osd", {"op": "status"})
        check(st["active"] is False, "keys_osd_toggle action turns it off")
        mcp.call("teruwm_test_key", {"action": "keys_osd_toggle"})
        st = mcp.call_json("teruwm_keys_osd", {"op": "status"})
        check(st["active"] is True, "keys_osd_toggle action turns it back on")

        # Hot-reload keeps a runtime-enabled OSD alive and feeds still work
        # (applyConfig drops the surface; next feed rebuilds it).
        mcp.call("teruwm_reload_config")
        st = mcp.call_json("teruwm_keys_osd", {"op": "status"})
        check(st["active"] is True, "reload_config keeps runtime-on OSD on")
        r = mcp.call_json("teruwm_keys_osd_feed", {"key": "t", "ctrl": True, "shift": True})
        check(r == {"entries": 1, "shown": True}, "feed after reload rebuilds surface")

        # Clean shutdown with the OSD live — releaseTimers must not UAF.
        os.kill(proc.pid, signal.SIGTERM)
        for _ in range(40):
            if proc.poll() is not None:
                break
            time.sleep(0.1)
        check(proc.poll() == 0, "clean SIGTERM exit (code %s) with OSD active" % proc.poll())
    except AssertionError as e:
        print(str(e), file=sys.stderr)
        failures = 1
    except Exception as e:  # noqa: BLE001
        print("ERROR: %s" % e, file=sys.stderr)
        failures = 1
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:  # noqa: BLE001
                proc.kill()
    print("keys_osd_e2e: %s" % ("PASS" if failures == 0 else "FAIL"))
    return failures


if __name__ == "__main__":
    sys.exit(main())
