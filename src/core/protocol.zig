//! JSON-RPC helpers shared by the daemon protocol surface.

const std = @import("std");
const errors = @import("errors.zig");

pub const JsonRpcVersion = "2.0";

pub const RequestEnvelope = struct {
    jsonrpc: []const u8,
    id: ?std.json.Value = null,
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
