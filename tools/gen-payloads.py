#!/usr/bin/env python3
"""
Run each vtebench benchmark script inside a forced-size PTY and capture
its stdout to a file. The captured file is the exact byte stream a
terminal would receive; our Zig bench then feeds it through teru's
VtParser.
"""
import os
import pty
import select
import subprocess
import sys
from pathlib import Path


VTEBENCH = Path(__file__).parent / "bench-bin/vtebench/benchmarks"
OUT_DIR = Path(__file__).parent / "bench-payloads"
OUT_DIR.mkdir(exist_ok=True)

# Fixed terminal dimensions so payloads are reproducible across runs and
# terminals; these match the default vtebench used inside alacritty.
COLS, ROWS = 200, 50


def run_in_pty(script: Path, out: Path) -> int:
    """Execute `script` with a PTY sized (COLS, ROWS). Returns bytes written."""
    pid, fd = pty.fork()
    if pid == 0:
        # Child: set window size, exec the script.
        import fcntl, struct, termios
        # struct winsize { rows, cols, xpixel, ypixel }
        ws = struct.pack("HHHH", ROWS, COLS, 0, 0)
        fcntl.ioctl(sys.stdout.fileno(), termios.TIOCSWINSZ, ws)
        os.execvp("/bin/sh", ["/bin/sh", str(script)])
    total = 0
    with open(out, "wb") as f:
        while True:
            try:
                r, _, _ = select.select([fd], [], [], 30)
                if not r:
                    break
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                f.write(chunk)
                total += len(chunk)
            except KeyboardInterrupt:
                break
    os.waitpid(pid, 0)
    return total


def main():
    if not VTEBENCH.exists():
        print(f"vtebench benchmarks not found at {VTEBENCH}", file=sys.stderr)
        sys.exit(1)

    targets = sorted(d for d in VTEBENCH.iterdir() if (d / "benchmark").exists())

    print(f"Generating payloads @ {COLS}x{ROWS}:")
    for bench in targets:
        name = bench.name
        out = OUT_DIR / f"{name}.bin"
        if out.exists() and out.stat().st_size > 0:
            print(f"  {name:40s} cached ({out.stat().st_size:>10,} bytes)")
            continue
        n = run_in_pty(bench / "benchmark", out)
        print(f"  {name:40s} {n:>10,} bytes")


if __name__ == "__main__":
    main()
