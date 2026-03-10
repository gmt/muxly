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

## tmux scrollback posture

tmux scrollback/history is useful backend evidence, but it is not the whole
policy:

- tmux scrollback may help produce a captured text artifact
- tmux visible pane state may help produce a captured surface artifact
- neither should be treated as automatically sufficient for every terminal mode
- muxml should not silently encode "tmux scrollback forever" as the default
  durable truth for all dead or frozen terminal-backed nodes

## Representation posture

This contract does not yet force one exact TOM/muxml encoding. Later phases may
represent these families using:

- new node kinds
- source-kind transitions
- lifecycle-state transitions
- or a hybrid of those approaches

The important first-pass rule is simpler:

- muxly must name the difference between recoverable live sources, captured
  text/history artifacts, and captured surface artifacts before persistence
  semantics harden around an accidental backend quirk
