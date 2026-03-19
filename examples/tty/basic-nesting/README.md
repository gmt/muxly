# Basic TTY Nesting

This example creates a small synthetic stage node, attaches three live
tmux-backed TTY regions underneath it, scopes `muxview` to that stage, and
launches a live attached viewer by default.

The stage is intentionally a little theatrical: one region looks like an
editor, one looks like a compile/error monitor, and one looks like a relay
surface coordinating several workers. Together they show that a scoped viewer
session can treat several active TTY-backed regions as one shared stage.

Each tmux-backed region appears as a projected subtree:

- stage `subdocument`
- tmux session `subdocument`
- tmux window `subdocument`
- projected pane `tty_leaf`

## Quick Start

From the repo root:

```sh
./examples/tty/basic-nesting/run.sh
```

The wrapper will:

- run `zig build example-deps`
- default to `/tmp/muxly-example-tty-basic.sock` unless `MUXLY_SOCKET` is set
- start `muxlyd` if nothing is listening on that socket
- create a synthetic TOM scope plus one operator note and three live TTY stages
- project each tmux session/window/pane subtree underneath that scope
- attach `muxview` live so the stage keeps repainting until you press `q`
- clean up the tmux session and view state afterward

If you want a deterministic one-shot frame of the same stage, run:

```sh
./examples/tty/basic-nesting/run.sh --snapshot
```

## Inputs

- `MUXLY_SOCKET`
  Uses this socket if set. The wrapper otherwise defaults to
  `/tmp/muxly-example-tty-basic.sock`.

## Manual Idea

If you want to reconstruct the shape by hand, the important ingredients are:

- append a synthetic parent with `muxly node append`
- attach several tmux sessions underneath it with `muxly session create-under`
- observe the resulting `session -> window -> pane` projected subtrees
- set the shared root with `muxly view set-root`
- attach with `muxview` and watch the stage move
- use `muxview --snapshot` when you want a single captured frame instead
