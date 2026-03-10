# changelog

This file summarizes completed milestones so the remaining phase files can stay
focused on open work.

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
- library helpers, CLI commands, and examples can drive the daemon through the
  public server API
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

## phase 3 — library API, viewer, CLI, and bindings

Completed work:

- library-first client consolidation:
  - `src/lib/api.zig` became the default home for implemented server-backed
    operation families
  - `muxly` CLI request construction moved out of app-specific shims
  - the old CLI-local request shim was removed
- intentional `libmuxly` surface:
  - handle-based client lifecycle documented in `include/muxly.h`
  - explicit ownership and null-on-failure notes for string-returning helpers
  - synthetic node/view editing helpers exposed through the C ABI
- example quality upgrades:
  - shipped C / Zig / Python "hello TOM" examples aligned on the same story
  - examples reorganized under `examples/tom/`
  - dedicated example sockets and playbook wrappers avoid colliding with a
    long-lived local daemon
  - `zig build example-deps` narrows the example prerequisite build to the
    daemon, CLI, shared library, and header
- docs/proof cleanup:
  - `README.md` and `docs/demos.md` point at authoritative example/proof paths
  - `scripts/run_binding_examples.py` is the checked-in live-daemon proof path
  - `muxview` remains a public-surface consumer rather than a privileged path
- terminology cleanup:
  - muxly's live server-side object graph is now described as the TOM
    (Terminal Object Model)
  - `muxml` is framed as the serializable representation of the TOM

Closure evidence:

- `zig build`
- `zig build test`
- `zig build example-deps`
- `python3 scripts/run_binding_examples.py`
- `python3 tests/integration/tmux_adapter_test.py`

## next major work

Work that is still important but **not** part of completed phase 1/2/3 scope is
tracked in later phase files, especially:

- phase 4 — tmux control-mode/state recovery
- phase 5 — keybindings, menu/modeline projection, Neovim integration
