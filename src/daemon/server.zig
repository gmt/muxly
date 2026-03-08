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

        const request = try readRequestLine(allocator, connection.stream, 1 << 20);
        defer allocator.free(request);
        const bytes = request;
        if (bytes.len == 0) continue;

        const response = try router.handleRequest(allocator, &store, bytes);
        defer allocator.free(response);
        try connection.stream.writeAll(response);
        try connection.stream.writeAll("\n");
    }
}

fn readRequestLine(allocator: std.mem.Allocator, stream: std.net.Stream, max_bytes: usize) ![]u8 {
    var request = std.array_list.Managed(u8).init(allocator);
    errdefer request.deinit();

    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) break;

        const chunk = buffer[0..bytes_read];
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |newline_index| {
            try request.appendSlice(chunk[0..newline_index]);
            break;
        }

        try request.appendSlice(chunk);
        if (request.items.len > max_bytes) return error.MessageTooLarge;
    }

    if (request.items.len > max_bytes) return error.MessageTooLarge;
    return try request.toOwnedSlice();
}
