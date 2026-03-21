//! Capability reporting for clients that need to adapt to platform and phase
//! support.

const std = @import("std");
const builtin = @import("builtin");

/// Public capability snapshot returned by `capabilities.get`.
pub const Capabilities = struct {
    protocol_version: []const u8 = "muxly/0.1",
    append_mode_default: bool = true,
    ordinary_client_viewer: bool = true,
    conversation_api: []const u8 = "library-first",
    tty_api_shape: []const u8 = "neutral-conversation",
    tty_size_negotiation: []const u8 = "requested-vs-actual",
    tty_source_serialization: []const u8 = "derived-state-only",
    follow_tail_semantics: []const u8 = "stored-node-preference",
    view_state_scope: []const u8 = "shared-document",
    tmux_backend_mode: []const u8 = "hybrid-control-invalidation",
    tmux_target_scope: []const u8 = "root-document-only",
    supports_tty_sources: bool = true,
    supports_monitored_files: bool = true,
    supports_static_files: bool = true,
    supports_freeze: bool = true,
    supports_rehydrate: bool = false,
    supports_tmux_backend: bool = builtin.os.tag != .windows,
    supports_unix_socket: bool = builtin.os.tag != .windows,
    supports_tcp_socket: bool = builtin.os.tag != .windows,
    supports_named_pipes: bool = false,
    supports_mouse: bool = true,
    supports_menu_projection: bool = false,
    supports_nvim_integration: bool = false,

    /// Writes the capability snapshot as JSON.
    pub fn writeJson(self: Capabilities, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"protocolVersion\":\"{s}\",", .{self.protocol_version});
        try writer.print("\"appendModeDefault\":{},", .{self.append_mode_default});
        try writer.print("\"ordinaryClientViewer\":{},", .{self.ordinary_client_viewer});
        try writer.print("\"conversationApi\":\"{s}\",", .{self.conversation_api});
        try writer.print("\"ttyApiShape\":\"{s}\",", .{self.tty_api_shape});
        try writer.print("\"ttySizeNegotiation\":\"{s}\",", .{self.tty_size_negotiation});
        try writer.print("\"ttySerialization\":\"{s}\",", .{self.tty_source_serialization});
        try writer.print("\"followTailSemantics\":\"{s}\",", .{self.follow_tail_semantics});
        try writer.print("\"viewStateScope\":\"{s}\",", .{self.view_state_scope});
        try writer.print("\"tmuxBackendMode\":\"{s}\",", .{self.tmux_backend_mode});
        try writer.print("\"tmuxTargetScope\":\"{s}\",", .{self.tmux_target_scope});
        try writer.print("\"supportsTtySources\":{},", .{self.supports_tty_sources});
        try writer.print("\"supportsMonitoredFiles\":{},", .{self.supports_monitored_files});
        try writer.print("\"supportsStaticFiles\":{},", .{self.supports_static_files});
        try writer.print("\"supportsFreeze\":{},", .{self.supports_freeze});
        try writer.print("\"supportsRehydrate\":{},", .{self.supports_rehydrate});
        try writer.print("\"supportsTmuxBackend\":{},", .{self.supports_tmux_backend});
        try writer.print("\"supportsUnixSocket\":{},", .{self.supports_unix_socket});
        try writer.print("\"supportsTcpSocket\":{},", .{self.supports_tcp_socket});
        try writer.print("\"supportsNamedPipes\":{},", .{self.supports_named_pipes});
        try writer.writeAll("\"implementedTransports\":[");
        if (self.supports_unix_socket) {
            try writer.writeAll("\"unix-domain-socket\"");
        }
        if (self.supports_tcp_socket) {
            if (self.supports_unix_socket) try writer.writeAll(",");
            try writer.writeAll("\"tcp\"");
            try writer.writeAll(",\"http\",\"h3wt\"");
        }
        if (self.supports_named_pipes) {
            if (self.supports_unix_socket or self.supports_tcp_socket) try writer.writeAll(",");
            try writer.writeAll("\"named-pipe\"");
        }
        try writer.writeAll("],");
        try writer.print("\"supportsMouse\":{},", .{self.supports_mouse});
        try writer.print("\"supportsMenuProjection\":{},", .{self.supports_menu_projection});
        try writer.print("\"supportsNvimIntegration\":{}", .{self.supports_nvim_integration});
        try writer.writeAll("}");
    }
};
