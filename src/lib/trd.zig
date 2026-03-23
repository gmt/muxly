//! TOM Resource Descriptor parsing and selector resolution helpers.
//!
//! TRDs let clients point at a daemon transport, a logical document, and an
//! optional node selector with one string. Absolute descriptors use
//! `trd://...`; relative selectors use `trd:#...`.

const std = @import("std");
const api = @import("api.zig");
const protocol = @import("../core/protocol.zig");

pub const default_tcp_port: u16 = 4488;
const default_host = "localhost";
pub const absolute_document_separator = "::/";
const local_default_endpoint = ".";

pub const TransportCode = enum {
    none,
    local_default,
    auto,
    unx,
    tcp,
    ssh,
    wtp,
    htp,
    ht3,
    ht2,
    ht1,

    pub fn parseExplicit(text: []const u8) !TransportCode {
        if (std.mem.eql(u8, text, "unx")) return .unx;
        if (std.mem.eql(u8, text, "tcp")) return .tcp;
        if (std.mem.eql(u8, text, "ssh")) return .ssh;
        if (std.mem.eql(u8, text, "wtp")) return .wtp;
        if (std.mem.eql(u8, text, "htp")) return .htp;
        if (std.mem.eql(u8, text, "ht3")) return .ht3;
        if (std.mem.eql(u8, text, "ht2")) return .ht2;
        if (std.mem.eql(u8, text, "ht1")) return .ht1;
        return error.UnsupportedResourceTransport;
    }
};

pub const Parsed = struct {
    kind: Kind,
    transport_code: ?[]u8 = null,
    endpoint: ?[]u8 = null,
    document_path: ?[]u8 = null,
    selector: ?[]u8 = null,

    pub const Properties = struct {
        is_relative: bool,
        is_absolute: bool,
        has_explicit_server: bool,
        has_explicit_document: bool,
        has_selector: bool,
        is_document_only: bool,
        is_node_targeted: bool,
        inherits_transport: bool,
        inherits_document: bool,
    };

    pub const Kind = enum {
        absolute,
        relative,
    };

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        if (self.transport_code) |value| allocator.free(value);
        if (self.endpoint) |value| allocator.free(value);
        if (self.document_path) |value| allocator.free(value);
        if (self.selector) |value| allocator.free(value);
    }

    pub fn properties(self: Parsed) Properties {
        const is_relative = self.kind == .relative;
        const has_explicit_server = self.transport_code != null or self.endpoint != null;
        const has_explicit_document = self.document_path != null;
        const has_selector = self.selector != null;
        return .{
            .is_relative = is_relative,
            .is_absolute = !is_relative,
            .has_explicit_server = has_explicit_server,
            .has_explicit_document = has_explicit_document,
            .has_selector = has_selector,
            .is_document_only = !has_selector,
            .is_node_targeted = has_selector,
            .inherits_transport = is_relative,
            .inherits_document = is_relative,
        };
    }

    pub fn resolve(
        self: Parsed,
        allocator: std.mem.Allocator,
        current_transport_spec: []const u8,
        current_document_path: []const u8,
    ) !Resolved {
        const props = self.properties();
        const transport_spec = switch (self.kind) {
            .relative => try allocator.dupe(u8, current_transport_spec),
            .absolute => if (props.has_explicit_server)
                try transportSpecFromReference(
                    allocator,
                    self.transport_code,
                    self.endpoint orelse "",
                )
            else
                try api.runtimeDefaultTransportSpecOwned(allocator),
        };
        errdefer allocator.free(transport_spec);

        const document_path = switch (self.kind) {
            .relative => try allocator.dupe(u8, current_document_path),
            .absolute => if (props.has_explicit_document)
                if (self.document_path) |value|
                    try allocator.dupe(u8, value)
                else
                    unreachable
            else
                try allocator.dupe(u8, protocol.default_document_path),
        };
        errdefer allocator.free(document_path);

        const selector = if (props.has_selector)
            if (self.selector) |value|
                try allocator.dupe(u8, value)
            else
                unreachable
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

    if (without_selector.len == 0) {
        return .{
            .kind = .absolute,
            .endpoint = try allocator.dupe(u8, local_default_endpoint),
            .selector = if (selector) |value| try allocator.dupe(u8, value) else null,
        };
    }

    var endpoint_and_document = without_selector;
    var document_path: ?[]const u8 = null;
    if (std.mem.indexOf(u8, without_selector, absolute_document_separator)) |doc_sep| {
        endpoint_and_document = without_selector[0..doc_sep];
        document_path = without_selector[doc_sep + absolute_document_separator.len - 1 ..];
    }

    var transport_code: ?[]const u8 = null;
    var endpoint: ?[]const u8 = if (endpoint_and_document.len != 0) endpoint_and_document else null;
    if (std.mem.indexOfScalar(u8, endpoint_and_document, '|')) |pipe_index| {
        const explicit_transport_code = endpoint_and_document[0..pipe_index];
        if (explicit_transport_code.len == 0) return error.UnsupportedResourceTransport;
        _ = try TransportCode.parseExplicit(explicit_transport_code);
        transport_code = explicit_transport_code;
        endpoint = endpoint_and_document[pipe_index + 1 ..];
    }

    const owned_transport_code = if (transport_code) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_transport_code) |value| allocator.free(value);

    const owned_endpoint = if (endpoint) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_endpoint) |value| allocator.free(value);

    const owned_document_path = if (document_path) |value|
        try normalizeDocumentPathOwned(allocator, value)
    else
        null;
    errdefer if (owned_document_path) |value| allocator.free(value);

    const owned_selector = if (selector) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_selector) |value| allocator.free(value);

    return .{
        .kind = .absolute,
        .transport_code = owned_transport_code,
        .endpoint = owned_endpoint,
        .document_path = owned_document_path,
        .selector = owned_selector,
    };
}

pub fn resolveNodeTarget(
    allocator: std.mem.Allocator,
    current_transport_spec: []const u8,
    current_document_path: []const u8,
    descriptor_text: []const u8,
) !NodeTarget {
    var parsed = try parse(allocator, descriptor_text);
    defer parsed.deinit(allocator);

    var resolved = try parsed.resolve(allocator, current_transport_spec, current_document_path);
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

pub fn resolveNodeTargetFromResolved(
    allocator: std.mem.Allocator,
    transport_spec: []const u8,
    document_path: []const u8,
    selector: ?[]const u8,
) !NodeTarget {
    return .{
        .transport_spec = try allocator.dupe(u8, transport_spec),
        .document_path = try allocator.dupe(u8, document_path),
        .node_id = try resolveSelectorToNodeId(
            allocator,
            transport_spec,
            document_path,
            selector,
        ),
    };
}

pub fn isDescriptor(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "trd:");
}

pub fn classifyTransportCode(transport_code: ?[]const u8, endpoint: ?[]const u8) !TransportCode {
    if (transport_code) |value| return try TransportCode.parseExplicit(value);
    if (endpoint) |value| {
        if (std.mem.eql(u8, value, local_default_endpoint)) return .local_default;
        return .auto;
    }
    return .none;
}

pub fn transportSpecFromReference(
    allocator: std.mem.Allocator,
    transport_code: ?[]const u8,
    endpoint: []const u8,
) ![]u8 {
    switch (try classifyTransportCode(transport_code, if (endpoint.len == 0) null else endpoint)) {
        .none, .local_default => return try api.runtimeDefaultTransportSpecOwned(allocator),
        .auto, .htp, .ht3 => return error.UnsupportedResourceTransport,
        .unx => {
            if (endpoint.len == 0) return try api.runtimeDefaultTransportSpecOwned(allocator);
            return try allocator.dupe(u8, endpoint);
        },
        .tcp => {
            const authority = try tcpEndpointWithDefaultPortOwned(allocator, endpoint);
            defer allocator.free(authority);
            return try std.fmt.allocPrint(allocator, "tcp://{s}", .{authority});
        },
        .ssh => {
            return try std.fmt.allocPrint(allocator, "ssh://{s}", .{if (endpoint.len == 0) default_host else endpoint});
        },
        .ht1 => {
            return try std.fmt.allocPrint(allocator, "http://{s}", .{if (endpoint.len == 0) default_host else endpoint});
        },
        .ht2 => {
            return try std.fmt.allocPrint(allocator, "h2://{s}", .{if (endpoint.len == 0) default_host else endpoint});
        },
        .wtp => {
            return try std.fmt.allocPrint(allocator, "h3wt://{s}", .{if (endpoint.len == 0) default_host else endpoint});
        },
    }
}

fn normalizeDocumentPathOwned(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return try allocator.dupe(u8, protocol.default_document_path);

    const document_path = if (value[0] == '/')
        try allocator.dupe(u8, value)
    else
        try std.fmt.allocPrint(allocator, "/{s}", .{value});
    errdefer allocator.free(document_path);

    if (!protocol.isCanonicalDocumentPath(document_path)) {
        return error.InvalidDocumentPath;
    }

    return document_path;
}

fn tcpEndpointWithDefaultPortOwned(allocator: std.mem.Allocator, endpoint: []const u8) ![]u8 {
    const authority = if (endpoint.len == 0) default_host else endpoint;
    if (tcpEndpointHasExplicitPort(authority)) return try allocator.dupe(u8, authority);
    if (authority.len != 0 and authority[0] == '[') {
        return try std.fmt.allocPrint(allocator, "{s}:{d}", .{ authority, default_tcp_port });
    }
    if (std.mem.indexOfScalar(u8, authority, ':') != null) {
        return try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ authority, default_tcp_port });
    }
    return try std.fmt.allocPrint(allocator, "{s}:{d}", .{ authority, default_tcp_port });
}

fn tcpEndpointHasExplicitPort(authority: []const u8) bool {
    if (authority.len == 0) return false;

    if (authority[0] == '[') {
        const close_index = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        if (close_index + 1 >= authority.len or authority[close_index + 1] != ':') return false;
        _ = std.fmt.parseInt(u16, authority[close_index + 2 ..], 10) catch return false;
        return true;
    }

    const colon_index = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return false;
    if (std.mem.indexOfScalar(u8, authority[0..colon_index], ':') != null) return false;
    _ = std.fmt.parseInt(u16, authority[colon_index + 1 ..], 10) catch return false;
    return true;
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
    if (node.get("name")) |name_value| {
        if (name_value == .string and std.mem.eql(u8, name_value.string, segment)) return true;
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
