# demos

Examples and demos should stay discoverable rather than being buried in test
fixtures.

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
