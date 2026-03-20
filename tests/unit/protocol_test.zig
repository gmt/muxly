const std = @import("std");
const muxly = @import("muxly");

test "protocol parse request smoke" {
    const payload =
        \\{"jsonrpc":"2.0","id":7,"method":"document.get","params":{}}
    ;
    const parsed = try muxly.protocol.parseRequest(std.testing.allocator, payload);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("2.0", parsed.value.jsonrpc);
    try std.testing.expectEqualStrings("document.get", parsed.value.method);
}

test "protocol request parsing keeps optional document target" {
    const payload =
        \\{"jsonrpc":"2.0","id":7,"target":{"documentPath":"/docs/demo"},"method":"document.get","params":{}}
    ;
    const parsed = try muxly.protocol.parseRequest(std.testing.allocator, payload);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("/docs/demo", try muxly.protocol.requestDocumentPath(parsed.value));
}

test "protocol client request writer emits document target" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try muxly.protocol.writeClientRequest(
        buffer.writer(),
        42,
        "/docs/demo",
        "document.status",
        "{}",
    );

    const parsed = try muxly.protocol.parseRequest(std.testing.allocator, buffer.items);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("document.status", parsed.value.method);
    try std.testing.expectEqualStrings("/docs/demo", try muxly.protocol.requestDocumentPath(parsed.value));
}
