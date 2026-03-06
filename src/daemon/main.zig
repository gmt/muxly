const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("muxlyd bootstrap: daemon target is wired up\n");
}
