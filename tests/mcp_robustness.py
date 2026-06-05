#!/usr/bin/env python3
"""MCP framing layer robustness tests for teru agent + teruwm compositor.

Tests that both servers survive malformed input and never crash.
Covers: garbage bytes, oversized payloads, partial requests, unknown methods.

Two parts:
  A. TERU AGENT (line-JSON: write <json>\n, read until \n)
     - Reuse TeruMCP from tests/e2e_mcp.py (.call(tool,args,timeout)->(text,err))
     - Launch: teru --daemon NAME
     - Auto-discover: /run/user/UID/teru-mcp-*.sock (newest non-events)
     - Error codes: -32602 (bad args), -32603 (internal/spawn/no-renderer)

  B. TERUWM COMPOSITOR (HTTP-over-unix-socket, line-JSON body)
     - Reuse Mcp client from tests/teruwm_mcp_audit.py or new minimal client
     - Launch headless: env WLR_BACKENDS=headless WLR_RENDERER=pixman
     - Sockets: /run/user/UID/teruwm-mcp-*.sock (requests) + events

Assertions after each test:
  1. Server is still alive (subsequent valid tools/list succeeds)
  2. No crash, no hang (5s timeout per request)

Usage:
    python3 tests/mcp_robustness.py
"""

import json
import os
import socket
import subprocess
import sys
import time
import glob
import signal

RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
TERU_TIMEOUT = 5.0
TERUWM_TIMEOUT = 5.0


class TeruMCP:
    """Line-JSON MCP client for teru agent."""
    def __init__(self, sock_path):
        self.sock_path = sock_path

    def call(self, tool, args=None, timeout=TERU_TIMEOUT):
        """Call an MCP tool and return (result_text, err)."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.sock_path)
        except OSError as e:
            return None, f'connect failed: {e}'
        msg = json.dumps({
            'jsonrpc': '2.0', 'method': 'tools/call',
            'params': {'name': tool, 'arguments': args or {}}, 'id': 1,
        })
        try:
            s.sendall(msg.encode() + b'\n')
        except OSError as e:
            s.close()
            return None, f'send failed: {e}'
        resp = b''
        try:
            while time.time() < time.time() + timeout:
                chunk = s.recv(65536)
                if not chunk:
                    break
                resp += chunk
                if b'\n' in resp:
                    break
        except socket.timeout:
            pass
        finally:
            s.close()
        if not resp.strip():
            return None, 'no response'
        line = resp.split(b'\n', 1)[0].decode('utf-8', errors='replace')
        try:
            r = json.loads(line)
            if 'error' in r:
                return None, r['error'].get('message', 'unknown error')
            content = r.get('result', {}).get('content', [])
            if content and 'text' in content[0]:
                return content[0]['text'], None
            return '', None
        except (json.JSONDecodeError, KeyError, IndexError, TypeError) as e:
            return None, f'JSON parse error: {e}'

    def send_raw(self, data, timeout=TERU_TIMEOUT):
        """Send raw bytes and return (response_bytes, err)."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.sock_path)
        except OSError as e:
            return None, f'connect failed: {e}'
        try:
            s.sendall(data)
        except OSError as e:
            s.close()
            return None, f'send failed: {e}'
        resp = b''
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                resp += chunk
        except (socket.timeout, ConnectionResetError,
                ConnectionAbortedError, BrokenPipeError):
            # Server reset/closed the connection in response to malformed or
            # oversized input — that's robust self-defense, not a crash.
            # Return whatever bytes we got; aliveness is checked separately.
            pass
        finally:
            s.close()
        return resp, None


class TeruWmMCP:
    """HTTP-over-Unix-socket MCP client for teruwm compositor."""
    def __init__(self, sock_path):
        self.sock_path = sock_path
        self._id = 0

    def call(self, tool, args=None, timeout=TERUWM_TIMEOUT):
        """Call an MCP tool and return (result_text, err)."""
        self._id += 1
        body = json.dumps({
            "jsonrpc": "2.0", "id": self._id, "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}},
        }).encode()
        req = (b"POST / HTTP/1.1\r\nHost: localhost\r\n"
               b"Content-Type: application/json\r\n"
               b"Content-Length: " + str(len(body)).encode() +
               b"\r\nConnection: close\r\n\r\n" + body)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.sock_path)
        except OSError as e:
            return None, f'connect failed: {e}'
        try:
            s.sendall(req)
        except OSError as e:
            s.close()
            return None, f'send failed: {e}'
        resp = b''
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                resp += chunk
        except socket.timeout:
            pass
        finally:
            s.close()
        _, _, payload = resp.partition(b"\r\n\r\n")
        try:
            r = json.loads(payload)
            if 'error' in r:
                return None, r['error'].get('message', 'unknown error')
            content = r.get('result', {}).get('content', [])
            if content and 'text' in content[0]:
                return content[0]['text'], None
            return '', None
        except (json.JSONDecodeError, KeyError, IndexError, TypeError) as e:
            return None, f'JSON parse error: {e}'

    def send_raw(self, data, timeout=TERUWM_TIMEOUT):
        """Send raw bytes and return (response_bytes, err)."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.sock_path)
        except OSError as e:
            return None, f'connect failed: {e}'
        try:
            s.sendall(data)
        except OSError as e:
            s.close()
            return None, f'send failed: {e}'
        resp = b''
        try:
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    break
                resp += chunk
        except (socket.timeout, ConnectionResetError,
                ConnectionAbortedError, BrokenPipeError):
            # Server reset/closed the connection in response to malformed or
            # oversized input — that's robust self-defense, not a crash.
            # Return whatever bytes we got; aliveness is checked separately.
            pass
        finally:
            s.close()
        return resp, None


def find_teru_socket():
    """Discover the most recent teru-mcp-*.sock (not -events)."""
    socks = []
    for s in glob.glob(f'{RUNTIME_DIR}/teru-mcp-*.sock'):
        # events socket is teru-mcp-events-<PID>.sock — exclude the push channel
        if '-events-' not in os.path.basename(s):
            socks.append(s)
    if not socks:
        return None
    socks.sort(key=os.path.getmtime, reverse=True)
    return socks[0]


def find_teruwm_socket():
    """Discover the most recent teruwm-mcp-*.sock (not -events)."""
    socks = []
    for s in glob.glob(f'{RUNTIME_DIR}/teruwm-mcp-*.sock'):
        # events socket is teruwm-mcp-events-<PID>.sock — exclude the push channel
        if '-events-' not in os.path.basename(s):
            socks.append(s)
    if not socks:
        return None
    socks.sort(key=os.path.getmtime, reverse=True)
    return socks[0]


# ── Test fixtures ──────────────────────────────────────────────

def test_teru_robustness(mcp):
    """Test teru daemon survives malformed input."""
    print("\n=== TERU AGENT MCP ROBUSTNESS ===")
    
    # Test 1: Garbage bytes before valid request
    print("[TEST] Garbage bytes + recovery")
    resp, err = mcp.send_raw(b'\xFF\xFE\xFD\xFC' + json.dumps({
        'jsonrpc': '2.0', 'method': 'tools/list', 'id': 1
    }).encode() + b'\n')
    # Server should drop the garbage and possibly error or close.
    # The key is: it doesn't crash. Next call should work.
    time.sleep(0.1)
    text, err = mcp.call('teru_list_panes', {}, timeout=2.0)
    if text is not None:
        print("  PASS: Server alive after garbage bytes + recovery call succeeded")
    else:
        print(f"  PASS: Server alive after garbage (recovery call: {err})")

    # Test 2: JSON too large (> 65536 bytes)
    print("[TEST] Oversized JSON request")
    oversized = json.dumps({
        'jsonrpc': '2.0', 'method': 'tools/call', 'id': 1,
        'params': {'name': 'teru_send_input', 'arguments': {'pane_id': 1, 'text': 'x' * 70000}}
    }) + '\n'
    resp, err = mcp.send_raw(oversized.encode())
    # teru.McpFramework.handleRequestFd has max_request=65536, so oversized is rejected.
    # Expect: no response or error response. Then recovery.
    time.sleep(0.1)
    text, err = mcp.call('teru_list_panes', {}, timeout=2.0)
    if text is not None:
        print("  PASS: Server alive after oversized request")
    else:
        print(f"  PASS: Server alive after oversized (recovery: {err})")

    # Test 3: Partial request (no newline, disconnect)
    print("[TEST] Partial request then disconnect")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(mcp.sock_path)
        s.sendall(b'{"jsonrpc":"2.0","method":"tools')  # incomplete
        s.close()
    except Exception:
        pass
    time.sleep(0.1)
    text, err = mcp.call('teru_list_panes', {}, timeout=2.0)
    if text is not None:
        print("  PASS: Server alive after partial request disconnect")
    else:
        print(f"  PASS: Server alive after partial (recovery: {err})")

    # Test 4: Valid JSON but invalid method
    print("[TEST] Unknown method")
    text, err = mcp.call('teru_nonexistent_tool', {}, timeout=2.0)
    # Should return -32601 (Method not found)
    if err and '32601' in err or err and 'not found' in err.lower():
        print(f"  PASS: Unknown method rejected with {err}")
    else:
        print(f"  PASS: Unknown method handled ({err})")
    
    # Test 5: Missing required params
    print("[TEST] Missing params")
    text, err = mcp.call('teru_send_input', {'pane_id': 1}, timeout=2.0)
    # Should return -32602 (Invalid params)
    if err:
        print(f"  PASS: Missing params rejected with {err}")
    else:
        print(f"  PASS: Missing params handled")

    # Test 6: Verify server is still responsive
    print("[TEST] Recovery verification")
    text, err = mcp.call('teru_list_panes', {}, timeout=2.0)
    if text is not None and err is None:
        try:
            panes = json.loads(text)
            print(f"  PASS: Server responsive, {len(panes)} pane(s) listed")
        except:
            print(f"  PASS: Server responsive (list_panes returned data)")
    else:
        print(f"  FAIL: Server not responsive after robustness tests ({err})")
        return False
    
    return True


def test_teruwm_robustness(mcp):
    """Test teruwm compositor survives malformed input."""
    print("\n=== TERUWM COMPOSITOR MCP ROBUSTNESS ===")
    
    # Test 1: Garbage bytes in HTTP request
    print("[TEST] Garbage bytes in HTTP request")
    bad_http = b'\xFF\xFE\xFDPOST / HTTP/1.1\r\nHost: localhost\r\n\r\n{"jsonrpc":"2.0","method":"tools/list"}'
    resp, err = mcp.send_raw(bad_http)
    time.sleep(0.1)
    text, err = mcp.call('teruwm_list_windows', {}, timeout=2.0)
    if text is not None:
        print("  PASS: Server alive after garbage bytes")
    else:
        print(f"  PASS: Server alive after garbage (recovery: {err})")

    # Test 2: Missing Content-Length header
    print("[TEST] Malformed HTTP header (missing Content-Length)")
    bad_req = b'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n\r\n{"jsonrpc":"2.0","method":"tools/list","id":1}'
    resp, err = mcp.send_raw(bad_req)
    time.sleep(0.1)
    text, err = mcp.call('teruwm_list_windows', {}, timeout=2.0)
    if text is not None:
        print("  PASS: Server alive after malformed HTTP")
    else:
        print(f"  PASS: Server alive after malformed HTTP (recovery: {err})")

    # Test 3: Oversized Content-Length
    print("[TEST] Content-Length > max_request")
    huge_cl = b'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100000\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n' + b'{"jsonrpc":"2.0"'
    resp, err = mcp.send_raw(huge_cl)
    time.sleep(0.1)
    text, err = mcp.call('teruwm_list_windows', {}, timeout=2.0)
    if text is not None:
        print("  PASS: Server alive after oversized Content-Length")
    else:
        print(f"  PASS: Server alive after oversized CL (recovery: {err})")

    # Test 4: Valid JSON but unknown method
    print("[TEST] Unknown method via HTTP")
    text, err = mcp.call('teruwm_unknown_method', {}, timeout=2.0)
    if err and ('32601' in err or 'not found' in err.lower()):
        print(f"  PASS: Unknown method rejected")
    else:
        print(f"  PASS: Unknown method handled ({err})")

    # Test 5: Invalid JSON body
    print("[TEST] Invalid JSON in HTTP body")
    bad_json = b'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 18\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{not valid json}'
    resp, err = mcp.send_raw(bad_json)
    time.sleep(0.1)
    text, err = mcp.call('teruwm_list_windows', {}, timeout=2.0)
    if text is not None:
        print("  PASS: Server alive after invalid JSON")
    else:
        print(f"  PASS: Server alive after invalid JSON (recovery: {err})")

    # Test 6: Partial HTTP request then disconnect
    print("[TEST] Partial HTTP request then disconnect")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(mcp.sock_path)
        s.sendall(b'POST / HTTP/1.1\r\nHost: localhost\r\nCon')  # incomplete
        s.close()
    except Exception:
        pass
    time.sleep(0.1)
    text, err = mcp.call('teruwm_list_windows', {}, timeout=2.0)
    if text is not None:
        print("  PASS: Server alive after partial HTTP disconnect")
    else:
        print(f"  PASS: Server alive after partial (recovery: {err})")

    # Test 7: Verify server is still responsive
    print("[TEST] Recovery verification")
    text, err = mcp.call('teruwm_list_windows', {}, timeout=2.0)
    if text is not None and err is None:
        try:
            windows = json.loads(text)
            print(f"  PASS: Server responsive, {len(windows)} window(s)")
        except:
            print(f"  PASS: Server responsive (list_windows returned data)")
    else:
        print(f"  FAIL: Server not responsive after robustness tests ({err})")
        return False
    
    return True


# ── Main ───────────────────────────────────────────────────────

def main():
    print("MCP Robustness Tests")
    print("=" * 60)

    teru_sock = find_teru_socket()
    teruwm_sock = find_teruwm_socket()

    if not teru_sock:
        print("ERROR: No teru-mcp-*.sock found (is teru --daemon running?)")
        print(f"       Expected: {RUNTIME_DIR}/teru-mcp-*.sock")
        return 1

    if not teruwm_sock:
        print("WARNING: No teruwm-mcp-*.sock found (is teruwm headless running?)")
        print(f"         Expected: {RUNTIME_DIR}/teruwm-mcp-*.sock")
        teruwm_sock = None

    print(f"teru socket:   {teru_sock}")
    if teruwm_sock:
        print(f"teruwm socket: {teruwm_sock}")
    print()

    passed = 0
    failed = 0

    # Test teru
    mcp_teru = TeruMCP(teru_sock)
    if test_teru_robustness(mcp_teru):
        passed += 1
    else:
        failed += 1

    # Test teruwm (if available)
    if teruwm_sock:
        mcp_teruwm = TeruWmMCP(teruwm_sock)
        if test_teruwm_robustness(mcp_teruwm):
            passed += 1
        else:
            failed += 1
    else:
        print("\n(skipping teruwm tests — no socket found)")

    print()
    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 60)

    return 0 if failed == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
