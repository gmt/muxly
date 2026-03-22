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

- maintaining the attached viewer session for one concrete viewport
- rendering
- drill-in navigation/orientation cues built on public view state
- follow-tail inspection of the stored node preference
- mouse/key UX
- explicit snapshot mode for scripts and deterministic debugging

This split is guidance, not dogma: if a behavior needs to survive outside one
viewer process or be shared across clients, it belongs in the daemon/core.

## Document state versus viewer-session state

Muxly should distinguish shared TOM state from optional shared viewer state.

- the daemon owns documents, node identity, source attachments, and server-side
  tty endpoints
- viewers own local rendering, input handling, and any purely private camera
  state
- when muxly needs cross-client mirroring, supervision, or inspectable viewer
  state, that state should live in an explicit daemon-mediated **viewer
  session**, not be smuggled into the document itself

That means two users can attach to the same document in different ways:

- as independent viewers with separate viewer sessions over the same document
- as participants in one intentionally shared viewer session
- as controllers/readers of different tty nodes within the same document

The daemon should act as the hub for shared viewer sessions:

- clients publish typed session snapshots/deltas to the daemon
- the daemon relays or exposes them to other participants
- admin/observer tooling can inspect session state through the same hub

This is different from giving arbitrary RPC conversations an ambient "current
document" by default. Bare requests should remain explicit and resource-targeted
unless a higher-level session/attachment contract says otherwise. In practice,
the current document-scoped `viewRootNodeId` behavior is a useful transitional
cutline, but it should not be mistaken for the final place where shared viewer
state belongs.

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
