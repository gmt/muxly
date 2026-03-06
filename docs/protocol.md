# muxly protocol

The public control surface is planned as JSON-RPC 2.0 over pluggable transports.

## Initial transports

- Unix domain sockets on Linux/macOS
- named pipes on Windows
- stdio for testing and embedding

## Initial method families

- lifecycle: `initialize`, `ping`
- documents: `document.get`, `document.serialize`, `document.freeze`
- nodes: `node.append`, `node.update`, `view.setRoot`, `view.elide`
- sources: `leaf.source.attach`, `leaf.source.detach`
- tmux helpers: `session.create`, `pane.split`, `pane.capture`

The same public protocol should be used by:

- the CLI
- the viewer
- external clients
- the C ABI bridge
