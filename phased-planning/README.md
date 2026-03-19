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
- `phase-4-control-mode-and-state-recovery.md` is the only active follow-on
  phase right now
- `phase-5-keybindings-menu-nvim.md` is a deferred backlog/reference document,
  not an execution target as one umbrella
- `phase-6-terminal-capture-and-persistence.md` is archived first-pass-complete
  material for the terminal artifact contract

## Current status snapshot

Active work is currently concentrated in one area:

- tmux backend default-path credibility
- narrow incremental event application where confidence is high
- explicit reconnect/drift fallback rules
- cleanup of projected tmux identity hacks

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

- deeper viewer UX
- daemon discovery/autostart policy

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
