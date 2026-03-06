# AGENTS.md

## Cursor Cloud specific instructions

### Project Overview

`muxly` is a multi-arch, multi-programming-framework TUI window manager with a tmux dependency (BSD 3-Clause). It ships as a **library** and a corresponding **daemon** across the full 3x2 platform grid:

|            | x86_64 | arm64 |
|------------|--------|-------|
| **Linux**  | yes    | yes   |
| **macOS**  | yes    | yes   |
| **Windows**| yes    | yes   |

Terminal automation is a core concern. QEMU multi-arch is used for cross-architecture testing. The repository is currently pre-development (no source code or build system yet).

### Toolchain & Runtimes

| Category | Tool | Version |
|---|---|---|
| C/C++ compiler (native) | gcc / g++ | 13.3.0 |
| C/C++ compiler (cross) | Zig cc | 0.13.0 |
| C/C++ compiler (Windows) | mingw-w64 (x86_64-w64-mingw32-gcc) | 13.2.0 |
| Build tools | GNU Make / CMake | 4.3 / 3.28 |
| TUI library | ncurses (libncurses-dev) | 6.4 |
| tmux (core dependency) | tmux | 3.4 |
| Rust | rustc / cargo | 1.83.0 |
| Go | go | 1.22.2 |
| Python | python3 | 3.12.3 |
| Node.js | node / npm | 22.22.0 / 10.9.4 |
| Perl | perl | 5.38.2 |
| Tcl/Expect | expect | 5.45.4 |
| Clang/LLVM | clang | 18.1.3 |

### Cross-Compilation Toolchains

#### Zig cc (preferred for C/C++ cross-compilation to all 6 targets)

Zig acts as a drop-in cross-compiler for C/C++. Use `-c` to produce object files (library) or link as needed.

| Target | Zig target triple |
|---|---|
| Linux x86_64 | `x86_64-linux-gnu` |
| Linux arm64 | `aarch64-linux-gnu` |
| macOS x86_64 | `x86_64-macos` |
| macOS arm64 | `aarch64-macos` |
| Windows x86_64 | `x86_64-windows-gnu` |
| Windows arm64 | `aarch64-windows-gnu` |

Example (library object): `zig cc -c -target aarch64-macos -o out.o src.c`

#### Go (daemon cross-compilation via GOOS/GOARCH)

Go natively supports cross-compilation with no extra toolchains.

| Target | GOOS | GOARCH |
|---|---|---|
| Linux x86_64 | `linux` | `amd64` |
| Linux arm64 | `linux` | `arm64` |
| macOS x86_64 | `darwin` | `amd64` |
| macOS arm64 | `darwin` | `arm64` |
| Windows x86_64 | `windows` | `amd64` |
| Windows arm64 | `windows` | `arm64` |

Example: `GOOS=darwin GOARCH=arm64 go build -o out ./cmd/muxlyd`

#### Rust (static library targets)

| Target | Rust target triple |
|---|---|
| Linux x86_64 | `x86_64-unknown-linux-gnu` |
| Linux arm64 | `aarch64-unknown-linux-gnu` |
| macOS x86_64 | `x86_64-apple-darwin` |
| macOS arm64 | `aarch64-apple-darwin` |
| Windows x86_64 | `x86_64-pc-windows-gnu` |
| Windows arm64 | `aarch64-pc-windows-gnullvm` |

All targets are pre-installed via `rustup target add`. Example: `cargo build --target aarch64-apple-darwin --release`

#### GCC Cross-Compilers (Linux targets)

- `aarch64-linux-gnu-gcc` / `g++` — ARM 64-bit
- `arm-linux-gnueabihf-gcc` / `g++` — ARM 32-bit (hard-float)
- `riscv64-linux-gnu-gcc` / `g++` — RISC-V 64-bit
- `x86_64-w64-mingw32-gcc` / `g++` — Windows x86_64 via mingw-w64
- `musl-gcc` — Static Linux builds via musl
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

- **Zig cc for libraries**: Use `-c` flag to produce object files. Without it, Zig tries to link an executable and fails with "undefined symbol: main".
- **Rust Windows arm64**: Uses the `gnullvm` ABI (`aarch64-pc-windows-gnullvm`), not `msvc`.
- **Go static binaries**: Go produces statically linked Linux binaries by default; for CGo-enabled builds, use `CGO_ENABLED=0` for static linking.
- libtmux `Pane.split(direction=...)` uses `PaneDirection` enum, not string literals like `"horizontal"`.
- `Server.new_session(kill_existing=True)` raises `TmuxSessionExists` if the session already exists from a previous crashed run; use `tmux kill-session -t <name>` first or wrap in try/except.
- The `.gitignore` is a standard C/C++ template filtering compiled artifacts (`.o`, `.so`, `.a`, `.exe`, etc.).
- No build system, lint, test, or run commands exist yet since the project has no source code.
