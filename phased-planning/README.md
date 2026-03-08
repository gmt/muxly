# roadmap

This directory breaks the larger muxly roadmap into smaller execution tranches.

`done.md` summarizes milestones that are already complete. The remaining phase
files track major work that is still open or still useful as a reference point.

## How to use these files

- treat each phase file as a self-contained execution target
- prefer completing one phase at a time
- use acceptance criteria and test notes in each phase file as the completion
  checklist
- update repo-visible docs and tests as you complete each phase

## Shared doctrine across all phases

Every phase should preserve the project-wide rules documented in
`docs/trine.md`, especially:

- function over form
- ordinary-client viewer discipline
- append-oriented behavior as the common-case bias
- TTYs as sources rather than serialized process state
- aggressive testing, including slow/emulator-heavy paths when useful
- cross-platform realism over fake uniformity

## Current layout

- `done.md` for completed phase 1 and 2 work
- `phase-3-ordinary-clients-and-bindings.md`
- `phase-4-control-mode-and-state-recovery.md`
- `phase-5-keybindings-menu-nvim.md`

## Current status snapshot

Phase 1 and 2 are summarized in `done.md`. Remaining large work is concentrated
in:

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

## Why this exists

Smaller phase files are easier to keep accurate than one large catch-all
roadmap.
