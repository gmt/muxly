# viewer architecture

`muxview` is intended to be the reference implementation and universal viewer
for live muxly documents.

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

- **viewer attachment** is the long-lived session that joins one TOM node
  through a concrete viewport and local interaction state
- **layout projection** is the continuously maintained mapping from
  `TOM + viewer state + viewport size` to visible regions
- **presentation substrate** is the mechanism that repaints that attached
  session over time
- **snapshot mode** is the explicit one-shot readout path for scripts,
  deterministic checks, and debugging

The current cutline already supports that model in a first-pass way:

- `muxview` attaches live by default when stdout is a TTY
- it enters the alternate screen, refreshes on a fixed cadence, and repaints
  from the public `view.get` surface
- `muxview --snapshot` keeps the one-shot textual readout available when a
  deterministic frame is the right tool
- tmux is the current likely first presentation substrate because it already
  buys much of the terminal/session machinery, while remaining replaceable if
  it later constrains the desired muxly experience

## Current phase-2 cutline

The current viewer is intentionally modest in interaction depth, but it should
still make the public state model legible:

- it consumes the public `view.get` surface, not a private daemon shortcut
- the first attached-viewer loop is still a textual presentation of that public
  projection rather than a richer tiled compositor
- root/elision state is currently **shared document state**, not viewer-local
  state
- follow-tail is currently a **stored node preference**, not a private capture
  cursor inside `muxview`
- tmux interaction remains command-backed in this phase; richer control-mode
  behavior belongs to phase 4

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

In the current phase-2 implementation, the immediate precursor model is:

- a shared `viewRootNodeId` supplied by the daemon
- breadcrumb/path text showing the current scope boundary
- explicit back-out affordances (`muxly view clear-root` / `muxly view reset`)
- visible elision markers when a node is hidden by shared view state

That is intentionally simpler than a full interactive drill-in UI, but it keeps
depthwise traversal state concrete, public, and testable.

## Mouse policy direction

Mouse behavior in a recursive terminal framework is a deliberately open design
problem. The current direction is:

- favor intuitive region targeting over purity of embedding boundaries
- keep behavior predictable even when mouse-supporting and non-mouse-supporting
  layers are nested
- accept flattening or adapter logic if needed to make visible regions behave
  the way users expect

The exact policy may evolve, but the project should behave according to an
explicit declared policy rather than ad hoc accidents.
