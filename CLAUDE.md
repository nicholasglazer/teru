# teru

One source tree, two binaries that share one version: `teru` (terminal emulator and multiplexer) and `teruwm` (a wlroots Wayland compositor built on the same library). Written in Zig, rendered on the CPU, with no Zig package dependencies.

## Build and test

```sh
zig build                                       # debug teru -> zig-out/bin/teru
zig build -Dcompositor                          # debug teru + teruwm + teruwmctl
zig build test                                  # inline tests; add -Dcompositor for the compositor's
zig build -Doptimize=ReleaseSafe -Dcompositor   # release build of both
make e2e-wm                                     # headless teruwm end-to-end test
make audit-wm                                   # headless sweep of every teruwm MCP tool and keybind action
```

- A bare `zig build` is the supported invocation. Do not pass `--libc` by hand. If a build fails with `libc installation is missing crt directory`, run `./tools/fix-crt.sh --check`.
- This tree, CI and releases build on the latest stable Zig (0.17.1). `main` and the feature branches must stay buildable on it. `build.zig.zon` holds the minimum version.
- Zig master (0.18-dev) work lives on the local branch `zig-0.18`, checked out in the sibling worktree `../teru-wt-zig18`. It is this branch plus the source changes only master accepts (`packed` becomes `bitpack`). Bring it up to date with `git -C ../teru-wt-zig18 merge <branch>`. It is not pushed, because CI would build it with stable.
- `zig` on PATH may be either compiler, so run `zig version` first. `make` uses the compiler directory named in an untracked `local.mk`, when that file exists.
- The Python end-to-end tests are in `tests/`; each file's header says what it covers.

## Where things are

`docs/ARCHITECTURE.md` is the module map. Two things it is easy to get wrong:

- `src/compositor/` is teruwm only. Everything else is shared by both binaries.
- There are two MCP servers on separate sockets. The terminal's is `src/agent/McpServer.zig` on `$XDG_RUNTIME_DIR/teru-mcp-$PID.sock`. The compositor's is `src/compositor/WmMcpServer.zig` on `$XDG_RUNTIME_DIR/teruwm-mcp-$PID.sock`. `teruwmctl` is the CLI for the second. `docs/MCP-API.md` lists every tool.

## Invariants

- Every function that does file, network or timer I/O takes `io: std.Io`, threaded down from `main`.
- The render hot path allocates nothing. It redraws only the rows between `grid.dirty_row_min` and `grid.dirty_row_max`, so anything that changes cells must keep that range correct.
- `VtParser` is pure: no I/O and no allocation. CSI parameters and OSC strings are bounded, and overflow truncates instead of failing. An `ESC` inside a DCS body goes through `.dcs_st_esc`, never the general escape state.
- No new dependencies without discussion, whether a Zig package, a system library or vendored C. Binary size and the no-GPU property depend on it.

## Version and docs

- The version is `const version` in `build.zig`, shared by both binaries. Bump it with `make bump-version V=x.y.z`, which also updates `build.zig.zon`.
- When behaviour a user can see changes, update the matching file in `docs/` in the same commit: `KEYBINDINGS.md`, `CONFIGURATION.md`, `MCP-API.md`, `INSTALLING.md`, `AI-INTEGRATION.md`, `SESSIONS.md`.
