# phased planning

This directory breaks the larger muxly roadmap into smaller execution tranches
that are easier for humans and long-running agents to consume.

`done.md` archives work from phases that are already closed on the current
branch. Active phase files should prefer tracking only unfinished work and
handoff notes.

## How to use these files

- treat each phase file as a self-contained execution target
- prefer completing one phase at a time
- use acceptance criteria and test notes in each phase file as the handoff/check
  list
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

## Suggested sequence

0. `done.md` for closed work already completed on the branch
1. `phase-1-foundation-and-protocol.md`
2. `phase-2-tmux-sources-and-views.md`
3. `phase-3-ordinary-clients-and-bindings.md`
4. `phase-4-control-mode-and-state-recovery.md`
5. `phase-5-keybindings-menu-nvim.md`

## Current status snapshot

Phases 1 and 2 are closed and summarized in `done.md`. Remaining large work is
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
- runnable examples/demos that future agents and users can use as living proofs

## Why this exists

The previous single large roadmap was useful operationally, but smaller phase
files are a better fit for incremental execution and future agent handoff.
