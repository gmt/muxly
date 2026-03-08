# viewer architecture

`muxview` is intended to be the reference implementation and universal viewer
for muxly documents.

## Design rule

`muxview` should use the same public API surface as other clients:

- no secret daemon APIs
- no privileged shortcuts
- no internal state bypasses unavailable to third-party consumers

## Responsibilities

- render muxml trees and regions
- provide drill-in/root/elision UX
- support follow-tail inspection
- host interaction-heavy UI ideas that do not need to be centralized

## Current phase-2 cutline

The current viewer is intentionally modest, but it should still make the public
state model legible:

- it consumes the public `view.get` surface, not a private daemon shortcut
- root/elision state is currently **shared document state**, not viewer-local
  state
- follow-tail is currently a **stored node preference**, not a private capture
  cursor inside `muxview`
- tmux interaction remains command-backed in this phase; richer control-mode
  behavior belongs to phase 4

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
