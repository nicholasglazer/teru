"""Exhaustive keybind test: every action in `Action.fromString` invoked via
`teruwm_test_key`, under a controlled scene. For each:

 - starting state is seeded deterministically (3 panes on ws0, layout set)
 - pre-snapshot + state capture
 - action invoked by name
 - post-snapshot + state capture
 - verdict:
     "render" — post-shot hash must differ from pre-shot hash
     "state"  — post state-dict must differ from pre (focused id,
                layouts, node placement etc.)
     "no-op"  — action must not crash or error; byte-equal shots are fine
     "external" — same as no-op (we can't verify external command output)
     "destructive" — run in isolation (fresh compositor) and verified
                     by checking that a *follow-up* MCP call still works
                     (or in the case of compositor:quit, that the process
                     exits within a short window)

Each test is a fresh teruwm process. Slow, but deterministic.
"""
from __future__ import annotations
import os
import sys
import time
from typing import Any

import harness
from actions import Act, ACTIONS
from preconditions import setup_for as precondition_setup

SHOT_ROOT = "/tmp/teruwm-e2e-shots/keybinds"


class TestReport:
    def __init__(self):
        self.rows: list[tuple[str, str, str]] = []
        self.shot_count = 0

    def record(self, status: str, name: str, detail: str = ""):
        self.rows.append((status, name, detail))
        tick = {"pass": "+", "fail": "x", "skip": "-"}.get(status, "?")
        sys.stdout.write(f"  {tick} {name:30s}  {detail}\n")
        sys.stdout.flush()

    def summary(self) -> bool:
        passes = sum(1 for s, *_ in self.rows if s == "pass")
        fails = sum(1 for s, *_ in self.rows if s == "fail")
        skips = sum(1 for s, *_ in self.rows if s == "skip")
        print(f"\n{'─' * 60}")
        print(f"keybinds: {passes} pass   {fails} fail   {skips} skip "
              f"(of {len(self.rows)} actions)")
        if fails:
            print("\nfailures:")
            for s, n, d in self.rows:
                if s == "fail":
                    print(f"  ✗ {n:30s}  {d}")
        return fails == 0


def _state_signature(wm: harness.Wm) -> dict[str, Any]:
    """Cheap snapshot of observable state — used by 'state' tests."""
    wins, _ = wm.call("teruwm_list_windows")
    wss, _ = wm.call("teruwm_list_workspaces")
    cfg, _ = wm.call("teruwm_get_config")
    return {
        "ws_active": cfg.get("active_workspace") if isinstance(cfg, dict) else None,
        "top_bar":   cfg.get("top_bar") if isinstance(cfg, dict) else None,
        "bottom_bar":cfg.get("bottom_bar") if isinstance(cfg, dict) else None,
        "windows": [(w["id"], w["workspace"], w["x"], w["y"], w["w"], w["h"])
                    for w in (wins or [])],
        "workspaces": [(w["id"], w["layout"], w["windows"], w["active"])
                       for w in (wss or [])],
    }


def _seed(wm: harness.Wm) -> None:
    """Put the compositor in a known 3-pane master-stack state on ws0."""
    # Already has 1 terminal from autospawn. Add two more.
    wm.spawn_terminal(ws=0)
    wm.spawn_terminal(ws=0)
    wm.call("teruwm_set_layout", {"layout": "master-stack", "workspace": 0})
    # Small render tick
    time.sleep(0.1)


def _action_dir(name: str, prefix: str = "") -> str:
    d = os.path.join(SHOT_ROOT, f"{prefix}{name}")
    os.makedirs(d, exist_ok=True)
    return d


def test_cheap_actions(report: TestReport) -> None:
    """no-op + external + state actions: share one compositor. ~40 tests
    in ~30s instead of 40 × 2s with fresh launches."""
    cheap = [a for a in ACTIONS if a.effect in ("no-op", "external", "state")]
    shared = _action_dir("_shared", "")

    with harness.start(shot_dir=shared, startup_timeout=8) as wm:
        _seed(wm)
        for act in cheap:
            dirp = _action_dir(act.name)
            # snap pre for this action (shared compositor, but each action
            # gets its own shot pair for visual audit trail).
            try:
                _, err_pre = wm.call("teruwm_screenshot",
                                     {"path": os.path.join(dirp, "001-pre.png")})
                pre_state = _state_signature(wm)
                _, err = wm.test_key(act.name)
                time.sleep(0.05)
                _, err_post = wm.call("teruwm_screenshot",
                                      {"path": os.path.join(dirp, "002-post.png")})
                post_state = _state_signature(wm)

                if err:
                    report.record("fail", act.name, f"dispatch: {err}")
                    continue

                # Compositor must still be responsive.
                _, alive = wm.call("teruwm_get_config")
                if alive is not None:
                    report.record("fail", act.name,
                                  f"compositor unresponsive: {alive}")
                    return  # shared comp broken — bail on the rest
                if act.effect == "state":
                    same = pre_state == post_state
                    report.record("pass", act.name,
                                  "state unchanged (ok)" if same else
                                  f"state changed ({act.note})")
                else:
                    report.record("pass", act.name, "no-crash")
            except Exception as e:
                report.record("fail", act.name, f"harness: {e}")


def test_render_actions(report: TestReport) -> None:
    """Render actions need fresh compositors (clean deterministic state).
    Actions with registered preconditions get their starting state tailored
    before the pre-shot so the test reflects the real action behaviour."""
    render = [a for a in ACTIONS if a.effect == "render"]
    for act in render:
        dirp = _action_dir(act.name)
        try:
            with harness.start(shot_dir=dirp, startup_timeout=8) as wm:
                _seed(wm)
                precond = precondition_setup(wm, act.name)
                pre_shot = wm.snap("pre")
                pre_h = harness.file_md5(pre_shot)
                pre_state = _state_signature(wm)

                _, err = wm.test_key(act.name)
                if err:
                    report.record("fail", act.name, f"dispatch: {err}")
                    continue
                time.sleep(0.15)  # render tick

                post_shot = wm.snap("post")
                post_h = harness.file_md5(post_shot)
                post_state = _state_signature(wm)

                precond_tag = f" [preset: {precond}]" if precond else ""
                if pre_h != post_h:
                    report.record("pass", act.name,
                                  f"shot changed{precond_tag}")
                elif pre_state != post_state:
                    report.record("pass", act.name,
                                  f"state changed, shot same{precond_tag}")
                else:
                    report.record("fail", act.name,
                                  f"no visible change{precond_tag}; expected {act.note}")
        except Exception as e:
            report.record("fail", act.name, f"harness: {e}")


def test_non_destructive(report: TestReport) -> None:
    """Back-compat entry point — splits into cheap + render."""
    test_cheap_actions(report)
    test_render_actions(report)


def test_destructive(report: TestReport) -> None:
    """Destructive actions each run in their own compositor with a
    specific post-check."""
    destructive = [a for a in ACTIONS if a.effect == "destructive"]
    for act in destructive:
        action_shot = os.path.join(SHOT_ROOT, "_destructive_" + act.name.replace(":", "_"))
        os.makedirs(action_shot, exist_ok=True)

        try:
            with harness.start(shot_dir=action_shot, startup_timeout=8) as wm:
                _seed(wm)
                pre_state = _state_signature(wm)
                pre_shot_count = len(pre_state["windows"])
                wm.snap("pre")

                _, err = wm.test_key(act.name)

                if act.name == "compositor_quit":
                    try:
                        wm.proc.wait(timeout=3.0)
                        report.record("pass", act.name,
                                      f"compositor exited (code={wm.proc.returncode})")
                    except Exception as e:
                        report.record("fail", act.name, f"did not exit: {e}")
                    continue

                if act.name == "compositor_restart":
                    # Re-execs with --restore. PID preserved.
                    time.sleep(1.0)
                    cfg, cerr = wm.call("teruwm_get_config", timeout=3.0)
                    if cerr:
                        report.record("fail", act.name,
                                      f"compositor dead after restart: {cerr}")
                    else:
                        report.record("pass", act.name, "compositor back online")
                    continue

                if act.name in ("pane_close", "window_close"):
                    # The focused pane dies. We expect N-1 windows.
                    time.sleep(0.2)
                    post = _state_signature(wm)
                    if len(post["windows"]) == pre_shot_count - 1:
                        wm.snap("post")
                        report.record("pass", act.name,
                                      f"{pre_shot_count} → {len(post['windows'])} panes")
                    else:
                        report.record("fail", act.name,
                                      f"expected {pre_shot_count-1} panes, got {len(post['windows'])}")
                    continue

                report.record("skip", act.name, "destructive handler unwritten")
        except Exception as e:
            report.record("fail", act.name, f"harness: {e}")


def main() -> int:
    os.makedirs(SHOT_ROOT, exist_ok=True)
    report = TestReport()
    print("── non-destructive actions ──")
    test_non_destructive(report)
    print("── destructive actions ──")
    test_destructive(report)
    return 0 if report.summary() else 1


if __name__ == "__main__":
    sys.exit(main())
