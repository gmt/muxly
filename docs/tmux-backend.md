# tmux backend

The current muxly tmux integration is intentionally thin and command-backed.

## Current state

- session creation via `tmux new-session`
- pane splitting via `tmux split-window`
- pane capture via `tmux capture-pane`
- tty-backed content refreshed from pane output
- public mutations/capture flow exposed through JSON-RPC/CLI/library helpers
- follow-tail stored as document/view metadata rather than a control-mode cursor
- tmux mutations now project into TOM subtrees instead of only attaching loose
  tty leaves:
  - session `subdocument`
  - window `subdocument`
  - pane `tty_leaf`
- `session.list`, `window.list`, and `pane.list` are now backed by normalized
  tmux pane snapshots rather than by scraping whatever tty leaves happen to be
  present in the document
- `session.create`, `window.create`, and `pane.split` now return the projected
  pane node inside that session/window subtree
- `pane.close` prunes empty projected tmux containers instead of leaving empty
  shells behind

## Planned evolution

Later iterations should move toward a richer control-mode-backed adapter with:

- event parsing
- refresh/reconnect handling
- normalized pane/window/session state snapshots
- lower-latency change observation than ad hoc command refreshes
- incremental event application on top of the current snapshot/reconcile path

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

The next substantive tranche is no longer "make control mode exist at all."
That groundwork now exists. The remaining work is to move from snapshot-backed
rebuild and projected tmux subtrees toward live event application, drift
handling, and reconnect.
