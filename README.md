# muxly

`muxly` is a Zig-first tmux-powered terminal window manager built around a
serializable **muxml** document model.

## Status

This repository has a working implementation centered on:

- a `muxlyd` daemon
- a public JSON-RPC control protocol
- a `muxview` reference viewer that uses the same public surfaces as other
  clients
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
- **The current cutline keeps semantics explicit.**
  Follow-tail is currently a stored node preference, shared view root/elision
  state lives in the daemon-backed document, and tmux interaction is still
  command-backed in this slice.
- **The reference viewer uses public surfaces.**
  `muxview` should consume the same public surfaces as any third-party tool.

## Binaries

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

Then, in another shell:

```sh
./zig-out/bin/muxlyd
./zig-out/bin/muxly capabilities get
./zig-out/bin/muxly document get
./zig-out/bin/muxly session create demo "sh -lc 'printf hello\\n; sleep 30'"
./zig-out/bin/muxly pane split %0 right "sh -lc 'printf split\\n; sleep 30'"
./zig-out/bin/muxly pane send-keys %0 "echo from-cli" --enter
./zig-out/bin/muxly pane scroll %0 -5 -1
./zig-out/bin/muxview
```

## Documentation

- `docs/architecture.md`
- `docs/trine.md`
- `docs/platform-matrix.md`
- `docs/muxml.md`
- `docs/protocol.md`
- `docs/tmux-backend.md`
- `docs/viewer-architecture.md`
- `docs/keybinding-model.md`
- `docs/neovim-integration.md`
- `docs/demos.md`

## Roadmap

Milestones and remaining major work live in `phased-planning/`:

- `done.md` summarizes completed phase 1 and 2 work
- `phase-3-library-viewer-cli-and-bindings.md` covers library API, viewer, CLI,
  and binding cleanup
- `phase-4-control-mode-and-state-recovery.md` covers the tmux backend upgrade
- `phase-5-keybindings-menu-nvim.md` covers deferred UX and integration work

## Examples

- `examples/zig/basic_client.zig`
- `examples/c/basic_client.c`
- `examples/python/basic_client.py`
