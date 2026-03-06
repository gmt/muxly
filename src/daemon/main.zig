const std = @import("std");
const config_mod = @import("config.zig");
const server = @import("server.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try config_mod.Config.load(allocator);
    defer config.deinit();

    const stderr = std.io.getStdErr().writer();
    try stderr.print("muxlyd listening on {s}\n", .{config.socket_path});
    try server.serve(allocator, config);
}
