const std = @import("std");
const muxly = @import("muxly");

test "trd parser keeps explicit server, document, and selector components" {
    var parsed = try muxly.trd.parse(
        std.testing.allocator,
        "trd://webtransport|127.0.0.1:4433/mux?sha256=deadbeef//doc/u/ment/id#node/path/in/TOM",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(muxly.trd.Parsed.Kind.absolute, parsed.kind);
    try std.testing.expectEqualStrings("webtransport", parsed.transport_code.?);
    try std.testing.expectEqualStrings("127.0.0.1:4433/mux?sha256=deadbeef", parsed.endpoint.?);
    try std.testing.expectEqualStrings("/doc/u/ment/id", parsed.document_path.?);
    try std.testing.expectEqualStrings("node/path/in/TOM", parsed.selector.?);
}

test "trd parsed properties expose the main semantic cuts without reparsing" {
    var doc_only = try muxly.trd.parse(std.testing.allocator, "trd://welcome");
    defer doc_only.deinit(std.testing.allocator);
    const doc_only_props = doc_only.properties();
    try std.testing.expect(doc_only_props.is_absolute);
    try std.testing.expect(!doc_only_props.is_relative);
    try std.testing.expect(!doc_only_props.has_explicit_server);
    try std.testing.expect(doc_only_props.has_explicit_document);
    try std.testing.expect(doc_only_props.is_document_only);
    try std.testing.expect(!doc_only_props.is_node_targeted);
    try std.testing.expect(!doc_only_props.inherits_transport);
    try std.testing.expect(!doc_only_props.inherits_document);

    var relative = try muxly.trd.parse(std.testing.allocator, "trd:#welcome/child");
    defer relative.deinit(std.testing.allocator);
    const relative_props = relative.properties();
    try std.testing.expect(relative_props.is_relative);
    try std.testing.expect(!relative_props.is_absolute);
    try std.testing.expect(!relative_props.has_explicit_server);
    try std.testing.expect(!relative_props.has_explicit_document);
    try std.testing.expect(relative_props.has_selector);
    try std.testing.expect(!relative_props.is_document_only);
    try std.testing.expect(relative_props.is_node_targeted);
    try std.testing.expect(relative_props.inherits_transport);
    try std.testing.expect(relative_props.inherits_document);

    var explicit_server = try muxly.trd.parse(std.testing.allocator, "trd://http|host.lan/rpc//docs/demo#left");
    defer explicit_server.deinit(std.testing.allocator);
    const explicit_server_props = explicit_server.properties();
    try std.testing.expect(explicit_server_props.is_absolute);
    try std.testing.expect(explicit_server_props.has_explicit_server);
    try std.testing.expect(explicit_server_props.has_explicit_document);
    try std.testing.expect(explicit_server_props.has_selector);
    try std.testing.expect(explicit_server_props.is_node_targeted);
}

test "trd document shorthand resolves to the runtime default transport" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd://welcome");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(
        std.testing.allocator,
        "tcp://127.0.0.1:4488",
        "/current/doc",
    );
    defer resolved.deinit(std.testing.allocator);

    const expected_default = try muxly.api.runtimeDefaultTransportSpecOwned(std.testing.allocator);
    defer std.testing.allocator.free(expected_default);

    try std.testing.expectEqualStrings(expected_default, resolved.transport_spec);
    try std.testing.expectEqualStrings("/welcome", resolved.document_path);
    try std.testing.expect(resolved.selector == null);
}

test "absolute trd selector on default transport keeps the root document" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd://#welcome");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(
        std.testing.allocator,
        "tcp://127.0.0.1:4488",
        "/current/doc",
    );
    defer resolved.deinit(std.testing.allocator);

    const expected_default = try muxly.api.runtimeDefaultTransportSpecOwned(std.testing.allocator);
    defer std.testing.allocator.free(expected_default);

    try std.testing.expectEqualStrings(expected_default, resolved.transport_spec);
    try std.testing.expectEqualStrings("/", resolved.document_path);
    try std.testing.expectEqualStrings("welcome", resolved.selector.?);
}

test "relative trd selectors stay on the current transport and document" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd:#welcome/child");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(
        std.testing.allocator,
        "http://127.0.0.1:8080/rpc",
        "/docs/demo",
    );
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqual(muxly.trd.Parsed.Kind.relative, parsed.kind);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080/rpc", resolved.transport_spec);
    try std.testing.expectEqualStrings("/docs/demo", resolved.document_path);
    try std.testing.expectEqualStrings("welcome/child", resolved.selector.?);
}

test "relative trd selectors can stay lazy through request targets" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd:#welcome/child");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(
        std.testing.allocator,
        "http://127.0.0.1:8080/rpc",
        "/docs/demo",
    );
    defer resolved.deinit(std.testing.allocator);

    const target = muxly.api.NodeRequestTarget.fromSelector(resolved.selector.?);
    try std.testing.expect(target.node_id == null);
    try std.testing.expectEqualStrings("welcome/child", target.selector.?);
}

test "trd explicit unix server defaults endpoint when omitted" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd://unix|//x/y");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(
        std.testing.allocator,
        "tcp://127.0.0.1:4488",
        "/current/doc",
    );
    defer resolved.deinit(std.testing.allocator);

    const expected_default = try muxly.api.runtimeDefaultTransportSpecOwned(std.testing.allocator);
    defer std.testing.allocator.free(expected_default);

    try std.testing.expectEqualStrings(expected_default, resolved.transport_spec);
    try std.testing.expectEqualStrings("/x/y", resolved.document_path);
    try std.testing.expect(resolved.selector == null);
}

test "trd explicit default transport code falls back to unix" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd://|relative.sock//y");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(
        std.testing.allocator,
        "tcp://127.0.0.1:4488",
        "/current/doc",
    );
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("relative.sock", resolved.transport_spec);
    try std.testing.expectEqualStrings("/y", resolved.document_path);
    try std.testing.expect(resolved.selector == null);
}

test "trd explicit webtransport server defaults host path and root document" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd://webtransport|foo//");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(
        std.testing.allocator,
        "tcp://127.0.0.1:4488",
        "/current/doc",
    );
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("h3wt://foo", resolved.transport_spec);
    try std.testing.expectEqualStrings("/", resolved.document_path);
    try std.testing.expect(resolved.selector == null);
}

test "trd explicit tcp server defaults localhost and the canonical muxly tcp port" {
    var parsed = try muxly.trd.parse(std.testing.allocator, "trd://tcp|//");
    defer parsed.deinit(std.testing.allocator);

    var resolved = try parsed.resolve(
        std.testing.allocator,
        "unix:///tmp/ignored.sock",
        "/current/doc",
    );
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("tcp://localhost:4488", resolved.transport_spec);
    try std.testing.expectEqualStrings("/", resolved.document_path);
    try std.testing.expect(resolved.selector == null);
}
