const std = @import("std");
const muxly = @import("muxly");

test "sessionCreateAtInDocument rejects non-root document targets before transport" {
    try std.testing.expectError(
        error.RootDocumentOnlyTarget,
        muxly.api.sessionCreateAtInDocument(
            std.testing.allocator,
            "/tmp/ignored.sock",
            "/demo/doc",
            null,
            "demo-session",
            null,
        ),
    );
}
