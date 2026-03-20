const std = @import("std");
const muxly = @import("muxly");
const config_mod = @import("config.zig");
const router = @import("router.zig");
const store_mod = @import("state/store.zig");

pub fn serve(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    var store = try store_mod.Store.init(allocator);
    defer store.deinit();

    var listener = try muxly.transport.Listener.init(&config.transport);
    defer listener.deinit();

    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.writeAll("muxlyd listening on ");
    try listener.writeDescription(stderr);
    try stderr.writeByte('\n');

    while (true) {
        var connection = try listener.accept();
        defer connection.stream.close();
        var request_reader = muxly.transport.MessageReader.init(allocator);
        defer request_reader.deinit();

        while (true) {
            const request = try request_reader.readMessageLine(
                connection.stream,
                muxly.transport.max_message_bytes,
            ) orelse break;
            defer allocator.free(request);
            if (request.len == 0) continue;

            const response = try router.handleRequest(allocator, &store, request);
            defer allocator.free(response);
            try connection.stream.writeAll(response);
            try connection.stream.writeAll("\n");
        }
    }
}
