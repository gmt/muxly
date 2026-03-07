# phase 2 — tmux, sources, and views

## Status

Closed on this branch.

Completed work has been moved to `done.md` so this file can focus on unfinished
phase-2 work only. There is no unfinished in-scope phase-2 work left here.

## Remaining work

None.

## Closure notes

Phase 2 is considered complete on the current branch because it now leaves
behind:

- mixed-source document creation and inspection through public APIs
- tmux mutation flows exercised end-to-end through the public protocol/CLI
- explicit follow-tail semantics as a stored node preference
- synthetic muxml editing coverage alongside live/file-backed nodes
- explicit shared-document view-state semantics reflected by `muxview`
- a documented/testable drill-in precursor model with breadcrumb/path and
  back-out cues
- aligned docs/examples/tests that describe the implementation truthfully

## Handoff notes

Related work that still exists but does **not** belong to an open phase 2 is
owned by later phases:

- phase 4
  - full tmux control-mode/state recovery
  - reconnect/recovery after daemon or tmux drift
  - authoritative tmux snapshot rebuilding
  - persistent rehydration semantics
- phase 5
  - keybinding analysis engine
  - menu/modeline projection
  - deeper viewer interaction work beyond the current phase-2 orientation model
  - Neovim integration
