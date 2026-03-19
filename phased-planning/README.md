# roadmap

This directory is not a pile of equally-live phase files anymore. Each doc
should clearly be one of:

- active follow-on work
- deferred backlog/reference
- archived implemented material

## Triage rule

Keep something active only when all of the following are true:

- it directly advances muxly's core objective: terminal session embedding and
  management, nested hierarchy, retargeting/rooting/elision, or truthful live
  backend behavior
- the remaining gap is concrete enough to execute and verify
- the repo does not already materially implement the named scope
- the work is important enough to deserve a checked-in execution doc rather
  than a vague future note

Archive work that already landed. Defer work that may still be interesting but
is not on the current critical path. Dismiss any framing that is stale,
contradictory, or too vague to execute honestly.

## How to use these files

Active docs should make five things obvious:

- repo baseline
- remaining gaps
- execution order
- verification
- exit condition

Deferred docs should not pretend to be execution-ready. They should name the
current scaffolding, why the work is deferred, and what would need to be true
before reactivating it.

Archived docs should point at the checked-in evidence that closed their scope
and should not quietly drift back into the active roadmap just because nearby
future work still exists.

## Shared doctrine across active phases

Every active phase should preserve the project-wide rules documented in
`docs/trine.md`, especially:

- function over form
- the viewer uses the same public surfaces as other clients
- append-oriented behavior as the common-case bias
- TTYs as sources rather than serialized process state
- aggressive testing, including slow/emulator-heavy paths when useful
- cross-platform realism over fake uniformity

## Current layout

- `changelog.md` records completed milestones and archived first-pass
  completions
- `phase-4-control-mode-and-state-recovery.md` is substantially complete:
  projected identity uses `backendId`, one incremental event family is shipped,
  and rebuild remains the correctness backstop
- `phase-5-keybindings-menu-nvim.md` is a deferred backlog/reference document,
  not an execution target as one umbrella
- `phase-6-terminal-capture-and-persistence.md` is archived first-pass-complete
  material for the terminal artifact contract

## Current status snapshot

Phase 4 work is substantially complete:

- projected tmux identity uses `backendId` instead of marker-content
- `window-renamed` notifications apply incrementally when confidence is high
- `window-close` notifications trigger targeted subtree removal
- rebuild remains the correctness backstop for everything else
- docs, capabilities, and backend description all agree

Interactive viewer work has landed:

- `muxview` now provides keyboard-driven hierarchy traversal
- region selection, drill-in/back-out, elide/expand, follow-tail toggling
- focused tty interaction mode that forwards input to the selected pane
- mouse-driven region targeting via SGR mouse protocol
- viewer-owned status bar with mode, selection, and scope indicators

Deferred work remains documented, but not active:

- bindings analysis
- menu/modeline projection
- Neovim integration

Archived implemented material:

- first-pass terminal artifact contract
- `node.freeze` public seam
- witness artifacts and verification paths around captured text/surface
  payloads

## Not promoted right now

Some seams may still matter later, but they are not being promoted into new
active phase docs in this cleanup:

- deeper per-viewer local view state (currently shared document state)
- daemon discovery/autostart policy
- cross-platform Windows transport

Those can return later if they become concrete enough to deserve their own
narrowly-scoped follow-on docs.

## Testing expectation

Future active phases should continue to leave behind:

- unit tests for pure logic
- integration tests for daemon/protocol/tmux behavior
- runnable examples or demos when they materially prove the claimed behavior

## Why this exists

A smaller and harsher roadmap is easier to keep honest than a long list of
future intentions.
