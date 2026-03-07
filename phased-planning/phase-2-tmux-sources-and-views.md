# phase 2 — tmux, sources, and views

## Goal

Turn muxly from a phase-1 bootstrap into a practically useful mixed-source
terminal/document system:

- tmux-backed live leaves
- monitored/static file leaves
- append-oriented capture and scrollback semantics
- explicit follow-tail semantics
- robust synthetic muxml editing alongside live sources
- view root/elision/reset behavior that is clearly scoped and truthfully
  documented
- a viewer story that reflects the public view model and makes nested traversal
  legible

## Why this phase still matters even though much of it already exists

This branch already contains a substantial **command-backed** implementation of
phase 2:

- tmux session/window/pane creation and mutation helpers
- pane capture / scroll / send-keys / resize / focus / close
- static and monitored file attachments
- synthetic node append/update/remove
- document/node/session/window/pane inspection
- view set-root / clear-root / elide / expand / reset
- a basic ordinary-client viewer that reflects the current document/view state

That is good progress, but phase 2 should not be treated as "done except for
control mode." Several important semantics are still under-specified or
under-documented:

- transport/capability claims still need to match reality
- follow-tail currently risks meaning "stored boolean" rather than explicit
  behavior
- view-root/elision semantics need a clear scope boundary
- drill-in/orientation behavior needs a concrete model instead of hand-wavy UX
  intent
- examples/docs/tests should prove the mixed-source public surface, not merely
  imply it

This file should therefore be read as both:

- a record of what phase 2 already has in command-backed form
- the execution target for the remaining semantic/documentation/coherence work
  needed to close the phase cleanly

## Carry-forward from phase 1

Phase 1 established the foundation, but several objectives were only partially
closed and now need to be explicitly carried into phase 2.

### 1. Transport and capability truthfulness

Phase 1's protocol/build/bootstrap story should not overclaim transports or
platform readiness that do not yet exist in the branch. In particular:

- transport docs must match the transports actually implemented
- capability reporting must not advertise support that is still scaffolded only
- platform notes should distinguish compile targets from runtime-ready paths

Phase 2 owns cleaning up those public truth claims anywhere they affect the
tmux/source/view surface.

### 2. Ordinary-client and view-state coherence

Phase 1 established the viewer as an ordinary client. Phase 2 must make that
meaningful by explicitly resolving the scope of view transforms:

- if root/elision/reset semantics are truly viewer-local or client-local, phase
  2 should implement and test that
- if they remain daemon-shared for now, phase 2 should say so plainly and make
  the protocol/docs/tests consistent with that reality

The project should not quietly claim "local view state" while persisting that
state in shared document storage.

### 3. Examples, demos, and tests as living proof

Phase 1's "examples run" expectation needs to be carried forward into the new
surface area introduced here. Mixed-source trees, tmux mutation flows, and view
transforms should be left behind with runnable proof paths rather than only
code-level intent.

## In scope

The remaining phase-2 work is best understood as a set of workstreams rather
than one flat bullet list.

### Workstream A — mixed-source leaf attachments and introspection

Deliver:

- tmux-backed live leaves
- monitored file leaves
- static file leaves
- `leaf.source.attach` / `leaf.source.get`
- `document.get`, `node.get`, `session.list`, `window.list`, `pane.list`

Acceptance criteria:

- A mixed-source document can be assembled through public surfaces containing
  at least:
  - one tty-backed live leaf
  - one monitored file leaf
  - one static file leaf
- Each attached source is visible through `document.get` and
  `leaf.source.get`, with source metadata that matches the attached
  backend/path.
- `session.list`, `window.list`, and `pane.list` return information that is
  consistent with the current muxml document for tmux-backed nodes.
- Integration coverage proves mixed-source documents rather than relying only
  on unit tests or manual inspection.

### Workstream B — tmux mutation coverage

Deliver:

- `session.create`
- `window.create`
- `pane.split`
- `pane.capture`
- `pane.scroll`
- `pane.sendKeys`
- `pane.resize`
- `pane.focus`
- `pane.close`

Acceptance criteria:

- Every listed tmux helper is invokable through the public protocol and the CLI
  without private daemon-only shortcuts.
- At least one end-to-end integration path proves:
  - create session/window/pane
  - capture pane output
  - send keys and observe resulting output
  - split a pane
  - resize and focus panes
  - close a pane
- Closing a pane removes or otherwise invalidates the corresponding node/leaf
  mapping in a documented, test-verified way.
- The phase doc and backend docs explicitly describe this implementation as
  command-backed unless/until phase 4 replaces it.

### Workstream C — append, capture, scrollback, and follow-tail semantics

Deliver:

- append-oriented capture behavior as the common-case bias
- scrollback/capture access through public APIs
- follow-tail controls for tty and monitored-file leaves
- an explicit statement of what "follow-tail" means in this phase

Acceptance criteria:

- The phase exit criteria explicitly state whether follow-tail in phase 2 means:
  - a persisted node/view preference only, or
  - observable capture-position/view behavior with runtime effects
- Whichever meaning is chosen is documented in protocol/viewer/backend docs and
  backed by tests.
- Scroll/capture behavior is described in testable public-API terms rather than
  as an implicit viewer trick.
- If follow-tail remains only a stored preference in this phase, that
  limitation is called out directly instead of being hidden behind suggestive
  wording.

### Workstream D — synthetic muxml node editing

Deliver:

- `node.append`
- `node.update`
- `node.remove`
- editing of non-source/synthetic muxml nodes inside mixed-source trees

Acceptance criteria:

- Synthetic nodes can be appended, updated, and removed through public APIs.
- Structural constraints are made explicit, such as whether removal is only
  valid for childless nodes.
- Tests prove synthetic editing coexists cleanly with attached source nodes in
  the same document rather than existing as an isolated toy path.

### Workstream E — view root, elision, expand, clear-root, and reset semantics

Deliver:

- `view.setRoot`
- `view.clearRoot`
- `view.elide`
- `view.expand`
- `view.reset`
- viewer reflection of the resulting state

Acceptance criteria:

- Phase 2 explicitly resolves the scope of view state:
  - truly viewer-local / client-local, or
  - shared daemon/document state for now
- Protocol docs, viewer docs, and tests all use wording that exactly matches
  the chosen scope; they must not claim local overrides if the implementation is
  still shared.
- A public-API test path verifies set-root, clear-root, elide, expand, and
  reset behavior.
- `muxview`, even if still minimal, visibly reflects root/elision state rather
  than silently ignoring it.

### Workstream F — drill-in and nested-boundary orientation

Deliver:

- depthwise traversal semantics for nested sub-muxml or embedded TUI boundaries
- orientation cues so users know what they drilled into and how to get back out
- a state model that can be validated independently of polished UI chrome

Acceptance criteria:

- Drill-in is not left as an implicit UI trick or aspirational note.
- Phase 2 defines either:
  - implemented drill-in behavior, or
  - an immediate precursor state model that is independently documented and
    testable
- Orientation cues are concrete enough to verify, such as one or more of:
  - breadcrumb/path labeling
  - explicit boundary annotations
  - current-scope title/context text
  - a documented "back out" affordance
- The user should not be able to enter a deeper target and lose track of where
  they are in the hierarchy with no declared recovery path.

### Workstream G — documentation, examples, and test coherence

Deliver:

- aligned protocol/backend/viewer docs
- mixed-source demo/example expectations
- tests that reflect actual public behavior
- no inflated claims about transports, locality, or backend sophistication

Acceptance criteria:

- Phase 2 leaves behind at least one runnable mixed-source flow that future
  users/agents can use as living proof.
- Integration coverage exists for both:
  - mixed-source documents
  - tmux mutation flows
- Repo-visible docs avoid overstating features that are only scaffolded or
  deferred.
- The current implementation is described as command-backed where applicable,
  with control-mode/recovery work explicitly handed off to phase 4.

## Out of scope

The following remain outside phase 2 and belong to later work, primarily phase
4:

- full control-mode/stateful tmux event engine
- reconnect/recovery logic after daemon or tmux drift
- authoritative tmux snapshot rebuilding from control-mode state
- generalized monitoring overlays beyond the implemented file-source semantics
- full persistent snapshot/rehydration semantics

Deferring these items does **not** mean phase 2 can leave semantic ambiguity in
place. Phase 2 is still responsible for making the command-backed public
surface explicit, truthful, and testable.

## Acceptance criteria

Phase 2 should only be called complete once all of the following are true:

- mixed-source document creation and inspection are proven through public APIs
- tmux mutation flows work end-to-end through the public protocol/CLI
- append/capture/scrollback/follow-tail behavior is explicitly defined and
  backed by tests
- synthetic muxml editing is covered and works alongside live/file-backed nodes
- view-root/elision/reset semantics are explicitly scoped and reflected by the
  viewer
- drill-in behavior, or a clearly defined precursor boundary-state model, is
  documented and testable
- phase-1 carry-forward items around transport truthfulness, ordinary-client
  coherence, and living proof artifacts are resolved or explicitly documented
- docs/examples/tests describe the branch as it actually exists rather than as
  an aspirational future state

## Current branch status

Substantial command-backed phase-2 functionality already exists and is backed by
build/test evidence. The biggest **backend architecture** gap is still the move
from ad hoc tmux command polling to a richer control-mode-backed state/recovery
layer, which belongs to phase 4.

However, phase 2 should not yet be treated as fully closed. Important remaining
work includes clarifying follow-tail semantics, reconciling claimed local view
behavior with actual shared state if necessary, tightening drill-in/orientation
expectations, and keeping transports/docs/capabilities/examples honest and
aligned with the public surface.
