const std = @import("std");

pub const Capabilities = struct {
    protocol_version: []const u8 = "muxly/0.1",
    append_mode_default: bool = true,
    ordinary_client_viewer: bool = true,
    tty_source_serialization: []const u8 = "derived-state-only",
    supports_tty_sources: bool = true,
    supports_monitored_files: bool = true,
    supports_static_files: bool = true,
    supports_freeze: bool = true,
    supports_rehydrate: bool = false,
    supports_tmux_backend: bool = true,
    supports_unix_socket: bool = true,
    supports_named_pipes: bool = true,
    supports_mouse: bool = false,
    supports_menu_projection: bool = false,
    supports_nvim_integration: bool = false,

    pub fn writeJson(self: Capabilities, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"protocolVersion\":\"{s}\",", .{self.protocol_version});
        try writer.print("\"appendModeDefault\":{},", .{self.append_mode_default});
        try writer.print("\"ordinaryClientViewer\":{},", .{self.ordinary_client_viewer});
        try writer.print("\"ttySerialization\":\"{s}\",", .{self.tty_source_serialization});
        try writer.print("\"supportsTtySources\":{},", .{self.supports_tty_sources});
        try writer.print("\"supportsMonitoredFiles\":{},", .{self.supports_monitored_files});
        try writer.print("\"supportsStaticFiles\":{},", .{self.supports_static_files});
        try writer.print("\"supportsFreeze\":{},", .{self.supports_freeze});
        try writer.print("\"supportsRehydrate\":{},", .{self.supports_rehydrate});
        try writer.print("\"supportsTmuxBackend\":{},", .{self.supports_tmux_backend});
        try writer.print("\"supportsUnixSocket\":{},", .{self.supports_unix_socket});
        try writer.print("\"supportsNamedPipes\":{},", .{self.supports_named_pipes});
        try writer.print("\"supportsMouse\":{},", .{self.supports_mouse});
        try writer.print("\"supportsMenuProjection\":{},", .{self.supports_menu_projection});
        try writer.print("\"supportsNvimIntegration\":{}", .{self.supports_nvim_integration});
        try writer.writeAll("}");
    }
};
