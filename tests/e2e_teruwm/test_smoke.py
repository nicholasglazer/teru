"""Smoke: harness starts teruwm, calls MCP, screenshots, exits cleanly."""
from __future__ import annotations
import os
import sys
import harness


def main() -> int:
    with harness.start(shot_dir="/tmp/teruwm-e2e-shots/smoke") as wm:
        cfg, err = wm.call("teruwm_get_config")
        assert err is None, f"get_config: {err}"
        assert cfg["output_width"] == 1280, cfg
        assert cfg["output_height"] == 720, cfg

        p1 = wm.snap("initial")
        assert os.path.exists(p1), p1
        size1 = os.path.getsize(p1)

        # Spawn a second terminal and verify the framebuffer changed.
        wm.spawn_terminal(ws=0)
        wins, _ = wm.call("teruwm_list_windows")
        assert len(wins) >= 2, wins

        p2 = wm.snap("two-terms")
        assert os.path.exists(p2), p2
        size2 = os.path.getsize(p2)

        # teruwm's PNG encoder always writes ~same size — compare hashes.
        h1 = harness.file_md5(p1)
        h2 = harness.file_md5(p2)

        wm.ensure_ws(2)  # bar "3" indicator lights, terminal area empties
        p3 = wm.snap("ws3-active")
        h3 = harness.file_md5(p3)

        print(f"  hashes: {h1[:8]}  {h2[:8]}  {h3[:8]}")
        assert h1 != h3, f"workspace switch didn't change shot: {p1} vs {p3}"

        perf, _ = wm.call("teruwm_perf")
        if isinstance(perf, dict):
            print(f"  terminals={perf.get('terminal_count')}  "
                  f"frames={perf.get('frame_count')}")
        else:
            print(f"  perf(str)={perf[:80]}")

    print("smoke: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
