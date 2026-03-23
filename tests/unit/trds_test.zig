const std = @import("std");
const muxly = @import("muxly");

test "trds parser applies defaults and keeps root document" {
    var parsed = try muxly.trds.parse(std.testing.allocator, "trds://host.lan");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(muxly.trds.SecureTransportCode.auto, parsed.transport_code);
    try std.testing.expectEqualStrings("host.lan", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("/rpc", parsed.https_path);
    try std.testing.expectEqualStrings("/", parsed.document_path);
    try std.testing.expect(parsed.selector == null);
}

test "trds parser handles explicit secure transport port path document selector and trust" {
    var parsed = try muxly.trds.parse(
        std.testing.allocator,
        "trds://ht2|example.com:9443/api?sha256=deadbeef&sni=rpc.example.com::/docs/demo#left/pane",
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(muxly.trds.SecureTransportCode.ht2, parsed.transport_code);
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 9443), parsed.port);
    try std.testing.expectEqualStrings("/api", parsed.https_path);
    try std.testing.expectEqualStrings("/docs/demo", parsed.document_path);
    try std.testing.expectEqualStrings("left/pane", parsed.selector.?);
    try std.testing.expectEqualStrings("deadbeef", parsed.certificate_hash.?);
    try std.testing.expectEqualStrings("rpc.example.com", parsed.server_name.?);
    try std.testing.expect(parsed.ca_file == null);
}

test "trds parser rejects malformed relative-style values" {
    try std.testing.expectError(
        error.InvalidResourceDescriptor,
        muxly.trds.parse(std.testing.allocator, "trds:#welcome"),
    );
}

test "trds parser rejects local ca file overrides in shareable descriptors" {
    try std.testing.expectError(
        error.InvalidResourceDescriptor,
        muxly.trds.parse(std.testing.allocator, "trds://htp|host.lan:9443/rpc?ca=/tmp/root.crt::/docs/demo"),
    );
}

test "trds parser recognizes explicit wtp transport" {
    var parsed = try muxly.trds.parse(std.testing.allocator, "trds://wtp|host.lan:9443/rpc::/docs/demo");
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(muxly.trds.SecureTransportCode.wtp, parsed.transport_code);
    try std.testing.expectEqualStrings("/docs/demo", parsed.document_path);
}

test "trds caddy render uses h2c upstream and internal tls for user mode" {
    var parsed = try muxly.trds.parse(std.testing.allocator, "trds://127.0.0.1:9443/custom::/docs/demo");
    defer parsed.deinit(std.testing.allocator);

    const rendered = try muxly.trds.renderCaddyfile(
        std.testing.allocator,
        parsed,
        .{
            .mode = .user,
            .output_dir = "/tmp/ignored",
            .muxlyd_bin = "/usr/bin/muxlyd",
            .upstream_port = 28449,
        },
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "https://127.0.0.1:9443") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tls internal") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "handle /custom*") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "reverse_proxy h2c://127.0.0.1:28449") != null);
}

test "trds system caddy snippet omits forced internal tls for non-local hosts" {
    var parsed = try muxly.trds.parse(std.testing.allocator, "trds://mux.example.com");
    defer parsed.deinit(std.testing.allocator);

    const rendered = try muxly.trds.renderSystemCaddySnippet(
        std.testing.allocator,
        parsed,
        .{
            .mode = .system,
            .output_dir = "/tmp/ignored",
            .muxlyd_bin = "/usr/bin/muxlyd",
        },
    );
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "tls internal") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "reverse_proxy h2c://127.0.0.1:4489") != null);
}

test "trds generators write mode-appropriate artifacts" {
    var parsed = try muxly.trds.parse(std.testing.allocator, "trds://localhost:9443");
    defer parsed.deinit(std.testing.allocator);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const output_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(output_dir);

    var caddy_paths = try muxly.trds.writeCaddyArtifacts(
        std.testing.allocator,
        parsed,
        .{
            .mode = .user,
            .output_dir = output_dir,
            .muxlyd_bin = "/tmp/muxlyd",
            .caddy_bin = "/usr/bin/caddy",
        },
    );
    defer caddy_paths.deinit(std.testing.allocator);
    var systemd_paths = try muxly.trds.writeSystemdArtifacts(
        std.testing.allocator,
        parsed,
        .{
            .mode = .system,
            .output_dir = output_dir,
            .muxlyd_bin = "/usr/bin/muxlyd",
        },
    );
    defer systemd_paths.deinit(std.testing.allocator);

    _ = try std.fs.cwd().access(caddy_paths.caddy_file, .{});
    _ = try std.fs.cwd().access(caddy_paths.caddy_unit_or_snippet, .{});
    _ = try std.fs.cwd().access(systemd_paths.muxlyd_unit, .{});
    _ = try std.fs.cwd().access(systemd_paths.caddy_unit_or_snippet, .{});
}

test "trds resolve renders secure transport specs and document defaults" {
    var resolved = try muxly.trds.resolve(
        std.testing.allocator,
        "trds://ht1|host.lan:9443/custom?sha256=deadbeef::/docs/demo#left",
    );
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "https1://host.lan:9443/custom?sha256=deadbeef",
        resolved.transport_spec,
    );
    try std.testing.expectEqualStrings("/docs/demo", resolved.document_path);
    try std.testing.expectEqualStrings("left", resolved.selector.?);
}

test "trds resolve renders explicit wtp transport specs" {
    var resolved = try muxly.trds.resolve(
        std.testing.allocator,
        "trds://wtp|mux.example.com::/docs/demo",
    );
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("h3wt://mux.example.com:443/rpc", resolved.transport_spec);
    try std.testing.expectEqualStrings("/docs/demo", resolved.document_path);
    try std.testing.expect(resolved.selector == null);
}

test "trds resolve rejects default auto descriptors without runtime probing" {
    try std.testing.expectError(
        error.UnsupportedResourceTransport,
        muxly.trds.resolve(std.testing.allocator, "trds://mux.example.com::/docs/demo"),
    );
}
