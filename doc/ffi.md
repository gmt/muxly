# libmuxly C / FFI reference

`libmuxly` exposes a small C ABI over muxly's transport and JSON-RPC surface.
The interface is intentionally thin: most functions return raw JSON-RPC
response payloads so downstream bindings can choose their own parsing and error
handling layer.

For backward compatibility, the header still exposes the original `char *`-only
entry points. New bindings should prefer the `_ex` variants plus
`muxly_status`, because they make library-side failures explicit without
overloading `NULL`.

## Ownership rules

- `muxly_version()` returns static storage owned by `libmuxly`; do not free it.
- Successful `muxly_*` calls that return `char *` allocate a NUL-terminated
  UTF-8 response string.
- Release returned strings only with `muxly_string_free()`.
- Client handles own their copied `socket_path` and release it in
  `muxly_client_destroy()`.

## Client handles

- Create handles with `muxly_client_create()`.
- Destroy handles with `muxly_client_destroy()`.
- Handles are not thread-safe; synchronize externally if a host language wants
  to share one across threads.
- A handle stores configuration, not a persistent daemon-side session; each
  request still performs its own transport round-trip.

## Failure model

- A non-`NULL` return is always a response buffer owned by the caller.
- That response buffer may still contain a JSON-RPC error payload from the
  daemon; callers should inspect the JSON-RPC envelope instead of treating
  non-`NULL` as unconditional success.
- `NULL` means `libmuxly` failed before it could return a response string.
- Typical `NULL` causes include allocation failure inside `libmuxly`,
  unsupported platform in the current transport layer, socket/transport
  failures, or client-side validation failures such as calling
  `muxly_client_node_update()` with both `title` and `content` set to `NULL`.
- The legacy `char *`-returning API does not expose structured reasons for
  `NULL`; use the `_ex` variants when bindings need richer library-side
  diagnostics.

## Structured status API

- The `_ex` entry points return `muxly_status` instead of overloading `NULL`.
- `MUXLY_STATUS_OK` means libmuxly successfully produced an output value.
- Response-oriented `_ex` functions write a caller-owned JSON-RPC response
  string through `out_response`.
- That response string may still be a daemon-side JSON-RPC error payload, so
  callers must still inspect the envelope.
- Non-`OK` status values distinguish at least:
  - `MUXLY_STATUS_NULL_ARGUMENT`
  - `MUXLY_STATUS_INVALID_ARGUMENT`
  - `MUXLY_STATUS_UNSUPPORTED_PLATFORM`
  - `MUXLY_STATUS_ALLOCATION_FAILURE`
  - `MUXLY_STATUS_TRANSPORT_FAILURE`
- `muxly_status_string()` returns a stable human-readable name for one status
  code.

## Legacy API

- The original `char *`-returning functions remain available for compatibility
  and for tiny scripts/examples.
- They are still reasonable for quick use, but new bindings should generally
  prefer the `_ex` variants.

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
