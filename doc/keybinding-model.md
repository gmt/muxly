# keybinding model

Keybinding analysis is a planned layer above the current muxly core.

## Intended model

Conflicts should eventually be analyzed across multiple environments:

- terminal emulator
- tmux tables
- shell bindings
- application/editor bindings

## Important constraint

Some conflicts are not just configuration collisions; they are impossible to
disambiguate because of terminal encoding limits.

## Current state

- documented as a future subsystem
- not yet implemented beyond architecture planning
