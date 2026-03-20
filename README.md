# muxly

`muxly` is a tmux-powered terminal window manager built around a live **TOM** (Terminal Object Model) with a serializable **muxml** representation.

## What?

It's a web pun. This is a jargon-heavy project but if you understand the web, this is kind of like that. We have:

- A TOM that tracks an in memory construct meant to control the presentation of various piles of text-like information to a user

- A human-readable `muxml` serialization format that can be converted to a TOM

The web metaphor breaks down pretty quickly, however: I suppose muxly would be a text-only web browser, but with no actual text on most pages, nor any hyperlink support. The actual purpose is to help developers build TUI applications with rich containment hierarchies.

## No, *what?*

The project is far from fully implemented&mdash;a work in progress. It has:

- a shared library with a C ABI
- an xml serialization format, sort of
- an undocumented but well-defined JSON-RPC control protocol
- a daemon to hold the object model
- a command line to orchestrate daemons and manipulate the object model
- a reference client to interact with and use muxly instances
- a bunch of glue for different languages and platforms

## Cast and characters

**The daemon is full of TOMs**

Unlike the web, the muxly "object model" lives in the server. It works kind of like a MUD: clients connect and enter a shared universe. Except instead of orcs or voxels this world is full of ttys



**TTYs are endpoints, not serialized program state**

muxly traffics in layout relationships, not program states; however event hooks are (supposed to be) provided which would make it possible to treat muxly tty clients as if program state were "in" the document, if you wanted. You would have to provide the code to accomplish this, however.

Instead, muxly gives you, the developer, a canvas. You paint layouts on the canvas. Then you put terminals in the layouts.



**The TOM**

Everything in the TOM is a node; nodes are rectangles made of text and you can stack rectangles in each other either vertically or horizontally. This forms a *visual hierarchy* which will also be present logically in the muxml representation. At the leaves of the tree of nodes are:

- in-memory text objects are meant to be the only way to add textual content that lives in the TOM

- file-backed text objects are meant to be read-only windows onto text files; they are a candidate for deletion from the model as I'm not sure these shouldn't be promoted to be terminals running less or something similar

- pseudo-ttys to which programs may be multiplexed via their stdin and stdout; they have a history which contains text which has scrolled off the top of the "virtual screen" which can be accessed in the viewer.

  Because programs attached to terminals need to know the dimensions of the terminal, this means there are three kinds of terminal viewers:

   - detached ***virtual*** viewers simply hold the terminal at a given virtual size, while

   - ***primary*** viewers, whose physical terminal size is meant to optionally force virtual terminal resizing to change as the virtual size changes, and finally

   - ***secondary*** viewers, who may be thought of as spectators, have read-only connections and do not control virtual terminal size.

The branch nodes all may contain each other and consist of:

- horizontal containers, and

- vertical containers

each has or will have various attributes including:

- an optional elider which will do something other than crop the contents of the box when they do not fit

- a vtail attribute that ties the viewport to the bottom (or top) of the canvas

- an htail attribute that ties the viewport to the right (or left) of the canvas

- a default origin which says, if not determiend by vtail or htail, where viewers land in the canvas coordinate space upon first encountering its node

- fixity attribute which determines whether the origin is controlled by the viewer

A muxly client enables the user to navigate the visual hierarchy both by scrolling virtually and horizontally in the virtual canvas space, or depthwise by viewing a node as if it were a canvas. The canvas and layout are dynamic in the TOM. They can be changed arbitrarily but my suspicion is the thing we will want to do most is append to them and this is supposed to be efficient.

## Binaries

- `muxlyd` — daemon; unlike in a web client, the TOM is on the server
- `muxly` — CLI for orchestrating servers and manipulating TOM from scripts
- `muxview` — reference viewer
- `libmuxly` — shared library

## Getting started

```sh
zig build
zig build test
zig build docs
zig build muxlyd
zig build muxly
zig build muxview
zig build muxguide
```

When launched in a terminal, `muxview` now attaches live by default with
interactive navigation. Press `q` to leave the attached viewer session.

### Transport specs

`muxly`, `muxlyd`, and `muxview` now accept `--transport` in addition to the
legacy `--socket` flag. Supported specs are:

- bare paths or `unix:///tmp/muxly.sock`
- `tcp://169.254.10.20:4488`
- `ssh://alice@example.com/tcp://169.254.10.20:4488`
- `ssh://alice@example.com:2222/tcp://169.254.10.20:4488`

Plain TCP is intentionally restricted to loopback and link-local addresses
unless you also pass
`--i-know-this-is-unencrypted-and-unauthenticated`.

If you need a custom SSH client config for transport testing or host-specific
identity/known-host settings, set `MUXLY_SSH_CONFIG=/path/to/ssh_config`.

You can exercise both TCP and SSH transports against a transient Docker-hosted
daemon with:

```sh
python3 tests/integration/docker_transport_test.py
```

### Viewer keys, exremely preliminary

- `j`/`k` or up/down arrows: select region
- `Enter` or right arrow: drill into selected region / enter focused pane mode
- `Escape` or left arrow: back out / exit focused mode
- `e`: elide selected region
- `t`: toggle follow-tail on tty region
- `r`: reset view (clear root and elision state); soon to be removed
- `q`: quit
- mouse click: select region by position

## Documentation

- `docs/architecture.md`
- `docs/trine.md`
- `docs/tom.md`
- `docs/platform-matrix.md`
- `docs/muxml.md`
- `docs/terminal-artifacts.md`
- `docs/protocol.md`
- `docs/tmux-backend.md`
- `docs/viewer-architecture.md`
- `docs/keybinding-model.md`
- `docs/neovim-integration.md`
- `docs/demos.md`

## Examples, such as they are

- `examples/artifacts/freeze-demo/` — runnable `node.freeze` text/surface demo
- `examples/artifacts/c-freeze/` — C `libmuxly` artifact freeze playbook
- `examples/artifacts/python-freeze/` — Python `ctypes` artifact freeze playbook
- `examples/artifacts/zig-freeze/` — Zig `libmuxly` artifact freeze playbook
- `examples/tom/zig/` — Zig "hello TOM" playbook
- `examples/tom/c/` — C "hello TOM" playbook
- `examples/tom/python/` — Python "hello TOM" playbook
- `examples/tty/basic-nesting/` — a more visually fun example application
- `examples/guided-tour/` — synthetic "tour" of muxly features
