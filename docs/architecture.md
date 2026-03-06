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
- sharable view transforms
- serialization

The viewer is responsible for local interaction and presentation:

- rendering
- drill-in navigation
- follow-tail UX
- mouse/key UX

This split is guidance, not dogma: if a behavior needs to survive outside one
viewer process or be shared across clients, it belongs in the daemon/core.
