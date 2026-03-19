# Guided Tour

`muxguide` is a synthetic stage demo for the boxed viewer. It does not talk to
`muxlyd` or tmux; instead it builds an in-memory TOM, applies a few deterministic
story beats, runs that through `projection.get`-style logic, and renders the
same boxed surface that `muxview` now uses.

It is meant to exercise the browsing/thread metaphor directly:

- top-level chrome
- a scrollable thread/document area
- a live-activity column
- a nested sub-agent stage
- viewer-local focus and scroll offsets

## Run

```sh
zig build muxguide
./zig-out/bin/muxguide
```

Press `q` to leave the live tour.

For deterministic snapshots:

```sh
./zig-out/bin/muxguide --snapshot --step 0
./zig-out/bin/muxguide --snapshot --step 2 --rows 18 --cols 72
```
