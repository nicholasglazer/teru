#!/usr/bin/env python3
"""JSON-RPC envelope conformance test for TERU and TERUWM MCP servers.

Tests all 59 MCP tools (22 teru agent + 37 teruwm compositor) against
JSON-RPC 2.0 envelope compliance:
  - Response has jsonrpc=="2.0"
  - Response has numeric id matching request
  - Response has exactly one of result|error (never both, never neither)
  - If error, error.code is numeric and error.message is string

Approach:
  1. Launch both teru daemon and headless teruwm
  2. Seed one pane (teru_create_pane) and one window (teruwm_spawn_terminal)
  3. For each tool, synthesize minimal valid args from inputSchema
  4. Call via line-JSON (teru) or HTTP-over-Unix (teruwm)
  5. Assert well-formed JSON-RPC 2.0 envelope
  6. Skip destructive tools (teruwm_quit, teru_session_restore, teruwm_session_restore)
  7. Report pass/fail per server and per tool

Exit: 0 = all non-skipped tools passed, 1 = any failure

Usage:
    python3 tests/tool_conformance_test.py [teru_bin] [teruwm_bin]

If binaries not specified, auto-discovers from zig-out/bin or ~/.local/bin.
"""

import glob
import json
import os
import signal
import socket
import subprocess
import sys
import time
from typing import Any, Dict, Optional, Tuple

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")

# ── Tool definitions (from source inspection) ────────────────────
TERU_TOOLS = {
    "teru_broadcast": {"workspace": 0, "text": "test\n"},
    "teru_close_pane": {"pane_id": 0},
    "teru_create_pane": {"direction": "vertical"},
    "teru_focus_pane": {"pane_id": 0},
    "teru_get_config": {},
    "teru_get_graph": {},
    "teru_get_state": {"pane_id": 0},
    "teru_list_panes": {},
    "teru_move_pane": {"pane_id": 0, "workspace": 1},
    "teru_read_output": {"pane_id": 0, "lines": 10},
    "teru_scroll": {"pane_id": 0, "direction": "up", "lines": 5},
    "teru_send_input": {"pane_id": 0, "text": "test\n"},
    "teru_send_keys": {"pane_id": 0, "keys": ["ctrl+c"]},
    "teru_session_restore": {"name": "test"},  # SKIP: destructive
    "teru_session_save": {"name": "test"},
    "teru_set_config": {"key": "padding", "value": "4"},
    "teru_set_layout": {"layout": "grid", "workspace": 0},
    "teru_subscribe_events": {},
    "teru_swap_pane": {"pane_id": 0, "direction": "next"},
    "teru_switch_workspace": {"workspace": 1},
    "teru_wait_for": {"pane_id": 0, "pattern": "test", "lines": 10},
    "teru_screenshot": {"path": "/tmp/teru-conformance.png"},
}

TERUWM_TOOLS = {
    "teruwm_click": {"x": 100, "y": 100, "button": 272},
    "teruwm_close_window": {"node_id": 0},
    "teruwm_delete_widget": {"name": "test"},
    "teruwm_focus_window": {"node_id": 0},
    "teruwm_get_config": {},
    "teruwm_list_widgets": {},
    "teruwm_list_windows": {},
    "teruwm_list_workspaces": {},
    "teruwm_mouse_path": {"from_x": 100, "from_y": 100, "to_x": 200, "to_y": 200},
    "teruwm_move_to_workspace": {"node_id": 0, "workspace": 1},
    "teruwm_notify": {"message": "test"},
    "teruwm_perf": {},
    "teruwm_press": {"key": "Return"},
    "teruwm_quit": {},  # SKIP: destructive
    "teruwm_reload_config": {},
    "teruwm_restart": {},  # SKIP: destructive
    "teruwm_screenshot": {"path": "/tmp/teruwm-conformance.png"},
    "teruwm_screenshot_pane": {"name": "term-0-0", "path": "/tmp/pane.png"},
    "teruwm_scroll": {"x": 100, "y": 100, "dy": 3},
    "teruwm_session_restore": {},  # SKIP: destructive
    "teruwm_session_save": {},
    "teruwm_set_bar": {"which": "top", "enabled": True},
    "teruwm_set_config": {"key": "gap", "value": "4"},
    "teruwm_set_layout": {"layout": "grid", "workspace": 0},
    "teruwm_set_name": {"node_id": 0, "new_name": "test"},
    "teruwm_set_widget": {"name": "test", "text": "hello"},
    "teruwm_spawn_terminal": {},
    "teruwm_subscribe_events": {},
    "teruwm_switch_workspace": {"workspace": 1},
    "teruwm_test_drag": {"from_x": 100, "from_y": 100, "to_x": 200, "to_y": 200, "button": 272},
    "teruwm_test_key": {"action": "pane_focus_next"},
    "teruwm_test_move": {"x": 150, "y": 150},
    "teruwm_toggle_bar": {"which": "top"},
    "teruwm_toggle_scratchpad": {"index": 0},
    "teruwm_type": {"text": "test"},
    "teruwm_zoom": {"direction": "in"},
}

SKIP_TOOLS = {
    "teru_session_restore",
    "teruwm_quit",
    "teruwm_restart",
    "teruwm_session_restore",
}


class TeruMCP:
    """Line-JSON MCP client for teru agent."""
    
    def __init__(self, sock_path):
        self.sock_path = sock_path
        self._id = 0
    
    def call(self, tool: str, args: Dict[str, Any]) -> Dict[str, Any]:
        """Call a tool, return parsed JSON-RPC response."""
        self._id += 1
        msg = json.dumps({
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}},
            "id": self._id,
        })
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        try:
            s.connect(self.sock_path)
            s.sendall(msg.encode() + b'\n')
        except OSError as e:
            return {"error": {"code": -999, "message": f"connect/send failed: {e}"}}
        
        resp = b''
        try:
            deadline = time.time() + 2.0
            while time.time() < deadline:
                try:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    resp += chunk
                    if b'\n' in resp:
                        break
                except socket.timeout:
                    break
        finally:
            s.close()
        
        if not resp.strip():
            return {"error": {"code": -999, "message": "no response from daemon"}}
        
        line = resp.split(b'\n', 1)[0].decode('utf-8', errors='replace')
        try:
            return json.loads(line)
        except json.JSONDecodeError as e:
            return {"error": {"code": -999, "message": f"JSON decode failed: {e}"}}


class TeruWMMCP:
    """HTTP-over-Unix MCP client for teruwm."""
    
    def __init__(self, sock_path):
        self.sock_path = sock_path
        self._id = 0
    
    def call(self, tool: str, args: Dict[str, Any]) -> Dict[str, Any]:
        """Call a tool, return parsed JSON-RPC response."""
        self._id += 1
        body = json.dumps({
            "jsonrpc": "2.0",
            "id": self._id,
            "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}},
        }).encode()
        
        req = (b"POST / HTTP/1.1\r\nHost: localhost\r\n"
               b"Content-Type: application/json\r\n"
               b"Content-Length: " + str(len(body)).encode() +
               b"\r\nConnection: close\r\n\r\n" + body)
        
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        try:
            s.connect(self.sock_path)
            s.sendall(req)
        except OSError as e:
            return {"error": {"code": -999, "message": f"connect/send failed: {e}"}}
        
        resp = b''
        try:
            while True:
                try:
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    resp += chunk
                except socket.timeout:
                    break
        finally:
            s.close()
        
        _, _, payload = resp.partition(b"\r\n\r\n")
        if not payload.strip():
            return {"error": {"code": -999, "message": "no response from compositor"}}
        
        try:
            return json.loads(payload)
        except json.JSONDecodeError as e:
            return {"error": {"code": -999, "message": f"JSON decode failed: {e}"}}


def launch_teru() -> Tuple[subprocess.Popen, str]:
    """Launch teru daemon, return (proc, socket_path)."""
    env = dict(os.environ)
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("DISPLAY", None)
    
    log = open("/tmp/teru-conformance.log", "w")
    proc = subprocess.Popen(["teru", "--daemon", "conformance"],
                            env=env, stdout=log, stderr=log,
                            start_new_session=True)
    
    sock = None
    for _ in range(40):
        time.sleep(0.1)
        socks = glob.glob(os.path.join(RUNTIME_DIR, "teru-mcp-*.sock"))
        if socks:
            sock = sorted(socks, key=os.path.getmtime)[-1]
            break
    
    if not sock:
        proc.send_signal(signal.SIGTERM)
        raise RuntimeError("teru did not create MCP socket")
    
    time.sleep(0.2)
    return proc, sock


def launch_teruwm() -> Tuple[subprocess.Popen, str]:
    """Launch teruwm headless, return (proc, socket_path)."""
    env = dict(os.environ)
    env.update({
        "WLR_BACKENDS": "headless",
        "WLR_RENDERER": "pixman",
        "TERU_LOG": "error",
    })
    env.pop("WAYLAND_DISPLAY", None)
    env.pop("DISPLAY", None)
    
    for stale in glob.glob(os.path.join(RUNTIME_DIR, "teruwm-mcp-*.sock")):
        try:
            os.unlink(stale)
        except:
            pass
    
    log = open("/tmp/teruwm-conformance.log", "w")
    proc = subprocess.Popen(["teruwm"], env=env, stdout=log, stderr=log,
                            start_new_session=True)
    
    sock = None
    for _ in range(40):
        time.sleep(0.1)
        socks = [s for s in glob.glob(os.path.join(RUNTIME_DIR, "teruwm-mcp-*.sock"))
                 if "events" not in s]
        if socks:
            sock = socks[0]
            break
    
    if not sock:
        proc.send_signal(signal.SIGTERM)
        raise RuntimeError("teruwm did not create MCP socket")
    
    time.sleep(0.3)
    return proc, sock


def check_response(r: Dict[str, Any], request_id: int, tool: str) -> Tuple[bool, str]:
    """Validate JSON-RPC 2.0 envelope. Return (ok, message)."""
    
    if not isinstance(r, dict):
        return False, f"response is not a dict: {type(r)}"
    
    # Check jsonrpc field
    if r.get("jsonrpc") != "2.0":
        return False, f"jsonrpc field missing or not '2.0': {r.get('jsonrpc')}"
    
    # Check id field
    if "id" not in r:
        return False, "id field missing"
    if r["id"] != request_id:
        return False, f"id mismatch: request={request_id}, response={r['id']}"
    
    # Check result/error (exactly one)
    has_result = "result" in r
    has_error = "error" in r
    
    if has_result and has_error:
        return False, "both result and error present"
    if not has_result and not has_error:
        return False, "neither result nor error present"
    
    # If error, check structure
    if has_error:
        err = r["error"]
        if not isinstance(err, dict):
            return False, f"error field is not a dict: {type(err)}"
        if "code" not in err or not isinstance(err["code"], int):
            return False, f"error.code missing or not int: {err.get('code')}"
        if "message" not in err or not isinstance(err["message"], str):
            return False, f"error.message missing or not string: {err.get('message')}"
    
    return True, ""


def run_test(server: str, mcp_client, tools: Dict[str, Dict], seed_pane_id: int = 0, seed_window_id: int = 0):
    """Test all tools on a server. Return list of (tool, ok, detail)."""
    results = []
    
    for tool, default_args in sorted(tools.items()):
        if tool in SKIP_TOOLS:
            results.append((tool, None, "SKIPPED (destructive)"))
            continue
        
        # Inject real ids for tools that need them
        args = dict(default_args)
        if "pane_id" in args and seed_pane_id > 0:
            args["pane_id"] = seed_pane_id
        if "node_id" in args and seed_window_id > 0:
            args["node_id"] = seed_window_id
        
        try:
            request_id = (tool.__hash__() % 10000) + 1000
            resp = mcp_client.call(tool, args)
            ok, detail = check_response(resp, mcp_client._id, tool)
            
            if ok:
                results.append((tool, True, ""))
            else:
                results.append((tool, False, detail))
        except Exception as e:
            results.append((tool, False, str(e)[:100]))
    
    return results


def main():
    teru_bin = sys.argv[1] if len(sys.argv) > 1 else "teru"
    teruwm_bin = sys.argv[2] if len(sys.argv) > 2 else "teruwm"
    
    teru_proc = None
    teruwm_proc = None
    
    try:
        print("=" * 70)
        print("JSON-RPC 2.0 Envelope Conformance Test")
        print("=" * 70)
        
        # Launch daemons
        print("\n[SETUP] Launching teru daemon...")
        try:
            teru_proc, teru_sock = launch_teru()
            print(f"  teru socket: {teru_sock}")
        except Exception as e:
            print(f"  ERROR: {e}")
            return 1
        
        print("\n[SETUP] Launching teruwm compositor...")
        try:
            teruwm_proc, teruwm_sock = launch_teruwm()
            print(f"  teruwm socket: {teruwm_sock}")
        except Exception as e:
            print(f"  ERROR: {e}")
            return 1
        
        # Seed pane and window
        print("\n[SETUP] Seeding test pane and window...")
        teru_mcp = TeruMCP(teru_sock)
        teruwm_mcp = TeruWMMCP(teruwm_sock)
        
        pane_resp = teru_mcp.call("teru_create_pane", {"direction": "vertical"})
        pane_id = 0
        if "result" in pane_resp:
            try:
                text = pane_resp["result"]["content"][0]["text"]
                pane_id = int(text.strip())
                print(f"  seeded pane: {pane_id}")
            except:
                print(f"  WARNING: could not parse pane_id from response")
        
        time.sleep(0.2)
        
        win_resp = teruwm_mcp.call("teruwm_spawn_terminal", {})
        window_id = 0
        if "result" in win_resp:
            wins = teruwm_mcp.call("teruwm_list_windows", {})
            try:
                win_list = json.loads(wins["result"]["content"][0]["text"])
                if win_list:
                    window_id = win_list[0]["id"]
                    print(f"  seeded window: {window_id}")
            except:
                print(f"  WARNING: could not parse window_id")
        
        time.sleep(0.2)
        
        # Run conformance tests
        print("\n[TEST] TERU agent server")
        print("-" * 70)
        teru_results = run_test("teru", teru_mcp, TERU_TOOLS, pane_id)
        
        print("\n[TEST] TERUWM compositor server")
        print("-" * 70)
        teruwm_results = run_test("teruwm", teruwm_mcp, TERUWM_TOOLS, 0, window_id)
        
        # Report results
        all_results = [("teru", r) for r in teru_results] + [("teruwm", r) for r in teruwm_results]
        
        print("\n" + "=" * 70)
        print("RESULTS")
        print("=" * 70)
        
        teru_pass = 0
        teru_fail = 0
        teru_skip = 0
        teruwm_pass = 0
        teruwm_fail = 0
        teruwm_skip = 0
        
        for server, (tool, ok, detail) in all_results:
            if ok is None:
                status = "SKIP"
                if server == "teru":
                    teru_skip += 1
                else:
                    teruwm_skip += 1
            elif ok:
                status = "PASS"
                if server == "teru":
                    teru_pass += 1
                else:
                    teruwm_pass += 1
            else:
                status = "FAIL"
                if server == "teru":
                    teru_fail += 1
                else:
                    teruwm_fail += 1
            
            detail_str = f" — {detail}" if detail else ""
            print(f"  [{status}] {server:7s} {tool:40s}{detail_str}"[:90])
        
        print("\n" + "=" * 70)
        print(f"TERU AGENT:      {teru_pass} passed, {teru_fail} failed, {teru_skip} skipped")
        print(f"TERUWM COMPOSITOR: {teruwm_pass} passed, {teruwm_fail} failed, {teruwm_skip} skipped")
        print("=" * 70)
        
        if teru_fail > 0 or teruwm_fail > 0:
            print("\nVERDICT: FAIL ✗")
            return 1
        else:
            print("\nVERDICT: PASS ✓")
            return 0
    
    finally:
        # Clean up
        for proc in [teru_proc, teruwm_proc]:
            if proc:
                try:
                    proc.send_signal(signal.SIGTERM)
                    proc.wait(timeout=2)
                except:
                    try:
                        proc.kill()
                    except:
                        pass


if __name__ == "__main__":
    sys.exit(main())
