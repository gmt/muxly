const std = @import("std");

pub const Parsed = struct {
    socket_path: []const u8,
    command_index: usize,
};

pub fn parse(argv: []const []const u8, default_socket_path: []const u8) Parsed {
    if (argv.len >= 4 and std.mem.eql(u8, argv[1], "--socket")) {
        return .{
            .socket_path = argv[2],
            .command_index = 3,
        };
    }

    return .{
        .socket_path = default_socket_path,
        .command_index = 1,
    };
}
