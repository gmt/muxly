# tmux backend

The current muxly tmux integration is intentionally thin and command-backed.

## Current state

- session creation via `tmux new-session`
- pane splitting via `tmux split-window`
- pane capture via `tmux capture-pane`
- tty-backed muxml leaves refreshed from pane output
- public mutations/capture flow exposed through JSON-RPC/CLI/library helpers
- follow-tail stored as document/view metadata rather than a control-mode cursor

## Planned evolution

Later iterations should move toward a richer control-mode-backed adapter with:

- event parsing
- refresh/reconnect handling
- normalized pane/window/session state snapshots
- lower-latency change observation than ad hoc command refreshes

Until that happens, this backend should be described plainly as
**command-backed** rather than implying an event-driven tmux mirror.

This document exists to make the current cutline explicit rather than
overstating backend sophistication.
