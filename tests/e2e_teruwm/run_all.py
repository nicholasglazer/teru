"""Run the full e2e suite: smoke, keybinds, layouts, mcp tools.

Each section is its own Python subprocess so stdout streams live and a
failure in one doesn't halt the rest. Final exit code is non-zero iff
any section failed.
"""
from __future__ import annotations
import os
import subprocess
import sys
import time


SECTIONS = [
    ("smoke",     "test_smoke.py"),
    ("layouts",   "test_layouts.py"),
    ("mcp_tools", "test_mcp_tools.py"),
    ("keybinds",  "test_keybinds.py"),   # last — slowest
]


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    summary: list[tuple[str, int, float]] = []
    any_fail = False
    env = dict(os.environ)
    env["PYTHONUNBUFFERED"] = "1"

    for name, script in SECTIONS:
        print(f"\n{'='*60}\n== {name}  ({script})\n{'='*60}", flush=True)
        t0 = time.time()
        rc = subprocess.call([sys.executable, "-u", script],
                             cwd=here, env=env)
        elapsed = time.time() - t0
        summary.append((name, rc, elapsed))
        if rc != 0:
            any_fail = True

    print(f"\n{'='*60}\nRUN ALL SUMMARY")
    print(f"{'='*60}")
    for name, rc, t in summary:
        mark = "+" if rc == 0 else "x"
        print(f"  {mark} {name:14s}  rc={rc}  {t:6.1f}s")
    return 1 if any_fail else 0


if __name__ == "__main__":
    sys.exit(main())
