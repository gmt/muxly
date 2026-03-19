# libmuxly C / FFI reference

`libmuxly` exposes a small C ABI over muxly's transport and JSON-RPC surface.
The interface is intentionally thin: most functions return raw JSON-RPC
response payloads so downstream bindings can choose their own parsing and error
handling layer.

## Ownership rules

- `muxly_version()` returns static storage owned by `libmuxly`; do not free it.
- Successful `muxly_*` calls that return `char *` allocate a NUL-terminated
  UTF-8 response string.
- Release returned strings only with `muxly_string_free()`.
- `NULL` indicates failure.

## Client handles

- Create handles with `muxly_client_create()`.
- Destroy handles with `muxly_client_destroy()`.
- Handles are not thread-safe; synchronize externally if a host language wants
  to share one across threads.

## Input strings

- All string parameters are expected to be NUL-terminated.
- `muxly_client_node_update()` allows either `title` or `content` to be `NULL`
  as long as the other is non-null.
- Some tmux helpers accept an optional `command` string that may be `NULL`.

## Response shape

- The C ABI returns raw JSON-RPC response payloads instead of unpacked structs.
- Callers should parse the outer success/error envelope and inner `result`
  payload according to their needs.

## Examples

- `examples/tom/c/`
- `examples/tom/python/`
- `examples/artifacts/c-freeze/`
- `examples/artifacts/python-freeze/`

See `include/muxly.h` below for the generated reference view of the exported
surface.
