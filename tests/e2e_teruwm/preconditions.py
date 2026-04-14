"""Per-action preconditions: some keybind actions are no-ops under the
default 3-pane-master-stack seed. Each entry sets up the minimal state
needed to make the action produce a visible effect.

The precondition function is called AFTER `_seed()` and BEFORE `pre-shot`,
so it appears in the audit trail as the starting state.
"""
from __future__ import annotations
import time
from typing import Callable, Optional


def _focus_non_master(wm) -> None:
    """Focus a slave pane so pane_set_master / swap_master / etc. actually swap."""
    wins, _ = wm.call("teruwm_list_windows")
    wins = sorted(wins or [], key=lambda w: w["id"])
    if len(wins) >= 2:
        # The "master" in master-stack is usually the leftmost (smallest x).
        # Focus the one furthest from the left.
        target = max(wins, key=lambda w: w["x"])
        wm.call("teruwm_focus_window", {"node_id": target["id"]})
        time.sleep(0.05)


def _float_focused(wm) -> None:
    """Float the currently focused pane so pane_sink has something to sink."""
    wm.test_key("float_toggle")
    time.sleep(0.1)


def _raise_master_count(wm) -> None:
    """Bump master count up so master_count_dec has room to drop."""
    wm.test_key("master_count_inc")
    time.sleep(0.05)


def _visit_other_ws(wm) -> None:
    """Switch to ws2 then back so workspace_toggle_last has a previous ws
    AND workspace_1 arrives somewhere new."""
    wm.call("teruwm_switch_workspace", {"workspace": 4})
    time.sleep(0.1)


def _populate_another_ws(wm) -> None:
    """Put a terminal on ws3 so workspace_next_nonempty has somewhere to go,
    then return to ws0."""
    wm.call("teruwm_switch_workspace", {"workspace": 2})
    time.sleep(0.1)
    wm.call("teruwm_spawn_terminal", {"workspace": 2})
    time.sleep(0.3)
    wm.call("teruwm_switch_workspace", {"workspace": 0})
    time.sleep(0.1)


def _set_accordion(wm) -> None:
    """Switch active workspace to accordion layout so vertical resize applies."""
    wm.call("teruwm_set_layout", {"layout": "accordion", "workspace": 0})
    time.sleep(0.1)


def _set_zoom_state(wm) -> None:
    """Toggle zoom on so subsequent zoom_* actions have state to change."""
    wm.test_key("zoom_toggle")
    time.sleep(0.1)


# action_name -> precondition setup function
PRECONDITIONS: dict[str, Callable] = {
    # Focus a slave pane so swap/set master actually moves things.
    "pane_set_master":    _focus_non_master,
    "pane_swap_master":   _focus_non_master,

    # Need a floating pane for sink operations.
    "pane_sink":          _float_focused,
    "pane_sink_all":      _float_focused,

    # Can't decrement below 1 — bump up first.
    "master_count_dec":   _raise_master_count,

    # Need a "previous" workspace stored.
    "workspace_toggle_last":   _visit_other_ws,

    # Need a non-empty other workspace.
    "workspace_next_nonempty": _populate_another_ws,

    # workspace_1 action goes to ws index 0; we seed on ws0 so we're already
    # there. Visit ws 4 first so workspace_1 actually moves.
    "workspace_1":         _visit_other_ws,

    # Zoom state toggles — prime the state first.
    "zoom_in":      _set_zoom_state,
    "zoom_out":     _set_zoom_state,
    "zoom_reset":   _set_zoom_state,

    # Vertical resize only has effect in layouts with vertical splits.
    "resize_shrink_h": _set_accordion,
    "resize_grow_h":   _set_accordion,
}


def setup_for(wm, action_name: str) -> Optional[str]:
    """Run the precondition for this action if one is registered.

    Returns a short label describing what was set up (for the audit trail),
    or None if no precondition was needed.
    """
    fn = PRECONDITIONS.get(action_name)
    if fn is None:
        return None
    fn(wm)
    return fn.__name__.lstrip("_")
