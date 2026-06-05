#!/usr/bin/env python3
"""teru MCP error-envelope test harness.

Tests JSON-RPC error responses for invalid input, missing required args,
nonexistent resources, and out-of-range parameters. Reuses TeruMCP class
from tests/e2e_mcp.py (.call(tool,args,timeout)->(text,err)).

Error codes:
  -32602: Invalid Request / bad/missing/out-of-range args
  -32603: Internal error (spawn failure, no renderer, etc)

Verifies error envelope structure:
  {"jsonrpc":"2.0","error":{"code":N,"message":"..."},"id":...}

Hermetic: launches its OWN throwaway `teru --daemon` (socket keyed to that
PID), drives it over the line-JSON socket, tears it down. Never connects to
a real interactive daemon, so it cannot disturb the user's session.

Usage:
    python3 tests/e2e_mcp_error_paths.py [path/to/teru]

If no binary path is given, resolves zig-out/bin/teru → ~/.local/bin/teru → PATH.
"""

import socket
import json
import time
import sys
import os
import glob
import subprocess
import signal

# ── MCP client (reuse from e2e_mcp.py) ─────────────────────────────

class TeruMCP:
    def __init__(self, sock_path):
        self.sock_path = sock_path

    def call(self, tool, args=None, timeout=2.0):
        """Call an MCP tool (line-JSON transport) and return (result_text, err)."""
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
            s.close(); return None, f'send failed: {e}'
        resp = b''
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            resp += chunk
            if b'\n' in resp:
                break
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
            return None, f'JSON parse error: {e} — line[:200]={line[:200]}'

    def call_raw(self, tool, args=None, timeout=2.0):
        """Call an MCP tool and return the raw JSON response (including errors)."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.sock_path)
        except OSError as e:
            return None
        msg = json.dumps({
            'jsonrpc': '2.0', 'method': 'tools/call',
            'params': {'name': tool, 'arguments': args or {}}, 'id': 1,
        })
        try:
            s.sendall(msg.encode() + b'\n')
        except OSError as e:
            s.close(); return None
        resp = b''
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            resp += chunk
            if b'\n' in resp:
                break
        s.close()
        if not resp.strip():
            return None
        line = resp.split(b'\n', 1)[0].decode('utf-8', errors='replace')
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return None


# ── Test framework ─────────────────────────────────────────────────

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

    def check_error_envelope(self, resp, expected_code, expected_msg_substr):
        """Verify JSON-RPC error envelope structure and content."""
        if resp is None:
            self.fail('no response received')
            return False
        if not isinstance(resp, dict):
            self.fail(f'response is not a dict: {type(resp).__name__}')
            return False
        if 'error' not in resp:
            self.fail(f'no error field in response: {list(resp.keys())}')
            return False
        error = resp['error']
        if not isinstance(error, dict):
            self.fail(f'error is not a dict: {type(error).__name__}')
            return False
        if 'code' not in error:
            self.fail(f'error.code missing: {list(error.keys())}')
            return False
        if 'message' not in error:
            self.fail(f'error.message missing: {list(error.keys())}')
            return False
        if resp.get('jsonrpc') != '2.0':
            self.fail(f'jsonrpc is not "2.0": {resp.get("jsonrpc")}')
            return False
        if error['code'] != expected_code:
            self.fail(f'expected error code {expected_code}, got {error["code"]}')
            return False
        msg = error['message']
        if expected_msg_substr not in msg:
            self.fail(f'expected message substring "{expected_msg_substr}", got "{msg}"')
            return False
        self.snap('error_envelope', {'code': error['code'], 'message': msg})
        return True


def run_error_tests(mcp):
    results = []

    # Missing pane_id errors (tests 1-5)
    for test_num, tool in enumerate([
        ('teru_focus_pane', {}),
        ('teru_close_pane', {}),
        ('teru_send_keys', {'keys': ['enter']}),
        ('teru_send_input', {'text': 'hello'}),
        ('teru_read_output', {}),
    ], 1):
        tool_name, args = test_num, tool
        t = TestResult(f'missing_pane_id_{tool[0].split("teru_")[1]}')
        resp = mcp.call_raw(tool[0], tool[1])
        if t.check_error_envelope(resp, -32602, 'Missing pane_id'):
            t.ok(f'{tool[0]} without pane_id → -32602')
        results.append(t)

    # Nonexistent pane_id errors (tests 6-15)
    for tool, msg_part in [
        ('teru_focus_pane', 'focus'),
        ('teru_close_pane', 'close'),
        ('teru_send_input', 'send_input'),
        ('teru_send_keys', 'send_keys'),
        ('teru_get_state', 'get_state'),
        ('teru_read_output', 'read_output'),
        ('teru_scroll', 'scroll'),
        ('teru_wait_for', 'wait_for'),
        ('teru_move_pane', 'move_pane'),
        ('teru_swap_pane', 'swap_pane'),
    ]:
        t = TestResult(f'nonexistent_pane_{msg_part}')
        args_map = {
            'teru_send_input': {'pane_id': 999999, 'text': 'hi'},
            'teru_send_keys': {'pane_id': 999999, 'keys': ['enter']},
            'teru_scroll': {'pane_id': 999999, 'direction': 'up'},
            'teru_wait_for': {'pane_id': 999999, 'pattern': 'test'},
            'teru_move_pane': {'pane_id': 999999, 'workspace': 1},
            'teru_swap_pane': {'pane_id': 999999, 'direction': 'next'},
        }
        args = args_map.get(tool, {'pane_id': 999999})
        resp = mcp.call_raw(tool, args)
        if t.check_error_envelope(resp, -32602, 'Pane not found'):
            t.ok(f'{tool} with invalid pane_id → -32602')
        results.append(t)

    # Out-of-range workspace errors (tests 16-20)
    for workspace_val, tool, args_base in [
        (99, 'teru_switch_workspace', {}),
        (10, 'teru_create_pane', {'direction': 'vertical'}),
        (15, 'teru_move_pane', {'pane_id': 1}),
        (11, 'teru_set_layout', {'layout': 'grid'}),
        (20, 'teru_broadcast', {'text': 'test'}),
    ]:
        t = TestResult(f'workspace_out_of_range_{tool.split("teru_")[1]}')
        args = {**args_base, 'workspace': workspace_val}
        resp = mcp.call_raw(tool, args)
        if t.check_error_envelope(resp, -32602, 'Workspace must be 0-9'):
            t.ok(f'{tool} with workspace={workspace_val} → -32602')
        results.append(t)

    # Missing workspace/text errors (tests 21-22)
    t = TestResult('missing_workspace_broadcast')
    resp = mcp.call_raw('teru_broadcast', {'text': 'hello'})
    if t.check_error_envelope(resp, -32602, 'Missing workspace'):
        t.ok('broadcast without workspace → -32602')
    results.append(t)

    t = TestResult('missing_text_broadcast')
    resp = mcp.call_raw('teru_broadcast', {'workspace': 0})
    if t.check_error_envelope(resp, -32602, 'Missing text'):
        t.ok('broadcast without text → -32602')
    results.append(t)

    # Layout errors (tests 23-24)
    t = TestResult('missing_layout_set_layout')
    resp = mcp.call_raw('teru_set_layout', {'workspace': 0})
    if t.check_error_envelope(resp, -32602, 'Missing layout'):
        t.ok('set_layout without layout → -32602')
    results.append(t)

    t = TestResult('unknown_layout')
    resp = mcp.call_raw('teru_set_layout', {'layout': 'nonexistent', 'workspace': 0})
    if t.check_error_envelope(resp, -32602, 'Unknown layout'):
        t.ok('set_layout with unknown layout → -32602')
    results.append(t)

    # Config errors (tests 25-27)
    t = TestResult('missing_config_key')
    resp = mcp.call_raw('teru_set_config', {'value': '12'})
    if t.check_error_envelope(resp, -32602, 'Missing key'):
        t.ok('set_config without key → -32602')
    results.append(t)

    t = TestResult('missing_config_value')
    resp = mcp.call_raw('teru_set_config', {'key': 'padding'})
    if t.check_error_envelope(resp, -32602, 'Missing value'):
        t.ok('set_config without value → -32602')
    results.append(t)

    t = TestResult('unknown_config_key')
    resp = mcp.call_raw('teru_set_config', {'key': 'bogus_key', 'value': '42'})
    if t.check_error_envelope(resp, -32602, 'Unknown config key'):
        t.ok('set_config with unknown key → -32602')
    results.append(t)

    # Session errors (tests 28-29)
    t = TestResult('missing_session_name_save')
    resp = mcp.call_raw('teru_session_save', {})
    if t.check_error_envelope(resp, -32602, 'Missing name'):
        t.ok('session_save without name → -32602')
    results.append(t)

    t = TestResult('missing_session_name_restore')
    resp = mcp.call_raw('teru_session_restore', {})
    if t.check_error_envelope(resp, -32602, 'Missing name'):
        t.ok('session_restore without name → -32602')
    results.append(t)

    # Additional missing args (tests 30-34)
    t = TestResult('missing_pane_scroll')
    resp = mcp.call_raw('teru_scroll', {})
    if t.check_error_envelope(resp, -32602, 'Missing pane_id'):
        t.ok('scroll without pane_id → -32602')
    results.append(t)

    t = TestResult('missing_pane_wait_for')
    resp = mcp.call_raw('teru_wait_for', {'pattern': 'test'})
    if t.check_error_envelope(resp, -32602, 'Missing pane_id'):
        t.ok('wait_for without pane_id → -32602')
    results.append(t)

    t = TestResult('missing_pattern_wait_for')
    resp = mcp.call_raw('teru_wait_for', {'pane_id': 1})
    if t.check_error_envelope(resp, -32602, 'Missing pattern'):
        t.ok('wait_for without pattern → -32602')
    results.append(t)

    t = TestResult('invalid_scroll_direction')
    resp = mcp.call_raw('teru_scroll', {'pane_id': 1, 'direction': 'sideways'})
    if t.check_error_envelope(resp, -32602, 'direction must be up/down/bottom'):
        t.ok('scroll with invalid direction → -32602')
    results.append(t)

    t = TestResult('missing_pane_move')
    resp = mcp.call_raw('teru_move_pane', {'workspace': 1})
    if t.check_error_envelope(resp, -32602, 'Missing pane_id'):
        t.ok('move_pane without pane_id → -32602')
    results.append(t)

    # BUG-B regression test (test 35): send_keys must REPORT both the
    # delivered count and the skipped (unrecognized / empty) count — not
    # silently drop bad key names. Response shape: "sent N keys, M skipped".
    # Uses the daemon's default pane (id 1); 'enter' resolves to a harmless
    # newline, the other two resolve to "" and must be counted as skipped.
    t = TestResult('send_keys_reports_skipped_BUG_B')
    resp = mcp.call_raw('teru_send_keys',
                        {'pane_id': 1, 'keys': ['enter', 'bogus_key', '']})
    result_text = None
    if resp and 'result' in resp:
        content = resp.get('result', {}).get('content', [])
        if content and 'text' in content[0]:
            result_text = content[0]['text']
    t.snap('response', result_text)
    if result_text and 'sent 1 keys' in result_text and '2 skipped' in result_text:
        t.ok('send_keys: 1 delivered, 2 skipped reported separately (BUG-B)')
    else:
        t.fail(f'expected "sent 1 keys, 2 skipped", got: {result_text}')
    results.append(t)

    # Path traversal xfail (test 36)
    t = TestResult('screenshot_path_traversal_xfail')
    resp = mcp.call_raw('teru_screenshot', {'path': '/../../../etc/passwd'})
    if resp and 'error' in resp:
        error = resp['error']
        code = error.get('code')
        msg = error.get('message', '')
        if code == -32603 and 'renderer' in msg.lower():
            t.ok('screenshot path_traversal → -32603 "No renderer" (daemon mode)')
        elif code == -32602 and 'Invalid path' in msg:
            t.ok('screenshot path_traversal → -32602 (renderer present)')
        else:
            t.fail(f'unexpected: code={code}, msg={msg}')
    else:
        t.fail('no error response for path_traversal')
    results.append(t)

    return results


def _resolve_teru_bin():
    """argv[1] (if a real path) → zig-out/bin/teru → ~/.local/bin/teru → PATH."""
    if len(sys.argv) > 1 and os.path.exists(sys.argv[1]):
        return sys.argv[1]
    for cand in ('zig-out/bin/teru', os.path.expanduser('~/.local/bin/teru')):
        if os.path.exists(cand):
            return cand
    return 'teru'


def launch_daemon(teru_bin):
    """Launch a throwaway headless `teru --daemon` and return (proc, sock).

    Hermetic by design: the socket is keyed to OUR proc.pid, so the tests
    never connect to (and never mutate) a real interactive daemon. The
    default pane is a fresh `shell`."""
    runtime = os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
    proc = subprocess.Popen(
        [teru_bin, '--daemon', 'errpaths_e2e'],
        stdout=open('/tmp/teru-errpaths.log', 'w'),
        stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        start_new_session=True)
    sock = os.path.join(runtime, f'teru-mcp-{proc.pid}.sock')
    for _ in range(50):
        time.sleep(0.2)
        if os.path.exists(sock):
            time.sleep(0.3)  # let the default pane's shell settle
            return proc, sock
    proc.kill()
    raise RuntimeError(f'teru --daemon did not create {sock} '
                       '(see /tmp/teru-errpaths.log)')


def main():
    teru_bin = _resolve_teru_bin()
    if '/' in teru_bin and not os.path.exists(teru_bin):
        print(f'teru binary not found: {teru_bin}', file=sys.stderr)
        sys.exit(2)

    print('teru MCP error-path tests (hermetic — own throwaway daemon)')
    proc, sock_path = launch_daemon(teru_bin)
    print(f'daemon pid {proc.pid}  socket {sock_path}')
    print()

    mcp = TeruMCP(sock_path)
    try:
        results = run_error_tests(mcp)
    finally:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=4)
        except subprocess.TimeoutExpired:
            proc.kill()

    print()
    print('=' * 70)
    print('  teru MCP Error-Path Test Report')
    print('=' * 70)

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
    print('=' * 70)
    print(f'  {passed} passed, {failed} failed, {len(results)} total')
    print('=' * 70)
    print()
    if failed == 0:
        print('VERDICT: all error-path tests passed')
        sys.exit(0)
    else:
        print(f'VERDICT: {failed} test(s) failed')
        sys.exit(1)


if __name__ == '__main__':
    main()
