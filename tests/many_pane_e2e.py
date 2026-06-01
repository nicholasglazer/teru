#!/usr/bin/env python3
"""Regression test: the daemon must drain EVERY pane's PTY, however many there are.

The user's claude-power layout is 34 panes in one session; they want "as many
subwindows as I need". The daemon's poll set used to be a fixed [36] array that
stopped enumerating PTYs at len-2 (~32 with a client attached), so panes beyond
that were never read — their PTY buffers filled and the agents blocked. This
test spawns 40 marker panes (spread across workspaces; a workspace caps at 16)
and asserts every one keeps producing output.

Run:  python3 tests/many_pane_e2e.py
Exit: 0 = all panes draining; non-zero otherwise.
"""
import os, pty, time, sys

REPO="/home/ng/code/workbench/foss/teru"; TERU=REPO+"/zig-out/bin/teru"
NAME="manypane"; N=40; PER_WS=16
SOCK=f"/run/user/{os.getuid()}/teru-session-{NAME}.sock"
OUT=lambda i: f"/tmp/teru_mp_{i}.out"

os.chmod(REPO+"/tests/marker.sh",0o755)
for i in range(N):
    try: os.unlink(OUT(i))
    except OSError: pass

# Build a template: N panes spread over ceil(N/16) workspaces.
lines=["[session]","name=%s"%NAME,""]
for i in range(N):
    ws=i//PER_WS + 1; pane=i%PER_WS + 1
    if pane==1:
        lines += [f"[workspace.{ws}]", f"name=w{ws}", "layout=grid", ""]
    lines += [f"[workspace.{ws}.pane.{pane}]", "role=m%d"%i,
              f"cmd={REPO}/tests/marker.sh {OUT(i)}", "auto_start=true", ""]
tmpl=f"/tmp/teru_{NAME}.tsess"
open(tmpl,"w").write("\n".join(lines))

def scan(pat):
    for d in os.listdir("/proc"):
        if not d.isdigit(): continue
        try: cl=open(f"/proc/{d}/cmdline","rb").read().replace(b"\0",b" ").decode("utf-8","replace")
        except OSError: continue
        if pat in cl: return int(d)
    return None
def counter(i):
    try:
        p=open(OUT(i)).read().split(); return int(p[0]) if p and p[0].isdigit() else None
    except: return None

pid,master=pty.fork()
if pid==0:
    e=dict(os.environ); e.pop("DISPLAY",None); e.pop("WAYLAND_DISPLAY",None)
    e["TERM"]="xterm-256color"
    os.execvpe(TERU,[TERU,"--daemon",NAME,"-t",tmpl],e)
import threading
def drain():
    try:
        while os.read(master,4096): pass
    except OSError: pass
threading.Thread(target=drain,daemon=True).start()

print(f"spawning {N} marker panes across {(N+PER_WS-1)//PER_WS} workspaces …")
# Let all panes start and tick a few times.
dl=time.time()+12
while time.time()<dl:
    started=sum(1 for i in range(N) if counter(i) is not None)
    if started>=N: break
    time.sleep(0.3)
time.sleep(2.0)
c1=[counter(i) for i in range(N)]
time.sleep(2.0)
c2=[counter(i) for i in range(N)]
dpid=scan(f"--daemon {NAME}")

started=sum(1 for v in c2 if v is not None)
advancing=sum(1 for a,b in zip(c1,c2) if a is not None and b is not None and b>a)
frozen=[i for i,(a,b) in enumerate(zip(c1,c2)) if not (a is not None and b is not None and b>a)]
print(f"daemon pid={dpid} alive={dpid is not None and os.path.exists(f'/proc/{dpid}')}")
print(f"panes started : {started}/{N}")
print(f"panes advancing (draining): {advancing}/{N}")
if frozen: print(f"FROZEN pane indices: {frozen}")

# cleanup: kill the daemon (specific pid) → its panes get SIGHUP via their pty
try: os.close(master)
except OSError: pass
if dpid and os.path.exists(f"/proc/{dpid}"): os.kill(dpid,9)
# kill any lingering markers (specific files' pids)
for i in range(N):
    try: os.kill(int(open(OUT(i)).read().split()[1]),9)
    except: pass
try: os.unlink(SOCK)
except OSError: pass

ok = (started==N and advancing==N)
print("\nVERDICT:", "PASS ✓" if ok else f"FAIL ✗ ({advancing}/{N} draining)")
sys.exit(0 if ok else 2)
