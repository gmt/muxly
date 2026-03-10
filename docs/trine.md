# trine

This document captures the cross-cutting doctrine for muxly. When a future
phase, implementation detail, or platform compromise is unclear, these
principles should take precedence over superficial elegance.

## North-star design law

Muxly should prioritize **predictable behavior under nested TUI composition**
over theoretical elegance, and should accept platform-specific adaptation where
necessary to preserve responsiveness, clarity, and control fidelity.

## Core doctrine

### Function over form

- prefer a jank-free experience over architectural purity
- accept platform-specific workarounds when they improve behavior
- do not force a single beautiful abstraction if it degrades terminal UX

### TTYs are sources, not serialized process state

- a live TTY is a source adapter
- muxly serializes derived muxml/document/view state
- arbitrary process/editor/shell runtime state remains the responsibility of
  that program unless a cooperative adapter exists
- when a terminal-backed node stops being purely live, muxly should distinguish
  between:
  - detached but recoverable sources
  - captured text/history artifacts
  - captured surface artifacts
- terminal persistence should not collapse by accident into "whatever tmux
  scrollback happened to be"

### Terminology clarity

- the daemon maintains a **TOM**: a Terminal Object Model
- TOM refers to muxly's live, server-side, DOM-like object graph
- muxml is the serializable representation and interchange shape, not the same
  thing as the live TOM
- older discussion may loosely call the TOM a "DOM" or "pseudo-DOM"
- when those terms refer to muxly's own server object rather than an exogenous
  concept, prefer **TOM** instead for clarity and consistency

### Projection over mutation

- the TOM is the persistent abstract structure, not a live framebuffer
- a `muxview` should attach to one TOM node and produce a layout projection for
  a concrete `(rows, cols)` viewport
- attaching a view should not casually mutate the TOM just because one viewer
  happened to be larger or smaller than another
- visible geometry belongs to the projection: after layout, each visible node
  should have a deterministic absolute `(x, y, width, height)` quad inside that
  view
- paint should operate on a flattened list of visible regions rather than
  walking hierarchy ad hoc during every draw

### Structure and source are different axes

- layout structure and source/render behavior should remain orthogonal where
  possible
- branch/container nodes describe composition:
  - slot-like single-child containers
  - stacked/split containers with an axis
  - grids
  - overlapping tab-like containers
- leaf/source nodes describe content behavior:
  - plain byte/line streams
  - ANSI-aware streams
  - live TTY-backed leaves
  - file-backed leaves
- muxly should avoid forcing source kind and layout kind into one combined
  ontology when a cleaner cross-product will do

### Terminal box model, not browser cargo cult

- muxly should borrow only the box-model ideas that pay rent in terminal space
- useful early concepts include:
  - bounded regions
  - direction/stacking
  - gap and padding
  - constrained width/height intent
  - explicit clipping, scrolling, and follow-tail policy
- full browser-era baggage such as a giant CSS cascade, selector cleverness, or
  margin-heavy layout negotiation should not be imported by default

### tmux is a backend, not the constitution

- tmux should be used where it helps, especially as a live TTY source backend
- tmux layout ontology should not become muxly ontology by accident
- muxly may project tmux sessions, windows, panes, and later layout metadata
  into the TOM, but tmux does not get to define the TOM's long-term meaning
- if tmux cannot satisfy the intended muxly model cleanly, the backend should
  bend or be replaced before the core model is contorted around it

### Append-oriented by default

- terminal and log-like regions usually grow downward
- append-friendly behavior and tail-following should be the common-case bias
- arbitrary mid-tree mutation is allowed, but not the primary optimization goal

### Public-surface rule

- the reference viewer uses the same public surfaces as other clients
- no secret friend APIs
- no hidden shortcuts unavailable to other clients

### Library-first contract

- consumers should be able to think of muxly primarily as a library
- the library API is responsible for conversations with the server
- applications such as the CLI and viewer should build on that API layer rather
  than reaching into daemon internals
- muxml shape and wire-protocol details may remain implementation details for
  many consumers
- muxml shape and wire-protocol details may change later if the library-level
  semantics stay coherent

### Testing is a product requirement

- muxly wins or loses on how much can be tested
- slow, emulator-heavy, or awkward testing is acceptable if it increases
  confidence
- manual validation helps, but automated validation should be pushed as far as
  practical

### Cross-platform realism

- cross-platform pain should be paid early where possible
- protocol/API shape should avoid accidental Unix-only assumptions
- function matters more than pretending every platform can behave identically
- WSL2 may be the long-term Windows recommendation, but MSYS2 or other
  intermediate strategies are acceptable if they are more testable sooner

### Protocol layering is acceptable

- terminal environments are inherently weird
- multiple protocol layers, adapters, escape hatches, and plugin boundaries are
  acceptable if they preserve user experience
- low-latency, low-overhead behavior matters more than enforcing a single
  universal wire shape everywhere
- when the library API is sufficient, consumers should not need to care about
  the wire format

## Viewer interaction priorities

- drill-in / depthwise traversal should be discoverable
- hierarchy boundaries should be clear when users traverse into nested views
- resizing and focus semantics should feel predictable
- mouse behavior should prioritize intuitive region targeting even when nested
  support combinations are messy
