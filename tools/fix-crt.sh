#!/usr/bin/env sh
# fix-crt.sh — engage the stripped-CRT workaround ONLY if this toolchain needs it.
#
# History: GCC 15 started emitting .sframe sections into the glibc CRT objects
# (crt1.o, Scrt1.o, gcrt1.o), and Zig's linker could not resolve the
# R_X86_64_PC64 relocations inside them. The workaround: objcopy the .sframe
# section out into .cache/crt-fix-all/, and point `zig build --libc` at a
# libc.txt whose crt_dir is that directory.
#
# That linker gap is FIXED upstream (verified on zig 0.17.0-dev.1946: linking
# against the unstripped system Scrt1.o succeeds under both LLD and zig's
# self-hosted ELF linker, and the .sframe section even survives into the output).
# The system CRTs still carry .sframe and always will, so the old trigger —
# "does readelf see a .sframe section?" — is a symptom that can never expire.
# It kept the workaround permanently armed on the critical path of the only way
# this machine starts a desktop.
#
# 2026-09-01: that cost a login. zig 0.17.0-dev.1946 (commit c269a604b660,
# "fix: crtbegin/crtend not being linked on linux", #32064) moved `.linux` into
# LibCInstallation.resolveCrtPaths' gcc_dir-resolving prong, so a libc.txt with
# an empty gcc_dir — which this script used to hand-write — now dies at link
# time with the misleading `error: libc installation is missing crt directory`.
# Every Makefile target funnels through --libc, so `startt` could not build,
# could not install, and dropped the user at a bare TTY with no desktop.
#
# Three rules came out of that, and this script now follows all three:
#   1. TRIGGER ON CAPABILITY, NOT SYMPTOM. Ask "does a bare `zig build-exe -lc`
#      actually fail?", not "does .sframe exist?". The workaround now retires
#      itself the moment the toolchain stops needing it.
#   2. NEVER HAND-WRITE libc.txt. LibCInstallation.parse() requires every field
#      it knows about, so a hand-rolled heredoc breaks the day zig adds one.
#      Generate it with `zig libc` (the exact inverse of parse()) and override
#      only crt_dir.
#   3. VALIDATE BEFORE PUBLISHING. The Makefile passes --libc whenever this file
#      merely EXISTS. So prove it links before leaving it there, and delete it
#      if it does not — degrading to a bare `zig build`, which works.
#
# Usage:
#   ./tools/fix-crt.sh              # decide, and set up (or tear down) the fix
#   ./tools/fix-crt.sh --check      # exit 1 if the build is NOT currently sound
#   ./tools/fix-crt.sh --clean      # remove the cache entirely
set -eu
# Deliberately no `pipefail`: the `ls | sort | tail` fallback below relies on
# the last command's status, and this script sits between the user and a login
# shell — nothing in here may fail fatally.

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/build.zig" ] || { echo "fix-crt: $REPO is not the teru repo root" >&2; exit 1; }

FIX_DIR="$REPO/.cache/crt-fix-all"
LIBC="$FIX_DIR/libc.txt"
STAMP="$FIX_DIR/.stamp"

ZIG="${ZIG:-zig}"

# ── Toolchain identity ────────────────────────────────────────────────
# The old fast path compared one mtime (/usr/lib/crt1.o) and so was blind to a
# gcc upgrade, a zig upgrade, a libc.txt schema change, and edits to this very
# script — every one of which changes the right answer. Stamp all of them.
toolchain_id() {
    {
        "$ZIG" version 2>/dev/null || echo "no-zig"
        # The PATH alone is stable across gcc point releases (Arch's dir is
        # ".../gcc/x86_64-pc-linux-gnu/16" for all of 16.x), so hash the object
        # itself — that is what actually changes.
        _cb="$(cc -print-file-name=crtbeginS.o 2>/dev/null || echo)"
        echo "${_cb:-no-cc}"
        case "$_cb" in /*) cat "$_cb" 2>/dev/null ;; esac
        cat "$0" 2>/dev/null
        cat /usr/lib/crt1.o /usr/lib/Scrt1.o /usr/lib/crti.o 2>/dev/null
        echo "$FIX_DIR"
    } | sha256sum 2>/dev/null | cut -d' ' -f1
}

# ── Probes ────────────────────────────────────────────────────────────
# 0 = a hello-world links, 1 = it does not, 2 = the probe could not be RUN.
# The 0/2 distinction matters: scratch space being unwritable (read-only
# checkout, full disk) is not evidence that the toolchain needs a CRT
# workaround, and treating it as such used to announce a false diagnosis and
# then die in objcopy. The scratch dir is per-process and OUTSIDE $FIX_DIR so
# two concurrent `make`s cannot delete each other's probe mid-link.
probe_link() {
    d="$(mktemp -d 2>/dev/null)" || return 2
    printf 'pub fn main() void {}\n' > "$d/t.zig" 2>/dev/null || { rm -rf "$d"; return 2; }
    if [ $# -ge 1 ]; then
        "$ZIG" build-exe -lc --libc "$1" -femit-bin="$d/t" "$d/t.zig" \
            --cache-dir "$d/cache" >/dev/null 2>&1
    else
        "$ZIG" build-exe -lc -femit-bin="$d/t" "$d/t.zig" \
            --cache-dir "$d/cache" >/dev/null 2>&1
    fi
    rc=$?; rm -rf "$d"; return $rc
}

# Drop the flag file so the Makefile's `[ -f libc.txt ]` gate expands empty and
# every target falls back to a bare `zig build`.
# Cache writes are ADVISORY: a read-only checkout must cost us the cache, not
# the user's build. The group redirect is what suppresses the shell's own
# "Permission denied" — `printf ... > f 2>/dev/null || true` still prints it.
disarm()     { rm -f "$LIBC" 2>/dev/null || true; }
write_stamp() { { printf '%s %s\n' "$WANT" "$1" > "$STAMP"; } 2>/dev/null || true; }

case "${1:-}" in
    --check)
        # Answer the question that actually matters: will `make` link right now?
        CRC=0
        if [ -f "$LIBC" ]; then
            probe_link "$LIBC" || CRC=$?
            [ "$CRC" -ne 1 ] || {
                echo "fix-crt: cached libc.txt is rejected by $("$ZIG" version 2>/dev/null)" >&2
                exit 1
            }
        else
            probe_link || CRC=$?
            [ "$CRC" -ne 1 ] || { echo "fix-crt: bare 'zig build-exe -lc' does not link" >&2; exit 1; }
        fi
        [ "$CRC" -ne 2 ] || echo "fix-crt: could not run the link probe; build soundness unverified" >&2
        exit 0
        ;;
    --clean)
        rm -rf "$FIX_DIR"
        echo "Removed $FIX_DIR"
        exit 0
        ;;
    "") ;;
    *) echo "usage: $0 [--check|--clean]" >&2; exit 2 ;;
esac

mkdir -p "$FIX_DIR" 2>/dev/null || true

# Serialize the decision. `make -j`, a rebuild in two teru panes, or the Mod+Q
# recompile chord racing a terminal build must not probe concurrently: a torn
# probe reads as "this toolchain needs the workaround" and gets cached forever.
# The loser re-reads the stamp the winner just wrote and takes the fast path.
# Never fatal (a failed redirect in `exec` would kill this shell outright) and
# never unbounded (a wedged holder must not hang a login).
# The writability test runs in a SUBSHELL: `:` is a POSIX special builtin, and a
# redirection error on one exits the shell outright — `2>/dev/null` suppresses
# the message but not the exit. On a read-only checkout that killed the script
# here, one line after the comment promising it could not.
if ( : > "$FIX_DIR/.lock" ) 2>/dev/null; then
    exec 9>"$FIX_DIR/.lock"
    flock -w 60 9 2>/dev/null || true
fi

# ── Fast path ─────────────────────────────────────────────────────────
# ~5ms when nothing in the toolchain moved. The stamp records the DECISION too,
# so the "no workaround needed" answer is cached just like the "fix built" one
# (otherwise the link probe would run on every single make target).
WANT="$(toolchain_id)"
# An empty hash (no sha256sum) would match every stamp forever and freeze the
# decision — treat it as "always re-decide" instead.
if [ -n "$WANT" ] && [ -f "$STAMP" ]; then
    HAVE="$(cut -d' ' -f1 "$STAMP" 2>/dev/null || echo)"
    DECIDED="$(cut -d' ' -f2 "$STAMP" 2>/dev/null || echo)"
    if [ "$HAVE" = "$WANT" ]; then
        case "$DECIDED" in
            nofix) [ -f "$LIBC" ] || exit 0 ;;   # still disarmed → nothing to do
            # `-s`, not `-f`: a 0-byte libc.txt is armed as far as the
            # Makefile is concerned and fails every target with a ParseError.
            fix)   if [ -s "$LIBC" ]; then exit 0; fi ;;  # still armed → nothing to do
        esac
    fi
fi

# ── Decide ────────────────────────────────────────────────────────────
PROBE_RC=0; probe_link || PROBE_RC=$?
if [ "$PROBE_RC" -eq 2 ]; then
    echo "fix-crt: could not run the link probe (no writable scratch space?) —" >&2
    echo "         leaving the build configuration exactly as it is." >&2
    exit 0
fi
if [ "$PROBE_RC" -eq 0 ]; then
    # The system CRT links fine as-is — this is the case on every current
    # toolchain. Tear the workaround down rather than leaving a stale libc.txt
    # for the Makefile to pick up.
    if [ -f "$LIBC" ]; then
        echo "fix-crt: system CRT links cleanly — retiring the .sframe workaround"
        disarm
    fi
    write_stamp nofix
    exit 0
fi

echo "fix-crt: bare 'zig build-exe -lc' fails — building stripped CRT copies in $FIX_DIR"

for t in readelf objcopy; do
    command -v "$t" >/dev/null 2>&1 || {
        echo "fix-crt: $t not found (install binutils) — cannot build the workaround." >&2
        echo "         Leaving the build unpatched; 'zig build' may fail." >&2
        # Deliberately no stamp: this is a broken state the user must fix, and
        # caching it as `nofix` would print this warning exactly once, then go
        # silent for every later build.
        disarm; exit 0
    }
done

# Strip .sframe from the glibc CRT objects that carry it.
for f in crt1.o Scrt1.o gcrt1.o; do
    [ -f "/usr/lib/$f" ] || continue
    if readelf -S "/usr/lib/$f" 2>/dev/null | grep -q sframe; then
        objcopy --remove-section=.sframe "/usr/lib/$f" "$FIX_DIR/$f"
        echo "  stripped .sframe from $f"
    else
        cp "/usr/lib/$f" "$FIX_DIR/$f"
    fi
done
for f in crti.o crtn.o Mcrt1.o grcrt1.o; do
    # `&&` here would make a false test the loop's exit status on the last
    # iteration, and `set -e` would kill the script one step before a desktop.
    if [ -f "/usr/lib/$f" ]; then cp "/usr/lib/$f" "$FIX_DIR/$f"; fi
done

# GCC's crtbegin/crtend are read from gcc_dir, not crt_dir, so they are NOT
# copied here any more — the old glob hardcoded the x86_64-pc-linux-gnu triple
# and sorted lexically, and left GCC-15 objects sitting next to a GCC-16 system.

# Zig resolves libc.so / libm.so relative to crt_dir when --libc is used, so the
# system libraries have to be reachable from here. Prune dead links first: soname
# bumps had rotted 2634 of 7226 entries. `${f##*/}` instead of basename: one fork
# per file cost ~3.5s.
find "$FIX_DIR" -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null || true
for f in /usr/lib/lib*.so* /usr/lib/lib*.a; do
    [ -e "$f" ] || continue            # unmatched glob stays literal in POSIX sh
    name=${f##*/}
    [ -e "$FIX_DIR/$name" ] || ln -sf "$f" "$FIX_DIR/$name"
done

# Generate libc.txt with zig itself and override only crt_dir. `zig libc` is
# render(), the exact inverse of parse(), so every field — including ones zig
# has yet to add — is correct by construction. Never hand-roll this file.
# Written to a per-process temp and renamed into place: `sed > "$LIBC"` truncates
# the published file BEFORE it writes, so any failure there left a 0-byte
# libc.txt that the Makefile still treats as armed — every target then dies with
# a ParseError. A rename is atomic, so the published file is always whole.
# crt_dir is substituted with awk, not sed: $FIX_DIR is the repo path and would
# be interpreted as a sed replacement (`&`, `\1`, and the `|` delimiter itself).
TMP="$FIX_DIR/libc.txt.$$"
if "$ZIG" libc > "$TMP" 2>/dev/null; then
    CRT_DIR="$FIX_DIR" awk '
        /^crt_dir=/ { print "crt_dir=" ENVIRON["CRT_DIR"]; next }
        { print }
    ' "$TMP" > "$TMP.2" && mv -f "$TMP.2" "$LIBC"
    rm -f "$TMP" "$TMP.2"
else
    rm -f "$TMP"
    # `zig libc` needs to spawn a C compiler; if it cannot, derive the fields.
    echo "fix-crt: 'zig libc' failed — falling back to a derived libc.txt" >&2
    gcc_dir="$(cc -print-file-name=crtbeginS.o 2>/dev/null || echo)"
    case "$gcc_dir" in
        /*) gcc_dir="$(dirname "$gcc_dir")" ;;
        *)  gcc_dir="" ;;   # cc echoes the bare name back when it cannot resolve it
    esac
    if [ -z "$gcc_dir" ] || [ ! -f "$gcc_dir/crtbegin.o" ]; then
        gcc_dir="$(ls -1d /usr/lib/gcc/*/*/crtbegin.o 2>/dev/null | sort -V | tail -1)"
        [ -n "$gcc_dir" ] && gcc_dir="$(dirname "$gcc_dir")"
    fi
    cat > "$TMP.2" << LIBCEOF
include_dir=/usr/include
sys_include_dir=/usr/include
crt_dir=$FIX_DIR
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=$gcc_dir
LIBCEOF
    mv -f "$TMP.2" "$LIBC"
fi

# ── Validate before publishing ────────────────────────────────────────
# The single change that makes this class of failure non-fatal forever. The
# Makefile trusts this file's existence; do not leave one here that cannot link.
if probe_link "$LIBC"; then
    write_stamp fix
    echo ""
    echo "CRT fix ready at $FIX_DIR"
    echo "Build with: zig build --libc \"$LIBC\""
else
    echo "fix-crt: the generated libc.txt is rejected by $("$ZIG" version 2>/dev/null) —" >&2
    echo "         disabling the workaround and building without --libc instead." >&2
    disarm
    write_stamp nofix
fi
exit 0
