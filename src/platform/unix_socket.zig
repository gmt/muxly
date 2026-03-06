const std = @import("std");

pub const Listener = struct {
    socket_path: []const u8,
    server: std.net.Server,

    pub fn init(socket_path: []const u8) !Listener {
        std.fs.deleteFileAbsolute(socket_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return .{
            .socket_path = socket_path,
            .server = try (try std.net.Address.initUnix(socket_path)).listen(.{}),
        };
    }

    pub fn deinit(self: *Listener) void {
        self.server.deinit();
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
    }

    pub fn accept(self: *Listener) !std.net.Server.Connection {
        return try self.server.accept();
    }
};

pub fn connect(socket_path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(socket_path);
}
