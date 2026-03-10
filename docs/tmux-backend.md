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

## Initial backend-to-TOM contract

As phase 4 grows beyond one-shot command calls, tmux should project into the
TOM according to a small explicit contract rather than through ad hoc
attachment shortcuts:

- a tmux session projects to a TOM `subdocument`
- a tmux window projects to a TOM `subdocument` nested under its session
- a tmux pane projects to a TOM `tty_leaf` nested under its window

This is intentionally the minimal stable object layer. It says nothing yet
about whether tmux split layout should eventually become first-class TOM
structure. For now, tmux layout remains backend/layout metadata rather than
part of muxly's core object taxonomy.

Identity should also stay explicit:

- tmux `session_name` and `session_id` are backend identity anchors for session
  projection
- tmux `window_id` is the backend identity anchor for window projection
- tmux `pane_id` is the backend identity anchor for pane projection
- muxly node ids remain muxly-local, but reconciliation should preserve them
  when the same tmux object is still present across rebuild

This keeps tmux useful as a source of truth without letting tmux's internal
layout ontology become muxly's constitution by accident.

## Current proof path

The current repo-local proof path for tmux-backed behavior is:

- `python3 tests/integration/tmux_adapter_test.py` for the main daemon/CLI/view
  flow
- `./examples/tty/basic-nesting/run.sh` for one small nested live-TTY demo

## Next implementation tranche

Phase 4 should start by making a real control-mode attachment and parser layer
exist as a distinct backend slice before attempting reconnect or richer viewer
claims.
