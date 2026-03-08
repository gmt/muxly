# phase 3 — library API, viewer, CLI, and bindings

## Goal

Make the library/client API layer usable by someone starting from the installed
binaries, public docs, header file, and shipped examples.

This phase is complete when the library-facing surfaces are self-explanatory and
consistent:

- the CLI covers the implemented protocol in user-facing terms
- `muxview` uses the same public client surfaces as other consumers
- the library/client API layer is the default home for server conversations
- the C ABI is usable without guesswork around ownership or lifecycle
- language examples demonstrate value, not only syntax

## In scope

- library/client API coverage for the implemented server-backed operations
- CLI coverage and UX for the implemented operations
- viewer uses the same public client surfaces as other consumers
- handle-based C ABI expansion for already-implemented flows that should be easy
  to call from external consumers
- C / Zig / Python examples that work against a live daemon
- header docs and memory ownership clarity
- docs/demos that make examples discoverable

## Out of scope

- a full multi-language binding matrix
- advanced viewer polish unrelated to the public-surface rule
- GUI-specific menu helpers
- phase 4 tmux control-mode/state-recovery work
- phase 5 keybindings/menu/modeline/Neovim work

## Acceptance criteria

- the library/client API layer covers the implemented operation families that
  phase 3 chooses to support as first-class consumer calls
- `muxly` can operate the implemented protocol families already listed in
  [docs/protocol.md](/home/greg/src/muxly/docs/protocol.md), except work
  explicitly deferred to later phases, without forcing raw JSON on users
- `muxview` uses only the same public client surfaces available to other tools
- `libmuxly` exposes a documented handle-based path for the shipped
  document/graph helpers, view helpers, and the tmux helpers documented for
  phase 3
- header comments and examples make string ownership and lifecycle rules hard
  to misuse
- examples run against a live daemon and are linked from repo docs with runnable
  setup commands
- tests or proof commands exist for the viewer/CLI/bindings path, not only
  daemon internals

## Repo baseline

Phase 3 starts from a working baseline:

- CLI coverage is broad in [src/cli/main.zig](/home/greg/src/muxly/src/cli/main.zig).
  It covers capability discovery, document/view APIs, synthetic node editing,
  leaf attachment, and the implemented tmux/file helpers listed in
  [docs/protocol.md](/home/greg/src/muxly/docs/protocol.md).
- The viewer is exercised through the public API path in
  [tests/integration/tmux_adapter_test.py](/home/greg/src/muxly/tests/integration/tmux_adapter_test.py).
- The Zig library/client API exists in
  [src/lib/api.zig](/home/greg/src/muxly/src/lib/api.zig), but it does not yet
  cover the whole implemented CLI surface.
- The shared library exports a handle-based client lifecycle plus a
  partial request surface in
  [src/lib/c_abi.zig](/home/greg/src/muxly/src/lib/c_abi.zig), with matching
  declarations in [include/muxly.h](/home/greg/src/muxly/include/muxly.h).
- Example consumers exist in C, Zig, and Python under
  [examples/c/basic_client.c](/home/greg/src/muxly/examples/c/basic_client.c),
  [examples/zig/basic_client.zig](/home/greg/src/muxly/examples/zig/basic_client.zig),
  and [examples/python/basic_client.py](/home/greg/src/muxly/examples/python/basic_client.py).
- Docs treat runnable examples as part of the contract in
  [docs/demos.md](/home/greg/src/muxly/docs/demos.md) and
  [README.md](/home/greg/src/muxly/README.md).

## Remaining gaps

What still keeps this phase from feeling complete:

- The phase file needs clearer targets so contributors can identify the next
  concrete phase-3 task.
- Slice 2 is now complete: the viewer and CLI use
  [src/lib/api.zig](/home/greg/src/muxly/src/lib/api.zig) as the default home
  for server-backed operations. The next remaining work is to make the C ABI,
  header, examples, and proof stack look equally intentional.
- The C ABI is useful but selective. It is not yet obvious which exported
  methods define the supported phase-3 surface versus which gaps remain.
- The header comments are minimal; ownership is mentioned, but ergonomics and
  failure behavior are mostly learned from source.
- The examples are real but basic:
  - they hard-code `/tmp/muxly.sock`
  - they assume useful node ids already exist
  - they demonstrate individual calls more than end-to-end consumer value
- Example validation is weakly coupled to the build. The integration test proves
  a lot about the CLI/viewer path, but not much about the example/binding path.
- Discoverability is decent, but the docs could do a better job telling a
  contributor which demo flow proves the viewer/CLI/bindings path.

## Agentic-harness starting point

The right starting move for phase 3 is:

1. do Slice 1 first, but keep it intentionally small
2. treat Slice 2 as the first substantive implementation tranche
3. defer Slice 3 and Slice 4 until Slice 2 clarifies the shared public surface
4. use Slice 5 to harden the proof path touched by the earlier slice, not as a
   detached cleanup pass

Why this order was correct:

- [README.md](/home/greg/src/muxly/README.md) and
  [docs/demos.md](/home/greg/src/muxly/docs/demos.md) are already decent, so
  Slice 1 should be a framing pass, not a long docs-only project
- the largest remaining phase-3 implementation gap at the time was the split
  between [src/cli/main.zig](/home/greg/src/muxly/src/cli/main.zig) and
  [src/lib/api.zig](/home/greg/src/muxly/src/lib/api.zig)
- the C ABI and examples should follow the stabilized shared API surface rather
  than guess at it early

If an agent needs one sentence of direction, use this one:

> Do a short Slice 1 pass to make the proof path and supported public surface
> obvious, then move immediately into Slice 2 and treat it as the first real
> code tranche of phase 3.

That sequence has now been exercised successfully in this repo. Slice 2 is no
longer the open question; Slice 3 is the next substantive tranche.

## Execution order

Work this phase in the following order. Do not jump to binding breadth before
the docs and proof path are coherent.

### Slice 1 — library-first framing and discoverability

Make the repo point to one clear library-first proof path for the viewer, CLI,
and bindings.

This slice is intentionally a short framing pass. Do not let it expand into a
long docs-only effort. Its job is to make the first implementation tranche
obvious and to leave behind one authoritative proof path that later slices can
reuse.

Likely touchpoints:

- [README.md](/home/greg/src/muxly/README.md)
- [docs/demos.md](/home/greg/src/muxly/docs/demos.md)
- [docs/architecture.md](/home/greg/src/muxly/docs/architecture.md)
- [docs/protocol.md](/home/greg/src/muxly/docs/protocol.md)
- [phased-planning/phase-3-library-viewer-cli-and-bindings.md](/home/greg/src/muxly/phased-planning/phase-3-library-viewer-cli-and-bindings.md)

Target:

- docs state that the library/client API is the preferred consumer contract
- `README.md` links to the main proof flow
- `docs/demos.md` names the authoritative demo commands
- this phase file names the next remaining tasks without requiring source
  spelunking

Done when:

- a new contributor can find the viewer/CLI/bindings demo path from
  [README.md](/home/greg/src/muxly/README.md) or
  [docs/demos.md](/home/greg/src/muxly/docs/demos.md) without reading source
- docs clearly distinguish the baseline from the remaining work
- phase 3 stops reading like a wish list and starts reading like a work queue

Preferred output from this slice:

- one repo-visible description of the authoritative viewer/CLI/bindings proof
  path
- one repo-visible statement that the library/client API is the preferred home
  for server conversations
- one repo-visible statement that Slice 2 is the next implementation target
  after the framing pass

### Slice 2 — library/client API consolidation

Move server request construction out of app-specific code when that logic
belongs in the shared library/client layer.

Treat this as the first real implementation tranche of phase 3.

Likely touchpoints:

- [src/lib/api.zig](/home/greg/src/muxly/src/lib/api.zig)
- [src/cli/main.zig](/home/greg/src/muxly/src/cli/main.zig)
- [src/viewer/main.zig](/home/greg/src/muxly/src/viewer/main.zig)
- docs that describe the consumer contract

Priorities:

- add library/client helpers for implemented operations that are currently
  rebuilt inside the CLI
- keep app-specific parsing and formatting in the CLI/viewer while moving server
  conversation details downward
- avoid introducing a second overlapping helper layer

This slice started from the concrete gaps that were visible in the repo:

- request families that still appear direct in
  [src/cli/main.zig](/home/greg/src/muxly/src/cli/main.zig) rather than as
  named helpers in [src/lib/api.zig](/home/greg/src/muxly/src/lib/api.zig),
  especially:
  - `initialize`
  - `session.list`, `window.list`, `pane.list`
  - `node.append`, `node.update`, `node.remove`
  - `document.freeze`, `document.serialize`
  - `leaf.source.attach`
  - `view.clearRoot`, `view.expand`
- duplicated JSON construction helpers in the CLI that are really expressing
  shared protocol semantics rather than CLI-specific UX

Work this slice by moving one coherent operation family at a time. Good
sub-tranche boundaries include:

- node mutation helpers
- document/view helpers
- tmux session/window/pane helpers
- leaf-source attachment helpers

Target:

- the shared library/client layer is the default place for request construction
- the CLI and viewer depend on that layer for server-backed operations
- docs no longer imply that raw server messages are the preferred consumer path

Done when:

- the main implemented CLI/viewer flows reach the server through the
  library/client layer
- remaining direct wire-level calls, if any, are small exceptions and are
  documented as such

Current status:

- complete
- [src/cli/main.zig](/home/greg/src/muxly/src/cli/main.zig) now routes its
  implemented server-backed operations through
  [src/lib/api.zig](/home/greg/src/muxly/src/lib/api.zig)
- the old CLI-local request shim in
  [src/cli/client.zig](/home/greg/src/muxly/src/cli/client.zig) was removed as
  part of this consolidation

Good stopping point for one agentic tranche:

- one operation family has moved out of the CLI into the shared API layer
- the CLI now calls the shared helper for that family
- docs/proof notes were updated if the public contract changed
- the default proof stack still passes

### Slice 3 — C ABI contract cleanup

Give `libmuxly` an explicit supported scope instead of letting it grow by
accident.

Do not start this slice until Slice 2 has clarified which shared helpers are
actually the supported phase-3 surface.

Likely touchpoints:

- [src/lib/c_abi.zig](/home/greg/src/muxly/src/lib/c_abi.zig)
- [include/muxly.h](/home/greg/src/muxly/include/muxly.h)
- [README.md](/home/greg/src/muxly/README.md)

Priorities:

- prefer handle-based helpers over one-off stateless entrypoints when both would
  exist only for convenience
- add exported helpers only when they materially improve consumer tasks
- document null/error behavior and string-freeing rules in the header, not only
  in Zig source

Current repo reality that should drive this slice:

- [src/lib/c_abi.zig](/home/greg/src/muxly/src/lib/c_abi.zig) exposes a useful
  but selective handle-based surface
- [include/muxly.h](/home/greg/src/muxly/include/muxly.h) does not yet explain
  failure semantics or argument expectations in enough detail to stand on its
  own
- the shipped examples in
  [examples/c/basic_client.c](/home/greg/src/muxly/examples/c/basic_client.c),
  [examples/zig/basic_client.zig](/home/greg/src/muxly/examples/zig/basic_client.zig),
  and [examples/python/basic_client.py](/home/greg/src/muxly/examples/python/basic_client.py)
  still hard-code `/tmp/muxly.sock` and assume useful node ids already exist

Start this slice in the following order:

1. define the supported phase-3 C ABI surface in the header
2. add only the missing exported helpers needed to make that surface credible
3. update the shipped examples to use only that documented surface
4. leave behind one documented proof path that exercises the examples against a
   live daemon

Concrete starting point:

- write header comments in [include/muxly.h](/home/greg/src/muxly/include/muxly.h)
  as if it were the only file a C caller will read
- explicitly state for every exported function:
  - whether null inputs are allowed
  - whether null return means failure
  - which strings must be freed with `muxly_string_free`
  - whether the returned JSON is a complete JSON-RPC response payload or some
    narrower convenience shape
- decide which helpers are part of the intentional phase-3 surface before
  adding more breadth

Preferred supported-surface bias for Slice 3:

- handle-based lifecycle plus handle-based request helpers should be the default
  contract
- keep stateless top-level helpers small and obviously convenience-oriented
- add helpers that let examples create their own setup instead of depending on
  pre-existing node ids
- do not chase full CLI parity if the extra exports are only speculative

Likely must-have additions for a credible example path:

- enough node/view helpers that an example can create a node and then inspect or
  focus it without assuming node id `2`
- or enough attach/session helpers that an example can create the live/file
  state it needs from scratch

Good sub-tranche boundaries:

- header contract and ownership comments
- minimal C ABI breadth to match the chosen documented surface
- example alignment across C, Zig, and Python
- proof/docs wiring

Target:

- document the supported phase-3 C ABI surface in one place
- ensure every string-returning function states ownership and null semantics
- make the examples use only that documented surface

Done when:

- the exported surface is explicitly documented as the supported phase-3 surface
- a C caller can understand lifecycle and ownership from the header alone
- examples do not depend on undocumented socket-path or node-id assumptions

Good stopping point for one agentic tranche:

- one header/documentation pass made the supported C ABI surface clearer
- one missing helper family was added only because an example or documented
  consumer flow needed it
- at least one shipped example became more self-sufficient and less assumption
  heavy
- the proof/docs path for that example was updated

### Slice 4 — example quality over quantity

Upgrade the existing examples before adding more languages.

Do not start this slice until Slice 2 and Slice 3 have made the supported
consumer contract explicit enough that examples are not teaching a transient
interface.

Likely touchpoints:

- [examples/c/basic_client.c](/home/greg/src/muxly/examples/c/basic_client.c)
- [examples/zig/basic_client.zig](/home/greg/src/muxly/examples/zig/basic_client.zig)
- [examples/python/basic_client.py](/home/greg/src/muxly/examples/python/basic_client.py)
- [docs/demos.md](/home/greg/src/muxly/docs/demos.md)

Priorities:

- remove avoidable hard-coded assumptions when a small amount of setup can make
  the flow clearer
- show at least one end-to-end flow that demonstrates value, not only request
  wrappers
- keep examples aligned across languages so they tell the same story

Target:

- each example reads the socket path from `MUXLY_SOCKET` or documents its input
  contract explicitly
- examples create the nodes or sessions they need, or the docs state the exact
  required precondition
- the C, Zig, and Python examples demonstrate the same flow shape

Done when:

- a new contributor can run the examples with only documented setup
- they are easy to run against a live daemon because the required socket/setup
  steps are documented in the repo
- they demonstrate public-surface usage patterns worth copying

### Slice 5 — proof hardening

Make the viewer/CLI/bindings path testable enough that regressions are obvious.

Use this slice to strengthen proof around whatever Slice 2 through Slice 4
changed most recently. Avoid doing proof hardening in isolation before the
public surface is stable enough to prove.

Likely touchpoints:

- [tests/integration/tmux_adapter_test.py](/home/greg/src/muxly/tests/integration/tmux_adapter_test.py)
- [build.zig](/home/greg/src/muxly/build.zig)
- docs that advertise the proof flow

Priorities:

- keep the existing integration test as the main CLI/viewer proof
- add example/binding validation if it can run as a repo-local script or build
  step without adding a separate test-harness stack
- prefer one strong end-to-end proof over many shallow "it compiles" claims

Target:

- one documented proof stack covers daemon startup, CLI/viewer behavior, and
  any binding/example flow touched by the change
- proof commands in docs match the commands contributors are actually expected
  to run

Done when:

- a contributor can run the documented proof commands and validate the daemon,
  CLI/viewer path, and any touched example/binding path
- examples and docs stop drifting separately from the implementation

## Per-slice proof

Every meaningful phase-3 change should leave behind updated proof steps. The
default proof stack for this phase is:

```sh
zig build
zig build test
python3 tests/integration/tmux_adapter_test.py
```

If work touches examples or the C ABI, also run the relevant live-daemon flow
and document it in repo-visible docs. The bar is not "I read the code and it
seems fine". The bar is "a documented viewer/CLI/binding path was exercised".

## Exit condition

Phase 3 can reasonably be called complete when all of the following are true:

- the CLI/viewer/docs/examples all describe the same public-surface rules
- the C ABI surface and header comments look intentional and stable for this
  slice
- the examples are credible living documentation
- proof commands exist and are actually useful for catching regressions

This phase does not require a larger language matrix. Strong CLI, viewer, C
ABI, and shipped-example paths are enough to move the center of gravity to
later phases.
