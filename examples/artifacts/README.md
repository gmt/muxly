# artifacts

This family holds small checked-in witness artifacts for muxly's durable
terminal-artifact contract.

These are intentionally **not** emitted by the daemon yet. They exist to keep
Phase 6 grounded in concrete payload shapes before implementation hardens.

## Current witnesses

- `captured-text.txt`
  A transcript-like payload representing an append/history-oriented terminal
  interaction.
- `captured-surface.txt`
  A visible-screen snapshot representing a fullscreen/raw/surface-oriented
  terminal interaction.
- `c-freeze/`
  C / `libmuxly` proof for the public terminal-artifact seam.
- `freeze-demo/`
  CLI/playbook proof for `node.freeze <text|surface>`.
- `python-freeze/`
  `ctypes`/`libmuxly` proof for the same public terminal-artifact seam.
- `zig-freeze/`
  Zig / `libmuxly` proof for the same public terminal-artifact seam.
- `scripts/run_artifact_examples.py`
  Convenience runner for the currently shipped runnable artifact playbooks.

## Intent

- make the text-versus-surface distinction concrete in the repo
- give later TOM/muxml representation work something specific to point at
- avoid letting "whatever tmux scrollback happened to be" become the only
  durable example anyone has seen
