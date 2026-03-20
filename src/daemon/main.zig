const std = @import("std");
const config_mod = @import("config.zig");
const server = @import("server.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var config = config_mod.Config.load(allocator, args) catch |err| switch (err) {
        error.ShowUsage => {
            try std.fs.File.stderr().writeAll(config_mod.usage);
            return;
        },
        else => return err,
    };
    defer config.deinit();
    try server.serve(allocator, config);
}
