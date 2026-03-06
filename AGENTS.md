# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

`muxly` is a greenfield C/C++ project — a planned TUI (Terminal UI) window manager (BSD 3-Clause licensed). The repository is currently pre-development with no source code or build system yet.

### Toolchain

- **Compiler**: GCC 13 (gcc/g++) — available system-wide
- **Build tools**: GNU Make 4.3, CMake 3.28
- **TUI library**: ncurses 6.4 (libncurses-dev) — link with `-lncurses`

### Notes

- The `.gitignore` is a standard C/C++ template filtering compiled artifacts (`.o`, `.so`, `.a`, `.exe`, etc.).
- No build system (Makefile, CMakeLists.txt) exists yet — one will need to be created when source code is added.
- No lint, test, or run commands exist yet since the project has no source code.
- When source code is added, compile with `-Wall -Wextra` for good diagnostics.
