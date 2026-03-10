# roadmap

This directory breaks the larger muxly roadmap into smaller execution tranches.

`changelog.md` summarizes milestones and completed slices that are already
closed. The remaining phase files track major work that is still open or still
useful as a reference point.

## How to use these files

- treat each phase file as a self-contained execution target
- prefer completing one phase at a time
- use acceptance criteria and test notes in each phase file as the completion
  checklist
- update repo-visible docs and tests as you complete each phase

## What makes a phase file useful

Phase files should be written for execution, not just for orientation.

Each active phase file should make the following obvious to a contributor or
agentic harness:

- what is already true in the repo right now
- what is still missing
- which slice should be done first
- which files are likely to move
- how to prove the slice is complete before claiming progress

When a phase file stays at the "good vibes" level, it becomes easy to produce
plausible-looking partial work without actually closing the named gap.

## Preferred phase-file shape

For active work, prefer keeping these sections up to date:

- `Goal`
- `In scope`
- `Out of scope`
- `Acceptance criteria`
- `Repo baseline`
- `Remaining gaps`
- `Execution order`
- `Per-slice proof`
- `Exit condition`

The point is not rigid formatting. The point is leaving behind a plan that an
unfamiliar contributor can execute in the right order without reverse
engineering project intent from scattered docs and code.

## Shared doctrine across all phases

Every phase should preserve the project-wide rules documented in
`docs/trine.md`, especially:

- function over form
- the viewer uses the same public surfaces as other clients
- append-oriented behavior as the common-case bias
- TTYs as sources rather than serialized process state
- aggressive testing, including slow/emulator-heavy paths when useful
- cross-platform realism over fake uniformity

## Current layout

- `changelog.md` for completed phase work and closed slice checkpoints
- `phase-4-control-mode-and-state-recovery.md`
- `phase-5-keybindings-menu-nvim.md`

## Current status snapshot

Phase 1, 2, and 3 are summarized in `changelog.md`. Remaining large work is
concentrated in:

- richer tmux control-mode/state recovery
- keybinding analysis engine
- menu/modeline projection
- deeper viewer UX
- Neovim integration

## Testing expectation

Future phases should continue to treat testing as first-class work:

- unit tests for pure logic
- integration tests for daemon/protocol/tmux behavior
- cross-target compile checks
- runnable examples/demos that users and contributors can use as living proofs

## Agentic harness doctrine

When an agent works from these phase files, it should prefer the smallest
slice that closes one named gap and leaves behind all of:

- code or doc changes that close the named gap
- updated proof instructions or automated coverage
- repo-visible evidence in docs/examples/tests rather than private notes

When a phase starts with a framing or discoverability slice, keep that slice
short and use it to make the first substantive implementation tranche obvious.
Do not spend multiple rounds polishing docs if the real blocker is still an
implementation split elsewhere in the repo.

When later slices depend on a stable shared surface, sequence them after that
surface is clarified. Do not expand examples, bindings, or convenience layers
against a contract that the preceding implementation slice is still defining.

Do not mark a phase complete because the implementation "feels close". A phase
should close only when the acceptance criteria and proof steps are true in the
repository as checked-in artifacts.

## Why this exists

Smaller phase files are easier to keep accurate than one large catch-all
roadmap.
