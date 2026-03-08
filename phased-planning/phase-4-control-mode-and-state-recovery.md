# phase 4 — tmux control mode and state recovery

## Goal

Replace the current command-backed tmux layer with a more durable backend that
can observe state changes, reconnect cleanly, and keep muxml synchronized with
less polling and fewer blind spots.

## In scope

- tmux control-mode attachment
- event parsing
- session/window/pane snapshot rebuilding
- recovery after drift or reconnect
- richer pane/window/session listings
- tighter integration between backend state and muxml documents

## Out of scope

- keybinding analysis
- menu/modeline projection
- Neovim bridge

## Acceptance criteria

- daemon can rebuild muxml state from tmux without manual reattachment hacks
- event-driven changes are reflected in document state
- reconnect/recovery tests exist
- `docs/tmux-backend.md` reflects the richer architecture

## Current status

Not complete. Current implementation is intentionally command-backed and is the
largest remaining technical gap inside the core platform.
