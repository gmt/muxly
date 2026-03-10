# phase 4 — tmux control mode and state recovery

## Goal

Replace the current command-backed tmux layer with a more durable backend that
can observe state changes, reconnect cleanly, and keep muxml synchronized with
less polling and fewer blind spots.

This phase is complete when muxly can treat tmux as a recoverable live backend
rather than a pile of one-shot subprocess calls:

- the daemon can attach to tmux control mode and keep that attachment alive
- tmux state can be rebuilt from snapshots rather than from ad hoc leaf hacks
- live events can update the TOM without requiring manual capture refreshes
- drift and reconnect paths are explicit, testable, and documented

## In scope

- tmux control-mode attachment
- event parsing
- session/window/pane snapshot rebuilding
- recovery after drift or reconnect
- richer pane/window/session listings
- tighter integration between backend state and muxml documents
- tests and demos that prove the new backend behavior

## Out of scope

- keybinding analysis
- menu/modeline projection
- Neovim bridge
- viewer-local interaction polish unrelated to backend state truthfulness
- speculative tmux feature parity beyond what phase 4 needs for recovery

## Acceptance criteria

- daemon can rebuild muxml state from tmux without manual reattachment hacks
- event-driven changes are reflected in document state
- reconnect/recovery tests exist
- `docs/tmux-backend.md` reflects the richer architecture
- `capabilities.get` and repo docs stop describing the tmux backend as purely
  command-backed once the new control-mode path is the default

## Repo baseline

Phase 4 starts from a working but intentionally thin tmux integration:

- [src/daemon/tmux/client.zig](/home/greg/src/muxly/src/daemon/tmux/client.zig)
  shells out to `tmux` commands such as `new-session`, `split-window`,
  `capture-pane`, `resize-pane`, and `send-keys`.
- [src/daemon/state/store.zig](/home/greg/src/muxly/src/daemon/state/store.zig)
  refreshes TTY-backed leaves by recapturing pane content on demand rather than
  by processing a live tmux event stream.
- [src/daemon/tmux/control_mode.zig](/home/greg/src/muxly/src/daemon/tmux/control_mode.zig),
  [src/daemon/tmux/parser.zig](/home/greg/src/muxly/src/daemon/tmux/parser.zig),
  and adjacent tmux modules now provide a real control-mode attachment path,
  typed command blocks, and normalized parser coverage.
- [docs/tmux-backend.md](/home/greg/src/muxly/docs/tmux-backend.md) correctly
  describes the current backend as command-backed and intentionally modest.
- [tests/integration/tmux_adapter_test.py](/home/greg/src/muxly/tests/integration/tmux_adapter_test.py)
  already proves a fair amount of tmux-backed behavior:
  session creation, pane split/capture/resize/focus/send-keys/close, file
  sources, and scoped viewer rendering.
- tmux session/window/pane projection is now real in the repo:
  - a session projects to a `subdocument`
  - a window projects to a nested `subdocument`
  - a pane projects to a nested `tty_leaf`
  - tmux mutation flows return the projected pane node rather than a loose leaf
- `session.list`, `window.list`, and `pane.list` now read from normalized tmux
  pane snapshots rather than from document-accidental tty leaves.
- [examples/tty/basic-nesting/](/home/greg/src/muxly/examples/tty/basic-nesting)
  now gives the repo one small nested live-TTY demo, but it still renders a
  snapshot through the current screen-at-a-time `muxview`.

## Remaining gaps

What still keeps this phase from feeling complete:

- there is still no live event application into the TOM from control-mode
- tmux state truth is still rebuilt from command-era snapshot refreshes rather
  than from a durable event stream
- recovery after daemon restart, tmux drift, or reconnect is not a first-class
  path
- projection identity still uses a temporary marker-content trick on projected
  tmux containers
- the current proof stack exercises tmux-backed behavior, but it does not yet
  prove durable control-mode recovery

## Agentic-harness starting point

The right starting move for phase 4 is:

1. do a short Slice 1 framing pass to make the execution order and proof path
   explicit
2. treat Slice 2 as the first substantive implementation tranche
3. do not jump to reconnect logic before a normalized control-mode attachment
   and snapshot shape exist
4. use Slice 5 to harden proof around the new backend rather than as a detached
   cleanup pass

If an agent needs one sentence of direction, use this one:

> Do a short Slice 1 pass to make the control-mode proof path obvious, then
> move immediately into Slice 2 and treat normalized control-mode attachment and
> parsing as the first real code tranche of phase 4.

## Execution order

Work this phase in the following order. Avoid blending snapshot design,
reconnect policy, and user-facing proof into one undifferentiated backend push.

### Slice 1 — backend framing and proof path

Make the current cutline and the first real control-mode tranche obvious.

This slice is intentionally short. Its job is to stop phase 4 from reading like
"tmux but better somehow" and to leave behind one authoritative proof path for
the later slices.

Likely touchpoints:

- [phased-planning/phase-4-control-mode-and-state-recovery.md](/home/greg/src/muxly/phased-planning/phase-4-control-mode-and-state-recovery.md)
- [docs/tmux-backend.md](/home/greg/src/muxly/docs/tmux-backend.md)
- [docs/demos.md](/home/greg/src/muxly/docs/demos.md)

Target:

- phase 4 names the current baseline and first substantive slice explicitly
- docs state that the current backend is still command-backed
- one repo-visible proof path is named for the new backend as it comes online

Done when:

- a contributor can tell what is already true in the repo and what phase 4
  still needs to change
- the first real implementation slice is obvious from this file alone

### Slice 2 — control-mode attachment and parser isolation

Create a long-lived tmux control-mode connection and isolate the logic that
turns its output into normalized muxly-side events and snapshots.

Treat this as the first real implementation tranche of phase 4.

Likely touchpoints:

- `src/daemon/tmux/` modules adjacent to
  [client.zig](/home/greg/src/muxly/src/daemon/tmux/client.zig)
- [src/daemon/server.zig](/home/greg/src/muxly/src/daemon/server.zig)
- [src/daemon/state/store.zig](/home/greg/src/muxly/src/daemon/state/store.zig)
- tests for parser or control-mode line handling

Priorities:

- keep control-mode parsing isolated from TOM mutation at first
- normalize tmux session/window/pane identity and event shapes before wiring
  them into the document model
- leave the command-backed path available as a fallback until later slices make
  the replacement credible

Good sub-tranche boundaries:

- spawn and hold a control-mode subprocess
- parse line-oriented control-mode output into typed events
- normalize snapshot payloads for sessions/windows/panes

Target:

- the daemon can maintain a live control-mode attachment
- tmux output is parsed into muxly-owned event/snapshot structures
- parser and normalization logic are testable without a full daemon round-trip

Done when:

- there is a repo-visible control-mode attachment path
- normalized event/snapshot structures exist and are not just ad hoc strings
- unit or focused integration proof exists for the parser path

Current status:

- first-pass complete
- control-mode attachment, parser isolation, typed command blocks, and focused
  proof all exist in the repository

### Slice 3 — snapshot rebuild and TOM reconciliation

Use normalized tmux snapshots to rebuild muxly state intentionally instead of
depending on command-era leaf attachment shortcuts.

Likely touchpoints:

- [src/daemon/state/store.zig](/home/greg/src/muxly/src/daemon/state/store.zig)
- document/source mapping code under `src/core/`
- tmux identity mapping modules introduced in Slice 2
- [tests/integration/tmux_adapter_test.py](/home/greg/src/muxly/tests/integration/tmux_adapter_test.py)

Priorities:

- define how tmux sessions/windows/panes map into TOM nodes during rebuild
- preserve stable identity where practical instead of tearing down and
  recreating unrelated nodes blindly
- make `session.list`, `window.list`, and `pane.list` richer if the snapshot
  model naturally supports it

Good sub-tranche boundaries:

- build a session/window/pane snapshot model
- reconcile one snapshot into document state
- replace manual attach/rebuild hacks with snapshot-driven reconstruction

Recommended execution order inside Slice 3:

- `3a` — mapping contract
  Decide what tmux `session`, `window`, and `pane` become in the TOM, which
  fields are preserved as metadata, and which identities should remain stable
  across rebuild.
  First acceptance bar:
  one written backend-to-TOM mapping exists, and one concrete snapshot/example
  can be judged against it.
- `3b` — snapshot model
  Expand the normalized snapshot types introduced in Slice 2 so they carry the
  data reconciliation actually needs, without mutating TOM state yet.
  First acceptance bar:
  one normalized snapshot shape exists with enough fields to describe one
  session with one window and multiple panes.
- `3c` — rebuild and reconcile
  Teach the store to rebuild one tmux-backed subtree from snapshot truth
  instead of relying on command-era attachment shortcuts.
  First acceptance bar:
  one snapshot can deterministically rebuild one tmux-backed subtree in memory.
- `3d` — list and query alignment
  Make `session.list`, `window.list`, and `pane.list` reflect the richer
  snapshot-driven model where that falls out naturally.
  First acceptance bar:
  at least one list family is derived from snapshot-backed state rather than an
  ad hoc one-shot command result.
- `3e` — proof and example touch-up
  Update integration proof and affected live-TTY demos so snapshot rebuild is
  demonstrated as checked-in behavior rather than as a private implementation
  claim.
  First acceptance bar:
  one checked-in proof path demonstrates rebuild from snapshot truth.

Target:

- muxly can rebuild relevant TTY-backed state from tmux truth
- the TOM shape for tmux-backed nodes is the result of a deliberate
  reconciliation step, not one-off command callbacks
- list operations reflect the richer snapshot model

Done when:

- daemon restart or explicit rebuild can recover tmux-backed document state
- nested/live TTY examples and integration proof no longer depend on
  hand-maintained attachment assumptions

Current status:

- first-pass complete
- `3a`: first-pass complete
- `3b`: first-pass complete
- `3c`: first-pass complete
- `3d`: first-pass complete
- `3e`: first-pass complete
- the closed first-pass Slice 3 work is summarized in
  [phased-planning/changelog.md](/home/greg/src/muxly/phased-planning/changelog.md)

### Slice 4 — live event application, drift handling, and reconnect

Move from "can rebuild from snapshots" to "can stay correct while tmux keeps
moving."

Likely touchpoints:

- control-mode attachment lifecycle code from Slice 2
- store reconciliation code from Slice 3
- daemon startup/reconnect paths
- integration tests that simulate drift or reconnect

Priorities:

- apply control-mode events into the TOM incrementally when safe
- define when to trust incremental updates versus when to trigger snapshot
  rebuild
- make reconnect/drift policy explicit rather than magical

Good sub-tranche boundaries:

- incremental event application for a narrow event family
- drift detection / invalidation policy
- reconnect path that reattaches and rebuilds state

Current status:

- first-pass complete
- a lazy control-mode attachment now drains state-changing tmux notifications
  into snapshot-backed rebuild for already-projected tmux session subtrees
- control-mode exit now degrades explicitly to request-time snapshot rebuild
  for known projections until reconnect succeeds
- focused control-mode proof now shows reattachment to surviving tmux state
  after the attached session exits
- integration proof now covers external pane/window/session drift against that
  invalidation-and-rebuild path
- this is still invalidation plus rebuild, not yet fine-grained incremental
  pane/window/session mutation handling

Target:

- event-driven changes are reflected in document state without manual refresh
  calls for the common path
- reconnect after daemon or tmux disruption is a supported path
- fallback rebuild behavior is explicit when event application loses confidence

Done when:

- a tmux-backed document can survive reconnect or drift through documented
  recovery behavior
- the control-mode path is credible as the default backend rather than a lab
  experiment

### Slice 5 — proof hardening and docs close-out

Strengthen proof around the new backend and update the docs to match the new
truth.

Likely touchpoints:

- [tests/integration/tmux_adapter_test.py](/home/greg/src/muxly/tests/integration/tmux_adapter_test.py)
- [examples/tty/](/home/greg/src/muxly/examples/tty/)
- [docs/tmux-backend.md](/home/greg/src/muxly/docs/tmux-backend.md)
- [docs/demos.md](/home/greg/src/muxly/docs/demos.md)
- capability reporting if backend semantics changed

Priorities:

- keep one strong end-to-end tmux proof path as the main backend check
- extend examples only where they demonstrate the new backend value clearly
- update backend docs and capability notes so they stop understating or
  overstating reality

Target:

- reconnect/recovery proof is checked in and runnable
- docs describe the backend that actually exists
- at least one repo-local TTY example demonstrates value from the richer
  backend rather than from static command-backed snapshots alone

Done when:

- the proof stack would catch a regression in control-mode attach, rebuild, or
  reconnect behavior
- repo docs and examples describe the new backend plainly

Current status:

- first-pass complete
- capability and viewer surfaces now report the backend as
  `hybrid-control-invalidation` instead of `command-backed`
- `zig build test` now covers parser/control-mode attachment, snapshot rebuild,
  and control-mode reattach
- the main integration proof covers external pane/window/session drift against
  the invalidation-and-rebuild path
- backend docs and demos now describe the hybrid cutline plainly

## Per-slice proof

Use the strongest proof that matches the slice:

- Slice 1:
  docs and phase-file updates only
- Slice 2:
  parser-focused unit tests plus one small integration proof that the daemon
  can hold a control-mode attachment
- Slice 3:
  integration proof that snapshot rebuild reconstructs tmux-backed state
- Slice 4:
  integration proof that reconnect or drift recovery restores correct state
- Slice 5:
  repo-local proof commands documented in docs plus updated integration/demo
  flows

The current baseline proof that later slices should evolve rather than replace
is:

- `zig build`
- `zig build test`
- `python3 tests/integration/tmux_adapter_test.py`
- the live TTY demo(s) under [examples/tty/](/home/greg/src/muxly/examples/tty/)

## Exit condition

Phase 4 closes when:

- tmux control mode is the default durable backend path
- muxly can rebuild and recover tmux-backed state intentionally
- reconnect/drift handling is proven in repo-local artifacts
- `docs/tmux-backend.md` and related demo docs describe that stronger backend
  accurately

Until then, this phase should remain open even if the backend "feels close."

Current phase status:

- Slice 1: first-pass complete
- Slice 2: first-pass complete
- Slice 3: first-pass complete and summarized in
  [phased-planning/changelog.md](/home/greg/src/muxly/phased-planning/changelog.md)
- Slice 4: first-pass complete
- Slice 5: first-pass complete
- Phase 4 overall: still open for deeper event-driven/default-backend work
