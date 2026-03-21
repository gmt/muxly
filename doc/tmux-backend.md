# tmux backend

The current muxly tmux integration is a hybrid backend:

- command-backed for mutations and direct capture
- control-mode-backed for notification-driven invalidation
- snapshot-backed for projected state rebuild
- best-effort live append for known follow-tail panes

That is materially beyond the old "one-shot tmux subprocesses only" cutline,
but it is still not a fully event-driven tmux mirror.

## Current state

- session creation via `tmux new-session`
- pane splitting via `tmux split-window`
- pane capture via `tmux capture-pane`
- request-time tty-backed content refresh from pane output
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
- a lazy control-mode attachment can now notice state-changing tmux
  notifications and trigger snapshot-backed projection rebuild for known tmux
  session subtrees on the next server pump
- structured `%output` / `%extended-output` notifications are now parsed, and
  known follow-tail pane leaves can append best-effort live output directly
  before the snapshot-rebuild fallback path catches up
- if the control-mode attachment exits unexpectedly, the backend now degrades to
  request-time snapshot rebuild for known tmux projections until a control-mode
  reattach succeeds
- focused control-mode verification now covers reattaching to surviving tmux state
  after the originally attached session exits

## Current cutline

The repo currently reports this backend mode as
`hybrid-control-invalidation`.

That should be read as:

- tmux mutations and explicit capture still go through tmux commands
- control mode is real and long-lived enough to notice drift and output
- known tmux projections can be invalidated and rebuilt intentionally
- some output can append live for follow-tail panes before rebuild catches up
- `window-renamed` notifications are applied incrementally when confidence is
  high, avoiding a full rebuild for title-only metadata changes
- `window-close` notifications trigger targeted subtree removal before the
  rebuild path catches up
- rebuild remains the explicit correctness backstop for all other topology
  changes and for cases where incremental application fails

That should **not** be read as:

- every tmux change is applied incrementally into the TOM
- every control-mode event is trusted as final truth
- muxly is already a perfect event-driven mirror of tmux

This document exists to make the current cutline explicit rather than
overstating backend sophistication.

## Initial backend-to-TOM contract

As the tmux backend grows beyond one-shot command calls, tmux should project
into the TOM according to a small explicit contract rather than through ad hoc
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
- projected session and window identity is carried in the non-renderable
  `backendId` field on TOM nodes, keeping backend bookkeeping out of
  user-visible content and rendering

This keeps tmux useful as a source of truth without letting tmux's internal
layout ontology become muxly's constitution by accident.

The current target-scope contract is intentionally narrow:

- tmux-backed methods remain rooted to the root document `/`
- non-root document targets should be rejected by client/library validation when
  a document path is present
- the server still rejects the same calls for raw callers that bypass client
  validation
- tmux `sessionName`, `target`, and `paneId` values remain backend-scoped ids,
  not TOM node targets and not TRDs

## Current verification path

The current repo-local verification path for tmux-backed behavior is:

- `zig build test` for parser/control-mode coverage, explicit
  snapshot-to-projection rebuild coverage from external tmux state, and
  control-mode reattach coverage
- `python3 tests/integration/tmux_adapter_test.py` for the main daemon/CLI/view
  flow
- `./examples/tty/basic-nesting/run.sh` for one small nested live-TTY demo

## Active follow-on

The next substantive tranche is no longer "make control mode exist at all."
That groundwork already exists. The remaining phase-4 work is narrower:

- make the default-backend cutline explicit and consistent across docs and
  capabilities
- add one narrow family of incremental topology or metadata updates on top of
  the rebuild path
- make confidence rules clearer for when to trust live events versus rebuild

In other words, the current work is about default-path credibility and cleaner
identity/recovery semantics, not about pretending the daemon must immediately
become a perfect event-by-event tmux replica.

The following phase-4 items have been completed:

- projected tmux identity now uses `backendId` instead of marker strings in
  node content
- `window-renamed` notifications are applied incrementally when possible
- `window-close` notifications trigger targeted subtree removal
- rebuild remains the correctness backstop for everything else
