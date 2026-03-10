# Basic TTY Nesting

This example creates a small synthetic stage node, attaches a live tmux-backed
TTY underneath it, scopes `muxview` to that stage, and prints the resulting
viewer snapshot.

The live source is a tiny theorem-prover-style chatter generator, so the output
shows a nested region that is both structurally scoped and actively changing.

## Quick Start

From the repo root:

```sh
./examples/tty/basic-nesting/run.sh
```

The wrapper will:

- run `zig build example-deps`
- default to `/tmp/muxly-example-tty-basic.sock` unless `MUXLY_SOCKET` is set
- start `muxlyd` if nothing is listening on that socket
- create a synthetic TOM scope plus a nested live TTY child
- print the scoped `muxview` output
- clean up the tmux session and view state afterward

## Inputs

- `MUXLY_SOCKET`
  Uses this socket if set. The wrapper otherwise defaults to
  `/tmp/muxly-example-tty-basic.sock`.

## Manual Idea

If you want to reconstruct the shape by hand, the important ingredients are:

- append a synthetic parent with `muxly node append`
- attach a tmux session underneath it with `muxly session create-under`
- set the shared root with `muxly view set-root`
- inspect the result with `muxview`
