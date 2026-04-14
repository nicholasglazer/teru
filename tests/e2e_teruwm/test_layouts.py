"""Layout smoke: render each of the 8 layouts with 4 panes + screenshot.
Verifies that (a) every layout is accepted by the MCP, (b) each produces
a distinct framebuffer, (c) the compositor doesn't crash cycling through.
"""
from __future__ import annotations
import os
import sys
import time

import harness


SHOT_ROOT = "/tmp/teruwm-e2e-shots/layouts"
LAYOUTS = [
    "master-stack", "grid", "monocle", "dishes",
    "spiral", "three-col", "columns", "accordion",
]


def main() -> int:
    os.makedirs(SHOT_ROOT, exist_ok=True)
    shots: dict[str, str] = {}
    hashes: dict[str, str] = {}
    failures: list[tuple[str, str]] = []

    with harness.start(shot_dir=SHOT_ROOT, startup_timeout=10) as wm:
        # Seed 4 panes — master-stack needs ≥2 slaves for visual diff with grid
        for _ in range(3):
            wm.spawn_terminal(ws=0)
        time.sleep(0.3)

        for layout in LAYOUTS:
            _, err = wm.call("teruwm_set_layout",
                             {"layout": layout, "workspace": 0})
            if err:
                failures.append((layout, f"set_layout: {err}"))
                continue
            time.sleep(0.25)  # let the arrange + render land

            path = wm.snap(layout)
            h = harness.file_md5(path)
            shots[layout] = path
            hashes[layout] = h

            _, alive = wm.call("teruwm_get_config")
            if alive:
                failures.append((layout, f"compositor unresponsive: {alive}"))
                break

            sys.stdout.write(f"  + {layout:14s}  {h[:8]}  {path}\n")
            sys.stdout.flush()

    # Verify every layout produced a distinct render. If two layouts
    # produce identical pixel data, something's wrong.
    seen: dict[str, str] = {}
    for layout, h in hashes.items():
        if h in seen:
            failures.append((layout, f"hash collision with {seen[h]}"))
        seen[h] = layout

    # Verify: monocle + master-stack + grid at 4 panes must be distinct.
    # (If someone refactors layouts into a single equivalent, this catches it.)
    distinct_check = {"master-stack", "grid", "monocle"}
    if distinct_check.issubset(hashes):
        distinct_hashes = {hashes[l] for l in distinct_check}
        if len(distinct_hashes) < 3:
            failures.append(("distinctness",
                             "master-stack/grid/monocle not all distinct"))

    print(f"\nlayouts: {len(hashes)} rendered, {len(failures)} failures")
    for layout, detail in failures:
        print(f"  x {layout}  {detail}")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
