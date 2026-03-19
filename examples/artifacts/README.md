# artifacts

This family holds small checked-in witness artifacts for muxly's durable
terminal-artifact contract.

These are intentionally **not** emitted by the daemon yet. They exist to keep
the now-archived first-pass artifact contract grounded in concrete payload
shapes rather than vague future intent.

## Current witnesses

- `captured-text.txt`
  A transcript-like payload representing an append/history-oriented terminal
  interaction.
- `captured-surface.txt`
  A visible-screen snapshot representing a fullscreen/raw/surface-oriented
  terminal interaction.
- `c-freeze/`
  C / `libmuxly` verification path for the public terminal-artifact seam.
- `freeze-demo/`
  CLI/playbook verification path for `node.freeze <text|surface>`.
- `python-freeze/`
  `ctypes`/`libmuxly` verification path for the same public terminal-artifact seam.
- `zig-freeze/`
  Zig / `libmuxly` verification path for the same public terminal-artifact seam.
- `scripts/run_artifact_examples.py`
  Convenience runner for the currently shipped runnable artifact playbooks.

## Intent

- make the text-versus-surface distinction concrete in the repo
- preserve closure evidence for the archived first-pass `node.freeze` /
  terminal-artifact work
- give later TOM/muxml representation or persistence follow-ons something
  specific to point at
- avoid letting "whatever tmux scrollback happened to be" become the only
  durable example anyone has seen
