# viewer architecture

`muxview` is intended to be the reference implementation and universal viewer
for live muxly documents.

This document mixes implemented cutline with directional architecture. It
should not be read as evidence that every deeper viewer interaction described here
is already shipped or currently on the immediate roadmap.

## Design rule

`muxview` should use the same public API surface as other clients:

- no secret daemon APIs
- no privileged shortcuts
- no internal state bypasses unavailable to third-party consumers

## Responsibilities

- maintain a long-lived viewer attachment for one concrete viewport
- render muxml trees and regions
- provide drill-in/root/elision UX
- support follow-tail inspection
- host interaction-heavy UI ideas that do not need to be centralized

## Projection model direction

The architectural direction should stay clear and concrete:

- a `muxview` attaches to one TOM node at a concrete `(rows, cols)` size
- that attachment should maintain a layout projection over time rather than
  mutating the persistent TOM for every viewer-local size change
- the projection step assigns deterministic absolute quads to visible regions
- rendering should flatten that projection into a paint list rather than depend
  on recursive hierarchy walking at paint time

In practice, attachment should feel like joining a live shared stage:

- an editor in one region and compile errors in another should keep updating as
  one viewer session
- a supervising agent can broadcast expensive reasoning into several worker TTY
  conversations beneath it
- a nested conversational stage can later be zoomed into without redefining the
  TOM around one viewer's local camera move

This keeps four concerns distinct:

- TOM structure and policies
- one concrete viewer-local layout projection
- the presentation substrate that repaints the attached session
- the paint/composition pass for the current terminal frame

Leaf content and viewport geometry also need to remain distinct. A live TTY,
ANSI stream, or file-backed region may have content larger than its currently
visible quad. Follow-tail, clipping, scrollback, and resize behavior should be
treated as per-class policy decisions, not as evidence that the TOM itself is a
literal framebuffer.

## Attachment and presentation

Viewer attachment, layout projection, presentation substrate, and snapshot mode
should each keep a clear job:

- **viewers** are clients. viewers ingest the library to talk to
  a server over a transport. in particular viewers create:
- a **viewport**, which defines the set of nodes in the TOM potentially 
  visible to a user at a given moment; this should not be confused with a
- **placement,** which specifies the x,y coordinates, width, and height
  in a partent node dedicated to presenting information from a child node
- **presentation** happens on a client; it recursively offsets projections
  by "scrolls" (displacements relative to origin) to determine the mapping
  of content from children into parents or occluded areas not visible.

The current cutline already supports that model in a first-pass way:

- `muxview` attaches live by default when stdout is a TTY
- it enters the alternate screen, refreshes on a fixed cadence, and repaints
  from the public `projection.get` surface
- `muxview --snapshot` keeps the one-shot textual readout available when a
  deterministic frame is the right tool
- tmux is the current likely first presentation substrate because it already
  buys much of the terminal/session machinery, while remaining replaceable if
  it later constrains the desired muxly experience

## Current cutline

The current viewer has moved beyond the initial passive display. It provides an
interactive terminal session with:

- keyboard-driven region selection (`j`/`k`, arrow keys)
- drill-in/back-out navigation (`Enter`/`Escape`, arrow right/left)
- `view.setRoot`, `view.clearRoot`, `view.reset` through the public API
- elide/expand toggling for per-region shared view state
- follow-tail toggling for tty-backed regions
- focused pane interaction mode that forwards input to the underlying tmux pane
- mouse-driven region targeting via SGR mouse protocol
- a viewer-owned status bar showing mode, selected region, and scope
- the viewer still consumes only public surfaces: `projection.get` for boxed
  rendering and `view.*`/`pane.*` for mutations

Root/elision state is currently **shared document state**, not viewer-local
state. Mouse policy is **viewer-owned region targeting** with no pointer
passthrough to nested panes in this slice.

## Collaboration modes and viewer sessions

Muxly needs to distinguish "shared document" from "shared viewer." The useful
cases are not all the same:

- one person mirrors another person's overall viewer/terminal session for
  teaching, supervision, or administration
- two people attach to the same document and read/navigate it independently
- two people attach to the same document and control different tty nodes
  simultaneously
- two people read/write the exact same tty node simultaneously

These cases suggest different semantics:

- shared document reading is core muxly magic and should be easy
- whole-session mirroring is valuable, but not the main document-collaboration
  case
- independent control of different tty nodes inside one document should fit the
  model cleanly
- simultaneous writers on one tty are plausible later, but are not required for
  the first useful collaboration cutline

The architectural consequence is that muxly should eventually model three
different things:

- **document state**: the shared TOM, node content, source attachments, and
  server-side tty endpoints
- **viewer session state**: an optional shareable attachment/camera object over
  one document or node
- **tty attachment state**: who is reading or writing one tty node, and under
  what role policy

For shared or inspectable viewer sessions, the right topography is a **star**:

- the daemon is the hub
- clients publish typed viewer-session snapshots/deltas to the daemon
- the daemon relays or exposes that state to other participants, observers, or
  admin tooling
- peer-to-peer viewer broadcast is not the primary muxly contract

That model allows both push and pull:

- a primary viewer can push changes as they happen
- another participant can subscribe to live session deltas
- an admin/observer can request the current session state without stealing
  control

The important discipline is that the daemon should not need opaque "broadcast
everything about your UI" behavior. Shared viewer state should be explicit and
typed, for example:

- current document or base TRD
- scoped root / zoomed node
- selected node or later input-focus token, if that becomes shareable
- viewport/camera origin and scroll state
- tty attachments and role claims
- viewer role metadata such as detached/primary/secondary, when terminal sizing
  semantics are in play

Under that model, the current `view.setRoot` / `view.clearRoot` behavior should
be read as a precursor implementation rather than final semantics. Storing view
root on the document is simple and testable, but it conflates document state
with one viewer's camera. If independent readers remain a first-class goal,
shared root/elision state should likely move out of `Document` and into an
optional viewer-session layer or another explicit shared-view object.

## Presentation substrate direction

The next viewer slice should evaluate how far tmux can carry the first
presentation substrate without distorting muxly semantics:

- if tmux can host the attached viewer session cleanly, formalize it as the
  first presentation substrate
- if tmux starts imposing the wrong viewing semantics, keep the attachment and
  projection model intact and move toward a vendored tmux path or a bespoke
  ANSI-generation engine

## Depthwise traversal / drill-in

When a user encounters an embedded TUI boundary or nested sub-muxml region, the
viewer should support traversing **into** that target rather than treating it as
dead decoration.

Acceptable UX patterns may include:

- scoped root remapping
- lightbox-like focused traversal
- full-screen pop-out views

Whichever pattern is used, users should get strong orientation cues:

- what boundary did I cross?
- where am I in the hierarchy?
- how do I get back out?

In the current implementation, the immediate precursor model is:

- a shared `viewRootNodeId` supplied by the daemon
- boxed stage boundaries showing the current scope boundary
- explicit external back-out affordances (`muxly view clear-root` /
  `muxly view reset`)
- visible elision markers when a node is hidden by shared view state

That is intentionally simpler than a full interactive drill-in UI, but it keeps
depthwise traversal state concrete, public, and testable.

It should be read as precursor architecture rather than as evidence that a
fully interactive depthwise viewer UX is already a current execution phase.

## Mouse policy

The current mouse policy is **viewer-owned region targeting**:

- mouse clicks select the smallest enclosing region at the click position
- selection drives the status bar, keyboard actions, and focused-pane entry
- no pointer events are passed through to nested tmux panes in this slice
- the policy is intentionally narrow; per-container pointer passthrough may
  come later when the contract is explicit enough to document and test

`capabilities.get` reports `supportsMouse: true`. The daemon accepts
`mouse.set` and reports the current policy, but the actual mouse protocol
handling lives in the viewer, not the daemon.
