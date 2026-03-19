# changelog

This file summarizes completed milestones and archived first-pass completions so
the remaining roadmap docs can stay honest about what is still active versus
merely deferred.

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
- mixed-source docs/examples/tests left behind as living evidence

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
- docs/verification cleanup:
  - `README.md` and `docs/demos.md` point at authoritative example/verification paths
  - `scripts/run_binding_examples.py` is the checked-in live-daemon verification path
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

## phase 4 slice 2 — control-mode attachment and parser isolation

Completed work:

- long-lived tmux control-mode attachment path
- parser isolation for line-oriented control-mode output
- typed command-block handling and normalized parser coverage
- focused verification around attachment and parser behavior

Closure evidence:

- `zig build`
- `zig build test`

## phase 4 slice 3 — snapshot rebuild and TOM reconciliation

Completed work:

- explicit backend-to-TOM projection contract for tmux-backed state:
  - tmux session -> TOM `subdocument`
  - tmux window -> nested `subdocument`
  - tmux pane -> nested `tty_leaf`
- normalized tmux pane snapshots now carry enough session/window/pane metadata
  to drive reconciliation
- snapshot-to-TOM reconciliation helpers for rebuilding one tmux session
  subtree intentionally from tmux truth
- store seams for explicit tmux session projection rebuild and rebuild-by-pane
- tmux mutation flows now return projected pane nodes rather than loose
  attached leaves
- `session.list`, `window.list`, and `pane.list` now read from normalized
  snapshot state
- projected tmux containers are pruned when pane close empties them
- explicit rebuild verification from external tmux state:
  - unit test coverage rebuilds a projected `session -> window -> pane` subtree from
    snapshots
  - integration coverage covers projected-parent retention under `create-under`
    plus later tmux mutations
- stale tmux test cruft removed:
  - deleted placeholder `daemon_protocol_test.zig`
  - deleted orphaned `tests/fixtures/sample_document.json`

Closure evidence:

- `zig build`
- `zig build test`
- `python3 tests/integration/tmux_adapter_test.py`
- `./examples/tty/basic-nesting/run.sh`

## phase 4 slices 4 and 5 — first-pass live invalidation, reconnect, and verification hardening

Completed work:

- lazy control-mode attachment for live tmux-backed documents
- notification-driven invalidation of known projected tmux session subtrees
- explicit drift fallback policy:
  - control-mode exit degrades to request-time snapshot rebuild
  - rebuild remains the correctness backstop when event confidence is limited
- reconnect/reattach path:
  - focused control-mode verification now covers reattaching to surviving tmux state
  - store-side backend pump can recover a live control attachment after exit
- structured control-mode output parsing:
  - `%output`
  - `%extended-output`
- best-effort live append for known follow-tail pane leaves on top of the
  invalidation/rebuild path
- conservative tmux output escape-sequence decoding for live append
- verification/docs hardening:
  - capabilities and viewer surfaces now report
    `hybrid-control-invalidation`
  - integration coverage covers external pane/window/session drift
  - backend docs describe the hybrid cutline plainly instead of calling it
    purely command-backed

Closure evidence:

- `zig build`
- `zig build test`
- `python3 tests/integration/tmux_adapter_test.py`
- `./examples/tty/basic-nesting/run.sh`

## phase 6 — first-pass terminal artifact contract and freeze seam

Completed work:

- durable terminal-artifact contract written down explicitly:
  - live tty source
  - detached but recoverable tty source
  - captured text artifact
  - captured surface artifact
- explicit append/history versus surface/raw distinction with concrete example
  classes and first-pass heuristics
- conservative TOM/muxml representation posture chosen:
  - preserve node identity and tree position
  - prefer `lifecycle` plus `source` transitions before a larger node-kind
    taxonomy
- checked-in witness artifacts under `examples/artifacts/`
- first implementation seam in the core model:
  - new `terminal_artifact` source family with `text` versus `surface`
  - tty provenance preserved when a node transitions into a captured artifact
  - XML source serialization now records source metadata alongside JSON
- first public seam:
  - `node.freeze <node-id> <text|surface>` through JSON-RPC
  - Zig API helper
  - CLI command
  - C ABI helper
- current capture posture:
  - `text` freezes from tmux history + visible capture
  - `surface` freezes from visible surface capture, with alternate-screen
    capture included opportunistically when tmux provides useful content
- payload shape is now explicit in source metadata:
  - `text` uses `contentFormat = plain_text`
  - `surface` uses `contentFormat = sectioned_text`
- captured terminal artifacts now also expose first-pass section metadata:
  - `text` reports `sections = []`
  - `surface` reports at least `sections = ["surface"]`
  - `alternate` is included when tmux exposes alternate-screen capture
- verification/examples:
  - unit test coverage for document-side tty-to-artifact transition
  - integration coverage for both `text` and `surface` freeze paths
  - runnable playbook under `examples/artifacts/freeze-demo/`
  - runnable C / Python / Zig `libmuxly` playbooks under:
    - `examples/artifacts/c-freeze/`
    - `examples/artifacts/python-freeze/`
    - `examples/artifacts/zig-freeze/`
  - shared artifact example runner under `scripts/run_artifact_examples.py`

Closure evidence:

- `zig build`
- `zig build test`
- `python3 tests/integration/tmux_adapter_test.py`
- `./examples/artifacts/freeze-demo/run.sh`
- `python3 scripts/run_artifact_examples.py`

## roadmap status after cleanup

Active follow-on work:

- phase 4 — tmux backend credibility and recovery:
  default-path definition, projected identity cleanup, narrow incremental event
  application, and reconnect truthfulness

Deferred backlog/reference:

- phase 5 — bindings analysis, menu/modeline work, and Neovim integration stay
  deferred and should only be reactivated as separate threads

Archived implemented reference:

- phase 6 — first-pass terminal artifact contract and freeze seam is archived
  implemented material, not active roadmap work
