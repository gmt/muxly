const std = @import("std");
const muxly = @import("muxly");

test "trd parser keeps transport, document, and selector components" {
    var parsed = try muxly.trd.parse(
        std.testing.allocator,
        "trd://wt|127.0.0.1:4433/mux?sha256=deadbeef//doc/u/ment/id#node/path/in/TOM",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(muxly.trd.Parsed.Kind.absolute, parsed.kind);
    try std.testing.expectEqualStrings("wt", parsed.transport_code.?);
    try std.testing.expectEqualStrings("127.0.0.1:4433/mux?sha256=deadbeef", parsed.endpoint.?);
    try std.testing.expectEqualStrings("/doc/u/ment/id", parsed.document_path.?);
    try std.testing.expectEqualStrings("node/path/in/TOM", parsed.selector.?);
}

test "trd shorthand selector resolves to the runtime default transport and root document" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd://welcome");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(std.testing.allocator, "tcp://127.0.0.1:4488");
    defer resolved.deinit(std.testing.allocator);

    const expected_default = try muxly.api.runtimeDefaultTransportSpecOwned(std.testing.allocator);
    defer std.testing.allocator.free(expected_default);

    try std.testing.expectEqualStrings(expected_default, resolved.transport_spec);
    try std.testing.expectEqualStrings("/", resolved.document_path);
    try std.testing.expectEqualStrings("welcome", resolved.selector.?);
}

test "relative trd selectors stay on the current transport" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd:#welcome/child");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(std.testing.allocator, "http://127.0.0.1:8080/rpc");
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(muxly.trd.Parsed.Kind.relative, parsed.kind);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/rpc", resolved.transport_spec);
    try std.testing.expectEqualStrings("/", resolved.document_path);
    try std.testing.expectEqualStrings("welcome/child", resolved.selector.?);
}
