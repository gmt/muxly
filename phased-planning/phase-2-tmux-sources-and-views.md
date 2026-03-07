# phase 2 — tmux, sources, and views

## Goal

Turn muxly into a genuinely useful terminal/document system:

- tmux-backed live leaves
- monitored/static file leaves
- append-oriented capture and follow-tail behavior
- viewer-local root/elision/reset semantics
- practical tmux mutation coverage

## In scope

- session/window/pane operations
- pane capture / scroll / send-keys / resize / close
- file capture and follow-tail controls
- node editing for synthetic muxml nodes
- view set-root / clear-root / elide / expand / reset
- document/node/session/window/pane introspection

## Out of scope

- full control-mode/stateful tmux event engine
- generalized monitoring overlays
- full persistent snapshot/rehydration semantics

## Acceptance criteria

- integration tests prove mixed-source documents
- tmux mutation flow works end-to-end
- scroll/follow-tail/view transforms work via public APIs
- viewer reflects root/elision state

## Current branch status

Largely completed as a command-backed implementation. The biggest remaining gap
is replacing ad hoc tmux command polling with a richer control-mode-backed
state/recovery layer.
