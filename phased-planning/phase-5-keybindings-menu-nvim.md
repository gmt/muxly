# phase 5 - deferred UX and integration backlog

## Status

Deferred on purpose. This file is no longer an execution-ready umbrella phase.
It records three future threads that should only be reactivated separately.

## Why deferred

The old phase-5 framing had several problems:

- bindings analysis, menu/modeline work, and Neovim integration are only
  loosely coupled
- none of them is on the current critical path for muxly's core objective
- the public contract and capability surface are still too thin or inconsistent
  to support one honest implementation phase
- "make unsupported stubs stop erroring" is not a meaningful completion bar

## Repo baseline

Right now this area is still mostly scaffolding:

- `src/daemon/router.zig` returns structured unsupported errors for:
  - `bindings.inspect`
  - `bindings.validate`
  - `bindings.propose`
  - `modeline.set`
  - `menu.set`
  - `menu.project`
  - `nvim.attach`
  - `nvim.detach`
- `src/core/capabilities.zig` only exposes:
  - `supportsMenuProjection = false`
  - `supportsNvimIntegration = false`
- there is no dedicated public capability flag yet for bindings analysis
- `docs/keybinding-model.md` and `docs/neovim-integration.md` are future-facing
  notes, not execution contracts
- `docs/protocol.md` does not yet describe these method families as real public
  protocol surfaces

## Dismissed framing

This cleanup explicitly rejects the following framing:

- do not reopen this as one umbrella implementation phase
- do not use "unsupported errors disappear" as the success criterion
- do not promise platform menu projection before a daemon-owned schema exists
- do not promise transparent Neovim pane semantics before runtime behavior is
  proven

## Deferred tracks

### Track A - bindings analysis

Status:

- deferred, but the most plausible later candidate for reactivation

Why it is still worth keeping around:

- it is the least platform-specific thread here
- terminal-layer conflict analysis is relevant to muxly's multi-layer terminal
  story in a way menus and Neovim are not

Reactivation bar:

- add an explicit capability surface for bindings analysis
- document one concrete payload shape
- choose one first supported environment stack instead of promising every layer
  at once
- prove one useful analysis result with a repo-local verification path

First useful slice if revived:

- implement `bindings.inspect` or `bindings.validate`
- start with terminal emulator plus tmux conflicts
- keep shell, editor, and application layers out of the first slice

### Track B - modeline/menu schema and projection

Status:

- deferred and subordinate to clearer viewer/presentation needs

Why it stays deferred:

- muxly still lacks a mature interactive viewer story for these surfaces
- stored schema and platform projection are being conflated too early in the
  old phase plan

Reactivation bar:

- define daemon-owned modeline/menu state before any OS-level projection work
- document one query/set surface and one internal schema
- keep projection capability-gated and explicitly partial

First useful slice if revived:

- stored modeline/menu state through a public API
- no pretense yet that KDE, macOS, or other platform integration is ready

### Track C - Neovim bridge

Status:

- deferred research item and the most speculative thread in this file

Why it stays deferred:

- it depends on runtime helper behavior, capability negotiation, and event
  semantics that are not otherwise needed by the current core roadmap
- there is no demonstrated reason yet to promote it over the tmux/viewer/core
  work still in flight

Reactivation bar:

- define a narrow attach/detach contract
- define capability negotiation honestly
- establish one repo-local verification path
- articulate why Neovim state needs to become first-class muxly data

First useful slice if revived:

- a narrow `nvim.attach` / `nvim.detach` handshake with explicit failure modes

## Reactivation rule

If any part of this file becomes active later, split it into separate docs or
tickets. Do not reactivate the whole file as one phase.

## Current status

- bindings analysis: deferred, plausible later
- menu/modeline projection: deferred, blocked on clearer stored-schema and
  presentation needs
- Neovim integration: deferred, speculative
- Phase 5 overall: deferred backlog/reference only
