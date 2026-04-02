---
name: teru
description: Build, test, run, format, and inspect the teru terminal emulator (Zig 0.16). Use when working on teru or needing quick terminal project commands.
---

# teru Terminal Skill

## Sub-commands

**`/teru build`** — Build and verify
```bash
cd /home/ng/code/foss/teru && zig build test 2>&1 && echo "TESTS OK" && zig build 2>&1 && echo "BUILD OK"
```

**`/teru release`** — Release build with size check
```bash
cd /home/ng/code/foss/teru && zig build -Doptimize=ReleaseSafe 2>&1 && strip zig-out/bin/teru && ls -lh zig-out/bin/teru
```

**`/teru run`** — Build and run in windowed mode
```bash
cd /home/ng/code/foss/teru && zig build run 2>&1
```

**`/teru raw`** — Build and run in TTY/raw mode
```bash
cd /home/ng/code/foss/teru && zig build run -- --raw 2>&1
```

**`/teru fmt`** — Format all Zig source files
```bash
cd /home/ng/code/foss/teru && zig fmt src/ 2>&1
```

**`/teru check`** — Format check (no write) + build test
```bash
cd /home/ng/code/foss/teru && zig fmt --check src/ 2>&1; zig build test 2>&1 && echo "ALL CHECKS PASSED"
```

**`/teru stats`** — Project statistics
```bash
cd /home/ng/code/foss/teru
echo "=== Lines ===" && find src -name "*.zig" -exec cat {} + | wc -l
echo "=== Files ===" && find src -name "*.zig" | wc -l
echo "=== Tests ===" && grep -rn "^test " src/ --include="*.zig" | wc -l
echo "=== Modules ===" && ls -d src/*/  2>/dev/null | sed 's|src/||;s|/||'
```

**`/teru x11`** — Build X11-only (no Wayland deps)
```bash
cd /home/ng/code/foss/teru && zig build -Dwayland=false 2>&1 && echo "X11-ONLY BUILD OK"
```

**`/teru wayland`** — Build Wayland-only (no X11 deps)
```bash
cd /home/ng/code/foss/teru && zig build -Dx11=false 2>&1 && echo "WAYLAND-ONLY BUILD OK"
```
