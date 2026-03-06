const std = @import("std");

pub fn writeResponse(writer: anytype, response: []const u8) !void {
    try writer.writeAll(response);
}
