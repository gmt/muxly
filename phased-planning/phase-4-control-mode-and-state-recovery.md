# phase 4 - active follow-on: tmux backend credibility and recovery

## Status

This file no longer tracks the whole history of control-mode bring-up.
Control-mode attachment, parser isolation, snapshot-backed reconciliation, lazy
invalidation, reconnect/reattach coverage, and first-pass live append already
exist and are summarized in `changelog.md`.

Phase 4 stays open only for the narrower remaining gap between the current
hybrid backend and a default backend path that feels deliberate instead of
provisional.

## Goal

Make the current hybrid tmux backend credible as muxly's default live backend
path without pretending the daemon must become a perfect event-by-event tmux
mirror or that every command-backed path must disappear.

This phase closes when:

- the default backend cutline is explicit in docs, capabilities, and tests
- one narrow family of structure changes can apply incrementally without
  forcing subtree rebuild every time
- rebuild remains the correctness backstop with explicit trust rules
- projected session/window identity no longer depends on marker strings stored
  in node content
- reconnect/drift behavior is documented and tested as a first-class path

## In scope

- default-backend definition for `hybrid-control-invalidation`
- narrow incremental event application on top of snapshot-backed rebuild
- explicit trust/fallback rules for event application versus
  invalidation/rebuild
- reconnect/drift semantics for already-projected tmux subtrees
- cleanup of the `tmux-session:` / `tmux-window:` marker-content identity hack
- docs, tests, and examples needed to make that cutline honest

## Out of scope

- removing every command-backed mutation/capture path for purity
- full event-driven mirroring of every tmux detail
- viewer-local navigation or retargeting UX work
- bindings, menu, or Neovim work
- persistence/rehydrate follow-on beyond the current artifact contract
- speculative tmux feature parity unrelated to default-path credibility

## Acceptance criteria

- `docs/tmux-backend.md`, this file, `README.md`, and `capabilities.get` all
  describe the same default backend cutline
- at least one narrow structure-changing event family is applied incrementally
  into TOM/projection state with focused tests
- the rebuild fallback remains explicit and documented for low-confidence cases
- projected session/window identity survives rebuild without storing backend
  marker strings in renderable `Node.content`
- end-to-end verification catches regressions in attach, rebuild, reconnect,
  and fallback behavior

## Repo baseline

The repo already has much more than the original phase title implies:

- `src/daemon/tmux/control_mode.zig` and `src/daemon/tmux/parser.zig` provide a
  real control-mode attachment path and structured parser coverage
- tmux session/window/pane projection into the TOM is real:
  - session -> `subdocument`
  - window -> nested `subdocument`
  - pane -> nested `tty_leaf`
- `session.list`, `window.list`, and `pane.list` now read from normalized tmux
  pane snapshots
- snapshot-to-TOM reconciliation already exists and is used as the correctness
  path for projected tmux state
- lazy control-mode invalidation and reattach behavior already exist for known
  tmux projections
- `%output` / `%extended-output` parsing already supports best-effort live
  append for known follow-tail panes
- `capabilities.get` already reports `tmuxBackendMode =
  hybrid-control-invalidation`
- `docs/tmux-backend.md` already describes the backend as hybrid rather than
  purely command-backed
- `src/daemon/tmux/reconcile.zig` still writes `tmux-session:` and
  `tmux-window:` markers into projected node content to keep identity stable
  across rebuild

## Remaining gaps

What still keeps this phase open:

- "default backend" still means different things in different docs and code
  comments
- topology/state truth still mostly advances by invalidating and rebuilding
  known projected session subtrees
- there is no narrow explicit incremental topology mutation path yet
- trust rules for when to accept live control-mode info versus rebuild are
  still implicit
- the marker-content identity seam leaks backend bookkeeping into document
  content and requires special-case hiding in rendering/projection paths
- verification proves the current hybrid path works, but the closure bar for
  "default" is still fuzzy

## Execution order

### Slice 1 - default-path definition and identity contract

Before more implementation, pin down what "default backend" means and choose a
non-content carrier for projected tmux identity.

Likely touchpoints:

- `docs/tmux-backend.md`
- `src/core/capabilities.zig`
- `src/daemon/tmux/reconcile.zig`
- document/source/metadata types under `src/core/`

Acceptance bar:

- one explicit statement exists for what `hybrid-control-invalidation`
  promises
- one explicit carrier for projected session/window identity is chosen that
  does not rely on renderable node content

### Slice 2 - projected identity cleanup

Replace the `tmux-session:` / `tmux-window:` marker-content trick with the
chosen identity carrier.

Priorities:

- preserve muxly node ids across rebuild when the tmux object still exists
- keep backend bookkeeping out of user-visible content
- avoid introducing a larger metadata taxonomy than the phase actually needs

Acceptance bar:

- projected session/window identity survives rebuild without the marker-content
  seam
- no projection code needs to hide synthetic marker strings from normal
  rendering

### Slice 3 - narrow incremental topology events

Add one deliberately small family of incremental control-mode-driven updates on
top of the existing snapshot/rebuild path.

Start with high-confidence topology or metadata changes rather than trying to
make every byte of pane output authoritative. Good candidates include one or
more of:

- pane add/remove
- window add/remove
- rename/title updates

Priorities:

- keep rebuild as the correctness backstop
- make trust versus rebuild rules explicit
- prove value with one event family before widening the surface

Acceptance bar:

- at least one family above applies incrementally into the projected TOM
- tests cover both the incremental happy path and the rebuild fallback

### Slice 4 - reconnect truthfulness and docs close-out

Once identity and one incremental family are real, harden the repo story around
the backend that actually exists.

Likely touchpoints:

- `tests/integration/tmux_adapter_test.py`
- control-mode lifecycle tests under `tests/unit/`
- `docs/tmux-backend.md`
- `README.md`
- capability reporting if semantics changed

Acceptance bar:

- repo docs define the backend default path plainly
- tests would catch regressions in control attachment, incremental updates,
  fallback rebuild, and reconnect
- the phase can close without pretending the backend is a perfect tmux mirror

## Per-slice verification

- Slice 1: docs plus focused unit coverage around any new identity carrier
- Slice 2: unit coverage for reconcile/identity behavior plus one
  projection/render sanity check
- Slice 3: focused parser/store tests and one integration path covering event
  application plus fallback rebuild
- Slice 4: `zig build test`, `python3 tests/integration/tmux_adapter_test.py`,
  and `./examples/tty/basic-nesting/run.sh` remain the authoritative repo-local
  checks

## Exit condition

Phase 4 closes when muxly can honestly call the current tmux path its default
live backend because:

- the cutline is documented consistently
- one narrow event family is applied incrementally when confidence is high
- rebuild remains the explicit correctness backstop when confidence is low
- reconnect/drift behavior is verified
- projected tmux identity no longer depends on marker strings in document
  content

## Current phase status

- earlier bring-up work is archived in `changelog.md`
- this file tracks only the remaining active follow-on
- Phase 4 overall: substantially complete

## Completed work (this follow-on)

- projected session/window identity now uses `backendId` on TOM nodes instead
  of synthetic marker strings in renderable `content`
- no projection or rendering code needs to hide synthetic markers
- `window-renamed` notifications are applied incrementally when confidence is
  high, avoiding full rebuild for title-only changes
- `window-close` notifications trigger targeted subtree removal
- rebuild remains the explicit correctness backstop for all other topology
  changes and low-confidence cases
- docs, capabilities, and backend description all describe the same
  `hybrid-control-invalidation` cutline with incremental event support
