//! Public Zig package surface for muxly.
//!
//! The daemon owns a live TOM (Terminal Object Model). This package exposes the
//! core TOM types, serialization helpers, client helpers, viewer building
//! blocks, and platform transport seams used by the rest of the project.

/// Identifier types and helpers used by documents and nodes.
pub const ids = @import("core/ids.zig");
/// Core TOM enum vocabulary such as node kinds and lifecycle states.
pub const types = @import("core/types.zig");
/// Source metadata for tty-backed, file-backed, and captured terminal leaves.
pub const source = @import("core/source.zig");
/// Serialization helpers for muxml, the durable representation of TOM state.
pub const muxml = @import("core/muxml.zig");
/// Live document/TOM ownership and mutation helpers.
pub const document = @import("core/document.zig");
/// Small JSON helpers used by daemon and client surfaces.
pub const json = @import("core/json.zig");
/// Stop-gap buffering limits shared by current transport and document paths.
pub const limits = @import("core/limits.zig");
/// JSON-RPC protocol helpers shared by daemon-side request handling.
pub const protocol = @import("core/protocol.zig");
/// Logical conversation broker helpers that sit between transport framing and request execution.
pub const conversation_broker = @import("core/conversation_broker.zig");
/// Shared RPC error codes.
pub const errors = @import("core/errors.zig");
/// Capability reporting for clients that need to adapt to platform support.
pub const capabilities = @import("core/capabilities.zig");
/// Shared document/view state helpers.
pub const view = @import("core/view.zig");
/// Boxed viewer projection helpers over the live TOM.
pub const projection = @import("core/projection.zig");
/// Future keybinding analysis model helpers.
pub const keymap = @import("core/keymap.zig");
/// Future menu/modeline schema helpers.
pub const menu = @import("core/menu.zig");
/// Viewer application loop building blocks.
pub const viewer_app = @import("viewer/app.zig");
/// CLI argument parsing helpers shared by tests and the CLI entrypoint.
pub const cli_args = @import("cli/args.zig");
/// Viewer rendering helpers.
pub const viewer_render = @import("viewer/render.zig");
/// Handle-based Zig client for talking to an external `muxlyd`.
pub const client = @import("lib/client.zig");
/// Stateless convenience wrappers over common daemon protocol operations.
pub const api = @import("lib/api.zig");
/// Shared transport parsing and stream helpers for clients, the daemon, and relays.
pub const transport = @import("lib/transport.zig");
/// Client-side logical conversation response routing helpers.
pub const conversation_router = @import("lib/conversation_router.zig");
/// TOM resource descriptor parsing and selector resolution helpers.
pub const trd = @import("lib/trd.zig");

/// Backend implementation modules used by the daemon.
pub const daemon = struct {
    /// tmux backend modules for command, control-mode, parsing, and reconciliation.
    pub const tmux = struct {
        pub const client = @import("daemon/tmux/client.zig");
        pub const commands = @import("daemon/tmux/commands.zig");
        pub const control_mode = @import("daemon/tmux/control_mode.zig");
        pub const events = @import("daemon/tmux/events.zig");
        pub const parser = @import("daemon/tmux/parser.zig");
        pub const reconcile = @import("daemon/tmux/reconcile.zig");
    };
};

/// Platform transport modules used by the daemon and client layers.
pub const platform = struct {
    /// Unix-domain socket transport primitives used on Unix-like hosts.
    pub const unix_socket = @import("platform/unix_socket.zig");
    /// Windows named-pipe transport placeholder. The current client surface is
    /// still Unix-only until a real Windows transport implementation lands.
    pub const windows_pipe = @import("platform/windows_pipe.zig");
};

/// Synthetic demos used to exercise viewer and TOM ideas without a live backend.
pub const demo = struct {
    pub const guided_tour = @import("demo/guided_tour.zig");
};
