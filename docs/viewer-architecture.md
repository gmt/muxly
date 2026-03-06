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
