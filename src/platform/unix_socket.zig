//! Unix-domain socket transport helpers used by the current daemon/client
//! surface.

const std = @import("std");

/// Listener for the daemon's Unix-domain socket transport.
pub const Listener = struct {
    socket_path: []const u8,
    server: std.net.Server,

    /// Creates a listening Unix-domain socket, removing any stale socket file
    /// first.
    pub fn init(socket_path: []const u8) !Listener {
        std.posix.unlink(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return .{
            .socket_path = socket_path,
            .server = try (try std.net.Address.initUnix(socket_path)).listen(.{}),
        };
    }

    /// Shuts down the listener and removes the socket file best-effort.
    pub fn deinit(self: *Listener) void {
        self.server.deinit();
        std.posix.unlink(self.socket_path) catch {};
    }

    /// Accepts one incoming client connection.
    pub fn accept(self: *Listener) !std.net.Server.Connection {
        return try self.server.accept();
    }
};

/// Connects to a daemon listening on a Unix-domain socket path.
pub fn connect(socket_path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(socket_path);
}
