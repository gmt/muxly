const std = @import("std");
const muxly = @import("muxly");
const cli_args = muxly.cli_args;
const admin_generate = @import("admin_generate.zig");
const cli_format = @import("format.zig");
const target_arg = @import("target_arg.zig");

fn tlsOverridesFromParsed(parsed: cli_args.Parsed) target_arg.SecureTransportOverrides {
    return .{
        .tls_ca_file = parsed.tls_ca_file,
        .tls_pin_sha256 = parsed.tls_pin_sha256,
        .tls_server_name = parsed.tls_server_name,
    };
}

fn applySecureTransportOverrides(
    allocator: std.mem.Allocator,
    transport_spec: []const u8,
    overrides: target_arg.SecureTransportOverrides,
) ![]u8 {
    if (overrides.tls_ca_file == null and overrides.tls_pin_sha256 == null and overrides.tls_server_name == null) {
        return try allocator.dupe(u8, transport_spec);
    }

    var address = try muxly.transport.Address.parse(allocator, transport_spec);
    defer address.deinit(allocator);

    switch (address.target) {
        .https => |*https| try applySecureOverridesToAddress(allocator, https, overrides),
        .https1 => |*https| try applySecureOverridesToAddress(allocator, https, overrides),
        .https2 => |*https| try applySecureOverridesToAddress(allocator, https, overrides),
        .h3wt => |*h3wt| try applySecureOverridesToH3wtAddress(allocator, h3wt, overrides),
        else => return try allocator.dupe(u8, transport_spec),
    }

    var rendered = std.array_list.Managed(u8).init(allocator);
    defer rendered.deinit();
    try address.write(rendered.writer());
    return try rendered.toOwnedSlice();
}

fn applySecureOverridesToAddress(
    allocator: std.mem.Allocator,
    https: *muxly.transport.Address.SecureHttpAddress,
    overrides: target_arg.SecureTransportOverrides,
) !void {
    if (overrides.tls_ca_file) |value| {
        if (https.ca_file) |existing| allocator.free(existing);
        https.ca_file = try allocator.dupe(u8, value);
    }
    if (overrides.tls_pin_sha256) |value| {
        if (https.certificate_hash) |existing| allocator.free(existing);
        https.certificate_hash = try allocator.dupe(u8, value);
    }
    if (overrides.tls_server_name) |value| {
        if (https.server_name) |existing| allocator.free(existing);
        https.server_name = try allocator.dupe(u8, value);
    }
}

fn applySecureOverridesToH3wtAddress(
    allocator: std.mem.Allocator,
    h3wt: *muxly.transport.Address.H3wtAddress,
    overrides: target_arg.SecureTransportOverrides,
) !void {
    if (overrides.tls_ca_file) |value| {
        if (h3wt.ca_file) |existing| allocator.free(existing);
        h3wt.ca_file = try allocator.dupe(u8, value);
    }
    if (overrides.tls_pin_sha256) |value| {
        if (h3wt.certificate_hash) |existing| allocator.free(existing);
        h3wt.certificate_hash = try allocator.dupe(u8, value);
    }
    if (overrides.tls_server_name) |value| {
        if (h3wt.server_name) |existing| allocator.free(existing);
        h3wt.server_name = try allocator.dupe(u8, value);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len <= 1) return printUsage();

    const transport_from_env = try muxly.api.transportSpecFromEnv(allocator);
    defer allocator.free(transport_from_env);
    const parsed = cli_args.parse(args, transport_from_env) catch |err| switch (err) {
        error.ShowUsage => return printUsage(),
        else => return err,
    };
    const tls_overrides = tlsOverridesFromParsed(parsed);
    if (parsed.allow_insecure_tcp and muxly.trds.isDescriptor(parsed.transport_spec)) {
        return error.InvalidArguments;
    }
    const transport_input = if (parsed.allow_insecure_tcp)
        try muxly.transport.withUnsafeTcpPrefix(allocator, parsed.transport_spec)
    else
        try allocator.dupe(u8, parsed.transport_spec);
    defer allocator.free(transport_input);

    var transport_spec = try allocator.dupe(u8, transport_input);
    defer allocator.free(transport_spec);
    var default_document_path = try allocator.dupe(u8, muxly.protocol.default_document_path);
    defer allocator.free(default_document_path);

    if (muxly.trds.isDescriptor(transport_input)) {
        allocator.free(transport_spec);
        var resolved = try muxly.client.resolveTransportInput(allocator, transport_input, tls_overrides);
        defer resolved.deinit(allocator);
        transport_spec = try allocator.dupe(u8, resolved.transport_spec);
        allocator.free(default_document_path);
        default_document_path = try allocator.dupe(
            u8,
            resolved.default_document_path orelse muxly.protocol.default_document_path,
        );
    } else {
        allocator.free(transport_spec);
        transport_spec = try applySecureTransportOverrides(allocator, transport_input, tls_overrides);
    }
    const cursor = parsed.command_index;

    if (cursor >= args.len) return printUsage();

    if (std.mem.eql(u8, args[cursor], "transport") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "relay")) {
        return try runTransportRelay(allocator, transport_spec);
    }
    if (std.mem.eql(u8, args[cursor], "admin") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "generate-caddy")) {
        return try admin_generate.run(allocator, .caddy, args[cursor + 2 ..]);
    }
    if (std.mem.eql(u8, args[cursor], "admin") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "generate-systemd")) {
        return try admin_generate.run(allocator, .systemd, args[cursor + 2 ..]);
    }

    const response = if (std.mem.eql(u8, args[cursor], "ping"))
        try muxly.api.ping(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "initialize"))
        try muxly.api.initialize(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "capabilities") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try muxly.api.capabilitiesGet(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "get")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .document_or_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeGetTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "node") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "append")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .document_or_node_concrete, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeAppendInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.requireNodeId() catch return printUsage(),
            args[cursor + 3],
            args[cursor + 4],
        );
    } else if (std.mem.eql(u8, args[cursor], "node") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "update")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .explicit_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeUpdateTargetInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.node_target,
            if (std.mem.eql(u8, args[cursor + 3], "title")) args[cursor + 4] else null,
            if (std.mem.eql(u8, args[cursor + 3], "content")) args[cursor + 4] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "node") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "freeze")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .explicit_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeFreezeTargetInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.node_target,
            args[cursor + 3],
        );
    } else if (std.mem.eql(u8, args[cursor], "node") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "remove")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .explicit_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeRemoveTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "session") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try muxly.api.sessionList(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "window") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try muxly.api.windowList(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try muxly.api.paneList(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "list"))
        try muxly.api.graphGet(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "split") and cursor + 2 < args.len) blk: {
        break :blk try muxly.api.paneSplit(
            allocator,
            transport_spec,
            args[cursor + 1],
            args[cursor + 2],
            if (cursor + 3 < args.len) args[cursor + 3] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "capture") and cursor + 1 < args.len) blk: {
        break :blk try muxly.api.paneCapture(allocator, transport_spec, args[cursor + 1]);
    } else if (std.mem.eql(u8, args[cursor], "session") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "create")) blk: {
        break :blk try muxly.api.sessionCreate(
            allocator,
            transport_spec,
            args[cursor + 2],
            if (cursor + 3 < args.len) args[cursor + 3] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "session") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "create-under")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .document_or_node_concrete, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.sessionCreateAtInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.requireNodeId() catch return printUsage(),
            args[cursor + 3],
            if (cursor + 4 < args.len) args[cursor + 4] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "window") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "create")) blk: {
        break :blk try muxly.api.windowCreate(
            allocator,
            transport_spec,
            args[cursor + 2],
            if (cursor + 3 < args.len) args[cursor + 3] else null,
            if (cursor + 4 < args.len) args[cursor + 4] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "split")) blk: {
        break :blk try muxly.api.paneSplit(
            allocator,
            transport_spec,
            args[cursor + 2],
            args[cursor + 3],
            if (cursor + 4 < args.len) args[cursor + 4] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "capture")) blk: {
        break :blk try muxly.api.paneCapture(allocator, transport_spec, args[cursor + 2]);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "scroll")) blk: {
        const start_line = try std.fmt.parseInt(i64, args[cursor + 3], 10);
        const end_line = try std.fmt.parseInt(i64, args[cursor + 4], 10);
        break :blk try muxly.api.paneScroll(allocator, transport_spec, args[cursor + 2], start_line, end_line);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "resize")) blk: {
        const amount = try std.fmt.parseInt(i64, args[cursor + 4], 10);
        break :blk try muxly.api.paneResize(allocator, transport_spec, args[cursor + 2], args[cursor + 3], amount);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "focus")) blk: {
        break :blk try muxly.api.paneFocus(allocator, transport_spec, args[cursor + 2]);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "send-keys")) blk: {
        break :blk try muxly.api.paneSendKeys(
            allocator,
            transport_spec,
            args[cursor + 2],
            args[cursor + 3],
            if (cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 4], "--enter")) true else false,
        );
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "close")) blk: {
        break :blk try muxly.api.paneClose(allocator, transport_spec, args[cursor + 2]);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "follow-tail")) blk: {
        break :blk try muxly.api.paneFollowTail(
            allocator,
            transport_spec,
            args[cursor + 2],
            std.mem.eql(u8, args[cursor + 3], "true"),
        );
    } else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try muxly.api.documentGetInDocument(allocator, transport_spec, default_document_path)
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "status"))
        try muxly.api.documentStatusInDocument(allocator, transport_spec, default_document_path)
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "freeze"))
        try muxly.api.requestInDocument(allocator, transport_spec, default_document_path, "document.freeze", "{}")
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "serialize"))
        try muxly.api.requestInDocument(allocator, transport_spec, default_document_path, "document.serialize", "{}")
    else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "attach-file")) blk: {
        break :blk try muxly.api.leafAttachFile(allocator, transport_spec, args[cursor + 2], args[cursor + 3]);
    } else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "source-get")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .explicit_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.leafSourceGetTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "file") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "capture")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .explicit_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.fileCaptureTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "file") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "follow-tail")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .explicit_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.fileFollowTailTargetInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.node_target,
            std.mem.eql(u8, args[cursor + 3], "true"),
        );
    } else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "attach-tty")) blk: {
        break :blk try muxly.api.leafAttachTty(allocator, transport_spec, args[cursor + 2]);
    } else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try muxly.api.requestInDocument(allocator, transport_spec, default_document_path, "view.get", "{}")
    else if (std.mem.eql(u8, args[cursor], "projection") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "get")) blk: {
        const rows = try std.fmt.parseInt(u16, args[cursor + 2], 10);
        const cols = try std.fmt.parseInt(u16, args[cursor + 3], 10);
        var focused_target = if (cursor + 4 < args.len)
            try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 4], .document_or_node_concrete, tls_overrides)
        else
            null;
        defer if (focused_target) |*value| value.deinit(allocator);
        break :blk try muxly.api.projectionGetInDocument(
            allocator,
            if (focused_target) |value| value.transport_spec else transport_spec,
            if (focused_target) |value| value.document_path else default_document_path,
            .{
                .rows = rows,
                .cols = cols,
                .local_state = .{
                    .focused_node_id = if (focused_target) |value| value.requireNodeId() catch return printUsage() else null,
                },
            },
        );
    } else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "reset"))
        try muxly.api.requestInDocument(allocator, transport_spec, default_document_path, "view.reset", "{}")
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "clear-root"))
        try muxly.api.requestInDocument(allocator, transport_spec, default_document_path, "view.clearRoot", "{}")
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "set-root")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .document_or_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.viewSetRootTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "elide")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .explicit_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.viewElideTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "expand")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, default_document_path, args[cursor + 2], .explicit_node_lazy, tls_overrides);
        defer target.deinit(allocator);
        break :blk try muxly.api.viewExpandTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else return printUsage();
    defer allocator.free(response);

    try cli_format.writeResponse(std.fs.File.stdout().deprecatedWriter(), response);
}

fn printUsage() !void {
    try std.fs.File.stdout().writeAll(
        \\muxly usage:
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] ping
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] initialize
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] capabilities get
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] node get <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] node append <parent-id> <kind> <title>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] node update <node-id> <title|content> <value>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] node freeze <node-id> <text|surface>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] node remove <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] session list
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] window list
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] pane list
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] list
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] split <target-pane> <direction> [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] capture <pane-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] session create <session-name> [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] session create-under <parent-id> <session-name> [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] window create <target-session> [window-name] [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] pane split <target-pane> <direction> [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] pane capture <pane-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] pane scroll <pane-id> <start-line> <end-line>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] pane resize <pane-id> <direction> <amount>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] pane focus <pane-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] pane send-keys <pane-id> <keys> [--enter]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] pane close <pane-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] pane follow-tail <pane-id> <true|false>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] document get
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] document status
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] document freeze
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] document serialize
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] file capture <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] file follow-tail <node-id> <true|false>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] leaf attach-file <static-file|monitored-file> <path>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] leaf source-get <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] leaf attach-tty <session-name>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] view get
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] projection get <rows> <cols> [focused-node-id]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] view reset
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] view clear-root
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] view set-root <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] view elide <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] [--tls-ca-file PATH] [--tls-pin-sha256 HEX] [--tls-server-name NAME] view expand <node-id>
        \\  muxly admin generate-caddy --descriptor TRDS --mode <user|system> --output-dir PATH [--upstream-port PORT] [--upstream-host HOST] [--upstream-path PATH] [--caddy-bin PATH] [--muxlyd-bin PATH]
        \\  muxly admin generate-systemd --descriptor TRDS --mode <user|system> --output-dir PATH [--upstream-port PORT] [--upstream-host HOST] [--upstream-path PATH] [--service-user USER] [--service-group GROUP] [--caddy-bin PATH] [--muxlyd-bin PATH]
        \\
        \\transport notes:
        \\  SPEC may be unix paths, tcp://, ssh://, http://, h2://, https://, https1://, https2://, h3wt://, or connectable trds://...
        \\  bare/default sockets use ${XDG_RUNTIME_DIR}/muxly.sock or /run/user/<uid>/muxly.sock
        \\  document-or-node targets (trd://::/doc, trd://host::/doc#node, trd:#node) are accepted by:
        \\    node get, node append, session create-under, projection get [focused target], view set-root
        \\  explicit-node targets (#selector or numeric id) are required by:
        \\    node update/freeze/remove, leaf source-get, file capture/follow-tail, view elide/expand
        \\  TRDS is a secure descriptor like trds://wtp|host:8443/rpc::/docs/demo#left
        \\  plain trds://host... now prefers WebTransport, then falls back to secure HTTP
        \\  trds://wtp|... forces WebTransport; trds://htp|... uses the secure HTTP family
        \\  trds://ht2|... forces secure H2; trds://ht1|... forces secure H1.1
        \\  trds://ht3|... is reserved for future generic secure HTTP/3 support
        \\  --tls-ca-file is local-machine state and is intentionally not embedded in trds://
        \\
    );
}

fn runTransportRelay(allocator: std.mem.Allocator, transport_spec: []const u8) !void {
    var client = try muxly.client.Client.init(allocator, transport_spec);
    defer client.deinit();
    const runtime_limits = try muxly.runtime_config.loadClientLimits(allocator);
    var stdin_reader = muxly.transport.MessageReader.init(allocator);
    defer stdin_reader.deinit();

    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    while (true) {
        const request = try stdin_reader.readMessageLine(
            stdin_file,
            runtime_limits.max_message_bytes,
        ) orelse break;
        defer allocator.free(request);
        if (request.len == 0) continue;

        const response = try client.requestJson(request);
        defer allocator.free(response);
        try stdout_file.writeAll(response);
        try stdout_file.writeAll("\n");
    }
}
