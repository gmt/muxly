# C Freeze Demo

This example uses `libmuxly` through the public C ABI to exercise the terminal
artifact freeze seam.

It creates:

- one transcript-ish tmux session and freezes it as `text`
- one surface-ish tmux session and freezes it as `surface`

Then it prints the frozen JSON payloads and a small parsed view of the surface
artifact sections.

## Quick Start

From the repo root:

```sh
./examples/artifacts/c-freeze/run.sh
```

The wrapper will:

- run `zig build example-deps`
- build the local example binary
- default to `/tmp/muxly-example-c-freeze.sock` unless `MUXLY_SOCKET` is set
- start `muxlyd` if nothing is listening on that socket
- run the C freeze client
- stop the daemon only if the wrapper started it

## Inputs

- `MUXLY_SOCKET`
  Uses this socket if set. The wrapper otherwise defaults to
  `/tmp/muxly-example-c-freeze.sock`.

## Intent

This playbook exists to show that a downstream C consumer can:

- create tmux-backed state through `libmuxly`
- freeze tty-backed nodes with `muxly_client_node_freeze`
- inspect `artifactKind` and `contentFormat`
- interpret the `sectioned_text` surface payload without using CLI-only helpers
