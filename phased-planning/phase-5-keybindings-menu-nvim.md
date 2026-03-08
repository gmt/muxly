# phase 5 — keybindings, menus, and Neovim

## Goal

Move beyond the core muxml/tmux platform into the more ambitious UX and
integration features originally envisioned.

## In scope

- keybinding conflict analysis engine
- library/client APIs, backed by server methods, for keybinding
  inspection/validation/proposal
- modeline/menu schemas and capability-gated projection
- KDE/macOS menu adapter work
- Neovim adapter boundary and initial attach/detach behavior

## Out of scope

- pretending all platform projections are production-ready from day one
- overpromising transparent Neovim pane semantics before runtime proof exists

## Acceptance criteria

- keybinding methods stop returning structured unsupported errors
- menu/modeline methods stop returning structured unsupported errors
- Neovim attach/detach methods stop returning structured unsupported errors
- docs and capability reporting distinguish scaffolded vs fully working support

## Current status

Scaffolded only. Structured unsupported-capability errors are present so future
clients get stable behavior while these systems remain deferred.
