const std = @import("std");
const muxly = @import("muxly");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    var socket_path = try muxly.api.socketPathFromEnv(allocator);
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--socket")) socket_path = args[2];

    const response = try muxly.api.viewGet(allocator, socket_path);
    defer allocator.free(response);

    const parsed_response = try std.json.parseFromSlice(std.json.Value, allocator, response, .{
        .allocate = .alloc_always,
    });
    defer parsed_response.deinit();

    const result = parsed_response.value.object.get("result") orelse {
        try std.io.getStdOut().writer().writeAll(response);
        return;
    };

    try muxly.viewer_render.renderDocumentValue(allocator, result, std.io.getStdOut().writer());
}
