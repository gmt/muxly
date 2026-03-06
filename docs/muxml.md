# muxml model

`muxml` is the canonical document model manipulated by muxly.

## Properties

- tree-shaped and DOM-like
- serializable and persistable when useful
- live/mutable while attached to active sources
- append-oriented in the common case

## Important distinction

A live TTY is **not** the serialized artifact.

Instead:

- a TTY is a **source**
- muxml content may stream in from that source
- muxly may serialize the **derived document/view state**
- program-specific runtime state remains the responsibility of the program

## Planned leaf source kinds

- TTY / terminal session
- monitored text file
- static text file
- future adapter-managed leaves (for example Neovim-derived entities)
