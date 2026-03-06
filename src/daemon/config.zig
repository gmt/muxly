const std = @import("std");

pub const Config = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const socket_path = std.process.getEnvVarOwned(allocator, "MUXLY_SOCKET") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => try allocator.dupe(u8, defaultSocketPath()),
            else => return err,
        };

        return .{
            .allocator = allocator,
            .socket_path = socket_path,
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.socket_path);
    }

    pub fn defaultSocketPath() []const u8 {
        return if (@import("builtin").os.tag == .windows)
            "\\\\.\\pipe\\muxly"
        else
            "/tmp/muxly.sock";
    }
};
