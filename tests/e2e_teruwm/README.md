# teruwm end-to-end test suite

Exhaustive E2E coverage for the teruwm compositor. Every keybind action,
every MCP tool, every tiling layout — exercised against a real headless
teruwm with screenshots as ground truth.

## Running

```sh
# Full suite (~10 min)
cd tests/e2e_teruwm && python3 -u run_all.py

# Individual sections
python3 -u test_smoke.py        # harness sanity check (~6 s)
python3 -u test_layouts.py      # 8 layouts, one screenshot each (~20 s)
python3 -u test_mcp_tools.py    # 30 MCP tools (~50 s)
python3 -u test_keybinds.py     # every Action enum variant (~9 min)

# Post-hoc: parse the artifact dir for a pass/fail table
python3 analyze.py
```

## How it works

- Every test launches its own teruwm on `WLR_BACKENDS=headless` — no TTY
  grab, no DRM, no nested-Wayland frame weirdness. A virtual 1280×720
  output is rendered directly to an internal framebuffer.
- Screenshots are captured via `teruwm_screenshot` which self-composites
  from terminal panes + bars (no backend dependency).
- Every action's pre/post screenshots land in `/tmp/teruwm-e2e-shots/<section>/<action>/`
  so every test leaves a visual audit trail.
- Comparison is by **md5, not by file size** — teru's PNG encoder produces
  ~2.77 MB for any 1280×720 frame regardless of content, so size is
  meaningless.

## Files

| File | Purpose |
|---|---|
| `harness.py` | `Wm` context manager, MCP helper with retry, `snap()`, `spawn_terminal()` |
| `actions.py` | Catalogue of every `Keybinds.Action` enum variant with effect + note |
| `preconditions.py` | Per-action setup: e.g. float a pane before `pane_sink` |
| `test_smoke.py` | Harness sanity — three distinct shots prove live capture |
| `test_layouts.py` | Each of 8 layouts rendered with 4 panes; hash collisions flagged |
| `test_mcp_tools.py` | All 30 teruwm_* MCP tools called with sensible args |
| `test_keybinds.py` | 92 `Action` enum variants — cheap (shared compositor), render (fresh), destructive (fresh) |
| `analyze.py` | Post-hoc analyzer of `/tmp/teruwm-e2e-shots/keybinds/` |
| `run_all.py` | Sequence everything, emit summary |

## What counts as a pass

An action is expected to have a `category` and an `effect`:

- **render** — post-shot md5 must differ from pre-shot (or state dict differs)
- **state** — `list_windows` / `list_workspaces` / `get_config` must differ
- **no-op** / **external** — no crash; compositor still responsive after call
- **destructive** — specific handler (process exited, window gone, etc.)

## Key invariants this catches

- **MCP tool schema regressions** — every tool accepts the request shape we send
- **Layout distinctness** — if two tiling layouts accidentally render the same
  pixel layout they collide and fail
- **Keybind dispatch coverage** — every `Action` enum value must be accepted
  by `teruwm_test_key`
- **Compositor survives destructive ops** — quit exits cleanly, restart comes
  back online via exec, close reduces window count by exactly one
- **No action crashes the compositor** — every `no-op` action is followed by
  a `get_config` to prove responsiveness

## Known limitations

- **XDG client buffers** are not in screenshots. `teruwm_screenshot` self-
  composites from teruwm's own terminal panes + bars; Wayland client surfaces
  from foot / firefox / etc. aren't painted in. Fine for keybind tests
  (everything is terminal panes) — a limitation for client-integration tests.
- **Single output**. All tests run on the one `HEADLESS-1` output. Multi-
  output behaviour (`focus_output_next`, `move_to_output_next`) falls through
  to no-op instead of being exercised.
- **8 failing actions** (as of initial run): `pane_sink`, `zoom_in/out/reset/toggle`,
  `resize_shrink_h`, `resize_grow_h`, `toggle_status_bar`. These need deeper
  precondition work OR point to real bugs — see failures in test output.

## Lessons saved for future runs

- Use compact JSON (`separators=(",",":")`) when talking to `WmMcpServer`.
  The parser's handling of pretty-printed JSON + Content-Length edge cases
  is fragile — not worth debugging for a test client.
- Python stdout is block-buffered when piped. Always `python3 -u` +
  `PYTHONUNBUFFERED=1` or the output never streams.
- Never `pkill -f` a pattern that could match a user process. Track
  subprocess PIDs explicitly and kill only those.
