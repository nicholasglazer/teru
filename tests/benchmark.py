#!/usr/bin/env python3
"""teru benchmark suite.

Measures real performance via MCP against a running teru daemon.
Run: python3 tests/benchmark.py [socket_path]
"""

import socket
import json
import time
import sys
import os
import glob
import re
import statistics


class TeruMCP:
    def __init__(self, sock_path):
        self.sock_path = sock_path

    def call(self, tool, args=None, timeout=5.0):
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
                    if cl_match and len(body_bytes) >= int(cl_match.group(1)):
                        break
            except socket.timeout:
                break
        s.close()
        raw = b''.join(chunks)
        if b'\r\n\r\n' not in raw:
            return None, 'no response'
        body = raw.split(b'\r\n\r\n', 1)[1].decode('utf-8', errors='replace')
        try:
            resp = json.loads(body)
            if 'error' in resp:
                return None, resp['error'].get('message', 'error')
            content = resp.get('result', {}).get('content', [])
            if content and 'text' in content[0]:
                return content[0]['text'], None
            return '', None
        except Exception as e:
            return None, str(e)

    def wait_for(self, pane_id, pattern, timeout=10):
        start = time.time()
        while time.time() - start < timeout:
            text, _ = self.call('teru_wait_for', {'pane_id': pane_id, 'pattern': pattern, 'lines': 30})
            if text and 'true' in text.lower():
                return True
            time.sleep(0.3)
        return False


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


def bench_mcp_latency(mcp):
    """Measure MCP round-trip latency."""
    times = []
    for _ in range(50):
        start = time.perf_counter()
        mcp.call('teru_list_panes')
        elapsed = (time.perf_counter() - start) * 1000
        times.append(elapsed)
    return times


def bench_pane_create_close(mcp):
    """Measure pane create + close cycle time."""
    times = []
    for _ in range(10):
        start = time.perf_counter()
        text, _ = mcp.call('teru_create_pane')
        if text:
            pid = int(text)
            mcp.call('teru_close_pane', {'pane_id': pid})
        elapsed = (time.perf_counter() - start) * 1000
        times.append(elapsed)
    return times


def bench_throughput(mcp, pane_id):
    """Measure PTY throughput by sending large output and timing read."""
    # Generate 10000 lines of output
    mcp.call('teru_send_input', {
        'pane_id': pane_id,
        'text': 'seq 1 10000\n'
    })
    time.sleep(3)

    # Time reading output
    times = []
    for _ in range(20):
        start = time.perf_counter()
        mcp.call('teru_read_output', {'pane_id': pane_id, 'lines': 50})
        elapsed = (time.perf_counter() - start) * 1000
        times.append(elapsed)
    return times


def bench_state_query(mcp, pane_id):
    """Measure state query latency."""
    times = []
    for _ in range(50):
        start = time.perf_counter()
        mcp.call('teru_get_state', {'pane_id': pane_id})
        elapsed = (time.perf_counter() - start) * 1000
        times.append(elapsed)
    return times


def bench_workspace_switch(mcp):
    """Measure workspace switch speed."""
    times = []
    for i in range(20):
        ws = i % 3
        start = time.perf_counter()
        mcp.call('teru_switch_workspace', {'workspace': ws})
        elapsed = (time.perf_counter() - start) * 1000
        times.append(elapsed)
    mcp.call('teru_switch_workspace', {'workspace': 0})
    return times


def report(name, times, unit='ms'):
    med = statistics.median(times)
    p95 = sorted(times)[int(len(times) * 0.95)]
    mn = min(times)
    mx = max(times)
    print(f'  {name:30s}  median={med:7.2f}{unit}  p95={p95:7.2f}{unit}  min={mn:7.2f}{unit}  max={mx:7.2f}{unit}  n={len(times)}')


def main():
    sock_path = sys.argv[1] if len(sys.argv) > 1 else find_socket()
    if not sock_path:
        print('ERROR: No teru MCP socket found')
        sys.exit(1)

    print(f'Socket: {sock_path}')
    mcp = TeruMCP(sock_path)

    # Get initial state
    panes_text, _ = mcp.call('teru_list_panes')
    panes = json.loads(panes_text) if panes_text else []
    pane_id = panes[0]['id'] if panes else 1

    print()
    print('=' * 80)
    print('  teru Benchmark Results')
    print('=' * 80)
    print()

    # MCP latency
    times = bench_mcp_latency(mcp)
    report('MCP round-trip (list_panes)', times)

    # State query
    times = bench_state_query(mcp, pane_id)
    report('State query (get_state)', times)

    # Workspace switch
    times = bench_workspace_switch(mcp)
    report('Workspace switch', times)

    # Pane lifecycle
    times = bench_pane_create_close(mcp)
    report('Pane create+close cycle', times)

    # Read output
    times = bench_throughput(mcp, pane_id)
    report('Read output (50 lines)', times)

    print()
    print('=' * 80)
    print()


if __name__ == '__main__':
    main()
