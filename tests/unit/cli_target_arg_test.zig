const std = @import("std");
const muxly = @import("muxly");
const target_arg = @import("cli_target_arg");

test "document-or-node lazy mode maps document-only TRDs to document root" {
    var target = try target_arg.resolve(
        std.testing.allocator,
        "http://127.0.0.1:8080/rpc",
        "/current/doc",
        "trd://docs/demo",
        .document_or_node_lazy,
    );
    defer target.deinit(std.testing.allocator);

    const expected_default = try muxly.api.runtimeDefaultTransportSpecOwned(std.testing.allocator);
    defer std.testing.allocator.free(expected_default);

    try std.testing.expectEqualStrings(expected_default, target.transport_spec);
    try std.testing.expectEqualStrings("/docs/demo", target.document_path);
    try std.testing.expect(target.node_target.node_id == null);
    try std.testing.expectEqualStrings("/", target.node_target.selector.?);
}

test "explicit-node lazy mode rejects document-only TRDs" {
    try std.testing.expectError(
        error.ExplicitNodeTargetRequired,
        target_arg.resolve(
            std.testing.allocator,
            "http://127.0.0.1:8080/rpc",
            "/current/doc",
            "trd://docs/demo",
            .explicit_node_lazy,
        ),
    );
}

test "explicit-node lazy mode keeps selectors lazy" {
    var target = try target_arg.resolve(
        std.testing.allocator,
        "http://127.0.0.1:8080/rpc",
        "/current/doc",
        "trd:#welcome/child",
        .explicit_node_lazy,
    );
    defer target.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("http://127.0.0.1:8080/rpc", target.transport_spec);
    try std.testing.expectEqualStrings("/current/doc", target.document_path);
    try std.testing.expect(target.node_target.node_id == null);
    try std.testing.expectEqualStrings("welcome/child", target.node_target.selector.?);
}
