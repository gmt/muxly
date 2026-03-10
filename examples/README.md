# examples

Examples are grouped by what they are trying to prove, not only by language.

## Current structure

- `artifacts/`
  Small checked-in witness artifacts for the terminal text-versus-surface
  persistence contract.
- `tom/`
  Language-specific "hello TOM" examples that exercise the daemon's Terminal
  Object Model through the public `libmuxly` surface.
- `tty/`
  Live terminal-backed examples that emphasize nested scopes, tmux connectivity,
  and visually active regions.

## Current families

- `artifacts/`
  Contract examples for captured text/history versus captured surface payloads.
- `tom/c/`
  C binding playbook for synthetic TOM inspection and mutation.
- `tom/zig/`
  Zig binding playbook for the same "hello TOM" flow.
- `tom/python/`
  Python `ctypes` binding playbook for the same "hello TOM" flow.
- `tty/basic-nesting/`
  A minimal nested live-TTY playbook with theorem-prover-style chatter.

All current hello-TOM playbooks target `zig build example-deps` rather than a
full repo build, so example setup stays focused on the daemon, CLI, shared
library, and header they actually need.

## Intent

- keep the current TOM examples small, copyable, and language-aligned
- keep durable artifact examples concrete even before the daemon emits them
- leave room for future example families that emphasize live TTY behavior,
  richer demos, or more theatrical muxly experiences
- prefer adding a new family when an example proves a different modality rather
  than cramming everything into one flat directory
