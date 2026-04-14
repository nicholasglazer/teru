"""Exhaustive MCP tool smoke: every teruwm_* tool is invoked with
sensible arguments. Validates that the tool:
 - accepts the request shape we send,
 - returns within the timeout,
 - doesn't leave the compositor unresponsive for subsequent calls.

Destructive tools (close_window, restart) run in their own section.
"""
from __future__ import annotations
import os
import sys
import time
from typing import Any, Optional

import harness


SHOT_ROOT = "/tmp/teruwm-e2e-shots/mcp_tools"


def _first_node_id(wm) -> Optional[int]:
    wins, _ = wm.call("teruwm_list_windows")
    if not wins:
        return None
    return wins[0]["id"]


def _newest_node_id(wm) -> Optional[int]:
    wins, _ = wm.call("teruwm_list_windows")
    if not wins:
        return None
    return max(w["id"] for w in wins)


# Tool -> (lazy_args_factory(wm), expected_effect)
# effect: "ok" | "destructive"
TOOL_SPECS: dict[str, tuple] = {
    # Read-only introspection
    "teruwm_get_config":       (lambda wm: {},                       "ok"),
    "teruwm_list_windows":     (lambda wm: {},                       "ok"),
    "teruwm_list_workspaces":  (lambda wm: {},                       "ok"),
    "teruwm_list_widgets":     (lambda wm: {},                       "ok"),
    "teruwm_perf":             (lambda wm: {},                       "ok"),
    "teruwm_subscribe_events": (lambda wm: {},                       "ok"),

    # Workspace / layout
    "teruwm_switch_workspace": (lambda wm: {"workspace": 2},         "ok"),
    "teruwm_set_layout":       (lambda wm: {"layout": "grid",
                                             "workspace": 0},        "ok"),

    # Window lifecycle + movement
    "teruwm_spawn_terminal":   (lambda wm: {"workspace": 0},         "ok"),
    "teruwm_focus_window":     (lambda wm: {"node_id": _first_node_id(wm)},
                                                                     "ok"),
    "teruwm_move_to_workspace":(lambda wm: {"node_id": _newest_node_id(wm),
                                             "workspace": 3},        "ok"),
    "teruwm_set_name":         (lambda wm: {"node_id": _first_node_id(wm),
                                             "new_name": "test-name"},"ok"),
    "teruwm_close_window":     (lambda wm: {"node_id": _newest_node_id(wm)},
                                                                     "destructive"),

    # Live config tweaks
    "teruwm_set_config":       (lambda wm: {"key": "gap", "value": "12"}, "ok"),
    "teruwm_reload_config":    (lambda wm: {},                       "ok"),

    # Bar controls
    "teruwm_toggle_bar":       (lambda wm: {"which": "top"},         "ok"),
    "teruwm_set_bar":          (lambda wm: {"which": "top",
                                             "enabled": True},       "ok"),

    # Widgets
    "teruwm_set_widget":       (lambda wm: {"name": "e2e",
                                             "text": "hello",
                                             "class": "info"},       "ok"),
    "teruwm_delete_widget":    (lambda wm: {"name": "e2e"},          "ok"),

    # Scratchpads
    "teruwm_scratchpad":       (lambda wm: {"name": "test-scratch",
                                             "cmd": "true"},         "ok"),
    "teruwm_toggle_scratchpad":(lambda wm: {"index": 0},             "ok"),

    # Notification overlay
    "teruwm_notify":           (lambda wm: {"message": "e2e test"},  "ok"),

    # Screenshots
    "teruwm_screenshot":       (lambda wm: {"path": "/tmp/e2e-full.png"},
                                                                     "ok"),
    "teruwm_screenshot_pane":  (lambda wm: {"node_id": _first_node_id(wm),
                                             "path": "/tmp/e2e-pane.png"},
                                                                     "ok"),

    # Session
    "teruwm_session_save":     (lambda wm: {},                       "ok"),
    "teruwm_session_restore":  (lambda wm: {},                       "ok"),

    # Test helpers (bypass xkb / pointer)
    "teruwm_test_key":         (lambda wm: {"action": "pane_focus_next"}, "ok"),
    "teruwm_test_move":        (lambda wm: {"x": 100, "y": 100},     "ok"),
    "teruwm_test_drag":        (lambda wm: {"from_x": 100, "from_y": 100,
                                             "to_x": 200, "to_y": 200,
                                             "super": False},        "ok"),

    # Destructive (own section)
    "teruwm_restart":          (lambda wm: {},                       "destructive"),
}


def main() -> int:
    os.makedirs(SHOT_ROOT, exist_ok=True)
    rows: list[tuple[str, str, str]] = []

    # ── Safe tools: one compositor, all in sequence ──
    safe = [n for n, (_, eff) in TOOL_SPECS.items() if eff == "ok"]
    with harness.start(shot_dir=SHOT_ROOT + "/_safe", startup_timeout=10) as wm:
        # Seed with 2 panes so node-id-requiring tools have something.
        wm.spawn_terminal(ws=0)
        wm.spawn_terminal(ws=0)
        time.sleep(0.3)

        for tool in safe:
            factory, _ = TOOL_SPECS[tool]
            try:
                args = factory(wm)
            except Exception as e:
                rows.append(("fail", tool, f"factory: {e}"))
                sys.stdout.write(f"  x {tool:34s}  factory: {e}\n")
                sys.stdout.flush()
                continue

            t0 = time.time()
            _, err = wm.call(tool, args, timeout=5.0)
            elapsed = time.time() - t0

            if err:
                rows.append(("fail", tool, f"err: {err}"))
                sys.stdout.write(f"  x {tool:34s}  {err}\n")
            else:
                # Compositor still responsive?
                _, alive = wm.call("teruwm_get_config", timeout=2.0)
                if alive:
                    rows.append(("fail", tool, f"compositor dead after: {alive}"))
                    sys.stdout.write(f"  x {tool:34s}  compositor dead: {alive}\n")
                    break
                rows.append(("pass", tool, f"{elapsed*1000:.0f}ms"))
                sys.stdout.write(f"  + {tool:34s}  {elapsed*1000:.0f}ms\n")
            sys.stdout.flush()

    # ── Destructive tools: fresh compositor for each ──
    sys.stdout.write("── destructive tools ──\n")
    sys.stdout.flush()
    for tool, (factory, _) in TOOL_SPECS.items():
        if TOOL_SPECS[tool][1] != "destructive":
            continue
        with harness.start(shot_dir=f"{SHOT_ROOT}/{tool}", startup_timeout=10) as wm:
            # Seed so close_window has something to close
            wm.spawn_terminal(ws=0)
            wm.spawn_terminal(ws=0)
            time.sleep(0.3)
            pre_count = len((wm.call("teruwm_list_windows")[0]) or [])

            try:
                args = factory(wm)
            except Exception as e:
                rows.append(("fail", tool, f"factory: {e}"))
                continue

            _, err = wm.call(tool, args, timeout=8.0)
            time.sleep(0.8)  # restart takes a moment

            if tool == "teruwm_restart":
                _, alive = wm.call("teruwm_get_config", timeout=4.0)
                if alive is None:
                    rows.append(("pass", tool, "compositor back online"))
                    sys.stdout.write(f"  + {tool:34s}  back online\n")
                else:
                    rows.append(("fail", tool, f"dead after restart: {alive}"))
                    sys.stdout.write(f"  x {tool:34s}  dead: {alive}\n")
            elif tool == "teruwm_close_window":
                wins, _ = wm.call("teruwm_list_windows", timeout=2.0)
                post_count = len(wins or [])
                if post_count == pre_count - 1:
                    rows.append(("pass", tool,
                                 f"{pre_count} -> {post_count} windows"))
                    sys.stdout.write(
                        f"  + {tool:34s}  {pre_count} -> {post_count}\n")
                else:
                    rows.append(("fail", tool,
                                 f"expected {pre_count-1}, got {post_count}"))
                    sys.stdout.write(
                        f"  x {tool:34s}  expected {pre_count-1} got {post_count}\n")
            sys.stdout.flush()

    passes = sum(1 for s, *_ in rows if s == "pass")
    fails = sum(1 for s, *_ in rows if s == "fail")
    print(f"\nmcp_tools: {passes} pass  {fails} fail  (of {len(rows)})")
    if fails:
        for s, n, d in rows:
            if s == "fail":
                print(f"  x {n}  {d}")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
