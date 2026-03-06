const std = @import("std");
const muxly = @import("muxly");

export fn muxly_version() [*:0]const u8 {
    return "0.1.0";
}

export fn muxly_ping(socket_path: [*:0]const u8) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(socket_path);
    const response = muxly.api.ping(allocator, path) catch return null;
    const owned = allocator.allocSentinel(u8, response.len, 0) catch {
        allocator.free(response);
        return null;
    };
    @memcpy(owned[0..response.len], response);
    allocator.free(response);
    return owned.ptr;
}

export fn muxly_string_free(value: ?[*:0]u8) void {
    if (value) |ptr| {
        const allocator = std.heap.c_allocator;
        allocator.free(std.mem.span(ptr));
    }
}
