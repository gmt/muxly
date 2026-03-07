# muxly protocol

The public control surface is JSON-RPC 2.0.

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
- `view.reset` clears shared root/elision transforms stored in the daemon's
  current document state without mutating source attachments or node content
- `pane.followTail` / `file.followTail` currently persist a node-level
  follow-tail preference only; they do **not** yet change capture-window or
  scrollback behavior on their own
- `capabilities.get` explicitly reports:
  - `followTailSemantics: "stored-node-preference"`
  - `viewStateScope: "shared-document"`
  - `tmuxBackendMode: "command-backed"`
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

The same public protocol should be used by:

- the CLI
- the viewer
- external clients
- the C ABI bridge
