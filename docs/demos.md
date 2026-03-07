# demos

Examples and demos should stay discoverable rather than being buried in test
fixtures.

They are not merely bonus material: with a system this cross-platform and
behavior-heavy, runnable examples are part of the documentation contract and a
key way to demonstrate the framework's value proposition.

Planned first demos:

1. hello-muxly end-to-end
2. mixed-source muxml with:
   - one TTY-backed region
   - one monitored text file
   - one static text file
3. `muxview` consuming daemon state as an ordinary client

Reference example locations:

- `examples/zig/basic_client.zig`
- `examples/c/basic_client.c`
- `examples/python/basic_client.py`
- `tests/integration/tmux_adapter_test.py` for an end-to-end tmux/file-backed flow

Expectation for future phases:

- major feature tranches should leave behind at least one runnable example or
  demo path
- examples should show real user value, not only raw API syntax

Quick manual demo flow:

```sh
zig build
./zig-out/bin/muxlyd
./zig-out/bin/muxly capabilities get
./zig-out/bin/muxly leaf attach-file static-file /tmp/example.txt
./zig-out/bin/muxly file capture 3
./zig-out/bin/muxview
```
