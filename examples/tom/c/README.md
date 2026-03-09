# Hello TOM in C

This example shows the phase-3 `libmuxly` C ABI using the synthetic
node/view scaffold.

## Quick Start

From the repo root:

```sh
./examples/tom/c/run.sh
```

The wrapper will:

- run `zig build example-deps`
- default to `/tmp/muxly-example-c.sock` unless `MUXLY_SOCKET` is set
- start `muxlyd` if nothing is listening on that socket
- build `basic_client` through the local `Makefile`
- run the example
- stop the daemon only if the wrapper started it

## Inputs

- `MUXLY_SOCKET`
  Uses this socket if set. The wrapper otherwise defaults to
  `/tmp/muxly-example-c.sock`, while the bare example itself falls back to
  `/tmp/muxly.sock`.

## Manual Flow

If you want to drive it yourself:

```sh
make -C examples/tom/c all
MUXLY_SOCKET=/tmp/muxly-example-c.sock ./zig-out/bin/muxlyd
MUXLY_SOCKET=/tmp/muxly-example-c.sock ./examples/tom/c/basic_client
```

If you want the self-contained path through `make`, use:

```sh
make -C examples/tom/c play
```
