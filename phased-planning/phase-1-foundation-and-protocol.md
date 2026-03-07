# phase 1 — foundation and protocol

## Goal

Establish the minimum working muxly platform:

- Zig workspace/build
- daemon / CLI / viewer / shared library targets
- muxml core types
- JSON-RPC transport and method routing
- basic examples and tests

## In scope

- build targets and install layout
- muxml document core
- JSON-RPC request/response framing
- Unix-socket host runtime
- capability discovery
- baseline document/view inspection
- repo docs and examples

## Out of scope

- deep tmux control-mode parsing
- advanced viewer UX
- keybinding analysis
- menu/modeline projection
- Neovim integration

## Acceptance criteria

- `zig build`
- `zig build test`
- `muxlyd`, `muxly`, `muxview`, `libmuxly` all build
- ordinary clients can talk to daemon over public protocol
- examples run

## Current branch status

Completed.
