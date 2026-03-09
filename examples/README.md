# examples

Examples are grouped by what they are trying to prove, not only by language.

## Current structure

- `tom/`
  Language-specific "hello TOM" examples that exercise the daemon's Terminal
  Object Model through the public `libmuxly` surface.

## Current families

- `tom/c/`
  C binding playbook for synthetic TOM inspection and mutation.
- `tom/zig/`
  Zig binding playbook for the same "hello TOM" flow.
- `tom/python/`
  Python `ctypes` binding playbook for the same "hello TOM" flow.

All current hello-TOM playbooks target `zig build example-deps` rather than a
full repo build, so example setup stays focused on the daemon, CLI, shared
library, and header they actually need.

## Intent

- keep the current TOM examples small, copyable, and language-aligned
- leave room for future example families that emphasize live TTY behavior,
  richer demos, or more theatrical muxly experiences
- prefer adding a new family when an example proves a different modality rather
  than cramming everything into one flat directory
