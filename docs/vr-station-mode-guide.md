---
relates_to:
  - src/compositor/ServerVr.zig
  - src/compositor/WmMcpTools.zig
  - src/compositor/Output.zig
  - src/compositor/wlr.zig
last_verified: "2026-11-16"
category: "guides"
audience: "all"
---

# VR station mode

VR station mode turns a laptop into a headset station: the internal panel is
powered off completely while the same desktop keeps being composited into a
virtual output that a VR client captures. The panel emits no light, draws no
backlight or scanout power, and the lid can be closed without the machine
suspending — while the headset keeps receiving live frames.

## Why the obvious approaches fail

Two cheaper mechanisms look sufficient and are not:

- **Disabling the output** (`wlr-randr --output eDP-1 --off`) stops the
  compositor committing that output. `wlr-screencopy` completes frames on
  output commit, so a capture client freezes on its last picture. Measured:
  `caps` fell to 0/60 while the XR loop kept presenting.
- **Backlight 0** (`/sys/class/backlight/intel_backlight/brightness`) reaches
  the driver (`actual_brightness` reads 0) but not the light: on this panel the
  LED string's hardware floor still emits. Platform power is unchanged —
  interleaved psys A/B measured 94.45 / 94.90 / 94.11 / 93.50 W with
  `bl_power` 0 and 4, so `bl_power` (FB_BLANK_POWERDOWN) is a no-op on i915's
  backlight as well.

Connector DPMS set behind wlroots' back is also wrong: the kernel routes a DPMS
property write to `drm_atomic_connector_commit_dpms()`, which deactivates the
CRTC. The next wlroots page-flip re-asserts `CRTC.active` without the
`ALLOW_MODESET` flag and fails with `-EINVAL`, which stops frames and therefore
stops screencopy.

## Mechanism

`teruwm_vr_mode` (see [MCP-API.md](MCP-API.md)):

1. Finds the internal panel (the first `eDP-*` output, or `panel=<name>`) and
   reads its layout box, size and refresh.
2. Creates a `wlr_headless_backend` on the compositor's own event loop and adds
   a headless output at that box with the panel's geometry and refresh.
3. Hands it to `Output.create` (`CreateOptions.layout_pos` +
   `CreateOptions.custom_mode`), removes the panel from `Server.outputs` and
   from the output layout, and focuses the headless output so the active
   workspace renders there.
4. Disables the panel with `miozu_output_commit_enabled(panel, 0)` — a full
   modeset, so i915 turns off the CRTC, the connector, the panel power and the
   backlight.
5. `off` reverses it: re-add and re-enable the panel, then destroy the headless
   backend (its output destroy handler frees the `Output`).

Because the headless output is the only output while VR mode is on, the
compositor renders the desktop exactly once — for the headset. Nothing is
rendered "to the laptop screen" and thrown away.

## Using it

The tool is exposed as `teruwm_vr_mode {op: on|off|toggle|status, panel?}` and
driven by `~/.miozu/bin/vr-mode.sh`, bound to `mod+v` and `mod+.` in
`~/.config/teruwm/config`. The script also takes the lid-close/sleep inhibitor
(`systemd-inhibit --what=handle-lid-switch:sleep`), because logind would
otherwise hibernate when the lid shuts.

A capture client should follow the swap itself: bind every `wl_output` and
prefer a `HEADLESS-*` output (teru-vr does this). The name is also returned by
the tool (`output=HEADLESS-N`) and can be forced with `TERU_VR_OUTPUT`.

## Limits

- VR mode does **not** survive a compositor hot restart (`mod+'` calls
  `releaseSeat`, which tears down the headless backend and re-enables the
  panel). Toggle it again afterwards.
- `output_power_management` clients cannot change the power of the panel or the
  headless output while VR mode owns them; that guard is deliberate, so a stale
  `wlopm` or an idle DPMS-off cannot re-light the panel or stop the capture.
- While VR mode is on, the headless output has no hardware cursor plane; the
  cursor is composited into the scene like any other buffer.

## Verification

```sh
# headless compositor (no DRM, no seat)
WLR_BACKENDS=headless WLR_RENDERER=pixman ./zig-out/bin/teruwm &
# then, over its MCP socket:
teruwm_vr_mode {"op":"on","panel":"HEADLESS-1"}
# -> active=true output=HEADLESS-2 1280x720 panel=HEADLESS-1 panel_enabled=false
TERU_VR_OUTPUT=HEADLESS-2 teru-vr --probe     # prints a 1280x720 frame
teruwm_vr_mode {"op":"off"}                   # -> panel restored, HEADLESS-2 gone
```
