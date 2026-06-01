#!/usr/bin/env python3
"""Set up teru for screenshots.

Creates a photogenic multi-pane layout for capturing hero screenshots.
After running, take a screenshot with your system tool (e.g. flameshot, grim).

Usage: python3 tests/screenshot_setup.py [socket_path]
"""

import socket
import json
import time
import sys
import os
import glob
import re


class TeruMCP:
    def __init__(self, sock_path):
        self.sock_path = sock_path

    def call(self, tool, args=None, timeout=5.0):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(self.sock_path)
        msg = json.dumps({
            'jsonrpc': '2.0', 'method': 'tools/call',
            'params': {'name': tool, 'arguments': args or {}}, 'id': 1
        })
        req = f'POST / HTTP/1.1\r\nContent-Length: {len(msg)}\r\nContent-Type: application/json\r\n\r\n{msg}'
        s.sendall(req.encode())
        chunks = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                chunk = s.recv(65536)
                if not chunk: break
                chunks.append(chunk)
                raw = b''.join(chunks)
                if b'\r\n\r\n' in raw:
                    h, b = raw.split(b'\r\n\r\n', 1)
                    m = re.search(rb'Content-Length:\s*(\d+)', h)
                    if m and len(b) >= int(m.group(1)): break
            except socket.timeout: break
        s.close()
        raw = b''.join(chunks)
        if b'\r\n\r\n' not in raw: return None
        body = raw.split(b'\r\n\r\n', 1)[1].decode('utf-8', errors='replace')
        try:
            resp = json.loads(body)
            content = resp.get('result', {}).get('content', [])
            if content and 'text' in content[0]: return content[0]['text']
        except: pass
        return None

    def wait_prompt(self, pane_id, timeout=5):
        start = time.time()
        while time.time() - start < timeout:
            text = self.call('teru_wait_for', {'pane_id': pane_id, 'pattern': '$', 'lines': 5})
            if text and 'true' in text.lower(): return True
            time.sleep(0.3)
        return False


def find_socket():
    socks = sorted(glob.glob('/run/user/*/teru-mcp-*.sock'), key=os.path.getmtime, reverse=True)
    for s in socks:
        try:
            t = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            t.settimeout(1); t.connect(s); t.close(); return s
        except: continue
    return None


def main():
    sock_path = sys.argv[1] if len(sys.argv) > 1 else find_socket()
    if not sock_path:
        print('ERROR: No teru MCP socket found'); sys.exit(1)

    mcp = TeruMCP(sock_path)
    print(f'Connected to {sock_path}')

    scene = sys.argv[2] if len(sys.argv) > 2 else 'hero'

    if scene == 'hero':
        print('Setting up hero screenshot (master-stack, 3 panes)...')
        mcp.call('teru_set_layout', {'layout': 'master-stack', 'workspace': 0})

        # Create 2 more panes (3 total with master-stack)
        p2 = mcp.call('teru_create_pane', {'direction': 'vertical'})
        p3 = mcp.call('teru_create_pane', {'direction': 'vertical'})
        time.sleep(2)

        # Pane 1: show project tree
        mcp.call('teru_send_input', {'pane_id': 1, 'text': 'ls --color=auto -la src/\n'})
        time.sleep(1)

        # Pane 2: show a zig file
        if p2:
            pid2 = int(p2)
            mcp.wait_prompt(pid2)
            mcp.call('teru_send_input', {'pane_id': pid2, 'text': 'head -40 src/core/VtParser.zig\n'})

        # Pane 3: show test output
        if p3:
            pid3 = int(p3)
            mcp.wait_prompt(pid3)
            mcp.call('teru_send_input', {'pane_id': pid3, 'text': 'echo "teru 照 -- AI-first terminal emulator" && echo "478+ tests, 1.4MB binary, 8 layouts" && echo "" && zig build test 2>&1 | tail -5\n'})

        print('Ready! Take screenshot with flameshot/grim/scrot.')
        print('  flameshot gui')
        print('  grim -g "$(slurp)" docs/assets/hero.png')

    elif scene == 'layouts':
        print('Cycling through layouts for GIF capture...')
        # Create 4 panes
        for i in range(3):
            mcp.call('teru_create_pane')
        time.sleep(1)

        layouts = ['master-stack', 'grid', 'monocle', 'dishes', 'spiral', 'three-col', 'columns', 'accordion']
        for layout in layouts:
            mcp.call('teru_set_layout', {'layout': layout, 'workspace': 0})
            print(f'  Layout: {layout} -- screenshot now')
            time.sleep(2)

        print('Done! Compose screenshots into GIF with:')
        print('  convert -delay 100 -loop 0 docs/assets/layout-*.png docs/assets/layouts.gif')

    elif scene == 'ai':
        print('Setting up AI agent demo...')
        mcp.call('teru_set_layout', {'layout': 'grid', 'workspace': 0})

        # Create panes simulating agent work
        p2 = mcp.call('teru_create_pane')
        p3 = mcp.call('teru_create_pane')
        p4 = mcp.call('teru_create_pane')
        time.sleep(2)

        if p2:
            pid2 = int(p2)
            mcp.wait_prompt(pid2)
            mcp.call('teru_send_input', {'pane_id': pid2, 'text': "printf '\\e]9999;agent:start;name=backend-dev;group=team\\a' && echo 'Agent: backend-dev (running)'\n"})

        if p3:
            pid3 = int(p3)
            mcp.wait_prompt(pid3)
            mcp.call('teru_send_input', {'pane_id': pid3, 'text': "printf '\\e]9999;agent:start;name=frontend-dev;group=team\\a' && echo 'Agent: frontend-dev (running)'\n"})

        if p4:
            pid4 = int(p4)
            mcp.wait_prompt(pid4)
            mcp.call('teru_send_input', {'pane_id': pid4, 'text': "printf '\\e]9999;agent:start;name=test-runner;group=team\\a' && echo 'Agent: test-runner (running)'\n"})

        print('Ready! Take screenshot showing agent panes.')

    else:
        print(f'Unknown scene: {scene}')
        print('Available: hero, layouts, ai')
        sys.exit(1)


if __name__ == '__main__':
    main()
