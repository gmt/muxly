const builtin = @import("builtin");
const std = @import("std");
const muxly = @import("muxly");
const config_mod = @import("config.zig");
const router = @import("router.zig");
const store_mod = @import("state/store.zig");
const unix_socket = muxly.platform.unix_socket;

pub fn serve(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

    var store = try store_mod.Store.init(allocator);
    defer store.deinit();

    var listener = try unix_socket.Listener.init(config.socket_path);
    defer listener.deinit();

    while (true) {
        var connection = try listener.accept();
        defer connection.stream.close();

        const request = try connection.stream.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 1 << 20);
        defer if (request) |bytes| allocator.free(bytes);
        if (request == null) continue;
        const bytes = request.?;
        if (bytes.len == 0) continue;

        const response = try router.handleRequest(allocator, &store, bytes);
        defer allocator.free(response);
        try connection.stream.writer().writeAll(response);
        try connection.stream.writer().writeByte('\n');
    }
}
