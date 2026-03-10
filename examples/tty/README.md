# tty examples

These examples emphasize live terminal-backed behavior rather than only
synthetic TOM mutation.

They are meant to prove that muxly can attach to real terminal activity and
render it coherently inside the TOM.

At the current cutline, `muxview` is still a screen-at-a-time reference viewer:
it renders a fresh textual snapshot of live state when invoked, rather than
staying resident and repainting continuously. That means the TTY examples are
currently best understood as snapshots of live terminal-backed structure, not
yet as a full continuously updating nested-terminal UI.

## Current families

- `basic-nesting/`
  A small nested live-TTY example that scopes `muxview` to a synthetic parent
  and shows a theorem-prover-style generator running underneath it.

Current tmux-backed TTY examples now use the projected tmux shape rather than a
single loose tty leaf:

- synthetic parent
- tmux session `subdocument`
- tmux window `subdocument`
- projected pane `tty_leaf`
