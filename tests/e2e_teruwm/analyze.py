"""Post-hoc analysis of /tmp/teruwm-e2e-shots/keybinds/.

Each action test produced pre.png + post.png under its own dir. For 'render'
effect actions, the hashes must differ. For no-op/external, just existence.
"""
from __future__ import annotations
import os
import sys

import harness
from actions import ACTIONS

SHOT_ROOT = "/tmp/teruwm-e2e-shots/keybinds"


def main() -> int:
    by_name = {a.name.replace(":", "_"): a for a in ACTIONS}
    rows: list[tuple[str, str, str]] = []

    for dir_name in sorted(os.listdir(SHOT_ROOT)):
        if dir_name.startswith("_"):  # destructive dirs prefixed
            continue
        act_name = dir_name
        act = by_name.get(act_name)
        if not act:
            rows.append(("skip", act_name, "unknown action"))
            continue

        d = os.path.join(SHOT_ROOT, dir_name)
        pre = os.path.join(d, "001-pre.png")
        post = os.path.join(d, "002-post.png")
        if not os.path.exists(pre) or not os.path.exists(post):
            rows.append(("fail", act_name,
                         f"missing shot: pre={os.path.exists(pre)} post={os.path.exists(post)}"))
            continue
        h1 = harness.file_md5(pre)
        h2 = harness.file_md5(post)
        same = h1 == h2

        if act.effect == "render":
            if not same:
                rows.append(("pass", act_name, f"shot changed"))
            else:
                rows.append(("fail", act_name,
                             f"expected render change ({act.note})"))
        elif act.effect == "state":
            # Can't verify from shots alone; pass if both exist + harness
            # didn't abort (we have pre+post, so it ran through).
            rows.append(("pass", act_name, "ran through"))
        elif act.effect in ("no-op", "external"):
            rows.append(("pass", act_name, "no-crash"))
        else:
            rows.append(("skip", act_name, act.effect))

    # Actions that didn't produce a dir = never reached
    covered = set(by_name.keys()) & set(os.listdir(SHOT_ROOT))
    missed = [a for a in ACTIONS
              if a.effect != "destructive" and a.name.replace(":","_") not in os.listdir(SHOT_ROOT)]

    # Print table
    w = max(len(n) for _, n, _ in rows) if rows else 10
    print(f"{'STATUS':<6} {'ACTION':<{w}}  NOTE")
    print("─" * (12 + w))
    for s, n, d in rows:
        tick = {"pass": "✓", "fail": "✗", "skip": "·"}[s]
        print(f"{tick} {s:<5}{n:<{w}}  {d}")

    passes = sum(1 for s,_,_ in rows if s == "pass")
    fails  = sum(1 for s,_,_ in rows if s == "fail")
    skips  = sum(1 for s,_,_ in rows if s == "skip")
    print()
    print(f"{passes} pass  {fails} fail  {skips} skip  (of {len(rows)} ran)")
    if missed:
        print(f"\nNot reached ({len(missed)}):")
        for a in missed:
            print(f"  · {a.name:30s}  ({a.category})")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
