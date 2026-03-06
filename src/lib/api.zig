const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");

pub fn ping(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    var client = try client_mod.Client.init(allocator, socket_path);
    defer client.deinit();
    return try client.request("ping", "{}");
}

pub fn documentGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    var client = try client_mod.Client.init(allocator, socket_path);
    defer client.deinit();
    return try client.request("document.get", "{}");
}

pub fn socketPathFromEnv(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "MUXLY_SOCKET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, defaultSocketPath()),
        else => return err,
    };
}

pub fn defaultSocketPath() []const u8 {
    return if (builtin.os.tag == .windows)
        "\\\\.\\pipe\\muxly"
    else
        "/tmp/muxly.sock";
}
