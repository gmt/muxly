//! TOM Resource Descriptor parsing and selector resolution helpers.
//!
//! TRDs let clients point at both a daemon transport and a logical node inside
//! the live TOM with one string. Absolute descriptors use `trd://...`; relative
//! selectors use `trd:#...`.

const std = @import("std");
const api = @import("api.zig");

pub const Parsed = struct {
    kind: Kind,
    transport_code: ?[]u8 = null,
    endpoint: ?[]u8 = null,
    document_path: ?[]u8 = null,
    selector: ?[]u8 = null,
    shorthand_selector: ?[]u8 = null,

    pub const Kind = enum {
        absolute,
        relative,
    };

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        if (self.transport_code) |value| allocator.free(value);
        if (self.endpoint) |value| allocator.free(value);
        if (self.document_path) |value| allocator.free(value);
        if (self.selector) |value| allocator.free(value);
        if (self.shorthand_selector) |value| allocator.free(value);
    }

    pub fn resolve(self: Parsed, allocator: std.mem.Allocator, current_transport_spec: []const u8) !Resolved {
        const transport_spec = switch (self.kind) {
            .relative => try allocator.dupe(u8, current_transport_spec),
            .absolute => if (self.transport_code) |transport_code|
                try transportSpecFromReference(
                    allocator,
                    transport_code,
                    self.endpoint orelse return error.InvalidResourceDescriptor,
                )
            else
                try api.runtimeDefaultTransportSpecOwned(allocator),
        };
        errdefer allocator.free(transport_spec);

        const document_path = if (self.document_path) |value|
            try allocator.dupe(u8, value)
        else
            try allocator.dupe(u8, "/");
        errdefer allocator.free(document_path);

        const selector_source = self.selector orelse self.shorthand_selector;
        const selector = if (selector_source) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (selector) |value| allocator.free(value);

        return .{
            .transport_spec = transport_spec,
            .document_path = document_path,
            .selector = selector,
        };
    }
};

pub const Resolved = struct {
    transport_spec: []u8,
    document_path: []u8,
    selector: ?[]u8,

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.transport_spec);
        allocator.free(self.document_path);
        if (self.selector) |value| allocator.free(value);
    }
};

pub const NodeTarget = struct {
    transport_spec: []u8,
    document_path: []u8,
    node_id: u64,

    pub fn deinit(self: *NodeTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.transport_spec);
        allocator.free(self.document_path);
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Parsed {
    if (!std.mem.startsWith(u8, text, "trd:")) return error.InvalidResourceDescriptor;
    const remainder = text["trd:".len..];

    if (std.mem.startsWith(u8, remainder, "#")) {
        return .{
            .kind = .relative,
            .selector = try allocator.dupe(u8, remainder[1..]),
        };
    }

    if (!std.mem.startsWith(u8, remainder, "//")) return error.InvalidResourceDescriptor;
    const payload = remainder[2..];

    var selector: ?[]const u8 = null;
    var without_selector = payload;
    if (std.mem.indexOfScalar(u8, payload, '#')) |hash_index| {
        selector = payload[hash_index + 1 ..];
        without_selector = payload[0..hash_index];
    }

    var document_path: ?[]const u8 = null;
    var transport_part = without_selector;
    if (std.mem.indexOf(u8, without_selector, "//")) |doc_sep| {
        document_path = if (doc_sep + 1 < without_selector.len)
            without_selector[doc_sep + 1 ..]
        else
            "/";
        transport_part = without_selector[0..doc_sep];
    }

    if (transport_part.len == 0) {
        return .{
            .kind = .absolute,
            .document_path = if (document_path) |value| try allocator.dupe(u8, value) else null,
            .selector = if (selector) |value| try allocator.dupe(u8, value) else null,
        };
    }

    if (std.mem.indexOfScalar(u8, transport_part, '|')) |pipe_index| {
        if (pipe_index == 0 or pipe_index == transport_part.len - 1) return error.InvalidResourceDescriptor;
        return .{
            .kind = .absolute,
            .transport_code = try allocator.dupe(u8, transport_part[0..pipe_index]),
            .endpoint = try allocator.dupe(u8, transport_part[pipe_index + 1 ..]),
            .document_path = if (document_path) |value| try allocator.dupe(u8, value) else null,
            .selector = if (selector) |value| try allocator.dupe(u8, value) else null,
        };
    }

    if (document_path != null or selector != null) return error.InvalidResourceDescriptor;

    return .{
        .kind = .absolute,
        .shorthand_selector = try allocator.dupe(u8, transport_part),
    };
}

pub fn resolveNodeTarget(
    allocator: std.mem.Allocator,
    current_transport_spec: []const u8,
    descriptor_text: []const u8,
) !NodeTarget {
    var parsed = try parse(allocator, descriptor_text);
    defer parsed.deinit(allocator);

    var resolved = try parsed.resolve(allocator, current_transport_spec);
    errdefer resolved.deinit(allocator);

    const node_id = try resolveSelectorToNodeId(
        allocator,
        resolved.transport_spec,
        resolved.document_path,
        resolved.selector,
    );
    if (resolved.selector) |selector| {
        allocator.free(selector);
        resolved.selector = null;
    }

    return .{
        .transport_spec = resolved.transport_spec,
        .document_path = resolved.document_path,
        .node_id = node_id,
    };
}

pub fn isDescriptor(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "trd:");
}

fn transportSpecFromReference(
    allocator: std.mem.Allocator,
    transport_code: []const u8,
    endpoint: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, transport_code, "ux")) {
        return try allocator.dupe(u8, endpoint);
    }
    if (std.mem.eql(u8, transport_code, "tcp")) {
        return try std.fmt.allocPrint(allocator, "tcp://{s}", .{endpoint});
    }
    if (std.mem.eql(u8, transport_code, "ssh")) {
        return try std.fmt.allocPrint(allocator, "ssh://{s}", .{endpoint});
    }
    if (std.mem.eql(u8, transport_code, "http")) {
        return try std.fmt.allocPrint(allocator, "http://{s}", .{endpoint});
    }
    if (std.mem.eql(u8, transport_code, "wt")) {
        return try std.fmt.allocPrint(allocator, "h3wt://{s}", .{endpoint});
    }
    return error.UnsupportedResourceTransport;
}

fn resolveSelectorToNodeId(
    allocator: std.mem.Allocator,
    transport_spec: []const u8,
    document_path: []const u8,
    selector: ?[]const u8,
) !u64 {
    const selector_text = selector orelse return try fetchRootNodeId(allocator, transport_spec, document_path);
    if (selector_text.len == 0 or std.mem.eql(u8, selector_text, "/")) {
        return try fetchRootNodeId(allocator, transport_spec, document_path);
    }

    const response = try api.documentGetInDocument(allocator, transport_spec, document_path);
    defer allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResourceSelector;
    if (result != .object) return error.InvalidResourceSelector;
    const root_node_id_value = result.object.get("rootNodeId") orelse return error.InvalidResourceSelector;
    const nodes_value = result.object.get("nodes") orelse return error.InvalidResourceSelector;
    if (root_node_id_value != .integer or nodes_value != .array) return error.InvalidResourceSelector;

    var current_id: u64 = @intCast(root_node_id_value.integer);
    var segments = std.mem.splitScalar(u8, selector_text, '/');
    while (segments.next()) |segment_raw| {
        if (segment_raw.len == 0 or std.mem.eql(u8, segment_raw, ".")) continue;
        if (std.mem.eql(u8, segment_raw, "..")) {
            const current_node = findNodeObject(nodes_value.array.items, current_id) orelse return error.InvalidResourceSelector;
            const parent_value = current_node.get("parentId") orelse return error.ResourceSelectorEscapesRoot;
            if (parent_value != .integer) return error.InvalidResourceSelector;
            current_id = @intCast(parent_value.integer);
            continue;
        }

        if (parseDirectNodeReference(segment_raw)) |direct_id| {
            current_id = direct_id;
            continue;
        }

        current_id = try resolveChildBySegment(nodes_value.array.items, current_id, segment_raw);
    }

    return current_id;
}

fn fetchRootNodeId(
    allocator: std.mem.Allocator,
    transport_spec: []const u8,
    document_path: []const u8,
) !u64 {
    const response = try api.documentStatusInDocument(allocator, transport_spec, document_path);
    defer allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResourceSelector;
    if (result != .object) return error.InvalidResourceSelector;
    const root_node_id_value = result.object.get("rootNodeId") orelse return error.InvalidResourceSelector;
    if (root_node_id_value != .integer) return error.InvalidResourceSelector;
    return @intCast(root_node_id_value.integer);
}

fn parseDirectNodeReference(segment: []const u8) ?u64 {
    if (segment.len == 0) return null;

    if (segment[0] == '@') {
        return std.fmt.parseInt(u64, segment[1..], 10) catch null;
    }

    if (std.mem.startsWith(u8, segment, "node-")) {
        return std.fmt.parseInt(u64, segment["node-".len..], 10) catch null;
    }

    return std.fmt.parseInt(u64, segment, 10) catch null;
}

fn resolveChildBySegment(nodes: []const std.json.Value, parent_id: u64, segment: []const u8) !u64 {
    const parent = findNodeObject(nodes, parent_id) orelse return error.InvalidResourceSelector;
    const children_value = parent.get("children") orelse return error.InvalidResourceSelector;
    if (children_value != .array) return error.InvalidResourceSelector;

    var match_count: usize = 0;
    var matched_id: u64 = 0;

    for (children_value.array.items) |child_id_value| {
        if (child_id_value != .integer) continue;
        const child_id: u64 = @intCast(child_id_value.integer);
        const child = findNodeObject(nodes, child_id) orelse continue;
        if (nodeMatchesSegment(child, segment)) {
            match_count += 1;
            matched_id = child_id;
        }
    }

    return switch (match_count) {
        0 => error.UnknownResourceSelectorSegment,
        1 => matched_id,
        else => error.AmbiguousResourceSelector,
    };
}

fn nodeMatchesSegment(node: std.json.ObjectMap, segment: []const u8) bool {
    if (node.get("title")) |title_value| {
        if (title_value == .string and std.mem.eql(u8, title_value.string, segment)) return true;
    }
    if (node.get("backendId")) |backend_id_value| {
        if (backend_id_value == .string and std.mem.eql(u8, backend_id_value.string, segment)) return true;
    }
    if (node.get("id")) |id_value| {
        if (id_value == .integer) {
            var buffer: [32]u8 = undefined;
            const direct = std.fmt.bufPrint(&buffer, "{d}", .{id_value.integer}) catch return false;
            if (std.mem.eql(u8, direct, segment)) return true;
            const with_prefix = std.fmt.bufPrint(&buffer, "node-{d}", .{id_value.integer}) catch return false;
            if (std.mem.eql(u8, with_prefix, segment)) return true;
        }
    }
    return false;
}

fn findNodeObject(nodes: []const std.json.Value, node_id: u64) ?std.json.ObjectMap {
    for (nodes) |node_value| {
        if (node_value != .object) continue;
        const id_value = node_value.object.get("id") orelse continue;
        if (id_value != .integer) continue;
        if (@as(u64, @intCast(id_value.integer)) == node_id) return node_value.object;
    }
    return null;
}
