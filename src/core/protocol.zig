//! JSON-RPC helpers shared by the daemon protocol surface.

const std = @import("std");
const errors = @import("errors.zig");

pub const JsonRpcVersion = "2.0";
pub const default_document_path = "/";

pub const RequestTarget = struct {
    documentPath: ?[]const u8 = null,
    nodeId: ?u64 = null,
    selector: ?[]const u8 = null,
};

pub const ConversationKind = enum {
    rpc,
    tty_control,
    tty_data,
    capture_data,
    projection_event,
};

pub const ConversationError = struct {
    code: i64,
    message: []const u8,
};

pub const ConversationEnvelope = struct {
    conversationId: []const u8,
    requestId: ?u64 = null,
    target: ?RequestTarget = null,
    kind: ConversationKind,
    payload: std.json.Value,
    fin: bool = true,
    conversationError: ?ConversationError = null,
};

pub const RequestEnvelope = struct {
    jsonrpc: []const u8,
    id: ?std.json.Value = null,
    target: ?RequestTarget = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub fn parseRequest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(RequestEnvelope) {
    return try std.json.parseFromSlice(RequestEnvelope, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn parseConversationEnvelope(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(ConversationEnvelope) {
    return try std.json.parseFromSlice(ConversationEnvelope, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn writeConversationEnvelope(
    writer: anytype,
    conversation_id: []const u8,
    request_id: ?u64,
    target: ?RequestTarget,
    kind: ConversationKind,
    payload_json: []const u8,
    fin: bool,
    err: ?ConversationError,
) !void {
    try writer.writeAll("{\"conversationId\":");
    try writer.print("{f}", .{std.json.fmt(conversation_id, .{})});
    try writer.writeAll(",\"requestId\":");
    if (request_id) |value| {
        try writer.print("{d}", .{value});
    } else {
        try writer.writeAll("null");
    }
    if (target) |resolved_target| {
        try writer.writeAll(",\"target\":");
        try writeRequestTarget(writer, resolved_target);
    }
    try writer.writeAll(",\"kind\":\"");
    try writer.writeAll(@tagName(kind));
    try writer.writeAll("\",\"payload\":");
    try writer.writeAll(payload_json);
    try writer.print(",\"fin\":{}", .{fin});
    if (err) |value| {
        try writer.writeAll(",\"conversationError\":{");
        try writer.print("\"code\":{d},\"message\":", .{value.code});
        try writer.print("{f}", .{std.json.fmt(value.message, .{})});
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

pub fn allocConversationEnvelope(
    allocator: std.mem.Allocator,
    conversation_id: []const u8,
    request_id: ?u64,
    target: ?RequestTarget,
    kind: ConversationKind,
    payload_json: []const u8,
    fin: bool,
    err: ?ConversationError,
) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();
    try writeConversationEnvelope(
        buffer.writer(),
        conversation_id,
        request_id,
        target,
        kind,
        payload_json,
        fin,
        err,
    );
    return try buffer.toOwnedSlice();
}

pub fn writeSuccess(
    writer: anytype,
    id: ?std.json.Value,
    result_json: []const u8,
) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":");
    try writer.writeAll(result_json);
    try writer.writeAll("}");
}

pub fn writeError(
    writer: anytype,
    id: ?std.json.Value,
    code: errors.RpcErrorCode,
    message: []const u8,
) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(writer, id);
    try writer.writeAll(",\"error\":{");
    try writer.print("\"code\":{d},\"message\":", .{@intFromEnum(code)});
    try writer.print("{f}", .{std.json.fmt(message, .{})});
    try writer.writeAll("}}");
}

pub fn requestDocumentPath(request: RequestEnvelope) ![]const u8 {
    const document_path = if (request.target) |target|
        target.documentPath orelse default_document_path
    else
        default_document_path;

    if (!isCanonicalDocumentPath(document_path)) {
        return error.InvalidDocumentPath;
    }

    return document_path;
}

pub fn requestTargetNodeId(request: RequestEnvelope, params_field_name: []const u8) !i64 {
    if (request.target) |target| {
        if (target.nodeId) |value| {
            if (value > std.math.maxInt(i64)) return error.InvalidNodeTarget;
            return @intCast(value);
        }
        if (target.selector != null) return error.UnsupportedNodeSelector;
    }

    return getInteger(request.params, params_field_name) orelse error.MissingNodeTarget;
}

pub fn writeClientRequest(
    writer: anytype,
    request_id: u64,
    document_path: []const u8,
    method: []const u8,
    params_json: []const u8,
) !void {
    return try writeClientRequestTarget(writer, request_id, .{
        .documentPath = document_path,
    }, method, params_json);
}

pub fn writeClientRequestTarget(
    writer: anytype,
    request_id: u64,
    target: RequestTarget,
    method: []const u8,
    params_json: []const u8,
) !void {
    const document_path = target.documentPath orelse default_document_path;
    if (!isCanonicalDocumentPath(document_path)) {
        return error.InvalidDocumentPath;
    }

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writer.print("{d}", .{request_id});
    try writer.writeAll(",\"target\":");
    try writeRequestTarget(writer, .{
        .documentPath = document_path,
        .nodeId = target.nodeId,
        .selector = target.selector,
    });
    try writer.writeAll(",\"method\":");
    try writer.print("{f}", .{std.json.fmt(method, .{})});
    try writer.writeAll(",\"params\":");
    try writer.writeAll(params_json);
    try writer.writeAll("}");
}

pub fn isCanonicalDocumentPath(document_path: []const u8) bool {
    if (document_path.len == 0 or document_path[0] != '/') return false;
    if (std.mem.eql(u8, document_path, default_document_path)) return true;
    if (document_path[document_path.len - 1] == '/') return false;

    var segments = std.mem.splitScalar(u8, document_path[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }

    return true;
}

pub fn validateRootDocumentOnlyTarget(document_path: []const u8) !void {
    if (!isCanonicalDocumentPath(document_path)) return error.InvalidDocumentPath;
    if (!std.mem.eql(u8, document_path, default_document_path)) {
        return error.RootDocumentOnlyTarget;
    }
}

/// Returns a string borrowed from `params` and therefore from the owning parsed
/// JSON tree; callers must not keep it past that parsed value's lifetime.
pub fn getString(params: ?std.json.Value, field_name: []const u8) ?[]const u8 {
    const value = params orelse return null;
    if (value != .object) return null;
    const field = value.object.get(field_name) orelse return null;
    if (field != .string) return null;
    return field.string;
}

pub fn getInteger(params: ?std.json.Value, field_name: []const u8) ?i64 {
    const value = params orelse return null;
    if (value != .object) return null;
    const field = value.object.get(field_name) orelse return null;
    if (field != .integer) return null;
    return field.integer;
}

pub fn getBool(params: ?std.json.Value, field_name: []const u8) ?bool {
    const value = params orelse return null;
    if (value != .object) return null;
    const field = value.object.get(field_name) orelse return null;
    if (field != .bool) return null;
    return field.bool;
}

fn writeId(writer: anytype, id: ?std.json.Value) !void {
    if (id) |value| {
        try writer.print("{f}", .{std.json.fmt(value, .{})});
    } else {
        try writer.writeAll("null");
    }
}

fn writeRequestTarget(writer: anytype, target: RequestTarget) !void {
    const document_path = target.documentPath orelse default_document_path;
    try writer.writeAll("{\"documentPath\":");
    try writer.print("{f}", .{std.json.fmt(document_path, .{})});
    if (target.nodeId) |node_id| {
        try writer.print(",\"nodeId\":{d}", .{node_id});
    }
    if (target.selector) |selector| {
        try writer.writeAll(",\"selector\":");
        try writer.print("{f}", .{std.json.fmt(selector, .{})});
    }
    try writer.writeAll("}");
}
