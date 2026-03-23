const std = @import("std");
const support = @import("async_transport_validation_support.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var transport_text: ?[]const u8 = null;
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--transport")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            transport_text = argv[index];
            continue;
        }

        if (std.mem.eql(u8, arg, "--seed")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            _ = std.fmt.parseInt(u64, argv[index], 10) catch return error.InvalidArguments;
            continue;
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\usage: muxly-async-transport-probe --transport tcp|http|h2|h3wt [--seed N]
                \\
            , .{});
            return;
        }

        return error.InvalidArguments;
    }

    const transport = try support.TransportKind.parse(transport_text orelse return error.InvalidArguments);
    try support.runTransportValidation(allocator, transport);
}
