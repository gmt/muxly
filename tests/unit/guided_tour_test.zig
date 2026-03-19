const std = @import("std");
const muxly = @import("muxly");

test "guided tour renders deterministic checkpoints" {
    const bootstrap = try muxly.demo.guided_tour.renderStep(std.testing.allocator, 0, 24, 80);
    defer std.testing.allocator.free(bootstrap);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap, "muxguide :: staged viewer tour :: bootstrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, bootstrap, "thread [tail]") != null);

    const nested = try muxly.demo.guided_tour.renderStep(std.testing.allocator, 2, 24, 80);
    defer std.testing.allocator.free(nested);
    try std.testing.expect(std.mem.indexOf(u8, nested, "subagent :: synthesizing boxed") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested, "sub-agent [tail]") != null);
    try std.testing.expect(std.mem.indexOf(u8, nested, "local viewer state bel") != null);
}
