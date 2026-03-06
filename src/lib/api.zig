const std = @import("std");
const client_mod = @import("client.zig");

pub fn ping(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    var client = try client_mod.Client.init(allocator, socket_path);
    defer client.deinit();
    return try client.request("ping", "{}");
}
