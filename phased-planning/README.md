# phased planning

This directory breaks the larger muxly roadmap into smaller execution tranches
that are easier for humans and long-running agents to consume.

## How to use these files

- treat each phase file as a self-contained execution target
- prefer completing one phase at a time
- use acceptance criteria and test notes in each phase file as the handoff/check
  list
- update repo-visible docs and tests as you complete each phase

## Suggested sequence

1. `phase-1-foundation-and-protocol.md`
2. `phase-2-tmux-sources-and-views.md`
3. `phase-3-ordinary-clients-and-bindings.md`
4. `phase-4-control-mode-and-state-recovery.md`
5. `phase-5-keybindings-menu-nvim.md`

## Current status snapshot

The current branch has already completed most of phases 1-3 and partially
covers phase 2 extras. Remaining large work is concentrated in:

- richer tmux control-mode/state recovery
- keybinding analysis engine
- menu/modeline projection
- deeper viewer UX
- Neovim integration

## Why this exists

The previous single large roadmap was useful operationally, but smaller phase
files are a better fit for incremental execution and future agent handoff.
