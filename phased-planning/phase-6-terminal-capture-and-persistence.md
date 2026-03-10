# phase 6 — terminal capture, scrollback, and durable artifacts

## Goal

Define the durable TOM/muxml contract for terminal-backed nodes so muxly does
not get trapped into "tmux scrollback forever" as an accidental permanent
policy.

This phase exists to answer a structural question before persistence/export
semantics harden too far:

- when a live TTY source is frozen, serialized, detached, or dies, what exactly
  should remain in the TOM?

## In scope

- distinction between:
  - live TTY-backed nodes
  - captured text/history artifacts
  - captured terminal-surface artifacts
- relationship between:
  - process/pty truth
  - tmux-provided scrollback/history
  - alternate-screen / raw-mode surface state
  - durable muxml payload
- lifecycle policy for:
  - process death
  - explicit freeze/export
  - detach/reconnect boundaries
- whether these transitions are represented as:
  - new node kinds
  - source-kind transitions
  - lifecycle-state transitions
  - or some combination

## Out of scope

- full implementation of a replacement terminal backend
- pretending tmux's current history model is the final truth
- UI polish unrelated to capture/persistence semantics

## Acceptance criteria

- one explicit written contract exists for how terminal-backed TOM nodes
  persist into durable artifacts
- the contract distinguishes append-ish/history-oriented cases from
  fullscreen/raw/surface-oriented cases
- docs stop leaving it ambiguous whether muxml persists tmux scrollback,
  terminal surface state, or both
- at least one concrete proof/example exists for each durable artifact family

## Repo baseline

Right now muxly treats TTYs primarily as live sources:

- tmux-backed panes project into TOM `tty_leaf` nodes
- pane content is currently refreshed/captured through tmux
- muxml persists the current TOM/document state
- the repo does **not** yet define a final durable contract for what a dead or
  frozen terminal-backed node should become

## Remaining gaps

What still needs to be designed before this area feels safe:

- whether dead/frozen TTY nodes collapse into plain UTF-8 blobs, surface
  snapshots, or different artifact families depending on mode
- how much trust muxly places in tmux scrollback/history as a durable source
- how alternate screen/raw-mode applications should serialize honestly
- how reconnect/recoverable live nodes differ from irreversibly captured ones

## Agentic-harness starting point

Start this phase as a design-contract pass, not as an implementation binge.

The first useful move is to write down:

1. the artifact families muxly wants
2. the transitions that create them
3. the minimum examples that prove the distinctions are worth having

First-pass Slice 1 contract:

- [`docs/terminal-artifacts.md`](/home/greg/src/muxly/docs/terminal-artifacts.md)
  now defines the initial artifact families and transition posture

## Execution order

### Slice 1 — terminology and artifact contract

Name the durable artifact families clearly and define when a live TTY-backed
node stays live, becomes recoverable-but-detached, or becomes a durable
captured artifact.

Current status:

- first-pass complete
- the first-pass contract distinguishes:
  - live tty source
  - detached but recoverable tty source
  - captured text artifact
  - captured surface artifact
- the contract also says explicitly that tmux scrollback is useful backend
  evidence but not the final durable policy on its own

### Slice 2 — append/history vs surface/raw distinction

Decide how muxly distinguishes append-ish text/history cases from
fullscreen/raw/alternate-screen surface cases and what each should serialize
into.

Current status:

- first-pass complete
- the contract now names concrete example classes for both families:
  - shell/log/transcript cases bias toward captured text artifacts
  - fullscreen/raw/alternate-screen cases bias toward captured surface
    artifacts
- alternate-screen behavior is now called out explicitly as a surface-biased
  durable case even when tmux history exists

### Slice 3 — muxml/TOM representation

Choose whether the durable forms are represented by new node kinds, source
transitions, lifecycle states, or some hybrid.

### Slice 4 — proof artifacts

Add small checked-in examples/proof paths for the chosen durable forms so the
contract is not purely theoretical.

## Per-slice proof

- Slice 1:
  design doc / roadmap contract only
- Slice 2:
  concrete example cases that demonstrate why the distinction matters
- Slice 3:
  docs/tests that show the chosen TOM/muxml representation
- Slice 4:
  repo-local proof/example for durable capture behavior

## Exit condition

This phase closes when muxly has an explicit durable terminal-artifact story
that does not accidentally reduce to "whatever tmux scrollback happened to be."

Current phase status:

- Slice 1: first-pass complete
- Slice 2: first-pass complete
- Slice 3: open
- Slice 4: open
