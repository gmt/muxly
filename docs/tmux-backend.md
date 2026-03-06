# tmux backend

The current muxly tmux integration is intentionally thin and command-backed.

## Current state

- session creation via `tmux new-session`
- pane splitting via `tmux split-window`
- pane capture via `tmux capture-pane`
- tty-backed muxml leaves refreshed from pane output

## Planned evolution

Later iterations should move toward a richer control-mode-backed adapter with:

- event parsing
- refresh/reconnect handling
- normalized pane/window/session state snapshots
- lower-latency change observation than ad hoc command refreshes

This document exists to make the current cutline explicit rather than
overstating backend sophistication.
