#!/bin/bash
# zig-lib-fix.sh — emit the `--zig-lib-dir <patched>` build flag when the
# system Zig still carries the upstream termios typo, else emit nothing.
#
# Background: zig 0.17.0-dev (dev.420 onward) ships an stdlib typo in
# std/os/linux.zig — `arch_bits == .alpha` should be `native_arch == .alpha`
# — that breaks the build of any termios user (i.e. teru/teruwm) on x86_64.
# This script keeps a one-line-patched copy of the *current* system std and
# points the build at it. It is version-agnostic and self-healing:
#   • greps for the bug instead of assuming a line number,
#   • regenerates the patched copy whenever the system std is newer
#     (a zig upgrade), so it can never go stale against the active compiler,
#   • removes the patched copy once upstream zig is fixed (then prints nothing).
#
# Contract: prints ONLY the flag (or empty) to stdout — all status goes to
# stderr — so callers can use it directly: `zig build ... $(./tools/zig-lib-fix.sh)`.
set -euo pipefail

PATCHED_LIB="${TERU_ZIG_PATCHED_LIB:-$HOME/.cache/teru-zig-lib-patched}"

# Locate the system std (ZON `.lib_dir = "…"`; fall back to the usual path).
SYS_LIB="$(zig env 2>/dev/null | sed -n 's/.*\.lib_dir = "\([^"]*\)".*/\1/p' | head -1)"
[ -z "$SYS_LIB" ] && SYS_LIB="/usr/lib/zig"
SYS_LINUX="$SYS_LIB/std/os/linux.zig"

# No bug (fixed zig, or can't read std) → nothing to do.
if ! grep -q 'arch_bits == .alpha' "$SYS_LINUX" 2>/dev/null; then
    if [ -d "$PATCHED_LIB" ]; then
        echo "zig-lib-fix: system zig is fixed — removing stale patched lib dir" >&2
        rm -rf "$PATCHED_LIB"
    fi
    exit 0
fi

# Bug present — (re)build the patched lib dir if missing or older than system std.
if [ ! -f "$PATCHED_LIB/std/os/linux.zig" ] || [ "$SYS_LINUX" -nt "$PATCHED_LIB/std/os/linux.zig" ]; then
    echo "zig-lib-fix: building patched zig lib dir (termios workaround) at $PATCHED_LIB" >&2
    rm -rf "$PATCHED_LIB"; mkdir -p "$PATCHED_LIB"
    # Symlink every top-level entry, then replace `std` with a real, patched copy.
    for e in "$SYS_LIB"/*; do ln -s "$e" "$PATCHED_LIB/$(basename "$e")"; done
    rm -f "$PATCHED_LIB/std"; cp -r "$SYS_LIB/std" "$PATCHED_LIB/std"
    # Patch the exact buggy comparison wherever it sits (no hardcoded line).
    sed -i 's/arch_bits == .alpha/native_arch == .alpha/' "$PATCHED_LIB/std/os/linux.zig"
fi

echo "zig-lib-fix: system zig has the termios typo → building with patched std" >&2
printf -- '--zig-lib-dir %s' "$PATCHED_LIB"
