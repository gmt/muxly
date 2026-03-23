const std = @import("std");
const muxly = @import("muxly");

pub const ResolutionMode = enum {
    document_or_node_lazy,
    explicit_node_lazy,
    document_or_node_concrete,
};

pub const Arg = struct {
    transport_spec: []u8,
    document_path: []u8,
    node_target: muxly.api.NodeRequestTarget,

    pub fn deinit(self: *Arg, allocator: std.mem.Allocator) void {
        allocator.free(self.transport_spec);
        allocator.free(self.document_path);
        if (self.node_target.selector) |selector| allocator.free(selector);
    }

    pub fn requireNodeId(self: Arg) !u64 {
        return self.node_target.node_id orelse error.NodeIdRequired;
    }
};

pub const SecureTransportOverrides = struct {
    tls_ca_file: ?[]const u8 = null,
    tls_pin_sha256: ?[]const u8 = null,
    tls_server_name: ?[]const u8 = null,
};

pub fn resolve(
    allocator: std.mem.Allocator,
    current_transport_spec: []const u8,
    current_document_path: []const u8,
    arg: []const u8,
    mode: ResolutionMode,
    overrides: SecureTransportOverrides,
) !Arg {
    if (!muxly.trd.isDescriptor(arg) and !muxly.trds.isDescriptor(arg)) {
        return .{
            .transport_spec = try applySecureTransportOverrides(allocator, current_transport_spec, overrides),
            .document_path = try allocator.dupe(u8, current_document_path),
            .node_target = .{ .node_id = try std.fmt.parseInt(u64, arg, 10) },
        };
    }

    if (muxly.trds.isDescriptor(arg)) {
        return switch (mode) {
            .document_or_node_lazy => try resolveLazyTrds(allocator, arg, true, overrides),
            .explicit_node_lazy => try resolveLazyTrds(allocator, arg, false, overrides),
            .document_or_node_concrete => try resolveConcreteTrds(allocator, arg, overrides),
        };
    }

    return switch (mode) {
        .document_or_node_lazy => try resolveLazy(
            allocator,
            current_transport_spec,
            current_document_path,
            arg,
            true,
            overrides,
        ),
        .explicit_node_lazy => try resolveLazy(
            allocator,
            current_transport_spec,
            current_document_path,
            arg,
            false,
            overrides,
        ),
        .document_or_node_concrete => try resolveConcrete(
            allocator,
            current_transport_spec,
            current_document_path,
            arg,
            overrides,
        ),
    };
}

fn resolveLazyTrds(
    allocator: std.mem.Allocator,
    descriptor_text: []const u8,
    allow_document_only: bool,
    overrides: SecureTransportOverrides,
) !Arg {
    var resolved = try muxly.trds.resolve(allocator, descriptor_text);
    defer resolved.deinit(allocator);

    if (resolved.selector == null and !allow_document_only) {
        return error.ExplicitNodeTargetRequired;
    }

    const node_target = if (resolved.selector) |selector|
        muxly.api.NodeRequestTarget{ .selector = try allocator.dupe(u8, selector) }
    else
        muxly.api.NodeRequestTarget{ .selector = try allocator.dupe(u8, "/") };
    errdefer if (node_target.selector) |selector| allocator.free(selector);

    return .{
        .transport_spec = try applySecureTransportOverrides(allocator, resolved.transport_spec, overrides),
        .document_path = try allocator.dupe(u8, resolved.document_path),
        .node_target = node_target,
    };
}

fn resolveConcreteTrds(
    allocator: std.mem.Allocator,
    descriptor_text: []const u8,
    overrides: SecureTransportOverrides,
) !Arg {
    var resolved = try muxly.trds.resolve(allocator, descriptor_text);
    defer resolved.deinit(allocator);

    var target = try muxly.trd.resolveNodeTargetFromResolved(
        allocator,
        resolved.transport_spec,
        resolved.document_path,
        resolved.selector,
    );
    defer target.deinit(allocator);

    return .{
        .transport_spec = try applySecureTransportOverrides(allocator, target.transport_spec, overrides),
        .document_path = try allocator.dupe(u8, target.document_path),
        .node_target = .{ .node_id = target.node_id },
    };
}

fn resolveLazy(
    allocator: std.mem.Allocator,
    current_transport_spec: []const u8,
    current_document_path: []const u8,
    descriptor_text: []const u8,
    allow_document_only: bool,
    overrides: SecureTransportOverrides,
) !Arg {
    var parsed = try muxly.trd.parse(allocator, descriptor_text);
    defer parsed.deinit(allocator);
    const props = parsed.properties();

    if (props.is_document_only and !allow_document_only) {
        return error.ExplicitNodeTargetRequired;
    }

    var resolved = try parsed.resolve(allocator, current_transport_spec, current_document_path);
    defer resolved.deinit(allocator);

    const node_target = if (resolved.selector) |selector|
        muxly.api.NodeRequestTarget{ .selector = try allocator.dupe(u8, selector) }
    else
        muxly.api.NodeRequestTarget{ .selector = try allocator.dupe(u8, "/") };
    errdefer if (node_target.selector) |selector| allocator.free(selector);

    return .{
        .transport_spec = try applySecureTransportOverrides(allocator, resolved.transport_spec, overrides),
        .document_path = try allocator.dupe(u8, resolved.document_path),
        .node_target = node_target,
    };
}

fn resolveConcrete(
    allocator: std.mem.Allocator,
    current_transport_spec: []const u8,
    current_document_path: []const u8,
    descriptor_text: []const u8,
    overrides: SecureTransportOverrides,
) !Arg {
    var target = try muxly.trd.resolveNodeTarget(
        allocator,
        current_transport_spec,
        current_document_path,
        descriptor_text,
    );
    defer target.deinit(allocator);

    return .{
        .transport_spec = try applySecureTransportOverrides(allocator, target.transport_spec, overrides),
        .document_path = try allocator.dupe(u8, target.document_path),
        .node_target = .{ .node_id = target.node_id },
    };
}

fn applySecureTransportOverrides(
    allocator: std.mem.Allocator,
    transport_spec: []const u8,
    overrides: SecureTransportOverrides,
) ![]u8 {
    if (overrides.tls_ca_file == null and overrides.tls_pin_sha256 == null and overrides.tls_server_name == null) {
        return try allocator.dupe(u8, transport_spec);
    }

    var address = try muxly.transport.Address.parse(allocator, transport_spec);
    defer address.deinit(allocator);

    switch (address.target) {
        .https => |*https| try applyOverridesToSecureHttpAddress(allocator, https, overrides),
        .https1 => |*https| try applyOverridesToSecureHttpAddress(allocator, https, overrides),
        .https2 => |*https| try applyOverridesToSecureHttpAddress(allocator, https, overrides),
        else => return try allocator.dupe(u8, transport_spec),
    }

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    try address.write(buffer.writer());
    return try buffer.toOwnedSlice();
}

fn applyOverridesToSecureHttpAddress(
    allocator: std.mem.Allocator,
    https: *muxly.transport.Address.SecureHttpAddress,
    overrides: SecureTransportOverrides,
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
