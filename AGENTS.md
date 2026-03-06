# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

`muxly` is a multi-arch, multi-programming-framework TUI (Terminal UI) window manager with a tmux dependency (BSD 3-Clause licensed). The project targets terminal automation across architectures and may use QEMU for multi-arch testing. The repository is currently pre-development (no source code or build system yet).

### Toolchain & Runtimes

| Category | Tool | Version |
|---|---|---|
| C/C++ compiler | gcc / g++ | 13.3.0 |
| Build tools | GNU Make / CMake | 4.3 / 3.28 |
| TUI library | ncurses (libncurses-dev) | 6.4 |
| tmux (core dependency) | tmux | 3.4 |
| Rust | rustc / cargo | 1.83.0 |
| Go | go | 1.22.2 |
| Python | python3 | 3.12.3 |
| Node.js | node / npm | 22.22.0 / 10.9.4 |
| Perl | perl | 5.38.2 |
| Tcl/Expect | expect | 5.45.4 |

### Cross-Compilation Toolchains

- `aarch64-linux-gnu-gcc` / `g++` — ARM 64-bit
- `arm-linux-gnueabihf-gcc` / `g++` — ARM 32-bit (hard-float)
- `riscv64-linux-gnu-gcc` / `g++` — RISC-V 64-bit
- Static linking required for QEMU user-mode: use `-static` flag

### QEMU Multi-Arch (v8.2.2)

- **System emulators**: `qemu-system-x86_64`, `qemu-system-aarch64`, `qemu-system-arm`, `qemu-system-riscv64`
- **User-mode (static)**: `qemu-aarch64-static`, `qemu-arm-static`, `qemu-riscv64-static`
- Cross-compile + run pattern: `aarch64-linux-gnu-gcc -static -o out src.c && qemu-aarch64-static ./out`

### Terminal Automation

- **libtmux** (Python, v0.53.1): programmatic tmux control. Direction enum: `from libtmux.constants import PaneDirection` with values `Above`, `Below`, `Right`, `Left`.
- **pexpect** (Python, v4.9.0): spawn and control interactive processes.
- **expect** (Tcl, v5.45.4): Tcl-based terminal automation.
- tmux sessions can be created/split/captured programmatically via libtmux for testing multi-pane layouts.

### Gotchas

- libtmux `Pane.split(direction=...)` uses `PaneDirection` enum, not string literals like `"horizontal"`.
- `Server.new_session(kill_existing=True)` raises `TmuxSessionExists` if the session already exists from a previous crashed run; use `tmux kill-session -t <name>` first or wrap in try/except.
- The `.gitignore` is a standard C/C++ template filtering compiled artifacts (`.o`, `.so`, `.a`, `.exe`, etc.).
- No build system, lint, test, or run commands exist yet since the project has no source code.
