const std = @import("std");
const muxly = @import("muxly");

pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !muxly.client.Client {
    return try muxly.client.Client.init(allocator, socket_path);
}
