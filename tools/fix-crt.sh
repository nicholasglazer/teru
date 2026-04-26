#!/usr/bin/env sh
# Fix CRT .sframe sections for GCC 15+ (Zig linker doesn't handle R_X86_64_PC64 in .sframe)
#
# Usage:
#   ./tools/fix-crt.sh              # check + setup stripped CRT files
#   ./tools/fix-crt.sh --check      # check only, exit 1 if fix needed
#   ./tools/fix-crt.sh --clean      # remove cached CRT files

set -eu

FIX_DIR="$(cd "$(dirname "$0")/.." && pwd)/.cache/crt-fix-all"
NEED_FIX=false

# Check which CRT files have .sframe sections
check_sframe() {
    NEED_FIX=false
    for f in crt1.o Scrt1.o gcrt1.o; do
        if [ -f "/usr/lib/$f" ] && readelf -S "/usr/lib/$f" 2>/dev/null | grep -q sframe; then
            NEED_FIX=true
            break
        fi
    done
    readonly NEED_FIX
}

if [ "${1:-}" = "--check" ]; then
    check_sframe
    $NEED_FIX && echo "CRT .sframe fix needed" && exit 1
    exit 0
fi

if [ "${1:-}" = "--clean" ]; then
    rm -rf "$FIX_DIR"
    echo "Removed $FIX_DIR"
    exit 0
fi

check_sframe

if ! $NEED_FIX; then
    echo "No .sframe issue detected — system CRT files are fine."
    exit 0
fi

echo "Detected .sframe sections in system CRT files — creating stripped copies..."

mkdir -p "$FIX_DIR"

# Strip .sframe from affected CRT files
for f in crt1.o Scrt1.o gcrt1.o; do
    if readelf -S "/usr/lib/$f" 2>/dev/null | grep -q sframe; then
        objcopy --remove-section=.sframe "/usr/lib/$f" "$FIX_DIR/$f"
        echo "  stripped .sframe from $f"
    else
        cp "/usr/lib/$f" "$FIX_DIR/$f"
    fi
done

# Copy unaffected CRT files
for f in crti.o crtn.o Mcrt1.o grcrt1.o; do
    [ -f "/usr/lib/$f" ] && cp "/usr/lib/$f" "$FIX_DIR/$f"
done

# Copy GCC CRT files (used by some targets)
for f in crtbegin.o crtbeginS.o crtend.o crtendS.o crtbeginT.o; do
    src="/usr/lib/gcc/x86_64-pc-linux-gnu/15.2.1/$f"
    [ -f "$src" ] && cp "$src" "$FIX_DIR/$f"
done

# Symlink system libraries into crt_fix_dir — Zig's linker resolves libc.so,
# libm.so etc. relative to crt_dir when --libc is used.
for f in /usr/lib/lib*.so* /usr/lib/lib*.a; do
    name=$(basename "$f")
    [ -f "$FIX_DIR/$name" ] || ln -sf "$f" "$FIX_DIR/$name"
done

# Write libc.txt pointing to our fixed CRT dir
cat > "$FIX_DIR/libc.txt" << LIBCEOF
include_dir=/usr/include
sys_include_dir=/usr/include
crt_dir=$FIX_DIR
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
LIBCEOF

echo ""
echo "CRT fix ready at $FIX_DIR"
echo "Build with: zig build --libc \"$FIX_DIR/libc.txt\""
