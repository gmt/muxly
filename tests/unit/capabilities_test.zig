const std = @import("std");
const builtin = @import("builtin");
const muxly = @import("muxly");

test "capabilities describe current phase-2 semantics truthfully" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try (muxly.capabilities.Capabilities{}).writeJson(buffer.writer());

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"followTailSemantics\":\"stored-node-preference\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"viewStateScope\":\"shared-document\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"tmuxBackendMode\":\"hybrid-control-invalidation\"") != null);

    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsUnixSocket\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsTcpSocket\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"implementedTransports\":[]") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsUnixSocket\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsTcpSocket\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"implementedTransports\":[\"unix-domain-socket\",\"tcp\"]") != null);
    }

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"supportsNamedPipes\":false") != null);
}
