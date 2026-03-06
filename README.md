# muxly

`muxly` is a Zig-first tmux-powered terminal window manager built around a
serializable **muxml** document model.

## Status

This repository is in active bootstrap. The first development slice focuses on:

- a `muxlyd` daemon
- a public JSON-RPC control protocol
- an ordinary-client `muxview` reference viewer
- a shared library / C ABI surface
- a muxml model that can mix:
  - TTY-backed live sources
  - monitored text files
  - static text files

## Core ideas

- **muxml is the primary object model.**
  tmux sessions, windows, and panes are backend projections into a richer
  document tree.
- **TTYs are sources, not serialized program state.**
  muxly serializes derived document/view state, not arbitrary process internals.
- **Append mode matters.**
  Terminal and log-like regions usually grow downward, so append-friendly
  operations and tail-following views are first-class.
- **The reference viewer is an ordinary client.**
  `muxview` should consume the same public surfaces as any third-party tool.

## Planned binaries

- `muxlyd` — daemon
- `muxly` — automation-first CLI
- `muxview` — reference viewer / universal viewer
- `libmuxly` — shared library with a C ABI

## Getting started

```sh
zig build
zig build test
zig build muxlyd
zig build muxly
zig build muxview
```

## Documentation

- `docs/architecture.md`
- `docs/platform-matrix.md`
- `docs/muxml.md`
- `docs/protocol.md`
- `docs/tmux-backend.md`
- `docs/viewer-architecture.md`
- `docs/keybinding-model.md`
- `docs/neovim-integration.md`
- `docs/demos.md`

## Examples

- `examples/zig/basic_client.zig`
- `examples/c/basic_client.c`
- `examples/python/basic_client.py`
