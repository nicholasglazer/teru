"""Catalogue of every keybind action teruwm accepts.

Derived from `src/config/Keybinds.zig` `Action.fromString`. Each entry is:
    (action_string, category, expected_visible_effect)

`visible_effect` is one of:
    "state"       — observable via MCP state query (workspace, node list, …)
    "render"      — changes what the screenshot shows (bar, panes)
    "no-op"       — is safe to call; has no visible effect in an empty teruwm
                    (typically teru-terminal-only actions like scroll, paste)
    "destructive" — exits or restarts the compositor; skipped by default
    "external"    — shells out to another command that may or may not exist
                    (media keys, brightness, volume); test only that the call
                    does not crash

Grouped so tests can iterate per category.
"""
from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class Act:
    name: str
    category: str
    effect: str
    note: str = ""


ACTIONS: list[Act] = [
    # ── Pane navigation (render + state) ──
    Act("pane_focus_next",        "pane",    "state",  "cycle focus forward"),
    Act("pane_focus_prev",        "pane",    "state",  "cycle focus backward"),
    Act("pane_focus_master",      "pane",    "state",  "focus master"),
    Act("pane_set_master",        "pane",    "render", "make focused the master"),
    Act("pane_swap_next",         "pane",    "render", "swap with next"),
    Act("pane_swap_prev",         "pane",    "render", "swap with prev"),
    Act("pane_swap_master",       "pane",    "render", "swap with master"),
    Act("pane_rotate_slaves_up",  "pane",    "render", "cycle stack up"),
    Act("pane_rotate_slaves_down","pane",    "render", "cycle stack down"),
    Act("pane_sink",              "pane",    "render", "demote to bottom of stack"),
    Act("pane_sink_all",          "pane",    "render", "sink all floating"),
    Act("pane_close",             "pane",    "destructive", "closes focused pane"),

    # ── Master count ──
    Act("master_count_inc",       "master",  "render", "promote one more slave"),
    Act("master_count_dec",       "master",  "render", "demote one master"),

    # ── Workspace switch (10) — enum uses workspace_1..workspace_0 where _0 is ws10 ──
    *[Act(f"workspace_{n}", "workspace", "render",
          f"switch to ws {n if n else 10}") for n in [1,2,3,4,5,6,7,8,9,0]],

    # ── Pane move-to-workspace (10) ──
    *[Act(f"pane_move_to_{n}", "move-to", "state",
          f"move pane to ws {n if n else 10}") for n in [1,2,3,4,5,6,7,8,9,0]],

    # ── Workspace navigation ──
    Act("workspace_toggle_last",    "workspace-nav", "render", "swap to prev ws"),
    Act("workspace_next_nonempty",  "workspace-nav", "render", "jump to next non-empty ws"),

    # ── Multi-output (headless has 1 output) ──
    Act("focus_output_next",     "output", "no-op", "single output = no-op"),
    Act("move_to_output_next",   "output", "no-op", "single output = no-op"),

    # ── Layout ──
    Act("layout_cycle",   "layout", "render", "next layout in workspace list"),
    Act("layout_reset",   "layout", "render", "drop split tree"),

    # ── Zoom ──
    Act("zoom_in",     "zoom", "render", "ratio +0.05"),
    Act("zoom_out",    "zoom", "render", "ratio -0.05"),
    Act("zoom_reset",  "zoom", "render", "ratio = default"),
    Act("zoom_toggle", "zoom", "render", "toggle zoom state"),

    # ── Resize ──
    Act("resize_shrink_w", "resize", "render", "master ratio -"),
    Act("resize_grow_w",   "resize", "render", "master ratio +"),
    Act("resize_shrink_h", "resize", "render", "split ratio -"),
    Act("resize_grow_h",   "resize", "render", "split ratio +"),

    # ── Spawn / window lifecycle ──
    Act("spawn_terminal",   "lifecycle", "render", "spawn a new pane"),
    Act("window_close",     "lifecycle", "destructive", "close focused"),

    # ── Compositor-wide ──
    Act("compositor_quit",    "compositor", "destructive", "exits compositor"),
    Act("compositor_restart", "compositor", "destructive", "re-execs"),
    Act("config_reload",      "compositor", "no-op",       "reloads config file"),
    Act("launcher_toggle",    "compositor", "render",      "shows launcher overlay"),

    # ── Float / fullscreen ──
    Act("float_toggle",      "float",      "render", "tile ↔ float focused"),
    Act("fullscreen_toggle", "fullscreen", "render", "fullscreen focused"),

    # ── Screenshot ──
    Act("screenshot",        "screenshot", "no-op", "invokes grim"),
    Act("screenshot_pane",   "screenshot", "no-op", "per-pane capture"),
    Act("screenshot_area",   "screenshot", "no-op", "slurp+grim"),

    # ── Bars ──
    Act("bar_toggle_top",       "bar", "render", "hide/show top bar"),
    Act("bar_toggle_bottom",    "bar", "render", "hide/show bottom bar"),
    Act("toggle_status_bar",    "bar", "render", "legacy alias"),

    # ── Media / brightness / volume (external) ──
    Act("volume_up",      "external", "external"),
    Act("volume_down",    "external", "external"),
    Act("volume_mute",    "external", "external"),
    Act("brightness_up",  "external", "external"),
    Act("brightness_down","external", "external"),
    Act("media_play",     "external", "external"),
    Act("media_next",     "external", "external"),
    Act("media_prev",     "external", "external"),

    # ── Clipboard (teru terminal) ──
    Act("copy_selection",   "clipboard", "no-op"),
    Act("paste_clipboard",  "clipboard", "no-op"),

    # ── Session ──
    Act("session_detach",  "session", "no-op"),
    Act("session_save",    "session", "no-op"),
    Act("session_restore", "session", "no-op"),

    # ── Mode transitions (teru terminal) ──
    Act("mode_normal",  "mode", "no-op"),
    Act("mode_prefix",  "mode", "no-op"),
    Act("mode_scroll",  "mode", "no-op"),
    Act("mode_search",  "mode", "no-op"),
    Act("mode_locked",  "mode", "no-op"),

    # ── Scroll (teru terminal) ──
    Act("scroll_up_1",     "scroll", "no-op"),
    Act("scroll_down_1",   "scroll", "no-op"),
    Act("scroll_up_half",  "scroll", "no-op"),
    Act("scroll_down_half","scroll", "no-op"),
    Act("scroll_top",      "scroll", "no-op"),
    Act("scroll_bottom",   "scroll", "no-op"),

    # ── Search ──
    Act("search_next", "search", "no-op"),
    Act("search_prev", "search", "no-op"),

    # ── Select / send ──
    Act("select_begin", "select", "no-op"),
    Act("send_through", "send",   "no-op"),

    # ── Split (teru terminal) ──
    Act("split_vertical",   "split", "no-op"),
    Act("split_horizontal", "split", "no-op"),
]


def by_category(cat: str) -> list[Act]:
    return [a for a in ACTIONS if a.category == cat]


def non_destructive() -> list[Act]:
    return [a for a in ACTIONS if a.effect != "destructive"]
