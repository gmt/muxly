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
   clients

Reference example locations:

- `examples/README.md`
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

Automated integration flow:

```sh
zig build
python3 tests/integration/tmux_adapter_test.py
```

This is the current authoritative tmux-backend proof path while the backend
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
