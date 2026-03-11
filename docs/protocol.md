# muxly protocol

The current daemon control protocol is JSON-RPC 2.0.

Most consumers should prefer the library/client API layer when it is
available. This document exists so the underlying server conversation format is
explicit, testable, and debuggable.

## Currently implemented transport

- Unix domain sockets on Linux/macOS

## Transport roadmap notes

- Windows named pipes are scaffolded in naming/API shape only and are **not**
  yet implemented in this branch
- stdio embedding/testing transport is planned but **not** yet implemented
- `capabilities.get` reports only transports that actually exist on the current
  runtime target

## Currently implemented methods

### Lifecycle and capability discovery

- `initialize`
- `ping`
- `capabilities.get`

### Documents, views, and graph inspection

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
- `view.clearRoot`
- `view.setRoot`
- `view.elide`
- `view.expand`
- `view.reset`

### Leaf/source operations

- `leaf.source.attach`
- `leaf.source.get`

### tmux-backed helpers

- `session.create`
- `window.create`
- `pane.split`
- `pane.capture`
- `pane.scroll`
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
- `document.get` / `view.get` currently expose **shared document-scoped** view
  state through `viewRootNodeId` and `elidedNodeIds`; these are not
  per-viewer local overrides in this phase
- `node.remove` currently succeeds only for childless nodes; callers should
  remove descendants first when editing synthetic muxml structure
- `node.freeze` currently supports tty-backed nodes only and accepts an
  `artifactKind` of `text` or `surface`; it preserves node identity while
  transitioning the source into a durable `terminal_artifact` form, including
  an explicit `contentFormat` in the source payload
- `view.reset` clears shared root/elision transforms stored in the daemon's
  current document state without mutating source attachments or node content
- `session.create` accepts an optional `parentId`; when omitted it attaches the
  new TTY leaf at the document root
- `pane.followTail` / `file.followTail` currently persist a node-level
  follow-tail preference only; they do **not** yet change capture-window or
  scrollback behavior on their own
- `capabilities.get` explicitly reports:
  - `followTailSemantics: "stored-node-preference"`
  - `viewStateScope: "shared-document"`
  - `tmuxBackendMode: "hybrid-control-invalidation"`
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
