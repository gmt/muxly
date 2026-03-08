# muxly architecture

`muxly` is split into four public-facing layers:

1. **daemon** — owns source adapters, muxml state, and protocol serving
2. **library / client API** — preferred consumer-facing surface for
   server-backed operations
3. **CLI** — automation-oriented command runner aligned with library/client
   semantics
4. **viewer** — reference universal viewer built on the same public surfaces as
   other clients

The daemon control protocol sits beneath that library/client layer. It is an
important compatibility boundary inside muxly, but most consumers should not
need to think in terms of raw server messages.

Within the library-facing side, it is useful to keep two sub-layers distinct:

- a transport/RPC client that knows how to talk to the daemon
- a muxly client API that knows what operations exist and how to express them

That split keeps wire concerns separate from muxly semantics. The CLI and
viewer should generally depend on the muxly client API layer rather than
constructing operation requests themselves.

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

- the daemon control protocol
- library/client API helpers built on top of it
- platform-specific helpers where necessary
- protocol layering
- adapter/plugin boundaries
- carefully scoped escape hatches for broken terminal behavior

The standard for choosing among these is not elegance in isolation, but whether
the result preserves responsiveness, predictability, and control fidelity.
