# trine

This document captures the cross-cutting doctrine for muxly. When a future
phase, implementation detail, or platform compromise is unclear, these
principles should take precedence over superficial elegance.

## North-star design law

Muxly should prioritize **predictable behavior under nested TUI composition**
over theoretical elegance, and should accept platform-specific adaptation where
necessary to preserve responsiveness, clarity, and control fidelity.

## Core doctrine

### Function over form

- prefer a jank-free experience over architectural purity
- accept platform-specific workarounds when they improve behavior
- do not force a single beautiful abstraction if it degrades terminal UX

### TTYs are sources, not serialized process state

- a live TTY is a source adapter
- muxly serializes derived muxml/document/view state
- arbitrary process/editor/shell runtime state remains the responsibility of
  that program unless a cooperative adapter exists

### Append-oriented by default

- terminal and log-like regions usually grow downward
- append-friendly behavior and tail-following should be the common-case bias
- arbitrary mid-tree mutation is allowed, but not the primary optimization goal

### Public-surface rule

- the reference viewer uses the same public surfaces as other clients
- no secret friend APIs
- no hidden shortcuts unavailable to other clients

### Library-first contract

- consumers should be able to think of muxly primarily as a library
- the library API is responsible for conversations with the server
- applications such as the CLI and viewer should build on that API layer rather
  than reaching into daemon internals
- muxml shape and wire-protocol details may remain implementation details for
  many consumers
- muxml shape and wire-protocol details may change later if the library-level
  semantics stay coherent

### Testing is a product requirement

- muxly wins or loses on how much can be tested
- slow, emulator-heavy, or awkward testing is acceptable if it increases
  confidence
- manual validation helps, but automated validation should be pushed as far as
  practical

### Cross-platform realism

- cross-platform pain should be paid early where possible
- protocol/API shape should avoid accidental Unix-only assumptions
- function matters more than pretending every platform can behave identically
- WSL2 may be the long-term Windows recommendation, but MSYS2 or other
  intermediate strategies are acceptable if they are more testable sooner

### Protocol layering is acceptable

- terminal environments are inherently weird
- multiple protocol layers, adapters, escape hatches, and plugin boundaries are
  acceptable if they preserve user experience
- low-latency, low-overhead behavior matters more than enforcing a single
  universal wire shape everywhere
- when the library API is sufficient, consumers should not need to care about
  the wire format

## Viewer interaction priorities

- drill-in / depthwise traversal should be discoverable
- hierarchy boundaries should be clear when users traverse into nested views
- resizing and focus semantics should feel predictable
- mouse behavior should prioritize intuitive region targeting even when nested
  support combinations are messy
