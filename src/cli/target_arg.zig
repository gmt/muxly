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

pub fn resolve(
    allocator: std.mem.Allocator,
    current_transport_spec: []const u8,
    current_document_path: []const u8,
    arg: []const u8,
    mode: ResolutionMode,
) !Arg {
    if (!muxly.trd.isDescriptor(arg)) {
        return .{
            .transport_spec = try allocator.dupe(u8, current_transport_spec),
            .document_path = try allocator.dupe(u8, current_document_path),
            .node_target = .{ .node_id = try std.fmt.parseInt(u64, arg, 10) },
        };
    }

    return switch (mode) {
        .document_or_node_lazy => try resolveLazy(
            allocator,
            current_transport_spec,
            current_document_path,
            arg,
            true,
        ),
        .explicit_node_lazy => try resolveLazy(
            allocator,
            current_transport_spec,
            current_document_path,
            arg,
            false,
        ),
        .document_or_node_concrete => try resolveConcrete(
            allocator,
            current_transport_spec,
            current_document_path,
            arg,
        ),
    };
}

fn resolveLazy(
    allocator: std.mem.Allocator,
    current_transport_spec: []const u8,
    current_document_path: []const u8,
    descriptor_text: []const u8,
    allow_document_only: bool,
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
        .transport_spec = try allocator.dupe(u8, resolved.transport_spec),
        .document_path = try allocator.dupe(u8, resolved.document_path),
        .node_target = node_target,
    };
}

fn resolveConcrete(
    allocator: std.mem.Allocator,
    current_transport_spec: []const u8,
    current_document_path: []const u8,
    descriptor_text: []const u8,
) !Arg {
    var target = try muxly.trd.resolveNodeTarget(
        allocator,
        current_transport_spec,
        current_document_path,
        descriptor_text,
    );
    defer target.deinit(allocator);

    return .{
        .transport_spec = try allocator.dupe(u8, target.transport_spec),
        .document_path = try allocator.dupe(u8, target.document_path),
        .node_target = .{ .node_id = target.node_id },
    };
}
