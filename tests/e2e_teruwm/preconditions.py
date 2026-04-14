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


def _raise_master_ratio(wm) -> None:
    """Bump master_ratio off the default so zoom_reset has something to
    reset back to."""
    wm.test_key("zoom_in")
    wm.test_key("zoom_in")
    time.sleep(0.1)


def _focus_and_raise_master_count(wm) -> None:
    """Resize_shrink_h lowers master_count; raise it first so the shrink
    has room. Also focus a non-master pane so h-resize has a visible
    effect (master-stack re-arranges when master_count changes)."""
    wm.test_key("master_count_inc")
    time.sleep(0.05)


def _zoom_prereq(wm) -> None:
    """zoom_toggle = xmonad W.zoom = swapWithMaster. That's a no-op
    when the focused pane is already master, so focus a slave first."""
    _focus_non_master(wm)


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

    # zoom_in / zoom_out change master_ratio directly — any seed with a
    # master-stack layout (the seed default) exposes the change.
    # zoom_reset restores ratio to default; prime with a different ratio
    # first so reset has something to reset to.
    "zoom_reset":   _raise_master_ratio,
    # zoom_toggle = swap focused with master — no-op unless focused is
    # already a slave.
    "zoom_toggle":  _zoom_prereq,

    # Vertical resize maps to master_count adjustment. Master-stack honors
    # it; default seed has master_count=1 so shrink would hit the lower
    # bound. Pre-raise the count so shrink has room.
    "resize_shrink_h": _focus_and_raise_master_count,
    # resize_grow_h raises master_count — visible under default seed.
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
