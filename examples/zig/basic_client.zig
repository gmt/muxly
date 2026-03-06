const std = @import("std");
const c = @cImport({
    @cInclude("muxly.h");
});

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("muxly version => {s}\n", .{std.mem.span(c.muxly_version())});

    const response_ptr = c.muxly_ping("/tmp/muxly.sock");
    if (response_ptr == null) return error.PingFailed;
    defer c.muxly_string_free(response_ptr);

    try stdout.print("ping => {s}\n", .{std.mem.span(response_ptr)});
}
