# Freeze Demo

This playbook demonstrates muxly's first public terminal-artifact seam:

- a live tmux-backed node frozen as a **text** artifact
- a live tmux-backed node frozen as a **surface** artifact

The point is not that muxly already has a rich surface-capture model. The point
is that the TOM can now stop treating both cases as forever-live tty sources,
and can preserve a durable captured form with explicit intent.

## Quick Start

From the repo root:

```sh
./examples/artifacts/freeze-demo/run.sh
```

The wrapper will:

- run `zig build example-deps`
- default to `/tmp/muxly-example-freeze.sock` unless `MUXLY_SOCKET` is set
- start `muxlyd` if nothing is listening on that socket
- create one transcript-style tmux session and one surface-style tmux session
- freeze one node as `text` and the other as `surface`
- print the resulting frozen node payloads
- clean up the tmux sessions and daemon afterward

## Inputs

- `MUXLY_SOCKET`
  Uses this socket if set. The wrapper otherwise defaults to
  `/tmp/muxly-example-freeze.sock`.

## What To Look For

- both frozen nodes keep `kind = tty_leaf`
- both frozen nodes move to `lifecycle = frozen`
- both switch their source to `kind = terminal_artifact`
- one records `artifactKind = text`
- the other records `artifactKind = surface`
- the source metadata now also records `contentFormat`, so consumers can tell
  whether the payload is plain transcript text or a sectioned surface capture
- the surface payload is prefixed with `[surface]` and may also include an
  `[alternate]` section later when tmux exposes alternate-screen contents

The current surface demo deliberately runs in the terminal alternate screen so
the frozen `surface` case is at least exercising fullscreen-style behavior.
tmux does not always expose a separate alternate-screen payload in a way that
produces useful extra content here, so `[alternate]` should be treated as an
opportunistic bonus rather than a guaranteed section today.

That is the current first-pass implementation of the Phase 6 contract:
preserve node identity, change source/lifecycle semantics, and keep provenance.
