# tty examples

These examples emphasize live terminal-backed behavior rather than only
synthetic TOM mutation.

They are meant to show that muxly can attach to real terminal activity and
render it coherently inside the TOM through a live viewer session. `muxview`
now stays attached by default on a terminal and repaints from the public
`view.get` surface; `--snapshot` keeps the deterministic one-shot readout
available when that is the better tool.

## Current families

- `basic-nesting/`
  A small live stage that scopes `muxview` to a synthetic parent and keeps an
  editor-like surface, a compile/error surface, and a relay surface moving
  together underneath it.

Current tmux-backed TTY examples now use the projected tmux shape rather than a
single loose tty leaf:

- synthetic parent
- tmux session `subdocument`
- tmux window `subdocument`
- projected pane `tty_leaf`
