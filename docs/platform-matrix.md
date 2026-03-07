# platform matrix

The public muxly shape is intended to stay cross-platform even though the first
usable backend slice is most mature on Unix-like systems.

## Current practical status

| Platform | Status | Notes |
|---|---|---|
| Linux x86_64 | active dev target | fully exercised in this environment |
| Linux arm64 | compile target | runtime follow-up expected |
| macOS x86_64 | compile target | Unix socket path should translate cleanly |
| macOS arm64 | compile target | same as above |
| Windows x86_64 | scaffolded transport story | tmux runtime expected via WSL2 / MSYS2 |
| Windows arm64 | scaffolded transport story | same constraints as above |

## Design intent

- keep protocol semantics transport-agnostic
- keep ordinary clients independent of Unix-only assumptions where possible
- capability-gate host-specific features instead of baking them into the API
- choose functional, testable platform paths over aesthetically uniform ones

## Practical stance

- cross-platform pain should be paid early where possible
- the long-term recommended Windows story may be WSL2, but intermediate testing
  may realistically happen sooner with MSYS2 or other easier-to-exercise
  environments
- it is acceptable for some platform paths to be uglier if that improves test
  coverage and real-world usability
- if protocol layering, plugins, or side-channel helpers are needed to keep
  terminal UX responsive and predictable, they are acceptable costs of doing
  business in terminal space
