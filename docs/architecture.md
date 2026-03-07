# muxly architecture

`muxly` is split into four public-facing layers:

1. **daemon** — owns source adapters, muxml state, and protocol serving
2. **library** — ordinary client access to the public protocol
3. **CLI** — automation-oriented command runner
4. **viewer** — reference universal viewer built as an ordinary client

The daemon is responsible for durable/shared semantics such as:

- muxml document state
- source attachments
- append-oriented region updates
- shared view transforms in the current phase-2 cutline
- serialization

The viewer is responsible for local interaction and presentation:

- rendering
- drill-in navigation/orientation cues built on public view state
- follow-tail inspection of the stored node preference
- mouse/key UX

This split is guidance, not dogma: if a behavior needs to survive outside one
viewer process or be shared across clients, it belongs in the daemon/core.

## Protocol layering realism

The terminal ecosystem is messy enough that muxly should not assume one perfect,
universal protocol or embedding strategy will solve every problem cleanly.

Acceptable tools include:

- the public JSON-RPC control surface
- platform-specific helpers where necessary
- protocol layering
- adapter/plugin boundaries
- carefully scoped escape hatches for broken terminal behavior

The standard for choosing among these is not elegance in isolation, but whether
the result preserves responsiveness, predictability, and control fidelity.
