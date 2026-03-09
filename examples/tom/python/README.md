# Hello TOM in Python

This example uses `ctypes` against the built `libmuxly` shared library.

The directory also includes a minimal `pyproject.toml` so the example has a
modern Python project surface without needing an old-style `setup.py`.

## Quick Start

From the repo root:

```sh
./examples/tom/python/run.sh
```

The wrapper will:

- run `zig build example-deps`
- default to `/tmp/muxly-example-python.sock` unless `MUXLY_SOCKET` is set
- start `muxlyd` if nothing is listening on that socket
- run `basic_client.py`
- stop the daemon only if the wrapper started it

## Inputs

- `MUXLY_SOCKET`
  Uses this socket if set. The wrapper otherwise defaults to
  `/tmp/muxly-example-python.sock`, while the bare example itself falls back to
  `/tmp/muxly.sock`.

## Manual Flow

```sh
zig build example-deps
MUXLY_SOCKET=/tmp/muxly-example-python.sock ./zig-out/bin/muxlyd
MUXLY_SOCKET=/tmp/muxly-example-python.sock python3 examples/tom/python/basic_client.py
```
