# phase 6 - archived: first-pass terminal artifact contract and freeze seam

## Status

Archived implemented material. This phase is no longer open roadmap work.

The named scope in the original phase did land: the repo has an explicit
terminal artifact contract, a first-pass `terminal_artifact` source family, a
public `node.freeze` seam, and matching examples/tests. Leaving the phase
"open" was muddying the difference between future persistence work and the
contract that already shipped.

## What shipped

The repo now has all of the following:

- `docs/terminal-artifacts.md` defines:
  - live tty source
  - detached but recoverable tty source
  - captured text artifact
  - captured surface artifact
- the core model preserves node identity and tty provenance across freeze into
  captured text/surface artifacts
- JSON-RPC, Zig API, CLI, and C ABI expose `node.freeze <node-id> <text|surface>`
- `examples/artifacts/` contains checked-in witness artifacts for the text and
  surface payload families
- `examples/artifacts/freeze-demo/` and `scripts/run_artifact_examples.py`
  provide runnable verification
- unit and integration coverage exercise both public freeze branches

## Closure evidence

The repo-local closure path for this archived phase is:

- `zig build`
- `zig build test`
- `python3 tests/integration/tmux_adapter_test.py`
- `./examples/artifacts/freeze-demo/run.sh`
- `python3 scripts/run_artifact_examples.py`

## Why archived instead of active

This phase is archived because:

- the original goal was to define the terminal-artifact contract and land a
  first public seam, and that goal is already satisfied
- the repo now explicitly distinguishes captured text versus captured surface
  payloads instead of leaving the durable story completely ambiguous
- the remaining future work is different in shape from the closed phase and
  should not inherit the old acceptance criteria by inertia

## What this file is still useful for

This file is now a historical and navigational pointer:

- it points roadmap readers at `docs/terminal-artifacts.md`
- it records what the old phase actually closed
- it reminds future contributors that muxly intentionally separated tty
  provenance from "tmux scrollback forever" as the durable policy

## Not covered by this archived phase

This archived phase does not claim to solve:

- rehydrate semantics
- export/import or durable daemon-store strategy
- richer detached-node behavior beyond the current first-pass contract
- backend-independent persistence beyond the current `node.freeze` seam

If any of that becomes active later, write a new narrower follow-on doc instead
of reopening phase 6.

## Current status

- terminal artifact contract: archived implemented
- `node.freeze` public seam: archived implemented
- future persistence/rehydrate ideas: not active roadmap material here
- Phase 6 overall: archived first-pass complete
