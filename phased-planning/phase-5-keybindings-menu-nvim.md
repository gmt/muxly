# phase 5 — keybindings, menus, and Neovim

## Goal

Move beyond the core muxml/tmux platform into the higher-level UX and
integration systems that motivated muxly's broader architecture:

- keybinding analysis
- modeline/menu projection
- Neovim-aware adapter work

This phase should turn those areas from "stable unsupported-capability stubs"
into explicit, capability-gated working subsystems.

## In scope

- keybinding conflict analysis engine
- library/client APIs, backed by server methods, for keybinding
  inspection/validation/proposal
- modeline/menu schemas and daemon-side storage/projection
- capability-gated platform/menu adapter work
- Neovim adapter boundary and initial attach/detach behavior

## Out of scope

- pretending all platform projections are production-ready from day one
- overpromising transparent Neovim pane semantics before runtime proof exists
- building a full menuing/windowing product before the data model is stable

## Acceptance criteria

- keybinding methods stop returning structured unsupported errors
- menu/modeline methods stop returning structured unsupported errors
- Neovim attach/detach methods stop returning structured unsupported errors
- capabilities and docs distinguish:
  - keybinding analysis support
  - menu/modeline projection support
  - Neovim integration support
- at least one repo-local proof/example exists for each subsystem that stops
  being scaffolded

## Repo baseline

Right now this phase is mostly scaffolding:

- the router exposes structured unsupported errors for:
  - `keybinding.*`
  - `modeline.*`
  - `menu.*`
  - `nvim.attach` / `nvim.detach`
- capability reporting still says:
  - `supportsMenuProjection = false`
  - `supportsNvimIntegration = false`
- repo docs already describe the intended direction in:
  - [`docs/keybinding-model.md`](/home/greg/src/muxly/docs/keybinding-model.md)
  - [`docs/neovim-integration.md`](/home/greg/src/muxly/docs/neovim-integration.md)
- menu/platform helper modules exist only as placeholders

## Remaining gaps

What still needs to become concrete before this phase feels real:

- a keybinding data model and first useful analysis cutline
- daemon-side modeline/menu state that can be queried and projected
- a platform-adapter posture that is capability-gated instead of hand-wavy
- a first explicit Neovim attach/detach contract and proof path

## Agentic-harness starting point

Do **not** start this phase by trying to implement every deferred subsystem at
once.

The first useful move should be the same move that helped in earlier phases:

1. make the execution order explicit
2. choose the smallest subsystem with the best leverage
3. leave behind one proof path before broadening outward

The recommended first substantive tranche is **keybinding analysis**, because it
is the least platform-specific and does not depend on menu adapters or Neovim
runtime behavior to become useful.

## Execution order

### Slice 1 — framing and capability cutline

Ground the phase in the repo as it exists now and make the first real
implementation tranche obvious.

Acceptance bar:

- the phase file names the current stubs, the first real implementation slice,
  and the proof path expected for each later slice

### Slice 2 — keybinding analysis contract and first engine

Turn keybinding analysis from architecture prose into a daemon-backed feature
with a narrow but real supported surface.

Current design target:

- start with inspection/conflict analysis, not automatic global remapping
- prefer one environment stack at first, then broaden:
  - terminal emulator
  - tmux
  - shell/app/editor layers later
- keep impossible terminal-encoding conflicts explicit rather than pretending
  all collisions are merely configurable

Acceptance bar:

- at least one `keybinding.*` method becomes real
- one documented keybinding payload shape exists
- one repo-local proof demonstrates a useful analysis result

### Slice 3 — menu/modeline schema and daemon state

Make menu/modeline work real first as **data and projection inputs**, not as
"magically appears in KDE/macOS."

Current design target:

- daemon-owned modeline/menu schema
- one query/set surface
- one internal representation that later adapters can consume

Acceptance bar:

- `modeline.*` and/or `menu.*` stop being pure unsupported stubs
- one stable schema/payload is documented
- one proof path shows stored state flowing through a public surface

### Slice 4 — capability-gated platform/menu projection

Only after the menu/modeline schema is real should platform projection become a
real slice.

Current design target:

- projection remains capability-gated and explicitly partial
- one platform path becoming real is more valuable than multiple fake ones
- unsupported platforms should still fail clearly and structurally

Acceptance bar:

- one real adapter path exists or one no-op/reference projection path is
  checked in explicitly
- capability reporting reflects the real supported surface
- docs stop implying projection is purely theoretical

### Slice 5 — Neovim adapter boundary and attach/detach

Treat Neovim integration as its own slice, not as a side effect of menu or
keybinding work.

Current design target:

- explicit attach/detach contract
- capability negotiation
- initial daemon-side adapter boundary
- no claims yet about complete pane transparency or perfect runtime fidelity

Acceptance bar:

- `nvim.attach` / `nvim.detach` stop being structured unsupported errors
- one repo-local proof demonstrates attach/detach behavior
- docs and capabilities describe the actual cutline honestly

### Slice 6 — proof hardening and docs close-out

Once one or more of the subsystems above are real, tighten proof and repo
storytelling so future contributors do not mistake scaffolding for support.

Acceptance bar:

- examples/docs/capabilities agree on what is actually supported
- unsupported-capability stubs remain only for the still-unimplemented areas
- at least one authoritative proof path exists for each newly real subsystem

## Per-slice proof

- Slice 1:
  docs-only proof
- Slice 2:
  one keybinding analysis proof/example
- Slice 3:
  one menu/modeline public-surface proof
- Slice 4:
  one capability-gated projection proof
- Slice 5:
  one Neovim attach/detach proof
- Slice 6:
  repo-local examples/docs/proof paths all agree

## Exit condition

This phase closes when keybinding analysis, menu/modeline projection, and the
initial Neovim adapter boundary are no longer merely scaffolded stubs, and the
repo can prove which parts are truly supported.

Current phase status:

- Slice 1: now framed in this file
- Slice 2: not started
- Slice 3: not started
- Slice 4: not started
- Slice 5: not started
- Slice 6: not started
- Phase 5 overall: execution-ready, implementation still deferred
