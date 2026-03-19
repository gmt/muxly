# demos

Examples and demos should stay discoverable rather than being buried in test
fixtures.

They are not merely bonus material: with a system this cross-platform and
behavior-heavy, runnable examples are part of the documentation contract and a
key way to demonstrate the framework's value proposition.

Core demos:

1. hello-muxly end-to-end
2. mixed-source muxml with:
   - one TTY-backed region
   - one monitored text file
   - one static text file
3. `muxview` consuming daemon state through the same public surfaces as other
   clients while staying attached to a live TOM stage

Reference example locations:

- `examples/README.md`
- `examples/artifacts/freeze-demo/`
- `examples/artifacts/c-freeze/`
- `examples/artifacts/python-freeze/`
- `examples/artifacts/zig-freeze/`
- `examples/tom/zig/`
- `examples/tom/c/`
- `examples/tom/python/`
- `examples/tty/basic-nesting/`
- `tests/integration/tmux_adapter_test.py` as the current reference mixed-source
  / tmux mutation flow

As the project grows:

- major feature tranches should leave behind at least one runnable example or
  demo path
- examples should show real user value, not only raw API syntax

Quick manual demo flow:

```sh
zig build
./zig-out/bin/muxlyd
./zig-out/bin/muxly capabilities get
printf 'alpha\nbeta\n' >/tmp/muxly-static.txt
printf 'tail-1\n' >/tmp/muxly-monitored.txt
./zig-out/bin/muxly leaf attach-file static-file /tmp/muxly-static.txt
./zig-out/bin/muxly leaf attach-file monitored-file /tmp/muxly-monitored.txt
./zig-out/bin/muxly session create demo "sh -lc 'printf hello-from-tmux\\n; sleep 30'"
./zig-out/bin/muxly document get
./zig-out/bin/muxly view set-root 2
./zig-out/bin/muxview
```

`muxview` attaches live by default when launched in a terminal. Press `q` to
leave the attached viewer session. When you want one deterministic rendered
frame instead, use:

```sh
./zig-out/bin/muxview --snapshot
```

Artifact-aware `muxview` manual verification:

Use this when you want to verify that `muxview` distinguishes live, detached,
and frozen terminal-backed nodes honestly through the same public surfaces used
by the automated tests. The snapshot form is handy here because the checks are
textual and deterministic.

```sh
zig build
./zig-out/bin/muxlyd
./zig-out/bin/muxly session create live-demo "sh -lc 'printf live-demo\\n; sleep 30'"
./zig-out/bin/muxly session create freeze-text-demo "sh -lc 'printf freeze-text-demo\\n; sleep 30'"
./zig-out/bin/muxly session create freeze-surface-demo "sh -lc 'printf freeze-surface-demo\\n; sleep 30'"
./zig-out/bin/muxly document get
# note the tty leaf node ids for the three new sessions from the document payload
./zig-out/bin/muxly node freeze <freeze-text-node-id> text
./zig-out/bin/muxly node freeze <freeze-surface-node-id> surface
./zig-out/bin/muxview --snapshot
```

What to confirm in the viewer output:

- the still-live tty node renders with `lifecycle=live`
- the frozen text node renders with `source=artifact:text`
- the frozen surface node renders with `source=artifact:surface`
- artifact metadata lines show tty provenance, content format, and sections
- if a tty node is later observed in `lifecycle=detached`, `muxview` prints
  `state :: detached tty source`

Automated integration flow:

```sh
zig build
python3 tests/integration/tmux_adapter_test.py
```

This is the current authoritative tmux-backend verification path while the backend
remains a command-backed/control-invalidating hybrid.

That flow now also exercises the current projected tmux shape:

- tmux session -> TOM `subdocument`
- tmux window -> nested `subdocument`
- tmux pane -> nested `tty_leaf`

The next substantive phase-4 tranche is no longer "make control mode exist."
That groundwork is in place. The remaining backend work is live event
application, drift handling, and reconnect.

Hello TOM example flow:

The shipped C / Zig / Python "hello TOM" examples now all follow the same
contract:

- they read `MUXLY_SOCKET` when it is set
- the playbook wrappers default to dedicated per-example sockets otherwise
- they create synthetic document/view state from scratch instead of assuming a
  useful pre-existing node id
- each example directory has a `README.md` plus `run.sh` playbook for
  self-contained local debugging

One simple way to exercise them against a live daemon is:

```sh
zig build example-deps
python3 scripts/run_binding_examples.py
```

Artifact freeze demo:

The first public Phase 6 seam is now runnable as a playbook too:

```sh
./examples/artifacts/freeze-demo/run.sh
```

That flow creates one transcript-like TTY and one surface-like TTY, freezes
them through `node.freeze`, and prints the resulting frozen artifact nodes.

Basic live viewer stage:

The `basic-nesting` playbook now launches a live attached `muxview` stage by
default:

```sh
./examples/tty/basic-nesting/run.sh
```

That stage leaves behind:

- one synthetic operator-note region
- one editor-like tty surface
- one compile/error-monitor tty surface
- one relay/agent-coordination tty surface

Use this when you want the quickest visual reminder of the intended viewer
story: one shared stage with several active tty-backed regions moving at
human-readable speed.

For a deterministic single frame of the same demo, use:

```sh
./examples/tty/basic-nesting/run.sh --snapshot
```

Binding-level artifact freeze demo:

There are also `libmuxly`-consumer versions of the same seam:

```sh
./examples/artifacts/c-freeze/run.sh
./examples/artifacts/python-freeze/run.sh
./examples/artifacts/zig-freeze/run.sh
```

Those playbooks exercise terminal artifact freezing through the public library
surface in C, Python/`ctypes`, and Zig, then print the frozen node payloads
plus a small parsed view of the surface artifact sections.

One simple way to run the currently shipped artifact playbooks together is:

```sh
python3 scripts/run_artifact_examples.py
```
