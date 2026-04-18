"""
Shared harness for teruwm end-to-end tests.

Design goals:
 - Each test starts with a **fresh teruwm** (clean state, deterministic).
 - Runs on `WLR_BACKENDS=headless` — no display, no TTY grab, no way to
   break the user's live session. Output is a virtual 1280x720.
 - MCP is HTTP-over-Unix. We use compact JSON (whitespace-free) because
   the existing `extractJsonString` parser is fragile around pretty
   JSON (pre-existing bug surfaced during this test bring-up).
 - A short retry on `BrokenPipeError` — the wl_event_loop has a tiny
   listen backlog (5) and rarely drops a connect under back-to-back
   calls; reconnect once before giving up.
 - `snap(label)` drops a screenshot under SHOT_DIR so every test leaves
   a visual trail.
"""

from __future__ import annotations
import contextlib
import glob
import hashlib
import json
import os
import socket
import subprocess
import time
from dataclasses import dataclass, field
from typing import Any, Optional


def file_md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

TERUWM = os.environ.get("TERUWM", "/home/ng/code/foss/teru/zig-out/bin/teruwm")
SOCK_DIR = f"/run/user/{os.getuid()}"
SHOT_DIR_DEFAULT = "/tmp/teruwm-e2e-shots"


class McpError(RuntimeError):
    pass


def _mcp_once(sock: str, body: bytes, timeout: float) -> bytes:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock)
    req = (
        b"POST / HTTP/1.1\r\nContent-Length: "
        + str(len(body)).encode()
        + b"\r\nContent-Type: application/json\r\n\r\n"
        + body
    )
    s.sendall(req)
    data = bytearray()
    try:
        while True:
            c = s.recv(65536)
            if not c:
                break
            data.extend(c)
    except socket.timeout:
        pass
    finally:
        with contextlib.suppress(OSError):
            s.close()
    return bytes(data)


def mcp_call(
    sock: str,
    tool: str,
    args: dict | None = None,
    timeout: float = 5.0,
    retries: int = 2,
) -> tuple[Any, Optional[str]]:
    """Call an MCP tool. Returns (parsed_text, error_or_None)."""
    msg = json.dumps(
        {
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}},
            "id": 1,
        },
        separators=(",", ":"),
    ).encode()

    last_err = None
    for attempt in range(retries + 1):
        try:
            raw = _mcp_once(sock, msg, timeout)
        except FileNotFoundError:
            # Socket is gone — compositor has exited. Retrying can't help.
            return None, "compositor-gone"
        except (BrokenPipeError, ConnectionResetError, ConnectionRefusedError) as e:
            last_err = f"transport: {e}"
            time.sleep(0.1 * (attempt + 1))
            continue
        if b"\r\n\r\n" not in raw:
            last_err = "no HTTP response"
            time.sleep(0.05)
            continue
        body = raw.split(b"\r\n\r\n", 1)[1].decode("utf-8", errors="replace")
        try:
            resp = json.loads(body)
        except json.JSONDecodeError as e:
            return None, f"json-parse: {e}"
        if "error" in resp:
            return None, resp["error"].get("message", "unknown")
        text = resp.get("result", {}).get("content", [{}])[0].get("text", "")
        # MCP wraps JSON-as-string — try to unwrap.
        try:
            return json.loads(text), None
        except json.JSONDecodeError:
            # Some tools return de-escaped JSON with literal \"
            try:
                return json.loads(text.replace('\\"', '"')), None
            except json.JSONDecodeError:
                return text, None  # Free-text tool
    return None, last_err or "unknown transport failure"


def _wait_socket(pid: int, timeout: float = 10.0) -> Optional[str]:
    path = f"{SOCK_DIR}/teruwm-mcp-{pid}.sock"
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            return path
        time.sleep(0.05)
    return None


@dataclass
class Wm:
    """A running teruwm instance. Yields from `start()` as a context manager."""

    proc: subprocess.Popen
    sock: str
    pid: int
    stderr_log: str
    shot_dir: str
    _shot_counter: int = field(default=0, init=False)

    def call(self, tool: str, args: dict | None = None, **kw):
        return mcp_call(self.sock, tool, args, **kw)

    def snap(self, label: str) -> str:
        """Take a screenshot to SHOT_DIR/NN-label.png and return the path.

        IMPORTANT: teruwm's PNG encoder writes essentially-uncompressed
        data, so **every shot has the same file size (~2.77 MB) regardless
        of content**. Compare by md5 (file_md5 helper), never by size.
        """
        self._shot_counter += 1
        name = f"{self._shot_counter:03d}-{label}.png"
        path = os.path.join(self.shot_dir, name)
        _, err = self.call("teruwm_screenshot", {"path": path})
        if err:
            raise McpError(f"screenshot({label}): {err}")
        return path

    def ensure_ws(self, ws: int) -> None:
        """Switch to a workspace and wait a render tick."""
        self.call("teruwm_switch_workspace", {"workspace": ws})

    def spawn_terminal(self, ws: int = 0, wait: float = 0.15) -> int:
        """Spawn a terminal and return its node_id."""
        before, err = self.call("teruwm_list_windows")
        if err == "compositor-gone":
            raise McpError("compositor gone before spawn_terminal")
        self.call("teruwm_spawn_terminal", {"workspace": ws})
        deadline = time.time() + 3.0
        while time.time() < deadline:
            after, err = self.call("teruwm_list_windows")
            if err == "compositor-gone":
                raise McpError("compositor gone during spawn_terminal")
            if after and len(after) > len(before or []):
                new_ids = {w["id"] for w in after} - {w["id"] for w in (before or [])}
                return next(iter(new_ids))
            time.sleep(wait)
        raise McpError("terminal did not appear")

    def test_key(self, action: str) -> tuple[Any, Optional[str]]:
        return self.call("teruwm_test_key", {"action": action})


def _cleanup_stale_sockets() -> None:
    for p in glob.glob(f"{SOCK_DIR}/teruwm-mcp-*.sock"):
        # Only unlink sockets whose pids are dead.
        try:
            pid = int(p.rsplit("-", 1)[-1].split(".", 1)[0])
            try:
                os.kill(pid, 0)
                continue  # still alive — leave it
            except ProcessLookupError:
                with contextlib.suppress(OSError):
                    os.unlink(p)
        except ValueError:
            pass


@contextlib.contextmanager
def start(
    shot_dir: str = SHOT_DIR_DEFAULT,
    env_extra: Optional[dict] = None,
    startup_timeout: float = 10.0,
):
    """Launch a fresh headless teruwm. Yields a `Wm` instance.

    Cleans up on exit even if the test body raises.
    """
    os.makedirs(shot_dir, exist_ok=True)
    _cleanup_stale_sockets()

    env = dict(os.environ)
    env["WLR_BACKENDS"] = "headless"
    env["XDG_RUNTIME_DIR"] = SOCK_DIR
    # WLR_LIBINPUT_NO_DEVICES avoids libinput init on headless.
    env.setdefault("WLR_LIBINPUT_NO_DEVICES", "1")
    # Don't inherit WAYLAND_DISPLAY — we want our own nested wayland-N.
    env.pop("WAYLAND_DISPLAY", None)
    if env_extra:
        env.update(env_extra)

    stderr_log = os.path.join(shot_dir, "_teruwm.stderr.log")
    proc = subprocess.Popen(
        [TERUWM],
        stdout=subprocess.DEVNULL,
        stderr=open(stderr_log, "w"),
        env=env,
    )
    sock = _wait_socket(proc.pid, timeout=startup_timeout)
    if sock is None:
        proc.kill()
        raise RuntimeError(
            f"teruwm {proc.pid} never created its MCP socket. "
            f"stderr at {stderr_log}"
        )
    # Small settle — let the initial output connect & terminal spawn.
    time.sleep(0.4)

    wm = Wm(proc=proc, sock=sock, pid=proc.pid, stderr_log=stderr_log, shot_dir=shot_dir)
    try:
        yield wm
    finally:
        with contextlib.suppress(ProcessLookupError, OSError):
            proc.terminate()
            try:
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                proc.kill()
        _cleanup_stale_sockets()
