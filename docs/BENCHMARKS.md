# Benchmarks

Honest numbers for teru (the terminal) and teruwm (the compositor),
with the methodology, the things we deliberately do **not** measure,
and how to reproduce every result.

> If you find a number here that disagrees with your measurement, please
> open an issue with the full command line you ran and the hardware you
> ran it on. Every number in this doc is a median of 30 runs on a
> single machine; we'd rather publish a narrower claim with repro than
> a bigger one you can't verify.

## Why these metrics, and not others

We follow the best practices argued for in:

- [Tristan Hume — *Making a USB keyboard-to-screen latency tester*](https://thume.ca/2020/05/20/making-a-latency-tester/) — on why software-only latency numbers are misleading.
- [David Justo — *M2P Latency*](https://davidjusto.com/articles/m2p-latency/) — monitor-to-photon methodology.
- [kitty — *Performance*](https://sw.kovidgoyal.net/kitty/performance/) — MB/s breakdown by payload class.
- [alacritty/vtebench](https://github.com/alacritty/vtebench) — the de facto PTY-read throughput harness.
- [Ghostty discussion #4837](https://github.com/ghostty-org/ghostty/discussions/4837) — public argument by Ghostty's author that vtebench alone isn't enough.

**What we measure:**

| Metric | Rationale |
|---|---|
| vtebench-payload throughput (MB/s) | Industry standard since 2019; directly comparable with kitty/alacritty/foot/ghostty's published numbers. |
| Parse-only vs parse+render split | Isolates `VtParser` cost from `SoftwareRenderer` cost so we can see which one a given payload stresses. |
| p50/p95/p99 over N=30 samples | Means and maxes are misleading — tail latency is the honest perf story. |
| Binary size (ReleaseFast, stripped) | A competitive compositor in < 7 MB is a concrete claim users can verify. |
| Startup time (`teru --help`) | Cold-path exec; includes fork/exec overhead. Sets a floor. |

**What we do NOT measure** (and why):

1. **Keypress-to-pixel latency.** A software-only measurement (JS
   timers, X11/Wayland polling, screen scraping) excludes the USB
   polling interval and the full monitor pipeline. Published research
   shows these sources dominate the number — Hume's phototransistor
   rig on macOS measured `kitty` at 36.1 ms and `Alacritty` at
   50.4 ms, while software-only tools rank them differently. Until
   we have a Teensy + phototransistor rig we will not publish a
   latency number. Publishing one anyway would be marketing, not
   measurement.
2. **FPS.** A terminal hitting 144 fps while missing half its vblanks
   is worse than one locked to 60 fps with zero drops. Without
   `wp_presentation_time` drop counts the number misleads.
3. **"Faster than X" claims.** We'll cite peer numbers from their
   own official pages; we won't run vtebench inside alacritty-hosted
   teru-hosted-by-teruwm and call that a fair comparison.

## System under test

| | |
|---|---|
| CPU | Intel Core Ultra 9 185H (22 threads) |
| RAM | 30 GiB |
| Kernel | 6.19.11-zen1-1-zen |
| Mesa | 1:26.0.4-1 |
| Zig | 0.16.0-dev.3144+ac6fb0b59 |
| Build | `zig build -Doptimize=ReleaseFast` |

Reproduce with:

```sh
zig build -Doptimize=ReleaseFast -Dcompositor
bash tools/run-bench.sh
```

The orchestrator writes `bench-results/<timestamp>.json`. Every number
below is from the snapshot at `2026-04-12_161849.json`.

## Binary size

| Binary | Release | Debug |
|---|---:|---:|
| `teru` (terminal) | **6.60 MB** | ~22 MB |
| `teruwm` (compositor) | **5.58 MB** | ~37 MB |

For reference: Alacritty 0.14 ships a ~11 MB binary, kitty ships as a
Python package + C extensions, Ghostty 1.x is ~25 MB.

## Startup time

`teru --help`, 30 samples after a 3-run warmup, median
subprocess wall-clock (includes fork + exec + argv parse + stdout
flush + exit):

| p50 | p95 | p99 |
|---:|---:|---:|
| **0.73 ms** | 1.38 ms | 1.45 ms |

For rough context: `hyperfine --warmup 3 'bash -c :'` on the same
machine reports ~2 ms, so teru's startup is dominated by exec + dynamic
linker, not teru itself.

## VT throughput (vtebench payloads)

For each payload we feed the captured byte stream through
`VtParser -> Grid` (parse-only) and through
`VtParser -> Grid -> SoftwareRenderer.renderDirty` (full
pipeline) 30 times in ReleaseFast. Throughput is derived from the p50
iteration; the p95/p99 columns show the full distribution.

### Parse-only (VtParser + Grid, no rendering)

| Payload | Bytes | p50 latency | p95 | p99 | **MB/s** |
|---|---:|---:|---:|---:|---:|
| dense_cells          | 7,020 KB | 16.7 ms | 16.8 ms | 16.8 ms | **401.3** |
| cursor_motion        | 2,412 KB |  5.7 ms | 11.2 ms | 11.5 ms | **396.1** |
| scrolling_fullscreen |     5 KB | 0.02 ms | 0.02 ms | 0.02 ms | **258.6** |
| light_cells          |   260 KB |  1.0 ms |  1.0 ms |  1.0 ms | **254.2** |
| sync_medium_cells    |   186 KB |  1.1 ms |  1.2 ms |  1.2 ms | **158.1** |
| medium_cells         |   178 KB |  1.1 ms |  1.2 ms |  1.2 ms | **154.0** |
| unicode              |   138 KB |  0.9 ms |  1.0 ms |  1.0 ms | **140.1** |

### Full pipeline (parse + render)

| Payload | **MB/s (render)** | Δ vs parse-only |
|---|---:|---:|
| dense_cells          | **390.6** | −2.7 % |
| cursor_motion        | **372.7** | −5.9 % |
| light_cells          | **183.9** | −27.7 % |
| sync_medium_cells    | **117.1** | −25.9 % |
| medium_cells         | **114.3** | −25.8 % |
| unicode              | **101.0** | −27.9 % |
| scrolling_fullscreen |  **13.0** | −95.0 % |

**Reading the numbers:** parse and render costs are well-matched for
large uniform updates (`dense_cells`, `cursor_motion`) — the render
path overhead is 3–6 % because most work is memcpy-shaped. Small
payloads (`medium_cells`, `unicode`) amortize per-frame setup worse,
so render adds ~25 %. `scrolling_fullscreen` is the worst case: a
tiny input stream causes a full-grid repaint, so parse is fast but
render dominates.

## Compared with peer terminals

Published numbers from each project's own benchmark pages. These
aren't run on our hardware — they're cited with links so you can
audit them. vtebench's `dense_cells` payload under kitty on a Ryzen
7 PRO 5850U is 121.8 MB/s; our number on a Core Ultra 9 185H is
390.6 MB/s (full pipeline). The CPUs differ, so don't read this as a
4× win — read it as "we're in the right ballpark for a
CPU-bound SIMD renderer."

| Terminal | Source | Notes |
|---|---|---|
| kitty 0.33 | [kitty perf page](https://sw.kovidgoyal.net/kitty/performance/) | Ryzen 7 PRO 5850U; avg across 4 payloads 134.55 MB/s |
| alacritty | [termbenchbot](https://github.com/alacritty/termbenchbot) | Runs vtebench on every commit; public CI history |
| foot | [foot perf](https://codeberg.org/dnkl/foot/wiki/Performance) | Wayland-only; dense_cells published |
| ghostty | [ghostty #4837](https://github.com/ghostty-org/ghostty/discussions/4837) | Author's own discussion of vtebench limits |
| moktavizen/terminal-benchmark | [repo](https://github.com/moktavizen/terminal-benchmark) | Cross-terminal latency + IO + RAM tables |

### To run vtebench against teru natively

vtebench launches inside your terminal under test. On a graphical
session, this is the honest way to add teru/teruwm to the comparison:

```sh
cd tools/bench-bin/vtebench
cargo run --release -- --dat /tmp/teru.dat   # run this inside teru
```

Results in `/tmp/teru.dat` are gnuplot-compatible and can be compared
with any other terminal where the same command was run.

## Reproducibility

Every number in this document can be reproduced with two commands
from a clean checkout:

```sh
python3 tools/gen-payloads.py     # one-time; caches to tools/bench-payloads/
bash   tools/run-bench.sh          # writes bench-results/<timestamp>.json
```

If your numbers differ significantly from ours, the likely causes are,
in order: CPU governor (set to `performance`), thermal throttling,
dynamic linker warm-up (run the warm-up loop), or ReleaseSafe vs
ReleaseFast. Report with `perf stat` if you're curious about where the
time went.

## Planned follow-ups

- [ ] Phototransistor-based keypress-to-photon latency. Hardware
      build: Teensy LC, IR phototransistor on the bezel, capture to
      CSV. Numbers go here when hardware is mounted.
- [ ] Compositor frame-delivery jitter via `wp_presentation_time`.
      Requires exporting the protocol in teruwm; ticket open.
- [ ] Session-restore latency: timer from `teruwm --restore` exec to
      first rendered frame. Unique to teruwm's hot-restart feature.
- [ ] `time cat 100MB.log` with the shell prompt as the sync point.
- [ ] Memory footprint: `teru` single pane vs `teruwm` with 10
      terminals vs `teruwm` hosting N XDG clients. Needs a standard
      `/proc/PID/status` capture in the orchestrator.

When any of these ships, this document gets updated in the same PR as
the feature. Stale benchmarks are worse than no benchmarks.
