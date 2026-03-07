# completed phase work

This file archives work that is complete on the current branch so the active
phase files can focus on unfinished execution targets and handoff notes.

## phase 1 — foundation and protocol

Completed work:

- Zig workspace/build targets for:
  - `muxlyd`
  - `muxly`
  - `muxview`
  - `libmuxly`
- muxml core types and document model
- JSON-RPC request/response framing and method routing
- Unix-socket daemon/client runtime
- capability discovery
- baseline document/view inspection
- repo docs and basic examples

Closure evidence:

- `zig build`
- `zig build test`
- ordinary clients talk to the daemon over the public protocol
- examples and library bindings have runnable baseline coverage

## phase 2 — tmux, sources, and views

Completed work:

- mixed-source leaf attachments and introspection:
  - tmux-backed live leaves
  - monitored file leaves
  - static file leaves
  - `leaf.source.attach` / `leaf.source.get`
  - `document.get`, `node.get`, `session.list`, `window.list`, `pane.list`
- tmux mutation coverage:
  - `session.create`
  - `window.create`
  - `pane.split`
  - `pane.capture`
  - `pane.scroll`
  - `pane.sendKeys`
  - `pane.resize`
  - `pane.focus`
  - `pane.close`
- append/capture/scrollback semantics through public APIs
- explicit follow-tail semantics as a **stored node preference**
- synthetic muxml editing:
  - `node.append`
  - `node.update`
  - `node.remove`
- explicit view-state semantics as **shared document state** for:
  - `view.setRoot`
  - `view.clearRoot`
  - `view.elide`
  - `view.expand`
  - `view.reset`
- viewer reflection of shared root/elision state with:
  - breadcrumb/path labeling
  - current-scope text
  - explicit back-out affordances
  - visible elision markers
- transport/capability/docs cleanup so the branch now truthfully describes:
  - Unix-domain sockets as the implemented transport on this target
  - named pipes/stdio as planned/scaffolded rather than implemented
  - the tmux backend as **command-backed**
- mixed-source docs/examples/tests left behind as living proof

Closure evidence:

- `zig build test`
- `zig build && python3 tests/integration/tmux_adapter_test.py`
- manual `muxview` verification of scoped-root and elision cues

## handoff boundary

Work that is still important but **not** part of completed phase 1/2 scope is
handed off to later phase files, especially:

- phase 4 — tmux control-mode/state recovery
- phase 5 — keybindings, menu/modeline projection, Neovim integration
