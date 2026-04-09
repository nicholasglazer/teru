PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

# ── Development ─────────────────────────────────────────────────────
.PHONY: dev
dev: ## Debug build (4MB, full safety + debug symbols)
	zig build

.PHONY: run
run: ## Build and run (debug)
	zig build run

.PHONY: test
test: ## Run all tests
	zig build test

# ── Release ─────────────────────────────────────────────────────────
.PHONY: release
release: ## Release build (1.3MB, optimized + safety checks)
	zig build -Doptimize=ReleaseSafe
	strip zig-out/bin/teru

.PHONY: release-small
release-small: ## Smallest build (~800KB, no safety checks)
	zig build -Doptimize=ReleaseSmall
	strip zig-out/bin/teru

# ── Minimal builds (single backend) ────────────────────────────────
.PHONY: release-x11
release-x11: ## X11-only release (no wayland-client dep)
	zig build -Doptimize=ReleaseSafe -Dwayland=false
	strip zig-out/bin/teru

.PHONY: release-wayland
release-wayland: ## Wayland-only release (no libxcb dep)
	zig build -Doptimize=ReleaseSafe -Dx11=false
	strip zig-out/bin/teru

# ── Install ─────────────────────────────────────────────────────────
.PHONY: install
install: release ## Install to PREFIX (default: /usr/local)
	install -Dm755 zig-out/bin/teru $(DESTDIR)$(BINDIR)/teru

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
	@echo "  main.zig and McpServer.zig read build_options.version at compile time"

# ── Clean ───────────────────────────────────────────────────────────
.PHONY: clean
clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache

# ── Info ────────────────────────────────────────────────────────────
.PHONY: help
help: ## Show this help
	@grep -E '^[a-z-]+:.*##' Makefile | awk -F ':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

.PHONY: size
size: ## Show binary size for all build profiles
	@echo "=== Build profiles ==="
	@zig build -Doptimize=ReleaseSafe 2>/dev/null && strip zig-out/bin/teru && printf "  ReleaseSafe:  %s\n" "$$(du -h zig-out/bin/teru | cut -f1)"
	@zig build -Doptimize=ReleaseSmall 2>/dev/null && strip zig-out/bin/teru && printf "  ReleaseSmall: %s\n" "$$(du -h zig-out/bin/teru | cut -f1)"
	@zig build 2>/dev/null && printf "  Debug:        %s\n" "$$(du -h zig-out/bin/teru | cut -f1)"

.PHONY: deps
deps: ## Check runtime dependencies
	@echo "=== Linked libraries ==="
	@zig build -Doptimize=ReleaseSafe 2>/dev/null && ldd zig-out/bin/teru 2>/dev/null | grep -E 'xcb|xkb|wayland' || echo "  (cross-compiled or static)"
	@echo ""
	@echo "=== Clipboard tools ==="
	@command -v xclip >/dev/null 2>&1 && echo "  xclip: found" || echo "  xclip: NOT FOUND (needed for X11 clipboard)"
	@command -v wl-copy >/dev/null 2>&1 && echo "  wl-copy: found" || echo "  wl-copy: NOT FOUND (needed for Wayland clipboard)"
	@echo ""
	@echo "=== Optional ==="
	@command -v xdg-open >/dev/null 2>&1 && echo "  xdg-open: found" || echo "  xdg-open: NOT FOUND (needed for URL click)"

.DEFAULT_GOAL := help
