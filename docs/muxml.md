# muxml model

`muxml` is the serializable document form manipulated by muxly.

Some consumers may interact with it directly, but many should be able to work
through library/client APIs without caring about the exact serialized muxml
shape.

Within the daemon, muxly maintains a live **TOM**: a Terminal Object Model.
`muxml` is the serializable representation of that live state, not the same
thing as the live TOM itself.

## Properties

- tree-shaped
- serializable and persistable when useful
- live/mutable while attached to active sources
- append-oriented in the common case

## Lifecycle / capability vocabulary

Useful working vocabulary for muxml objects:

- **live** — attached to an active backend/runtime and expected to change
- **read-only** — inspectable but not directly editable
- **detached** — not currently attached to a live backend pump, but still
  treated as recoverable source-backed state rather than as a final artifact
- **frozen** — detached from active mutation and treated as a captured form
- **serializable** — exportable into a durable or transferable representation
- **rehydratable** — potentially restorable into a live form, subject to source
  and backend limits

These are capabilities and states, not universal promises for every object.

## Important distinction

A live TTY is **not** the serialized artifact.

Instead:

- a TTY is a **source**
- TOM state may stream in from that source
- muxly may serialize the **derived document/view state**
- program-specific runtime state remains the responsibility of the program

Durable terminal-backed artifacts should also be distinguished explicitly:

- **detached but recoverable tty source** — still part of a live/recoverable
  source story
- **captured text artifact** — append/history-oriented durable payload
- **captured surface artifact** — fullscreen/raw/surface-oriented durable
  payload

That contract is defined in
[`docs/terminal-artifacts.md`](/home/greg/src/muxly/docs/terminal-artifacts.md).

## Planned leaf source kinds

- TTY / terminal session
- monitored text file
- static text file
- future adapter-managed leaves (for example Neovim-derived entities)
