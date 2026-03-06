const std = @import("std");
const muxly = @import("muxly");

export fn muxly_version() [*:0]const u8 {
    return "0.1.0";
}

export fn muxly_ping(socket_path: [*:0]const u8) ?[*:0]u8 {
    return callStringApi(socket_path, muxly.api.ping);
}

export fn muxly_document_get(socket_path: [*:0]const u8) ?[*:0]u8 {
    return callStringApi(socket_path, muxly.api.documentGet);
}

export fn muxly_string_free(value: ?[*:0]u8) void {
    if (value) |ptr| {
        const allocator = std.heap.c_allocator;
        allocator.free(std.mem.span(ptr));
    }
}

fn callStringApi(
    socket_path: [*:0]const u8,
    comptime api_fn: fn (std.mem.Allocator, []const u8) anyerror![]u8,
) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(socket_path);
    const response = api_fn(allocator, path) catch return null;
    const owned = allocator.allocSentinel(u8, response.len, 0) catch {
        allocator.free(response);
        return null;
    };
    @memcpy(owned[0..response.len], response);
    allocator.free(response);
    return owned.ptr;
}
