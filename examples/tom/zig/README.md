# Hello TOM in Zig

This example uses Zig plus the installed `libmuxly` C ABI surface.

## Quick Start

From the repo root:

```sh
./examples/tom/zig/run.sh
```

The wrapper will:

- run `zig build example-deps`
- default to `/tmp/muxly-example-zig.sock` unless `MUXLY_SOCKET` is set
- start `muxlyd` if nothing is listening on that socket
- run `basic_client.zig` against the built shared library
- stop the daemon only if the wrapper started it

## Inputs

- `MUXLY_SOCKET`
  Uses this socket if set. The wrapper otherwise defaults to
  `/tmp/muxly-example-zig.sock`, while the bare example itself falls back to
  `/tmp/muxly.sock`.

## Manual Flow

```sh
zig build example-deps
MUXLY_SOCKET=/tmp/muxly-example-zig.sock ./zig-out/bin/muxlyd
MUXLY_SOCKET=/tmp/muxly-example-zig.sock \
  LD_LIBRARY_PATH="$PWD/zig-out/lib" \
  zig run examples/tom/zig/basic_client.zig -lc -Izig-out/include -Lzig-out/lib -lmuxly
```
