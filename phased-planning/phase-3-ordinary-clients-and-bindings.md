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

## Out of scope

- full 11-language binding matrix
- advanced viewer polish
- GUI-specific menu helpers

## Acceptance criteria

- CLI can operate the main implemented surface without raw JSON
- C ABI supports creation, document/graph/view helpers, and tmux helpers
- examples run against live daemon

## Current branch status

Mostly completed for the initial binding surface. Future work can add more
binding examples and broader exported methods as needed.
