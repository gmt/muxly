# Neovim integration

Neovim integration is intentionally postponed beyond the first working muxly
slice.

## Direction

The most promising long-term path is to treat Neovim as an adapter-managed
source of first-class muxml entities instead of scraping terminal text alone.

That likely means:

- a daemon-side bridge/adaptor
- multigrid-aware event handling
- capability negotiation with a lightweight Neovim-side helper

## Current stance

- not implemented in the first execution tranche
- should remain capability-gated
- should avoid overpromising transparent pane semantics until runtime behavior
  is proven
