PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

# ── CRT fix (GCC 15+ .sframe — Zig linker R_X86_64_PC64 gap) ──────────
# fix-crt.sh is idempotent: fast no-op when .sframe not present,
# creates stripped CRT copies + libc.txt when needed.
CRT_FIX_LIBC = .cache/crt-fix-all/libc.txt
CRT_FIX_FLAG = $$([ -f $(CRT_FIX_LIBC) ] && echo "--libc $(CRT_FIX_LIBC)")

.PHONY: prepare
prepare: ## Run once: set up CRT fix (auto-detect, idempotent)
	./tools/fix-crt.sh

# ── Development ─────────────────────────────────────────────────────
.PHONY: dev
dev: ## Debug build (4MB, full safety + debug symbols)
	./tools/fix-crt.sh
	zig build $(CRT_FIX_FLAG)

.PHONY: run
run: ## Build and run (debug)
	./tools/fix-crt.sh
	zig build run $(CRT_FIX_FLAG)

.PHONY: test
test: ## Run all tests
	./tools/fix-crt.sh
	zig build test $(CRT_FIX_FLAG)

.PHONY: test-wm
test-wm: ## Run library + compositor inline tests
	./tools/fix-crt.sh
	zig build test -Dcompositor $(CRT_FIX_FLAG)

.PHONY: e2e-wm
e2e-wm: ## Headless teruwm end-to-end MCP test (spawn / tiling / shell-exit / no-spin)
	./tools/fix-crt.sh
	zig build -Dcompositor $(CRT_FIX_FLAG) $$(./tools/zig-lib-fix.sh)
	python3 tests/teruwm_e2e.py zig-out/bin/teruwm

.PHONY: audit-wm
audit-wm: ## Headless teruwm MCP usability audit (all 37 tools + 58 keybind actions)
	./tools/fix-crt.sh
	zig build -Dcompositor $(CRT_FIX_FLAG) $$(./tools/zig-lib-fix.sh)
	python3 tests/teruwm_mcp_audit.py zig-out/bin/teruwm

# ── Release ─────────────────────────────────────────────────────────
.PHONY: release
release: ## Release build (1.3MB, optimized + safety checks)
	./tools/fix-crt.sh
	zig build -Doptimize=ReleaseSafe $(CRT_FIX_FLAG)
	strip zig-out/bin/teru

.PHONY: release-small
release-small: ## Smallest build (~800KB, no safety checks)
	./tools/fix-crt.sh
	zig build -Doptimize=ReleaseSmall $(CRT_FIX_FLAG)
	strip zig-out/bin/teru

# ── Minimal builds (single backend) ────────────────────────────────
.PHONY: release-x11
release-x11: ## X11-only release (no wayland-client dep)
	./tools/fix-crt.sh
	zig build -Doptimize=ReleaseSafe -Dwayland=false $(CRT_FIX_FLAG)
	strip zig-out/bin/teru

.PHONY: release-wayland
release-wayland: ## Wayland-only release (no libxcb dep)
	./tools/fix-crt.sh
	zig build -Doptimize=ReleaseSafe -Dx11=false $(CRT_FIX_FLAG)
	strip zig-out/bin/teru

# ── Compositor (teruwm) ─────────────────────────────────────────────
.PHONY: compositor
compositor: ## Debug build with compositor (teruwm)
	./tools/fix-crt.sh
	zig build -Dcompositor $(CRT_FIX_FLAG)

.PHONY: release-compositor
release-compositor: ## Release build with compositor (teruwm)
	./tools/fix-crt.sh
	zig build -Doptimize=ReleaseSafe -Dcompositor $(CRT_FIX_FLAG)
	strip zig-out/bin/teruwm

.PHONY: run-wm
run-wm: ## Build and run teruwm compositor
	./tools/fix-crt.sh
	zig build run-wm --libc $(CRT_FIX_FLAG)

# ── Install ─────────────────────────────────────────────────────────
.PHONY: install
install: release ## Install to PREFIX (default: /usr/local)
	install -Dm755 zig-out/bin/teru $(DESTDIR)$(BINDIR)/teru

# install-local: the "always latest" target behind `startt`. One
# `-Dcompositor` build produces both teru + teruwm; the CRT fix and the
# termios-typo zig-lib patch are applied automatically, then both binaries
# are stripped and installed to ~/.local/bin (no sudo, no /usr/local).
LOCALBIN ?= $(HOME)/.local/bin
.PHONY: install-local
install-local: ## Build release teru + teruwm, install both to ~/.local/bin
	./tools/fix-crt.sh
	zig build -Doptimize=ReleaseSafe -Dcompositor $(CRT_FIX_FLAG) $$(./tools/zig-lib-fix.sh)
	strip zig-out/bin/teru zig-out/bin/teruwm
	install -Dm755 zig-out/bin/teru   $(LOCALBIN)/teru
	install -Dm755 zig-out/bin/teruwm $(LOCALBIN)/teruwm
	@echo "install-local: installed teru + teruwm → $(LOCALBIN)"

# dev-install: the fast inner-loop sibling of install-local. Debug build
# (incremental, ~seconds; full safety + symbols for crash diagnostics), NOT
# stripped, installed to ~/.local/bin. This is the "recompile" half of the
# edit → recompile → `Super+'` hot-restart loop. Pair with the `tr` shell
# alias. teruwm re-execs whatever sits at ~/.local/bin/teruwm on restart, so
# a dev-install immediately before `Super+'` lands you on the new code with
# PTYs intact.
.PHONY: dev-install
dev-install: ## Fast DEBUG build of teru + teruwm, install both to ~/.local/bin
	./tools/fix-crt.sh
	zig build -Dcompositor $(CRT_FIX_FLAG) $$(./tools/zig-lib-fix.sh)
	install -Dm755 zig-out/bin/teru   $(LOCALBIN)/teru
	install -Dm755 zig-out/bin/teruwm $(LOCALBIN)/teruwm
	@echo "dev-install: installed DEBUG teru + teruwm → $(LOCALBIN)"

.PHONY: uninstall
uninstall: ## Remove installed binary
	rm -f $(DESTDIR)$(BINDIR)/teru

# ── Version ─────────────────────────────────────────────────────
.PHONY: bump-version
bump-version: ## Bump version: make bump-version V=x.y.z
	@test -n "$(V)" || (echo "Usage: make bump-version V=x.y.z" && exit 1)
	@sed -i 's/const version = ".*"/const version = "$(V)"/' build.zig
	@sed -i 's/\.version = ".*"/.version = "$(V)"/' build.zig.zon
	@echo "Bumped to $(V) in build.zig + build.zig.zon"

# ── Clean ───────────────────────────────────────────────────────────
.PHONY: clean
clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache .cache/crt-fix-all

.PHONY: help
help: ## Show this help
	@grep -E '^[a-z-]+:.*##' Makefile | awk -F ':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

.PHONY: size
size: ## Show binary size for all build profiles
	./tools/fix-crt.sh
	zig build -Doptimize=ReleaseSafe $(CRT_FIX_FLAG) 2>/dev/null && strip zig-out/bin/teru && printf "  ReleaseSafe:  %s\n" "$$(du -h zig-out/bin/teru | cut -f1)"; true
	zig build -Doptimize=ReleaseSmall $(CRT_FIX_FLAG) 2>/dev/null && strip zig-out/bin/teru && printf "  ReleaseSmall: %s\n" "$$(du -h zig-out/bin/teru | cut -f1)"; true
	zig build $(CRT_FIX_FLAG) 2>/dev/null && printf "  Debug:        %s\n" "$$(du -h zig-out/bin/teru | cut -f1)"; true

.PHONY: deps
deps: ## Check runtime dependencies
	./tools/fix-crt.sh
	@echo "=== Linked libraries ==="
	@zig build -Doptimize=ReleaseSafe $(CRT_FIX_FLAG) 2>/dev/null && ldd zig-out/bin/teru 2>/dev/null | grep -E 'xcb|xkb|wayland' || echo "  (cross-compiled or static)"; true
	@echo ""
	@echo "=== Clipboard tools ==="
	@command -v xclip >/dev/null 2>&1 && echo "  xclip: found" || echo "  xclip: NOT FOUND (needed for X11 clipboard)"
	@command -v wl-copy >/dev/null 2>&1 && echo "  wl-copy: found" || echo "  wl-copy: NOT FOUND (needed for Wayland clipboard)"
	@echo ""
	@echo "=== Optional ==="
	@command -v xdg-open >/dev/null 2>&1 && echo "  xdg-open: found" || echo "  xdg-open: NOT FOUND (needed for URL click)"

.DEFAULT_GOAL := help
