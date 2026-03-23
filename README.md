# muxly

`muxly` is a tmux-powered terminal window manager built around a live **TOM** (Terminal Object Model) with a serializable **muxml** representation.

## What?

It's a web pun. This is a jargon-heavy project but if you understand the web, this is kind of like that. We have:

- A TOM that tracks an in memory construct meant to control the presentation of various piles of text-like information to a user

- A human-readable `muxml` serialization format that can be converted to a TOM

The web metaphor breaks down pretty quickly, however: I suppose muxly would be a text-only web browser, but with no actual text on most pages, nor any hyperlink support. The actual purpose is to help developers build TUI applications with rich containment hierarchies.

## No, *what?*

This entire project is a work in progress & far from fully implemented. If you are looking for a project that does useful stuff, now, try tmux! It it does what it says on the tin, and is a mature working implementation; at this time muxly largely doesn't and isn't, respectively. But, if you are interested in looking into this project or helping with development, here is the broad
shape of what is being built here:

- a shared library with a C ABI
- an xml serialization format, sort of
- an undocumented but well-defined JSON-RPC control protocol
- a daemon to hold object model instances
- a command line to orchestrate daemons and manipulate the object model
- a reference viewer to interact with and use the resulting interfaces
- a bunch of glue for different languages and platforms

## OK but... why?

Because tmux, although totally amazing and powerful, is not exactly intended as a way to build an application. It's more like a way to get a bunch of terminals, well, *mux*'ed&mdash;that is, multiplexed&mdash;into a single terminal, and lay them out in a useful way, and also demultiplexed, in the sense that multiple clients can connect to a single tmux session and share it.

This is incredibly useful but the layout and positioning is more-or-less the user's job in tmux. Powerful automations are achievable but they require building up from scratch. tmux really isn't trying to be any kind of development environment or design substrate; that part is left as an exercise for the user.

Muxly is trying to complete the exercise, stealing ideas from the web and other frameworks to hopefully construct a more suitable substrate for designing applications that may be both embedded in code or syndicated as a service to end-users. 'Trying,' to be clear, is not humility; it is a description of the work. This thing is buggy, full of vibe-coded slop muddled by rapid terminological and conceptual drift, and just basically a hot mess. I have not given up and am very much on the war-path, but that is the status-quo. You have been warned.

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
  
  Because programs attached to terminals need to know the dimensions of the terminal, there is a "virtual" terminal size known to the server. The viewer also has a physical terminal size; whether and when these two are continuously synchronized remains somewhat of an open question but the obvious simple thing called for in many scenarios would be that the single client may resize their terminal at will and this simply propagates to the server's virtual terminal, potentially re-flowing its contents. The metaphor of a magically resize-able piece of paper will be familiar to most anyone from the web or from using terminal emulator software.

- branch nodes all may contain each other and consist of either vertical or horizontal containers with some sizing logic to lay out elements in a box-model of some kind; each has or will have various attributes including:

- an optional elider frob which will do something other than crop the contents of the box when they do not fit

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
zig build test-ci
zig build test-docker
zig build docs
zig build muxlyd
zig build muxly
zig build muxview
zig build muxguide
```

When launched in a terminal, `muxview` now attaches live by default with
interactive navigation. Press `q` to leave the attached viewer session.

### Transport specs

`muxly`, `muxview`, and, for direct listener transports, `muxlyd` accept
`--transport` in addition to the legacy `--socket` flag.

Direct transports include:

- bare paths or `unix:///run/user/$UID/muxly.sock`
- `tcp://169.254.10.20:4488`
- `http://127.0.0.1:8080/rpc`
- `h2://127.0.0.1:8080/rpc`
- `h3wt://127.0.0.1:4433/mux?sha256=<cert-pin>`
- `ssh://alice@example.com/tcp://169.254.10.20:4488`
- `ssh://alice@example.com:2222/tcp://169.254.10.20:4488`

Client-side secure transports also include:

- `https://rpc.example.com/rpc`
- `https1://rpc.example.com/rpc`
- `https2://rpc.example.com/rpc`
- `trds://rpc.example.com//docs/demo`

When no transport is specified, muxly prefers
`${XDG_RUNTIME_DIR}/muxly.sock`, then `/run/user/$UID/muxly.sock`, and finally
falls back to `/tmp/muxly.sock`.

Plain `tcp://`, `http://`, and `h2://` are intentionally restricted to loopback and
link-local addresses unless you also pass
`--i-know-this-is-unencrypted-and-unauthenticated`.

`h2://` is explicit cleartext HTTP/2 (H2C). `http://` remains the HTTP/1.1
transport spelling.

`h3wt://` is a WebTransport-over-HTTP/3 transport. The daemon prints a
ready-to-use `?sha256=...` certificate pin when it starts listening, and the
client accepts `wt://` as a shorthand alias for the same transport.

`muxlyd` itself still listens on direct transports only in this slice; secure
`https://...` and `trds://...` entrypoints remain client-side forms fronted by
Caddy or another secure edge.

If you need a custom SSH client config for transport testing or host-specific
identity/known-host settings, set `MUXLY_SSH_CONFIG=/path/to/ssh_config`.

Runtime buffer policy is now configurable via JSON:

- client/user tools read `${XDG_CONFIG_HOME:-$HOME/.config}/muxly/config.json`
- the daemon checks user XDG config first, then `/etc/muxly/config.json`
- `MUXLY_CONFIG=/path/to/config.json` overrides implicit discovery
- `muxlyd` also accepts `--config`, `--max-message-bytes`, and
  `--max-document-content-bytes`

The current config schema is intentionally small:

```json
{
  "limits": {
    "maxMessageBytes": 134217728,
    "maxDocumentContentBytes": 1073741824
  }
}
```

`zig build test` stays Docker-free and permission-free. For CI, use
`zig build test-ci`; it runs the unit suite by default and only adds the Docker
transport integration coverage when `MUXLY_ENABLE_DOCKER_TESTS=1` is present.

To run the local HTTP/H3WT transport integration coverage, use:

```sh
zig build test-transport
```

To run the Docker-backed integration coverage explicitly, including the raw TCP
path that requires
`--i-know-this-is-unencrypted-and-unauthenticated`, use either:

```sh
zig build test-docker
```

or the underlying script directly:

```sh
python3 tests/integration/docker_transport_test.py
```

### TRD descriptors

TOM Resource Descriptors combine a transport, a document path, and an optional
TOM selector into one string. The short version is:

- `trd://builds/demo`

- `trd://webtransport|host.lan:4433/mux?sha256=...//doc/path#node/path`

- `trd://http|127.0.0.1:8080/rpc//#welcome`

- `trd:#welcome/child`

- document comes first, selector comes after `#`

- `trd://...` is absolute

- `trd:#...` stays on the current transport and current document

- `trd://#...` means selector within the root document on the runtime-default transport

Supported public transport names are `unix`, `tcp`, `ssh`, `http`, and
`webtransport`. `ux` and `wt` remain accepted as aliases.

Defaults:

- `trd://` resolves to the root document on the runtime-default transport
- `trd://foo` resolves to document `/foo` on the runtime-default transport
- `trd://#foo` resolves selector `foo` in document `/` on the runtime-default transport
- `trd://unix|//foo` uses the runtime-default unix socket path and document `/foo`
- `trd://|relative.sock//foo` is shorthand for `trd://unix|relative.sock//foo`
- `trd://http|//` defaults the endpoint to `localhost`
- `trd://webtransport|//` defaults the endpoint to `localhost`
- `trd://tcp|//` defaults to `localhost:4488`

See [doc/trine.md](doc/trine.md) for the normative TRD doctrine and full
grammar. Some CLI arguments already accept lazy selector-bearing TRDs; a few
id-only paths still require numeric node ids and say so in their command help.

### `trds://` secure descriptors

`trds://...` is the preferred secure user-facing descriptor family. It still
describes a secure edge plus the same document/selector targeting shape used by
TRDs, and it now prefers muxly-native WebTransport before falling back to the
secure HTTP family:

- `trds://wt|mux.example.com//docs/demo`
- `trds://ht|127.0.0.1:9443/rpc//docs/demo#left`
- `trds://h1|mux.example.com//`
- `trds://h2|mux.example.com:9443/rpc//docs/demo`
- `trds://mux.example.com//` defaults to `wt`, then `ht`

Defaults:

- missing port defaults to `443`
- missing HTTPS path defaults to `/rpc`
- missing document defaults to `/`
- missing secure transport code defaults to `wt`, then `ht`

Secure transport codes:

- `wt` means muxly-native WebTransport/QUIC
- `ht` means the secure HTTP family, equivalent to lower-level `https://`
- `h2` means strict secure HTTP/2
- `h1` means strict secure HTTP/1.1

Trust metadata:

- shareable descriptors may carry `sha256=` and `sni=` query params
- local CA bundle override stays outside the descriptor via `--tls-ca-file`
- native secure CLI and viewer clients also accept `--tls-pin-sha256` and
  `--tls-server-name`

Use the admin generators to render Caddy and systemd artifacts from a secure
descriptor:

```sh
./zig-out/bin/muxly admin generate-caddy --descriptor trds://127.0.0.1:9443/rpc//docs/demo --mode user --output-dir /tmp/muxly-secure
./zig-out/bin/muxly admin generate-systemd --descriptor trds://127.0.0.1:9443/rpc//docs/demo --mode user --output-dir /tmp/muxly-secure
```

Connect natively through that HTTPS edge with the same descriptor family:

```sh
./zig-out/bin/muxly --transport trds://127.0.0.1:9443/rpc --tls-ca-file /tmp/muxly-secure/caddy-data/caddy/pki/authorities/local/root.crt ping
```

Current boundaries:

- plain `trds://...` now means: prefer `trds://wt|...`, then `trds://ht|...`
- `trds://wt|...` maps to the existing `h3wt://` WebTransport-over-HTTP/3
  transport
- generated secure deployments use Caddy as the HTTPS fixer in front of loopback
  `h2://...` muxlyd upstreams
- direct `muxlyd --transport https://...` listeners are still deferred
- `trds://h3|...` is reserved for future generic secure HTTP/3 support
- the current generators still provision the secure HTTP fallback endpoint for
  plain `trds://...` and `trds://wt|...` deployments in this slice

There is also an opt-in user-mode smoke test for the generated artifacts:

```sh
MUXLY_ENABLE_SYSTEMD_USER_TESTS=1 python3 tests/integration/systemd_secure_deploy_test.py
```

### Viewer keys, exremely preliminary

- `j`/`k` or up/down arrows: select region
- `Enter` or right arrow: drill into selected region / enter tty interaction mode
- `Escape` or left arrow: back out / exit tty interaction mode
- `e`: elide selected region
- `t`: toggle follow-tail on tty region
- `r`: reset view (clear root and elision state); [TODO] current transitional control, likely to change as viewer-session semantics firm up
- `q`: quit
- mouse click: select region by position

## Documentation

Start with [doc/README.md](doc/README.md) for the source-tree documentation map.

## Examples

- `examples/artifacts/freeze-demo/` — runnable `node.freeze` text/surface demo
- `examples/artifacts/c-freeze/` — C `libmuxly` artifact freeze playbook
- `examples/artifacts/python-freeze/` — Python `ctypes` artifact freeze playbook
- `examples/artifacts/zig-freeze/` — Zig `libmuxly` artifact freeze playbook
- `examples/tom/zig/` — Zig "hello TOM" playbook
- `examples/tom/c/` — C "hello TOM" playbook
- `examples/tom/python/` — Python "hello TOM" playbook
- `examples/tty/basic-nesting/` — a more visually fun example application
- `examples/guided-tour/` — synthetic "tour" of muxly features
