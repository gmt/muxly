# tom model

This document defines muxly's **TOM**: the live Terminal Object Model owned by
the daemon.

It is written from four reference frames that need to stay aligned:

1. the **object model** used in code
2. the **ownership model** used to reason about runtime state
3. the **serialization / deserialization posture** used for persistence
4. the **wire protocol posture** used by remote consumers

`muxml` is the serializable representation of TOM state. It is not the TOM
itself. The TOM is the live graph; muxml is one durable/exportable view of that
graph.

## Why this exists

Muxly is trying to behave like a serious terminal composition environment, not
just a tmux helper or a pretty chat transcript.

That means several hierarchies need to agree with each other:

- the component hierarchy in code
- the containment hierarchy users imagine and navigate
- the hierarchy presentation confirms on screen
- the hierarchy that persists and crosses process boundaries

If those diverge too far, the system gets uncanny fast.

## Object model

The first reference frame is the in-memory component model.

At the coarsest level:

```text
tom -> node
         |-- leaf
         |    |-- text-ish / appendable content
         |    |-- tty-backed content
         |    `-- file-backed content
         `-- container
              |-- horizontal / vertical composition
              `-- scroll-bearing regions
```

The current concrete node vocabulary in code is:

- `document`
- `subdocument`
- `container`
- `scroll_region`
- `tty_leaf`
- `monitored_file_leaf`
- `static_file_leaf`
- `monitor_leaf`
- `modeline_region`
- `menu_region`

See [types.zig](/home/greg/src/muxly/src/core/types.zig).

### Core class family

The durable conceptual family should stay simple even if different language
bindings express it through classes, tagged unions, interfaces, or records:

- `Tom`
  - owns node identity space and the root node
  - owns lifecycle, attachment, and shared document state
- `Node`
  - common base contract:
    - identity
    - title
    - content
    - parent/children linkage
    - source metadata
    - lifecycle
    - follow-tail preference
- `LeafNode`
  - no structural children
  - content comes from text, files, tty sources, or future adapters
- `ContainerNode`
  - owns structural composition of child nodes
  - may be slot-like, stacked, split, grid-like, or other explicit composition
    strategies later
- `ScrollRegion`
  - a structurally meaningful scroll-bearing node
  - distinct from viewer-local camera state

The current repo uses a single `Node` struct plus `NodeKind` and `Source`
variants rather than a deep runtime class hierarchy. That is fine. The design
law is about semantic shape, not forcing inheritance where a tagged union is a
better fit.

### Structure and source are different axes

Muxly should continue treating these as separate dimensions:

- **structure kinds**
  - `document`
  - `subdocument`
  - `container`
  - `scroll_region`
  - `modeline_region`
  - `menu_region`
- **source kinds**
  - `none`
  - `tty`
  - `file`
  - `terminal_artifact`

That separation matters because a live coding thread or nested agent stage is
not "a tty" or "a file." It is usually a structural region containing several
leaves and subregions, some of which happen to be tty-backed.

### Current gap

For the browsing / agent-thread metaphor, muxly likely wants an explicit
appendable text or document leaf that is not pretending to be a tty. Today that
role is partially covered by node `content`, but a richer first-class text
region is a likely future extension.

## Ownership model

The second reference frame is runtime ownership.

The TOM is not just an inert tree. It is a live owned graph.

### Daemon-owned graph

At the top level:

- one `muxlyd` process owns one live TOM per document/session
- that TOM owns all nodes contained in that document
- node identity and parent/child linkage are daemon-owned
- shared document-scoped view state is daemon-owned in the current cutline

This makes the TOM closer to a miniature datastore or micro-daemon than to a
plain serialized DTO blob.

### Nested ownership

Containment implies ownership of substructure:

- a `document` owns its root stage
- a `subdocument` owns its contained subtree
- a `container` owns layout/composition over its children
- a `scroll_region` owns semantically meaningful scroll-bearing content
- a tty-backed leaf owns attachment metadata to its current source, but not the
  underlying program's internal runtime state

This is the right mental model for nested agent work:

- a top-level thread stage may contain live activities
- a live activity may contain its own history and status regions
- that activity may itself contain sub-agent stages

The shape is recursive, but ownership remains local and explicit.

### Source ownership boundary

A live source remains outside muxly's full sovereignty:

- tmux owns tmux runtime state
- the child process owns its own program/editor/shell state
- muxly owns the derived TOM nodes, attachments, and persisted viewable state

That is why "TTYs are sources, not serialized process state" remains a
project-wide law.

## Serialization / deserialization posture

The third reference frame is persistence.

### TOM versus muxml

- TOM is the live owned graph
- muxml is the serializable representation of that graph
- serialization should preserve the meaning of the live graph without claiming
  to capture arbitrary external process internals

### What should serialize

Muxly should serialize:

- node identity and hierarchy
- node kind
- title/content
- lifecycle
- source metadata when relevant
- durable/shared view-related state when the daemon owns it

Muxly should not pretend to serialize:

- arbitrary shell/editor runtime state
- every hidden tmux implementation detail
- every viewer-local camera move or projection accident

### Current procedure

The current repo already has a real seam:

- the daemon maintains the live graph
- `document.get` / `view.get` expose that graph in JSON form
- `document.serialize` exposes muxml/XML serialization
- frozen terminal artifacts use explicit `terminal_artifact` source metadata
  rather than silently impersonating live tty nodes forever

### Placeholder for fuller ser/des policy

The repo still wants a fuller written procedure for:

- what counts as stable serialized schema versus implementation detail
- which fields are mandatory versus optional across bindings
- how rehydration should behave for detached or frozen nodes
- which projection/view fields are document-owned versus viewer-local

That fuller policy can land later, but TOM and muxml should remain clearly
distinguished in the meantime.

## Wire protocol posture

The fourth reference frame is the wire/API story.

Consumers may see the TOM through several surfaces:

- JSON-RPC protocol
- library/client API
- CLI
- viewer
- serialized muxml export

Those surfaces are not the TOM itself. They are projections or operations over
the TOM.

### Current wire shape

Today the public protocol already exposes core TOM operations such as:

- `document.get`
- `document.status`
- `document.serialize`
- `graph.get`
- `view.get`
- `view.elide`
- `view.setRoot`
- `view.clearRoot`
- node append/update/remove/freeze operations

See [protocol.md](/home/greg/src/muxly/doc/protocol.md).

### Protocol design rule

The wire protocol should describe operations and externally useful state, not
force consumers to care about daemon-internal implementation details.

So the posture is:

- the protocol is a compatibility boundary
- the library/client API is the preferred consumer surface
- muxml and wire payloads may evolve as long as consumer-facing semantics remain
  coherent

## Visual containment model

For users, the TOM should be visually legible as the same hierarchy it owns in
memory.

That means a live "browser" or "agent thread" stage should be representable as:

- top chrome
  - status or modeline regions
  - menus
- body region
  - a scroll-bearing history/document region
  - embedded live activities
  - nested sub-stages

And each live activity may itself contain:

- its own status region
- its own history/document region
- more nested activities or worker stages

That recursive stage model is the important imaginative frame:

- component hierarchy in code
- ownership hierarchy at runtime
- containment hierarchy on screen
- persistence hierarchy in muxml

All four should rhyme.

## Working doctrine

If a future feature makes TOM semantics blurry, prefer these checks:

1. Can this be named cleanly as a node or source kind?
2. Who owns it at runtime?
3. Does it belong in durable muxml, or only in viewer-local projection?
4. Does the wire/API surface expose the right semantic operation instead of a
   backend accident?
5. Will the visual presentation confirm the same hierarchy users are meant to
   reason about?

If the answer to those questions stays clear, the TOM is probably staying
healthy.
