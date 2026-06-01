#!/usr/bin/env python3
"""mcp-probe — drive a running teru / teruwm MCP server from the shell.

The compositor (teruwm) and terminal (teru) each expose an MCP server over a
Unix socket in $XDG_RUNTIME_DIR. This sends one JSON-RPC tools/call (HTTP-over-
unix-socket framing) and prints the response — handy for debugging by hand or
from an agent. Pair it with `TERU_LOG=debug` on the server to see the matching
`(mcp) →`/`←` trace in the server's stderr.

Usage:
  tools/mcp-probe.py <tool> [json-args]           # auto-discover teruwm socket
  tools/mcp-probe.py --teru <tool> [json-args]    # auto-discover teru socket
  tools/mcp-probe.py --sock <path> <tool> [args]  # explicit socket
  tools/mcp-probe.py --list [--teru]              # tools/list

Examples:
  tools/mcp-probe.py teruwm_list_windows
  tools/mcp-probe.py teruwm_spawn_terminal
  tools/mcp-probe.py teruwm_type '{"text":"echo hi"}'
  tools/mcp-probe.py --teru teru_list_panes
"""
import glob
import json
import os
import socket
import sys

PATTERNS = {"teruwm": "teruwm-mcp-*.sock", "teru": "teru-mcp-*.sock"}


def discover(kind):
    rt = os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid())
    # exclude the separate event-push sockets (…-events-…)
    socks = sorted(s for s in glob.glob(os.path.join(rt, PATTERNS[kind])) if "events" not in s)
    return socks[0] if socks else None


def rpc(sock_path, payload):
    body = json.dumps(payload).encode()
    req = (b"POST / HTTP/1.1\r\nHost: localhost\r\n"
           b"Content-Type: application/json\r\n"
           b"Content-Length: " + str(len(body)).encode() +
           b"\r\nConnection: close\r\n\r\n" + body)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    s.connect(sock_path)
    s.sendall(req)
    resp = b""
    while True:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        resp += chunk
    s.close()
    _, _, payload_bytes = resp.partition(b"\r\n\r\n")
    return json.loads(payload_bytes)


def main(argv):
    kind, sock, want_list, rest = "teruwm", None, False, []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--teru":
            kind = "teru"
        elif a == "--teruwm":
            kind = "teruwm"
        elif a == "--list":
            want_list = True
        elif a == "--sock":
            i += 1
            sock = argv[i]
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            rest.append(a)
        i += 1

    if sock is None:
        sock = discover(kind)
        if sock is None:
            print("mcp-probe: no %s MCP socket in $XDG_RUNTIME_DIR "
                  "(is it running?)" % kind, file=sys.stderr)
            return 2

    if want_list:
        print(json.dumps(rpc(sock, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}), indent=2))
        return 0
    if not rest:
        print(__doc__)
        return 2

    tool = rest[0]
    args = json.loads(rest[1]) if len(rest) > 1 else {}
    doc = rpc(sock, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                     "params": {"name": tool, "arguments": args}})
    print(json.dumps(doc, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
