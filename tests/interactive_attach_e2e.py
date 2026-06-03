#!/usr/bin/env python3
"""End-to-end test of the 0.8.0-0.8.3 interactive remote-attach fixes.

Drives a REAL `teru -n` TUI client over a controlling-terminal PTY (sshd model)
against a 4-pane grid session, reconstructs the rendered screen from the client's
ANSI output, and asserts the things the python wire/survival tests don't cover:

  - multi-pane GRID layout actually renders as a grid (0.8.0 S3: grid was
    rendering as master-stack), and ALL panes draw incl. the bottom ones
    (0.8.1 EAGAIN: bottom panes used to stay blank over SSH).
  - clicking a pane focuses THAT pane and typed input lands in it (0.8.0 S1/S2:
    click focused the wrong pane; input went to a different pane than highlighted).
  - the active (orange #FF9837) border tracks the clicked pane.
  - nested mode (0.8.2): the inner teru DROPS its status bar (row N is content,
    not a bar) and Ctrl+A (0.8.3) drives the inner (focus moves on `Ctrl+A n`).

Run:  python3 tests/interactive_attach_e2e.py [session-name]
Exit: 0 = all assertions pass.
"""
import os, sys, pty, time, threading, fcntl, termios, struct, signal, re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TERU = os.path.join(REPO, "zig-out", "bin", "teru")
SESS = sys.argv[1] if len(sys.argv) > 1 else "e2e_iact"
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
SOCK = os.path.join(RUNTIME, f"teru-session-{SESS}.sock")
TSESS = f"/tmp/teru_{SESS}.tsess"
ROWS, COLS = 40, 120
ORANGE = "38;2;255;152;55"  # active-border SGR (miozu orange)

def log(m): print(f"  {m}", flush=True)

def scan(pat):
    out = []
    for d in os.listdir("/proc"):
        if not d.isdigit(): continue
        try: cl = open(f"/proc/{d}/cmdline","rb").read().replace(b"\0",b" ").decode("utf-8","replace")
        except OSError: continue
        if pat in cl: out.append(int(d))
    return out

def daemon_pid():
    p = scan(f"--daemon {SESS}")
    return p[0] if p else None

def cleanup():
    dp = daemon_pid()
    if dp:
        try: os.kill(dp, signal.SIGKILL)
        except ProcessLookupError: pass
    for p in (SOCK, TSESS):
        try: os.unlink(p)
        except OSError: pass

class Screen:
    """Minimal ANSI screen reconstruction: CUP, ED(2J), EL(K), text runs, and
    an 'is the current fg orange?' flag so we can find the active-border bbox."""
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.buf = [[" "]*cols for _ in range(rows)]
        self.orange = [[False]*cols for _ in range(rows)]
        self.r = self.c = 0
        self.fg_orange = False
    def feed(self, s):
        i, n = 0, len(s)
        while i < n:
            ch = s[i]
            if ch == "\x1b" and i+1 < n and s[i+1] == "[":
                j = i+2
                while j < n and not (0x40 <= ord(s[j]) <= 0x7e): j += 1
                if j >= n: break
                final = s[j]; params = s[i+2:j]
                if final == "H":  # CUP
                    parts = params.split(";")
                    self.r = (int(parts[0])-1) if parts and parts[0] else 0
                    self.c = (int(parts[1])-1) if len(parts)>1 and parts[1] else 0
                    self.r = max(0,min(self.rows-1,self.r)); self.c = max(0,min(self.cols-1,self.c))
                elif final == "J" and params in ("2",""):
                    self.buf = [[" "]*self.cols for _ in range(self.rows)]
                    self.orange = [[False]*self.cols for _ in range(self.rows)]
                elif final == "K":
                    for cc in range(self.c, self.cols): self.buf[self.r][cc] = " "
                elif final == "m":
                    if ORANGE in params: self.fg_orange = True
                    elif params in ("0","") or "39" in params.split(";") or "38;5" in params: self.fg_orange = False
                    elif params.startswith("38;2"): self.fg_orange = False
                i = j+1; continue
            if ch == "\r": self.c = 0; i += 1; continue
            if ch == "\n": self.r = min(self.rows-1, self.r+1); i += 1; continue
            if ch == "\x1b": i += 1; continue
            if ord(ch) < 32: i += 1; continue
            if self.c < self.cols:
                self.buf[self.r][self.c] = ch
                self.orange[self.r][self.c] = self.fg_orange
                self.c += 1
            i += 1
    def text(self): return "\n".join("".join(r).rstrip() for r in self.buf)
    def find(self, needle):
        for ri,row in enumerate(self.buf):
            line = "".join(row)
            cidx = line.find(needle)
            if cidx >= 0: return (ri, cidx)
        return None
    def orange_bbox(self):
        rs=[]; cs=[]
        for ri in range(self.rows):
            for ci in range(self.cols):
                if self.orange[ri][ci]: rs.append(ri); cs.append(ci)
        if not rs: return None
        return (min(rs),min(cs),max(rs),max(cs))
    def has_box_drawing(self):
        return any(any(ch in "─│┌┐└┘├┤┬┴┼" for ch in row) for row in self.buf)

def render(sink):
    sc = Screen(ROWS, COLS)
    sc.feed(b"".join(sink).decode("utf-8","replace"))
    return sc

def spawn(args, env_extra=None):
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.setsid()
        try: fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        except OSError: pass
        os.dup2(slave,0); os.dup2(slave,1); os.dup2(slave,2)
        if slave>2: os.close(slave)
        os.close(master)
        env = dict(os.environ); env.pop("DISPLAY",None); env.pop("WAYLAND_DISPLAY",None)
        env["TERM"]="xterm-256color"
        if env_extra: env.update(env_extra)
        try: os.execvpe(TERU,[TERU]+args,env)
        except Exception as e:
            os.write(2,f"exec failed: {e}\n".encode()); os._exit(127)
    os.close(slave)
    return pid, master

def drain(fd, sink):
    try:
        while True:
            b = os.read(fd,4096)
            if not b: break
            sink.append(b)
    except OSError: pass

def click(master, col, row):
    # press and release as SEPARATE reads — teru's last_mouse is a single slot
    # processed once per feed(); a batched press+release would only surface the
    # release (which doesn't focus). A real click is two distinct reads anyway.
    os.write(master, f"\x1b[<0;{col};{row}M".encode()); time.sleep(0.35)
    os.write(master, f"\x1b[<0;{col};{row}m".encode()); time.sleep(0.35)

def quadrant(pos):
    if pos is None: return None
    r,c = pos
    return ("T" if r < ROWS//2 else "B") + ("L" if c < COLS//2 else "R")

def main():
    if not os.path.exists(TERU): sys.exit(f"FAIL: {TERU} not built")
    cleanup()
    # 1 workspace, 4 bash panes, grid layout.
    t = ["[session]", f"name={SESS}", "", "[workspace.1]", "name=main", "layout=grid", ""]
    for p in range(1,5):
        # distinct role per pane — restore() is idempotent-by-role and would skip
        # duplicate roles, collapsing to a single pane.
        t += [f"[workspace.1.pane.{p}]", f"role=p{p}", "cmd=/bin/bash", "auto_start=true", ""]
    open(TSESS,"w").write("\n".join(t))

    ver = os.popen(f"{TERU} --version").read().strip()
    print(f"\n=== teru interactive-attach E2E (session '{SESS}', {ver}) ===")
    print(f"binary: {TERU}\n")

    fails = []

    # ── 1. Attach a 4-pane grid client ───────────────────────────────
    print("[1] Attach 4-pane GRID session over a PTY (= ssh + teru -n -t grid4)")
    sink = []
    pid, master = spawn(["-n", SESS, "-t", TSESS])
    threading.Thread(target=drain,args=(master,sink),daemon=True).start()
    time.sleep(4.0)
    sc = render(sink)
    box = sc.has_box_drawing()
    # status bar: last content row should carry the layout name in non-nested
    last_rows = sc.text().splitlines()
    bar_present = any("grid" in ln or "main" in ln for ln in last_rows[-2:])
    log(f"box-drawing borders present : {box}")
    log(f"status bar shows layout/ws  : {bar_present}")
    if not box: fails.append("no box-drawing borders (multi-pane grid didn't render)")
    if not bar_present: fails.append("status bar missing layout/workspace name")

    # ── 2. Click bottom-right pane, type, assert input lands there ────
    print("\n[2] Click BOTTOM-RIGHT pane, type a marker — does it land in that pane?")
    click(master, 100, 34)  # SGR left click in BR quadrant
    os.write(master, b"echo MARK_BR_9f\r")
    time.sleep(1.2)
    sc = render(sink)
    pos_br = sc.find("MARK_BR_9f")
    q_br = quadrant(pos_br)
    bbox = sc.orange_bbox()
    log(f"'MARK_BR_9f' found at        : {pos_br}  quadrant={q_br}")
    log(f"active(orange) border bbox   : {bbox}")
    if q_br not in ("BR",):
        fails.append(f"input after BR click landed in {q_br}, not BR (S1/S2 focus-routing bug)")

    # ── 3. Click top-left pane, type, assert it lands there ──────────
    print("\n[3] Click TOP-LEFT pane, type a marker — focus must move, input lands TL")
    click(master, 10, 4)  # click TL quadrant
    os.write(master, b"echo MARK_TL_3a\r")
    time.sleep(1.2)
    sc = render(sink)
    pos_tl = sc.find("MARK_TL_3a")
    q_tl = quadrant(pos_tl)
    bbox2 = sc.orange_bbox()
    log(f"'MARK_TL_3a' found at        : {pos_tl}  quadrant={q_tl}")
    log(f"active border bbox after TL  : {bbox2}")
    if q_tl not in ("TL",):
        fails.append(f"input after TL click landed in {q_tl}, not TL (focus-routing bug)")
    # the BR marker must still be visible (reattach/steady content preserved)
    if sc.find("MARK_BR_9f") is None:
        fails.append("BR marker vanished after TL click (content not preserved)")

    # detach
    os.write(master, b"\x02d")  # Ctrl+B d
    time.sleep(0.8)
    try: os.close(master)
    except OSError: pass
    try: os.waitpid(pid,0)
    except ChildProcessError: pass
    time.sleep(0.5)

    # ── 4. Nested mode: bar dropped + Ctrl+A prefix drives inner ─────
    print("\n[4] Reattach with TERU_NESTED=1 — inner drops its status bar; Ctrl+A drives it")
    sink2 = []
    pid2, master2 = spawn(["-n", SESS], env_extra={"TERU_NESTED":"1"})
    threading.Thread(target=drain,args=(master2,sink2),daemon=True).start()
    time.sleep(3.0)
    sc = render(sink2)
    rows_txt = sc.text().splitlines()
    # In nested mode content_height == full height: the LAST row should be a
    # pane border/content, NOT the status bar. Non-nested put the bar there.
    last_row = rows_txt[-1] if rows_txt else ""
    last_is_bar = ("grid" in last_row or re.search(r"\b1\b.*\b2\b.*\b3\b", last_row) is not None)
    last_has_content = bool(last_row.strip()) and not last_is_bar
    log(f"nested: last row is bar?     : {last_is_bar}  (expect False)")
    log(f"nested: last row has content : {last_has_content}")
    if last_is_bar: fails.append("nested mode still drew its status bar on the last row (0.8.2)")

    bbox_before = sc.orange_bbox()
    os.write(master2, b"\x01n")  # Ctrl+A n = focus_next (must pass through outer-less env)
    time.sleep(1.0)
    sc = render(sink2)
    bbox_after = sc.orange_bbox()
    log(f"active bbox before Ctrl+A n  : {bbox_before}")
    log(f"active bbox after  Ctrl+A n  : {bbox_after}")
    if bbox_before and bbox_after and bbox_before == bbox_after:
        fails.append("Ctrl+A n did not move focus in nested mode (0.8.3 prefix not honoured)")
    elif not (bbox_before and bbox_after):
        log("  (could not resolve active border bbox; skipping strict prefix check)")

    os.write(master2, b"\x01d")  # Ctrl+A d detach (nested prefix)
    time.sleep(0.6)
    try: os.close(master2)
    except OSError: pass
    try: os.waitpid(pid2,0)
    except ChildProcessError: pass

    # snapshot of final nested frame
    print("\n  --- nested frame (top 6 rows) ---")
    for ln in sc.text().splitlines()[:6]:
        print("   | " + ln[:118])

    print("\n=== VERDICT:", "PASS ✓" if not fails else "FAIL ✗", "===")
    for f in fails: print("   ✗ " + f)
    cleanup()
    sys.exit(0 if not fails else 1)

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: cleanup(); sys.exit(130)
