# muxly

`muxly` is a Zig-first tmux-powered terminal window manager built around a live
**TOM** (Terminal Object Model) with a serializable **muxml** representation.

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

- **The daemon maintains a TOM.**
  tmux sessions, windows, and panes are backend projections into a richer
  terminal object model that can be serialized as muxml.
- **TTYs are sources, not serialized program state.**
  muxly serializes derived document/view state, not arbitrary process internals.
  The durable artifact contract for dead/frozen terminal-backed nodes is
  intentionally separate: muxly should distinguish recoverable live sources,
  captured text/history artifacts, and captured surface artifacts instead of
  treating tmux scrollback as the whole policy.
- **Append mode matters.**
  Terminal and log-like regions usually grow downward, so append-friendly
  operations and tail-following views are first-class.
- **The current cutline keeps semantics explicit.**
  Follow-tail is currently a stored node preference, shared view root/elision
  state lives in the daemon-backed document, and tmux interaction is currently
  a hybrid of command-backed mutation/capture plus control-mode invalidation
  even though tmux session/window/pane projection and snapshot-backed list
  queries are now real inside the daemon.
- **The reference viewer uses public surfaces.**
  `muxview` should consume the same public surfaces as any third-party tool,
  stay attached to a live TOM stage by default, and keep snapshot mode explicit
  when a one-shot frame is the right tool.

## Binaries

- `muxlyd` — daemon
- `muxly` — automation-first CLI
- `muxview` — reference viewer / universal viewer
- `libmuxly` — shared library with a C ABI

## Getting started

```sh
zig build
zig build test
zig build docs
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
./zig-out/bin/muxview --snapshot
```

When launched in a terminal, `muxview` now attaches live by default. Press `q`
to leave the attached viewer session.

## Documentation

- `docs/architecture.md`
- `docs/trine.md`
- `docs/tom.md`
- `docs/platform-matrix.md`
- `docs/muxml.md`
- `docs/terminal-artifacts.md`
- `docs/protocol.md`
- `docs/tmux-backend.md`
- `docs/viewer-architecture.md`
- `docs/keybinding-model.md`
- `docs/neovim-integration.md`
- `docs/demos.md`

Generated Zig API docs can be built with:

```sh
zig build docs
```

They are installed under `zig-out/docs/api/`.

## Roadmap

Milestones and remaining major work live in `phased-planning/`:

- `changelog.md` summarizes completed phase 1, 2, and 3 work
- `phase-4-control-mode-and-state-recovery.md` covers the tmux backend upgrade
- `phase-5-keybindings-menu-nvim.md` covers deferred UX and integration work
- `phase-6-terminal-capture-and-persistence.md` covers durable terminal
  artifact semantics

## Examples

- `examples/README.md` — example taxonomy and intended structure
- `examples/artifacts/` — durable text/surface artifact witnesses for Phase 6
- `examples/artifacts/freeze-demo/` — runnable `node.freeze` text/surface demo
- `examples/artifacts/c-freeze/` — C `libmuxly` artifact freeze playbook
- `examples/artifacts/python-freeze/` — Python `ctypes` artifact freeze playbook
- `examples/artifacts/zig-freeze/` — Zig `libmuxly` artifact freeze playbook
- `examples/tom/zig/` — Zig "hello TOM" playbook
- `examples/tom/c/` — C "hello TOM" playbook
- `examples/tom/python/` — Python "hello TOM" playbook
- `examples/tty/basic-nesting/` — live attached stage with several active
  tty-backed regions

The playbook wrappers use dedicated example sockets by default so they can be
run locally without colliding with a long-lived `muxlyd` on `/tmp/muxly.sock`.
They also target `zig build example-deps` so the examples only build the daemon,
CLI, shared library, and header they actually need.

## Phase 3 C ABI Surface

The intentional phase-3 `libmuxly` surface is:

- a handle-based client lifecycle in `muxly.h`
- document/graph/status inspection helpers
- synthetic node/view editing helpers
- selected tmux helpers for capture and session/pane creation
- shipped C / Zig / Python examples that use only that documented surface

Current daemon-lifecycle posture:

- `libmuxly` is currently a client library for an external `muxlyd`
- library calls expect a daemon to already be listening on the chosen socket
- the example/playbook wrappers may auto-launch `muxlyd`, but the library does
  not currently do so on its own
- a more transparent downstream-consumer experience likely wants an explicit
  daemon discovery/autostart policy rather than leaving that behavior implicit

The default verification path for the shipped binding examples is:

```sh
zig build example-deps
python3 scripts/run_binding_examples.py
```

The default verification path for the shipped terminal-artifact examples is:

```sh
python3 scripts/run_artifact_examples.py
```
