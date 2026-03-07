# viewer architecture

`muxview` is intended to be the reference implementation and universal viewer
for muxly documents.

## Design rule

`muxview` should be an **ordinary client**:

- no secret daemon APIs
- no privileged shortcuts
- no internal state bypasses unavailable to third-party consumers

## Responsibilities

- render muxml trees and regions
- provide drill-in/root/elision UX
- support follow-tail inspection
- host interaction-heavy UI ideas that do not need to be centralized

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
