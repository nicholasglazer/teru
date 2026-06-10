#!/usr/bin/env python3
"""Headless E2E for teruwm clipboard (#33/#34) + hot-restart display memory (#32).

Drives a freshly-built teruwm on the wlroots headless backend over MCP.
Verification is TEXTUAL: whole-screen dumps are taken by drag-selecting the
full pane and reading the seat selection back with wl-paste (a real Wayland
client) — no OCR, no row-position assumptions, shell-agnostic.

  - copy:    echo a marker, full-screen drag + copy_selection, wl-paste must
             contain the marker (native pane -> Wayland clipboard).
  - paste:   wl-copy (foreign client source) -> paste_clipboard into
             `head -1 > file` -> file must match (async pipe path).
  - restart: echo a marker, dump (must contain), teruwm_restart (execve in
             place), dump again — the restored grid must still contain it.
"""
import json, os, subprocess, sys, time

SOCK = sys.argv[1]
DISPLAY = sys.argv[2]
MCP = "/tmp/teruwm-probe/mcp.py"

def call(name, args=None, _id=[0]):
    _id[0] += 1
    req = {"jsonrpc": "2.0", "id": _id[0], "method": "tools/call",
           "params": {"name": name, "arguments": args or {}}}
    out = subprocess.run(["python3", MCP, SOCK, json.dumps(req)],
                         capture_output=True, text=True, timeout=20).stdout
    start = out.find("{")
    try:
        return json.loads(out[start:]) if start >= 0 else {"raw": out}
    except Exception:
        return {"raw": out}

def text_of(resp):
    try:
        return resp["result"]["content"][0]["text"]
    except Exception:
        return str(resp)

def wl_paste():
    env = dict(os.environ, WAYLAND_DISPLAY=DISPLAY)
    p = subprocess.run(["wl-paste"], env=env, capture_output=True,
                       text=True, timeout=10)
    return p.stdout

def pane_rect():
    wins = json.loads(text_of(call("teruwm_list_windows")))
    terms = [w for w in wins if w["kind"] == "terminal"]
    assert terms, f"no terminal pane: {wins}"
    return terms[0]

def type_line(s):
    call("teruwm_type", {"text": s})
    call("teruwm_press", {"key": "Return"})

def screen_dump():
    """Full-pane drag-select + copy_selection + wl-paste."""
    r = pane_rect()  # re-fetch: tiling shifts when wl-copy surfaces map
    call("teruwm_test_drag", {
        "from_x": r["x"] + 9, "from_y": r["y"] + 9,
        "to_x": r["x"] + r["w"] - 12, "to_y": r["y"] + r["h"] - 12,
    })
    res = text_of(call("teruwm_test_key", {"action": "copy_selection"}))
    assert "handled=true" in res, f"copy_selection not handled: {res}"
    time.sleep(0.5)
    return wl_paste()

fails = []
def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + ("" if ok else f"  -> {detail}"))
    if not ok:
        fails.append(label)

# ── setup: one terminal pane ─────────────────────────────────────
call("teruwm_spawn_terminal")
time.sleep(2.0)

# ── #33 copy: pane text reaches the Wayland clipboard ────────────
type_line("echo COPYTEST_HELLO_42")
time.sleep(1.0)
dump = screen_dump()
check("copy: full-screen selection reaches wl-paste with the marker",
      "COPYTEST_HELLO_42" in dump, repr(dump[-300:]))

# ── #34 paste: foreign wl-copy source -> async pipe -> PTY ───────
subprocess.Popen(["wl-copy", "FOREIGN_PIPE_TEXT_99"],
                 env=dict(os.environ, WAYLAND_DISPLAY=DISPLAY),
                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                 stderr=subprocess.DEVNULL, start_new_session=True)
time.sleep(0.8)
verify = "/tmp/teru-paste-verify.txt"
if os.path.exists(verify):
    os.unlink(verify)
type_line(f"head -1 > {verify}")
time.sleep(0.8)
res = text_of(call("teruwm_test_key", {"action": "paste_clipboard"}))
check("paste: action handled", "handled=true" in res, res)
time.sleep(1.2)                  # pipe drain is async on the event loop
call("teruwm_press", {"key": "Return"})
time.sleep(1.0)
content = open(verify).read().strip() if os.path.exists(verify) else "<missing>"
check("paste: foreign clipboard landed in the PTY",
      content == "FOREIGN_PIPE_TEXT_99", repr(content))

# ── #32 restart: grid content survives the execve ────────────────
type_line("echo RESTART_KEEP_ME_7")
time.sleep(1.0)
before = screen_dump()
check("restart precondition: marker on screen before restart",
      "RESTART_KEEP_ME_7" in before, repr(before[-300:]))
call("teruwm_restart")
time.sleep(3.5)                  # exec + restore + first frames
after = screen_dump()
check("restart: restored grid still holds the screen content",
      "RESTART_KEEP_ME_7" in after, repr(after[-400:]))
# the marker line appears TWICE (echo cmd + output) — both should survive
check("restart: command line above the marker survived too",
      "echo RESTART_KEEP_ME_7" in after, repr(after[-400:]))

print("ALL PASS" if not fails else f"FAILURES: {fails}")
sys.exit(1 if fails else 0)
