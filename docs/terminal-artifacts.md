# terminal artifacts

This document defines muxly's first-pass contract for what terminal-backed TOM
nodes are allowed to become when they stop being purely live sources.

It exists to prevent an accidental long-term policy of "whatever tmux
scrollback happened to contain" from becoming muxly's durable terminal story by
default.

## Artifact families

Muxly should distinguish four states for terminal-backed nodes:

- **live tty source**
  - backed by an active terminal source such as a tmux pane
  - expected to change
  - not itself the durable artifact
- **detached but recoverable tty source**
  - not currently attached to a live backend pump
  - still treated as a recoverable source rather than a frozen artifact
  - may reconnect or rebuild back into a live state
- **captured text artifact**
  - durable append/history-oriented payload
  - appropriate for shells, logs, REPL transcripts, and similar cases where a
    UTF-8 history blob is an honest representation of what matters
- **captured surface artifact**
  - durable screen/surface-oriented payload
  - appropriate for fullscreen, raw-mode, or alternate-screen applications
    where the visible terminal surface is more truthful than a linear text log

## Transition rules

These families should be treated as deliberate transitions, not as accidental
side effects of whatever backend happened to be in use.

- a live TTY should remain live while muxly still believes the source is
  recoverable
- loss of the backend pump or temporary daemon/backend disconnect should prefer
  **detached but recoverable** over immediate freezing
- explicit freeze/export may turn a terminal-backed node into a captured
  artifact
- irrecoverable source death may also turn a terminal-backed node into a
  captured artifact, but the chosen artifact family should depend on the kind
  of terminal interaction it represented

## History versus surface

Muxly should treat append/history-oriented and fullscreen/surface-oriented
terminal behavior as different durable cases:

- append/history-oriented cases should serialize to **captured text artifacts**
- fullscreen/raw/alternate-screen cases should serialize to **captured surface
  artifacts**
- muxly may preserve both history and surface metadata for one node later, but
  it should not pretend they are the same thing

## Example classification

Concrete examples should be classified by what durable representation tells the
truth most honestly:

- **captured text artifact**
  - shell transcript
  - tailing log output
  - compiler/test runner output
  - line-oriented REPL or chat transcript
- **captured surface artifact**
  - fullscreen editor in alternate screen
  - process monitor / dashboard TUI
  - ncurses file manager
  - terminal game or animation

Some cases may eventually preserve both forms, but the primary durable
representation should still be chosen intentionally instead of leaving one
backend-specific capture mode to impersonate both.

## First-pass classification heuristics

Until muxly grows richer terminal-aware classification, this should remain a
good first-pass bias:

- if the value of the terminal interaction is mainly in the append-only or
  history-like transcript, prefer **captured text artifact**
- if the value is mainly in the currently visible arranged surface, prefer
  **captured surface artifact**
- alternate-screen behavior should bias toward **captured surface artifact**
- plain tmux history availability alone should not force a surface-oriented
  program into the text-artifact bucket

## tmux scrollback posture

tmux scrollback/history is useful backend evidence, but it is not the whole
policy:

- tmux scrollback may help produce a captured text artifact
- tmux visible pane state may help produce a captured surface artifact
- neither should be treated as automatically sufficient for every terminal mode
- muxml should not silently encode "tmux scrollback forever" as the default
  durable truth for all dead or frozen terminal-backed nodes

## Representation posture

The first-pass TOM/muxml posture should be conservative:

- preserve node identity and tree position when a terminal-backed node changes
  from live to detached or captured
- prefer representing the distinction through `lifecycle` plus `source`
  transitions before introducing a large new node-kind taxonomy
- allow later phases to add richer capture metadata or dedicated artifact kinds
  only if the source/lifecycle approach becomes too cramped

In practical terms, the first-pass representation target is:

- **live tty source**
  - stays a `tty_leaf`
  - keeps `source = tty`
  - uses `lifecycle = live`
- **detached but recoverable tty source**
  - stays a `tty_leaf`
  - keeps `source = tty`
  - uses `lifecycle = detached`
- **captured text artifact**
  - keeps the same logical node identity
  - uses `lifecycle = frozen`
  - stops pretending to be a live tty source
  - carries a durable text payload in TOM/muxml content
- **captured surface artifact**
  - keeps the same logical node identity
  - uses `lifecycle = frozen`
  - stops pretending to be a live tty source
  - carries a durable surface-oriented payload plus any future metadata needed
    to describe the captured screen honestly

The first implementation seam for this posture now exists in the core model:

- live recoverable terminals still use `source = tty`
- captured terminal artifacts now use `source = terminal_artifact`
- `terminal_artifact` currently distinguishes `text` versus `surface`
  artifacts while preserving tty provenance fields
- the first public daemon seam now exists as `node.freeze <node-id> <text|surface>`
  over the JSON-RPC/API/CLI surface
- the integration proof now exercises both public branches:
  - `node.freeze ... text`
  - `node.freeze ... surface`

This leaves room for later implementation choices:

- new node kinds
- source-kind transitions
- lifecycle-state transitions
- or a hybrid of those approaches

The important first-pass rule is still simpler:

- muxly must name the difference between recoverable live sources, captured
  text/history artifacts, and captured surface artifacts before persistence
  semantics harden around an accidental backend quirk
