# muxly protocol

The public control surface is JSON-RPC 2.0 over pluggable transports.

## Initial transports

- Unix domain sockets on Linux/macOS
- named pipes on Windows
- stdio for testing and embedding

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
- `graph.get`
- `view.get`
- `view.setRoot`
- `view.elide`

### Leaf/source operations

- `leaf.source.attach`
- `leaf.source.get`

### tmux-backed helpers

- `session.create`
- `window.create`
- `pane.split`
- `pane.capture`
- `pane.resize`
- `pane.focus`
- `pane.sendKeys`
- `pane.close`

## Current response-shape notes

- `graph.get` currently aliases the same muxml/tree payload returned by
  `document.get` / `view.get`
- `document.status` returns a smaller lifecycle/count-oriented payload
- TTY-backed leaves serialize **derived muxml/view state**, not underlying
  process runtime state

## Planned-but-not-yet-implemented families

- richer node mutation methods such as `node.append`, `node.update`
- keybinding analysis methods
- menu/modeline APIs
- richer tmux control-mode event/subscription methods
- Neovim and external menu integration methods

The same public protocol should be used by:

- the CLI
- the viewer
- external clients
- the C ABI bridge
