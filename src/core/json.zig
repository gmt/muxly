const std = @import("std");

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return try std.json.stringifyAlloc(allocator, value, .{});
}
