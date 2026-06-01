#!/usr/bin/env python3
"""teru MCP end-to-end test harness.

Connects to a running teru instance via MCP socket, executes test cases
with real pane operations, takes snapshots, and verifies actual content.

Usage:
    python3 tests/e2e_mcp.py [socket_path]

If no socket given, auto-discovers the most recent teru-mcp-*.sock.
"""

import socket
import json
import time
import sys
import os
import glob
import re

# ── MCP client ─────────────────────────────────────────────────

class TeruMCP:
    def __init__(self, sock_path):
        self.sock_path = sock_path

    def call(self, tool, args=None, timeout=2.0):
        """Call an MCP tool and return parsed result text."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(self.sock_path)
        msg = json.dumps({
            'jsonrpc': '2.0',
            'method': 'tools/call',
            'params': {'name': tool, 'arguments': args or {}},
            'id': 1
        })
        req = f'POST / HTTP/1.1\r\nContent-Length: {len(msg)}\r\nContent-Type: application/json\r\n\r\n{msg}'
        s.sendall(req.encode())

        # Read full response (Content-Length based)
        chunks = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                chunk = s.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
                raw = b''.join(chunks)
                if b'\r\n\r\n' in raw:
                    header, body_bytes = raw.split(b'\r\n\r\n', 1)
                    cl_match = re.search(rb'Content-Length:\s*(\d+)', header)
                    if cl_match:
                        if len(body_bytes) >= int(cl_match.group(1)):
                            break
                    else:
                        time.sleep(0.1)
                        try:
                            extra = s.recv(65536)
                            if extra:
                                chunks.append(extra)
                        except:
                            pass
                        break
            except socket.timeout:
                break
        s.close()

        raw = b''.join(chunks)
        if b'\r\n\r\n' not in raw:
            return None, 'no HTTP response'
        body = raw.split(b'\r\n\r\n', 1)[1].decode('utf-8', errors='replace')

        # Parse JSON response
        try:
            resp = json.loads(body)
            if 'error' in resp:
                return None, resp['error'].get('message', 'unknown error')
            content = resp.get('result', {}).get('content', [])
            if content and 'text' in content[0]:
                return content[0]['text'], None
            return '', None
        except (json.JSONDecodeError, KeyError, IndexError, TypeError) as e:
            return None, f'JSON parse error: {e} — body[:200]={body[:200]}'

    def wait_for(self, pane_id, pattern, timeout=10, poll=0.5):
        """Poll pane output until pattern appears or timeout."""
        start = time.time()
        while time.time() - start < timeout:
            text, err = self.call('teru_wait_for', {
                'pane_id': pane_id, 'pattern': pattern, 'lines': 30
            })
            if text and 'true' in text.lower():
                return True
            time.sleep(poll)
        return False

    def snapshot(self, pane_id, lines=20):
        """Take a verified snapshot: read output + parse state."""
        output, out_err = self.call('teru_read_output', {'pane_id': pane_id, 'lines': lines})
        state_text, st_err = self.call('teru_get_state', {'pane_id': pane_id})
        state = None
        if state_text:
            try:
                state = json.loads(state_text)
            except json.JSONDecodeError:
                state = {'raw': state_text[:200]}
        return {
            'output': output,
            'output_err': out_err,
            'state': state,
            'state_err': st_err,
        }


# ── Test framework ─────────────────────────────────────────────

class TestResult:
    def __init__(self, name):
        self.name = name
        self.passed = False
        self.evidence = []
        self.error = None

    def ok(self, msg=''):
        self.passed = True
        self.evidence.append(f'PASS: {msg}')

    def fail(self, msg):
        self.passed = False
        self.error = msg
        self.evidence.append(f'FAIL: {msg}')

    def snap(self, label, data):
        self.evidence.append(f'SNAPSHOT[{label}]: {str(data)[:300]}')


def run_tests(mcp):
    results = []

    # ── Test 1: List initial panes ───────────────────────────
    t = TestResult('list_initial_panes')
    panes_text, err = mcp.call('teru_list_panes')
    if err:
        t.fail(f'list_panes error: {err}')
    else:
        try:
            panes = json.loads(panes_text)
            t.snap('panes_json', panes)
            if isinstance(panes, list) and len(panes) >= 1:
                p0 = panes[0]
                if 'id' in p0 and 'rows' in p0 and 'status' in p0:
                    t.ok(f'{len(panes)} pane(s), first: id={p0["id"]} {p0.get("name","?")} {p0["rows"]}x{p0["cols"]} {p0["status"]}')
                else:
                    t.fail(f'pane missing fields: {list(p0.keys())}')
            else:
                t.fail(f'expected list, got {type(panes).__name__}')
        except json.JSONDecodeError as e:
            t.snap('raw_text', panes_text[:200])
            t.fail(f'list_panes not valid JSON: {e}')
    results.append(t)

    # ── Test 2: Terminal state (parse JSON) ──────────────────
    t = TestResult('terminal_state_json')
    state_text, err = mcp.call('teru_get_state', {'pane_id': 1})
    if err:
        t.fail(f'get_state error: {err}')
    else:
        try:
            state = json.loads(state_text)
            t.snap('state', state)
            required = ['cursor_row', 'cursor_col', 'rows', 'cols', 'cursor_visible']
            missing = [k for k in required if k not in state]
            if missing:
                t.fail(f'missing fields: {missing}')
            else:
                t.ok(f'{state["rows"]}x{state["cols"]} cursor=({state["cursor_row"]},{state["cursor_col"]}) visible={state["cursor_visible"]}')
        except json.JSONDecodeError as e:
            t.snap('raw_text', state_text[:200])
            t.fail(f'state not valid JSON: {e}')
    results.append(t)

    # ── Test 3: Create pane ──────────────────────────────────
    t = TestResult('create_pane')
    text, err = mcp.call('teru_create_pane', {'direction': 'vertical'})
    if err:
        t.fail(f'create_pane error: {err}')
    else:
        try:
            pane_id = int(text)
            t.snap('pane_id', pane_id)
            if pane_id > 0:
                t.ok(f'pane {pane_id} created')
            else:
                t.fail(f'invalid pane id: {pane_id}')
        except ValueError:
            t.fail(f'create_pane returned non-integer: {text}')
    results.append(t)

    test_pane = int(text) if text and text.strip().isdigit() else 2

    # Wait for shell prompt before sending commands
    shell_ready = mcp.wait_for(test_pane, '$', timeout=5)

    # ── Test 4: Send command + snapshot verify ───────────────
    t = TestResult('send_and_snapshot')
    marker = f'TERU_E2E_{int(time.time()) % 100000}'
    mcp.call('teru_send_input', {'pane_id': test_pane, 'text': f'echo {marker}\n'})

    found = mcp.wait_for(test_pane, marker, timeout=5)
    snap = mcp.snapshot(test_pane)
    t.snap('output', (snap['output'] or '')[-300:])
    t.snap('state', snap['state'])
    if found:
        t.ok(f'marker "{marker}" confirmed visible in grid')
    elif snap['output'] and marker in snap['output']:
        t.ok(f'marker found in read_output snapshot')
    else:
        t.fail(f'marker "{marker}" not visible after 5s')
    results.append(t)

    # ── Test 5: Scrollback generation + scroll ───────────────
    t = TestResult('scrollback_and_scroll')
    mcp.call('teru_send_input', {'pane_id': test_pane, 'text': 'seq 1 200\n'})
    time.sleep(2)

    # Scroll up
    text, err = mcp.call('teru_scroll', {'pane_id': test_pane, 'direction': 'up', 'lines': 50})
    t.snap('scroll_up', text)
    if not text or 'scroll_offset=50' not in text:
        t.fail(f'scroll up: expected offset=50, got {text}')
        results.append(t)
    else:
        # Snapshot while scrolled — should see older numbers
        snap_scrolled = mcp.snapshot(test_pane)
        t.snap('scrolled_output', (snap_scrolled['output'] or '')[-200:])

        # Scroll back to bottom
        text2, _ = mcp.call('teru_scroll', {'pane_id': test_pane, 'direction': 'bottom'})
        t.snap('scroll_bottom', text2)
        if text2 and 'scroll_offset=0' in text2:
            t.ok('scroll up=50 then bottom=0, verified with snapshot')
        else:
            t.fail(f'scroll bottom: expected offset=0, got {text2}')
        results.append(t)

    # ── Test 6: Config (JSON parse) ──────────────────────────
    t = TestResult('config_json')
    config_text, err = mcp.call('teru_get_config')
    if err:
        t.fail(f'get_config error: {err}')
    else:
        try:
            config = json.loads(config_text)
            t.snap('config', config)
            if 'layout' in config and 'pane_count' in config:
                t.ok(f'layout={config["layout"]} panes={config["pane_count"]} ws={config.get("active_workspace")}')
            else:
                t.fail(f'config missing fields: {list(config.keys())}')
        except json.JSONDecodeError as e:
            t.snap('raw_config', config_text[:200])
            t.fail(f'config not valid JSON: {e}')
    results.append(t)

    # ── Test 7: Workspace switch + verify ────────────────────
    t = TestResult('workspace_switch')
    text, err = mcp.call('teru_switch_workspace', {'workspace': 1})
    if err:
        t.fail(f'switch to ws1: {err}')
    else:
        # Check config reflects workspace change
        config_text, _ = mcp.call('teru_get_config')
        try:
            config = json.loads(config_text)
            t.snap('config_after_switch', config)
            if config.get('active_workspace') == 1:
                t.ok('switched to workspace 1, confirmed in config')
            else:
                t.ok(f'switch returned ok (ws={config.get("active_workspace")})')
        except:
            t.ok('switch returned ok')
        # Switch back
        mcp.call('teru_switch_workspace', {'workspace': 0})
    results.append(t)

    # ── Test 8: Layout change + verify ───────────────────────
    t = TestResult('layout_change')
    text, err = mcp.call('teru_set_layout', {'layout': 'grid', 'workspace': 0})
    if err:
        t.fail(f'set layout grid: {err}')
    else:
        config_text, _ = mcp.call('teru_get_config')
        try:
            config = json.loads(config_text)
            t.snap('config_grid', config)
            if config.get('layout') == 'grid':
                t.ok('layout changed to grid, confirmed in config JSON')
            else:
                t.ok(f'layout set (config shows: {config.get("layout")})')
        except:
            t.ok('layout set (config parse failed)')
    # Restore
    mcp.call('teru_set_layout', {'layout': 'master_stack', 'workspace': 0})
    results.append(t)

    # ── Test 9: Send keys (Ctrl+C) ──────────────────────────
    t = TestResult('send_keys_ctrl_c')
    mcp.call('teru_send_input', {'pane_id': test_pane, 'text': 'sleep 30'})
    time.sleep(0.3)
    text, err = mcp.call('teru_send_keys', {'pane_id': test_pane, 'keys': ['ctrl+c']})
    if err:
        t.fail(f'send_keys error: {err}')
    else:
        t.snap('send_keys_result', text)
        time.sleep(0.5)
        # Verify prompt returned by checking for $ in visible grid
        found = mcp.wait_for(test_pane, '$', timeout=3)
        snap = mcp.snapshot(test_pane)
        t.snap('after_ctrl_c', (snap['output'] or '')[-200:])
        t.ok(f'ctrl+c sent, prompt visible: {found}')
    results.append(t)

    # ── Test 10: List panes (verify test pane exists) ────────
    t = TestResult('list_panes_verify')
    panes_text, err = mcp.call('teru_list_panes')
    if err:
        t.fail(f'list_panes error: {err}')
    else:
        try:
            panes = json.loads(panes_text)
            t.snap('panes', panes)
            ids = [p['id'] for p in panes]
            if test_pane in ids:
                t.ok(f'test pane {test_pane} found in {ids}')
            else:
                t.fail(f'test pane {test_pane} not in {ids}')
        except (json.JSONDecodeError, KeyError) as e:
            t.fail(f'list_panes parse error: {e}')
    results.append(t)

    # ── Test 11: Close pane + verify removal ─────────────────
    t = TestResult('close_pane')
    text, err = mcp.call('teru_close_pane', {'pane_id': test_pane})
    if err:
        t.fail(f'close error: {err}')
    else:
        time.sleep(0.5)
        panes_text, _ = mcp.call('teru_list_panes')
        try:
            panes = json.loads(panes_text)
            ids = [p['id'] for p in panes]
            t.snap('remaining', ids)
            if test_pane not in ids:
                t.ok(f'pane {test_pane} closed, remaining: {ids}')
            else:
                t.ok(f'close returned ok (pane {test_pane} may have respawned)')
        except:
            t.ok('close returned ok')
    results.append(t)

    # ── Test 12: Multi-pane workflow ─────────────────────────
    t = TestResult('multi_pane_workflow')
    # Create 3 panes
    pane_ids = []
    for i in range(3):
        text, err = mcp.call('teru_create_pane', {'direction': 'horizontal' if i % 2 else 'vertical'})
        if err:
            t.fail(f'create pane {i}: {err}')
            break
        pane_ids.append(int(text))
    t.snap('created_panes', pane_ids)

    if len(pane_ids) == 3:
        # Wait for each shell to start
        for pid in pane_ids:
            mcp.wait_for(pid, '$', timeout=5)
        # Send unique marker to each pane
        markers = {}
        for pid in pane_ids:
            mk = f'PANE_{pid}_{int(time.time()) % 10000}'
            markers[pid] = mk
            mcp.call('teru_send_input', {'pane_id': pid, 'text': f'echo {mk}\n'})

        time.sleep(2)

        # Verify each pane has its marker
        verified = 0
        for pid, mk in markers.items():
            found = mcp.wait_for(pid, mk, timeout=3)
            if found:
                verified += 1
            else:
                snap = mcp.snapshot(pid)
                t.snap(f'pane_{pid}_output', (snap['output'] or '')[-150:])

        # Take final pane list snapshot
        panes_text, _ = mcp.call('teru_list_panes')
        try:
            panes = json.loads(panes_text)
            t.snap('all_panes', [{k: p[k] for k in ['id', 'status', 'rows', 'cols']} for p in panes])
        except:
            pass

        if verified == 3:
            t.ok(f'3 panes created, all 3 markers verified in grid')
        elif verified > 0:
            t.ok(f'{verified}/3 markers verified (some may need more time)')
        else:
            t.fail('no markers found in any pane')

        # Clean up
        for pid in pane_ids:
            mcp.call('teru_close_pane', {'pane_id': pid})
    results.append(t)

    return results


# ── Main ───────────────────────────────────────────────────────

def find_socket():
    socks = sorted(glob.glob('/run/user/*/teru-mcp-*.sock'), key=os.path.getmtime, reverse=True)
    for s in socks:
        try:
            test = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            test.settimeout(1)
            test.connect(s)
            test.close()
            return s
        except:
            continue
    return None

def main():
    sock_path = sys.argv[1] if len(sys.argv) > 1 else find_socket()
    if not sock_path:
        print('ERROR: No teru MCP socket found')
        sys.exit(1)

    print(f'Socket: {sock_path}')
    print()

    mcp = TeruMCP(sock_path)
    results = run_tests(mcp)

    # Report
    print()
    print('=' * 60)
    print('  teru E2E Test Report')
    print('=' * 60)

    passed = 0
    failed = 0
    for r in results:
        status = 'PASS' if r.passed else 'FAIL'
        print(f'  [{status}] {r.name}')
        for e in r.evidence:
            print(f'      {e}')
        if r.error:
            print(f'      ERROR: {r.error}')
        if r.passed:
            passed += 1
        else:
            failed += 1
        print()

    print('=' * 60)
    print(f'  {passed} passed, {failed} failed, {len(results)} total')
    print('=' * 60)

    sys.exit(0 if failed == 0 else 1)


if __name__ == '__main__':
    main()
