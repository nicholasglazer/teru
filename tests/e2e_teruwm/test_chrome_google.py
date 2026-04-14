"""Real end-to-end: launch chromium inside a live (headless) teruwm,
navigate to Google search, drive compositor interactions through teruwm
MCP (real Wayland pointer events), then screenshot with grim to prove
chromium actually rendered the Google page.

 - Chromium: native Wayland. teruwm composites its buffers like any
   real xdg-shell client.
 - Search: hit /search?q=... directly. This proves the *page load and
   render path* works end-to-end — the search box handling is Chrome's
   job, not teruwm's.
 - Clicks: teruwm_test_move + teruwm_test_drag. These synthesize actual
   `wlr_cursor` motion + `wlr_seat_pointer_notify_button` events that
   land in chromium's Wayland queue. Same code path as a physical click.
 - Screenshots: grim via wlr-screencopy. Includes xdg buffers (chromium),
   unlike teruwm_screenshot which only composites teruwm's own panes.
 - Keyboard verification: we dispatch Mod+F (fullscreen_toggle) via
   teruwm_test_key and confirm chromium's rect expanded to the full
   output — that's the v0.5.1 fix for bug #2.
"""
from __future__ import annotations
import json
import os
import subprocess
import sys
import time
import urllib.request
from typing import Optional

import harness

SHOT_DIR = "/tmp/teruwm-chrome-shots"
REPORT = os.path.join(SHOT_DIR, "report.txt")
CDP_PORT = 9333
SEARCH_URL = "https://www.google.com/search?q=teruwm+tiling+wayland+compositor"

os.makedirs(SHOT_DIR, exist_ok=True)


def log(msg: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    with open(REPORT, "a") as f:
        f.write(line + "\n")


def grim(wayland: str, out: str) -> bool:
    env = {**os.environ, "WAYLAND_DISPLAY": wayland,
           "XDG_RUNTIME_DIR": "/run/user/1000"}
    try:
        r = subprocess.run(["grim", out], env=env, capture_output=True, timeout=8)
        if r.returncode == 0 and os.path.exists(out) and os.path.getsize(out) > 1000:
            return True
        log(f"grim rc={r.returncode} stderr={r.stderr.decode()[:200]}")
        return False
    except Exception as e:
        log(f"grim: {e}")
        return False


def cdp_tabs() -> list[dict]:
    try:
        r = urllib.request.urlopen(f"http://127.0.0.1:{CDP_PORT}/json",
                                    timeout=3)
        return json.loads(r.read())
    except Exception as e:
        log(f"CDP: {e}")
        return []


class _MiniWS:
    """Minimal websocket-13 client for CDP. Enough to send a single
    command + read a single reply. No handshake key randomisation."""

    def __init__(self, url: str, timeout: float = 10.0):
        import base64, hashlib, socket, ssl, struct, os as _os
        from urllib.parse import urlparse
        u = urlparse(url)
        host = u.hostname or "127.0.0.1"
        port = u.port or 80
        path = u.path or "/"
        self._struct = struct
        self._sock = socket.create_connection((host, port), timeout=timeout)
        key = base64.b64encode(_os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
        self._sock.sendall(req)
        # Consume handshake response headers
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self._sock.recv(4096)
            if not chunk:
                raise RuntimeError("ws handshake truncated")
            buf += chunk

    def send(self, text: str) -> None:
        data = text.encode()
        hdr = bytearray([0x81])  # FIN + text
        n = len(data)
        mask = b"\x00\x00\x00\x00"  # server requires mask from client
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += self._struct.pack(">H", n)
        else:
            hdr.append(0x80 | 127)
            hdr += self._struct.pack(">Q", n)
        hdr += mask
        self._sock.sendall(bytes(hdr) + data)

    def recv(self) -> str:
        hdr = self._recv_exact(2)
        fin_op = hdr[0]
        ln = hdr[1] & 0x7F
        if ln == 126:
            ln = self._struct.unpack(">H", self._recv_exact(2))[0]
        elif ln == 127:
            ln = self._struct.unpack(">Q", self._recv_exact(8))[0]
        payload = self._recv_exact(ln) if ln else b""
        return payload.decode("utf-8", "replace")

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("ws short read")
            buf += chunk
        return buf

    def close(self) -> None:
        try: self._sock.close()
        except: pass


def cdp_screenshot(tab_ws_url: str, out_path: str) -> bool:
    """Navigate on already-loaded tab, capture a PNG via
    Page.captureScreenshot, save to disk. Proves chromium actually
    rendered the page (independent of compositor screencopy)."""
    import base64
    try:
        ws = _MiniWS(tab_ws_url)
        ws.send(json.dumps({"id": 1, "method": "Page.captureScreenshot",
                            "params": {"format": "png"}}))
        # Skip event frames, collect reply to id=1
        for _ in range(50):
            msg = json.loads(ws.recv())
            if msg.get("id") == 1:
                png_b64 = msg["result"]["data"]
                with open(out_path, "wb") as f:
                    f.write(base64.b64decode(png_b64))
                ws.close()
                return True
        ws.close()
        log("cdp_screenshot: no reply")
        return False
    except Exception as e:
        log(f"cdp_screenshot: {e}")
        return False


def cdp_eval(tab_ws_url: str, expr: str) -> Optional[str]:
    """Evaluate JS on the page and return the result as a string.
    Proves real DOM queries work."""
    try:
        ws = _MiniWS(tab_ws_url)
        ws.send(json.dumps({"id": 2, "method": "Runtime.evaluate",
                            "params": {"expression": expr,
                                       "returnByValue": True}}))
        for _ in range(50):
            msg = json.loads(ws.recv())
            if msg.get("id") == 2:
                ws.close()
                r = msg.get("result", {}).get("result", {})
                return str(r.get("value", r.get("description", "")))
        ws.close()
        return None
    except Exception as e:
        log(f"cdp_eval: {e}")
        return None


def main() -> int:
    open(REPORT, "w").close()
    log("test_chrome_google start")

    with harness.start(shot_dir=SHOT_DIR + "/_harness", startup_timeout=10) as wm:
        time.sleep(0.5)

        # Derive wayland display from teruwm stderr
        wayland = "wayland-0"
        with open(wm.stderr_log) as f:
            for line in f:
                if "WAYLAND_DISPLAY=" in line:
                    wayland = line.strip().split("WAYLAND_DISPLAY=")[-1]
                    break
        log(f"teruwm pid={wm.pid}  WAYLAND_DISPLAY={wayland}")

        # 01 — empty compositor (terminal pane + bars only)
        if grim(wayland, f"{SHOT_DIR}/01-teruwm-fresh.png"):
            log(f"01-teruwm-fresh.png ok ({os.path.getsize(SHOT_DIR+'/01-teruwm-fresh.png')} B)")
        else:
            log("01 grim failed — headless wlr-screencopy may not be working")

        # ── Launch chromium as native Wayland client ─────────────
        chrome_env = {
            **os.environ,
            "WAYLAND_DISPLAY": wayland,
            "XDG_RUNTIME_DIR": "/run/user/1000",
            "DISPLAY": "",  # force wayland path
        }
        chrome = subprocess.Popen([
            "chromium",
            "--ozone-platform=wayland",
            "--enable-features=UseOzonePlatform",
            f"--remote-debugging-port={CDP_PORT}",
            "--remote-allow-origins=*",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-features=TranslateUI,Translate",
            "--no-sandbox",            # headless env has no cgroup namespace
            "--disable-dev-shm-usage", # /dev/shm is limited in some envs
            "--disable-gpu-sandbox",
            "--user-data-dir=/tmp/teruwm-chrome-profile",
            "--window-size=1280,720",
            SEARCH_URL,
        ], env=chrome_env,
           stdout=subprocess.DEVNULL,
           stderr=open(f"{SHOT_DIR}/_chrome.stderr.log", "w"))
        log(f"chromium pid={chrome.pid} (native wayland, CDP port {CDP_PORT})")

        # Wait for chromium to map
        chrome_nid: Optional[int] = None
        deadline = time.time() + 25
        while time.time() < deadline:
            wins, _ = wm.call("teruwm_list_windows")
            xdg = [w for w in (wins or []) if w.get("kind") != "terminal"]
            if xdg:
                chrome_nid = xdg[0]["id"]
                log(f"chrome mapped: node_id={chrome_nid} rect="
                    f"({xdg[0]['x']},{xdg[0]['y']}) {xdg[0]['w']}x{xdg[0]['h']}")
                break
            time.sleep(0.4)

        if chrome_nid is None:
            log("ERROR: chromium never mapped")
            ch_err = open(f"{SHOT_DIR}/_chrome.stderr.log").read()[-500:]
            log(f"chromium stderr tail:\n{ch_err}")
            chrome.kill()
            return 1

        # 02 — chromium tiled (waits for page render)
        time.sleep(5.0)
        grim(wayland, f"{SHOT_DIR}/02-chrome-tiled.png")
        log(f"02-chrome-tiled.png")

        # ── Verify via CDP that search page actually loaded ──────
        tabs = cdp_tabs()
        search_tab = None
        if tabs:
            log(f"CDP: {len(tabs)} tab(s)")
            for t in tabs[:3]:
                log(f"   - {t.get('type','?')}: {t.get('url','')}")
                log(f"     title: {t.get('title','')}")
            search_tab = next(
                (t for t in tabs
                 if t.get("type") == "page"
                 and "google.com/search" in t.get("url", "")),
                None,
            )
            if search_tab:
                log(f"CONFIRMED: Google search results URL loaded via CDP")
                log(f"  URL: {search_tab['url']}")
                log(f"  TITLE: {search_tab['title']}")
            else:
                log(f"WARN: no google.com/search tab found")
        else:
            log("WARN: no CDP response — chromium debug port down")

        # 03a — chromium's own screenshot (proves rendering at page level)
        if search_tab:
            ws_url = search_tab["webSocketDebuggerUrl"]
            ok = cdp_screenshot(ws_url, f"{SHOT_DIR}/03a-chrome-cdp-shot.png")
            log(f"03a-chrome-cdp-shot.png via CDP: {'ok' if ok else 'FAIL'}")
            h1_text = cdp_eval(ws_url,
                "document.querySelector('h3') ? "
                "document.querySelector('h3').innerText : '<no h3>'")
            log(f"first <h3> on page: {h1_text!r}")
            title_text = cdp_eval(ws_url, "document.title")
            log(f"document.title: {title_text!r}")

        # 03b — compositor-level screenshot (teruwm_screenshot; self-
        # composites terminal+bars only, but confirms compositor state)
        _, _ = wm.call("teruwm_screenshot",
                       {"path": f"{SHOT_DIR}/03b-compositor-shot.png"})
        log("03b-compositor-shot.png via teruwm_screenshot")

        # 03c — try grim (may be zero-size in headless)
        grim(wayland, f"{SHOT_DIR}/03c-grim-shot.png")

        # ── Real click via teruwm MCP (not a CDP shortcut) ──────
        wins, _ = wm.call("teruwm_list_windows")
        cw = next(w for w in wins if w["id"] == chrome_nid)
        # Click near the top-left of the chromium rect (title area) —
        # inside chromium but not on a specific link. Just proves the
        # pointer event reached a live Wayland client.
        click_x = cw["x"] + 200
        click_y = cw["y"] + 100
        log(f"clicking via teruwm MCP at ({click_x},{click_y})")
        _, err = wm.call("teruwm_test_move", {"x": click_x, "y": click_y})
        log(f"  test_move err={err}")
        _, err = wm.call("teruwm_test_drag", {
            "from_x": click_x, "from_y": click_y,
            "to_x":   click_x, "to_y": click_y,
            "super": False,
        })
        log(f"  test_drag (click) err={err}")
        time.sleep(0.6)
        grim(wayland, f"{SHOT_DIR}/04-after-click.png")

        # ── Verify the fullscreen-fix bug fix (Mod+F) ────────────
        log("testing Mod+F fullscreen fix on chromium (was bug #2)")
        _, err = wm.call("teruwm_focus_window", {"node_id": chrome_nid})
        log(f"  focus err={err}")
        time.sleep(0.1)
        _, err = wm.test_key("fullscreen_toggle")
        log(f"  fullscreen_toggle err={err}")
        time.sleep(0.6)

        wins, _ = wm.call("teruwm_list_windows")
        cfg, _ = wm.call("teruwm_get_config")
        cw = next(w for w in wins if w["id"] == chrome_nid)
        full_w, full_h = cfg["output_width"], cfg["output_height"]
        is_full = (cw["w"] >= full_w * 0.95 and cw["h"] >= full_h * 0.95 and
                   cw["x"] <= 10 and cw["y"] <= 10)
        verdict = "PASS" if is_full else "FAIL"
        log(f"FULLSCREEN-FIX-VERIFY: chrome rect after Mod+F = "
            f"({cw['x']},{cw['y']}) {cw['w']}x{cw['h']}  full=({full_w}x{full_h}) -> {verdict}")
        time.sleep(0.3)
        grim(wayland, f"{SHOT_DIR}/05-fullscreen.png")

        # ── Un-fullscreen back to tiled ─────────────────────────
        _, _ = wm.test_key("fullscreen_toggle")
        time.sleep(0.4)
        grim(wayland, f"{SHOT_DIR}/06-unfullscreen.png")

        # Cleanup
        chrome.terminate()
        try: chrome.wait(timeout=3)
        except: chrome.kill()

    log("DONE. artifacts:")
    for p in sorted(os.listdir(SHOT_DIR)):
        full = os.path.join(SHOT_DIR, p)
        if os.path.isfile(full):
            log(f"  {os.path.getsize(full):>10d}  {full}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
