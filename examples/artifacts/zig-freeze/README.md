# Zig Freeze Demo

This example uses Zig plus `muxly.h` against the built `libmuxly` shared
library to exercise the public terminal artifact freeze seam.

It creates:

- one transcript-ish tmux session and freezes it as `text`
- one surface-ish tmux session and freezes it as `surface`

Then it prints the frozen node payloads and a small parsed view of the surface
artifact sections.

## Quick Start

From the repo root:

```sh
./examples/artifacts/zig-freeze/run.sh
```

The wrapper will:

- run `zig build example-deps`
- default to `/tmp/muxly-example-zig-freeze.sock` unless `MUXLY_SOCKET` is set
- start `muxlyd` if nothing is listening on that socket
- run the Zig freeze demo against `libmuxly`
- stop the daemon only if the wrapper started it

## Inputs

- `MUXLY_SOCKET`
  Uses this socket if set. The wrapper otherwise defaults to
  `/tmp/muxly-example-zig-freeze.sock`.

## Intent

This playbook exists to show that a downstream Zig consumer can:

- create live tmux-backed state
- freeze tty-backed nodes through the public handle API
- inspect `artifactKind` and `contentFormat`
- interpret `sectioned_text` surface payloads without going through CLI-only paths
