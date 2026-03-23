# muxly protocol

The current daemon control protocol is JSON-RPC 2.0.

Most consumers should prefer the library/client API layer when it is
available. This document exists so the underlying server conversation format is
explicit, testable, and debuggable.

## Currently implemented transport

- Unix domain sockets on Linux/macOS
- raw TCP on Linux/macOS
- HTTP/1.1 via explicit `http://` bridge transport
- HTTP/2 (H2C) via explicit `h2://` bridge transport
- secure TCP with `https://` / `https1://` / `https2://` bridge transports
- WebTransport-over-HTTP/3 via explicit `h3wt://` bridge transport

## Transport roadmap notes

- Windows named pipes are scaffolded in naming/API shape only and are **not**
  yet implemented in this branch
- stdio embedding/testing transport is planned but **not** yet implemented
- `capabilities.get` reports only transports that actually exist on the current
  runtime target
- `trds://...` secure descriptors now resolve to secure TCP transports:
  - `trds://ht|...` => prefer secure H2, allow secure H1 fallback
  - `trds://ht1|...` => strict secure H1
  - `trds://ht2|...` => strict secure H2
- secure TCP client trust defaults to the OS trust store, with explicit local
  overrides for CA bundle, pin, and SNI
- direct secure `muxlyd` listeners are still deferred; secure deployment is
  still Caddy HTTPS -> loopback muxly upstream

## Currently implemented methods

### Lifecycle and capability discovery

- `initialize`
- `ping`
- `capabilities.get`

### Documents, views, and graph inspection

- `document.create`
- `document.list`
- `document.get`
- `document.status`
- `document.serialize`
- `document.freeze`
- `node.get`
- `node.append`
- `node.update`
- `node.freeze`
- `node.remove`
- `session.list`
- `window.list`
- `pane.list`
- `graph.get`
- `view.get`
- `projection.get`
- `view.clearRoot`
- `view.setRoot`
- `view.elide`
- `view.expand`
- `view.reset`
- `mouse.set`

### Leaf/source operations

- `leaf.source.attach`
- `leaf.source.get`

### tmux-backed helpers

- `session.create`
- `window.create`
- `pane.split`
- `pane.capture`
- `pane.scroll`
- `pane.capture.stream.open`
- `pane.scroll.stream.open`
- `pane.resize`
- `pane.focus`
- `pane.sendKeys`
- `pane.close`
- `pane.followTail`

### file-backed helpers

- `file.capture`
- `file.followTail`

## Current response-shape notes

- `graph.get` currently aliases the same muxml/tree payload returned by
  `document.get` / `view.get`
- `document.status` returns a smaller lifecycle/count-oriented payload
- created documents currently live for the daemon lifetime; there is no public
  delete/close surface in this slice
- `document.get` / `view.get` currently expose **shared document-scoped** view
  state through `viewRootNodeId` and `elidedNodeIds`; these are not
  per-viewer local overrides in this phase
- [TODO] that shared document-scoped view state is transitional; the intended
  direction is an explicit viewer-session/shared-view layer rather than
  storing one viewer's camera on the document itself
- document `path` is the public document handle for now; internal numeric
  document ids remain introspection/status data, not caller-facing identity
- the root document `/` is built in, selected by default, and not creatable via
  `document.create`
- `document.create` currently accepts:
  - `path`: canonical absolute non-root document path
    - must start with `/`
    - must not end with `/`
    - must not contain empty, `.` or `..` segments
  - optional `title`
- `document.list` returns the daemon's registered document catalog, including
  each document's path, id, title, lifecycle, retention policy, root node id,
  and node count
- `document.status` currently includes:
  - path, id, title
  - lifecycle and `retentionPolicy`
  - root/view root ids
  - node/elision counts
- request `target` metadata now supports:
  - `documentPath`
  - optional `nodeId`
  - optional `selector`
- `target.documentPath` currently follows the same canonical absolute-path rule
  as `document.create`, except that `/` is valid and selects the built-in root
  document
- daemon-owned node-targeted methods currently prefer `target.nodeId` over
  legacy `params.nodeId` when both are present
- when `target.selector` is present, daemon-owned node-targeted methods now
  resolve it within the targeted document using the same segment semantics as
  TRD selectors:
  - empty or `/` => document root
  - `.` / `..` for relative traversal
  - `@42`, `42`, `node-42` for direct node references
  - otherwise sibling `name` matching beneath the current node
- `projection.get` is the current public boxed-view surface for one concrete
  viewport; it combines:
  - shared document state from the daemon-owned TOM
  - viewer-local viewport size
  - optional viewer-local focus and scroll offsets
- `projection.get` should currently be read as a structural/layout-facing
  surface rather than as the final definition of viewer-side imaging/composition
- the current attached `muxview` loop polls `projection.get` for boxed layout
  and shared view state; snapshot mode uses that same surface for a one-shot
  rendered frame
- on native H3/WT tty paths, the reference viewer may also consume a live tty
  output stream for direct leaf output instead of relying on repeated projection
  polling alone
- additive pane-capture streaming currently exists as a conversation/native-stream
  path:
  - `pane.capture.stream.open`
  - `pane.scroll.stream.open`
  - these return finite chunk streams rather than one eager whole-message blob
  - native `h2://` and `h3wt://` clients can consume those streams directly
  - buffered compatibility transports still use eager `pane.capture` /
    `pane.scroll` in this slice
- `node.remove` currently succeeds only for childless nodes; callers should
  remove descendants first when editing synthetic muxml structure
- `node.freeze` currently supports tty-backed nodes only and accepts an
  `artifactKind` of `text` or `surface`; it preserves node identity while
  transitioning the source into a durable `terminal_artifact` form, including
  an explicit `contentFormat` plus first-pass `sections` metadata in the source
  payload and freeze response
- `view.reset` clears shared root/elision transforms stored in the daemon's
  current document state without mutating source attachments or node content
- generic document/node/view/file methods now honor `target.documentPath`
- tmux-backed methods remain rooted to `/` for now; targeting another document
  returns a structured unsupported error instead of mutating the root document
- library/client surfaces that accept a document path for tmux-backed methods
  should reject non-root targets early, but the server still performs the same
  refusal when raw callers bypass that validation
- `session.create` accepts an optional `parentId`; when omitted it attaches the
  new TTY leaf at the document root
- tmux `sessionName`, `target`, and `paneId` fields are backend-scoped ids, not
  TOM node targets and not TRDs
- `pane.followTail` / `file.followTail` currently persist a node-level
  follow-tail preference only; they do **not** yet change capture-window or
  scrollback behavior on their own
- `capabilities.get` explicitly reports:
  - `followTailSemantics: "stored-node-preference"`
  - `viewStateScope: "shared-document-transitional"`
  - `bufferPolicy: "runtime-configurable"`
  - `paneCaptureStreaming: "h2-and-h3wt"`
  - `maxMessageBytes: <effective runtime cap>`
  - `maxDocumentContentBytes: <effective runtime cap>`
  - `tmuxBackendMode: "hybrid-control-invalidation"`
  - `tmuxTargetScope: "root-document-only"`
  - `supportsMouse: true`
- whole-message and aggregate document-content limits are now runtime policy
  rather than compile-time constants
- config discovery currently uses:
  - user-side XDG config at `${XDG_CONFIG_HOME:-$HOME/.config}/muxly/config.json`
  - daemon-side user XDG first, then `/etc/muxly/config.json`
  - explicit override via `MUXLY_CONFIG` or `muxlyd --config`
- the current `muxview` is an interactive viewer with keyboard-driven hierarchy
  traversal, region selection, drill-in/back-out navigation, elide/expand
  toggling, follow-tail toggling, mouse-driven region targeting, and a tty
  interaction mode that forwards input to the selected tty leaf
- nodes carry an optional `backendId` field for non-renderable projected
  identity; this replaces the old marker-content trick that leaked tmux
  session/window IDs into renderable `content`
- the tmux backend now applies incremental `window-renamed` updates directly
  from control-mode notifications when confidence is high, falling back to
  snapshot-backed rebuild when confidence is low
- TTY-backed leaves serialize **derived muxml/view state**, not underlying
  process runtime state

## Planned-but-not-yet-implemented families

- keybinding analysis methods
- menu/modeline APIs
- richer tmux control-mode event/subscription methods
- Neovim and external menu integration methods

Some later-phase methods are intentionally present only as **structured
unsupported-capability stubs** so clients receive stable JSON-RPC errors instead
of `method_not_found`.

This protocol currently sits beneath:

- the Zig library/client API
- the C ABI bridge
- the CLI
- the viewer
