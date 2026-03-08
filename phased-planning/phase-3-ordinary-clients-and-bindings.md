# phase 3 — ordinary clients and bindings

## Goal

Strengthen the public-consumer story:

- ordinary-client viewer
- automation-friendly CLI
- usable C ABI
- example consumers across multiple languages

## In scope

- CLI command coverage for implemented protocol methods
- viewer stays on public surfaces only
- handle-based C ABI
- C / Zig / Python examples
- header docs and memory ownership clarity
- discoverable demos/examples as part of documentation, not just buried in test
  artifacts

## Out of scope

- full 11-language binding matrix
- advanced viewer polish
- GUI-specific menu helpers

## Acceptance criteria

- CLI can operate the main implemented surface without raw JSON
- C ABI supports creation, document/graph/view helpers, and tmux helpers
- examples run against live daemon
- examples/demos communicate the value proposition of the framework, not just
  raw API syntax

## Current status

The initial binding surface is largely in place. Future work in this phase is
mostly expansion: broader exported methods, more examples, and tighter
consumer-facing polish.
