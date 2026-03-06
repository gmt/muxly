const std = @import("std");
const muxly = @import("muxly");
const protocol = muxly.protocol;
const errors = muxly.errors;
const store_mod = @import("state/store.zig");

pub fn handleRequest(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    request_bytes: []const u8,
) ![]u8 {
    const parsed = protocol.parseRequest(allocator, request_bytes) catch {
        return try buildError(allocator, null, .parse_error, "invalid JSON-RPC payload");
    };
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.jsonrpc, protocol.JsonRpcVersion)) {
        return try buildError(allocator, parsed.value.id, .invalid_request, "jsonrpc must be 2.0");
    }

    if (std.mem.eql(u8, parsed.value.method, "ping")) {
        return try buildResult(allocator, parsed.value.id, "{\"pong\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "initialize") or std.mem.eql(u8, parsed.value.method, "capabilities.get")) {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        try store.capabilities.writeJson(result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "document.get")) {
        try store.refreshSources();
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        try store.document.writeJson(result.writer());
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "document.serialize")) {
        try store.refreshSources();
        var xml = std.ArrayList(u8).init(allocator);
        defer xml.deinit();
        try store.document.writeXml(xml.writer());

        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        try result.writer().writeAll("{\"format\":\"xml\",\"document\":");
        try std.json.stringify(xml.items, .{}, result.writer());
        try result.writer().writeAll("}");
        return try buildResult(allocator, parsed.value.id, result.items);
    }

    if (std.mem.eql(u8, parsed.value.method, "document.freeze")) {
        store.document.freeze();
        return try buildResult(allocator, parsed.value.id, "{\"lifecycle\":\"frozen\"}");
    }

    if (std.mem.eql(u8, parsed.value.method, "view.setRoot")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        store.document.setViewRoot(@intCast(node_id)) catch
            return try buildError(allocator, parsed.value.id, .invalid_params, "unknown nodeId");
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "view.elide")) {
        const node_id = protocol.getInteger(parsed.value.params, "nodeId") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "nodeId is required");
        store.document.toggleElided(@intCast(node_id)) catch
            return try buildError(allocator, parsed.value.id, .invalid_params, "unknown nodeId");
        return try buildResult(allocator, parsed.value.id, "{\"ok\":true}");
    }

    if (std.mem.eql(u8, parsed.value.method, "leaf.source.attach")) {
        const kind = protocol.getString(parsed.value.params, "kind") orelse
            return try buildError(allocator, parsed.value.id, .invalid_params, "kind is required");

        if (std.mem.eql(u8, kind, "static-file") or std.mem.eql(u8, kind, "monitored-file")) {
            const path = protocol.getString(parsed.value.params, "path") orelse
                return try buildError(allocator, parsed.value.id, .invalid_params, "path is required");
            const node_id = store.attachFile(path, if (std.mem.eql(u8, kind, "static-file")) .static else .monitored) catch
                return try buildError(allocator, parsed.value.id, .source_error, "unable to attach file source");
            return try buildNodeAttached(allocator, parsed.value.id, node_id, kind);
        }

        if (std.mem.eql(u8, kind, "tty")) {
            const session_name = protocol.getString(parsed.value.params, "sessionName") orelse
                return try buildError(allocator, parsed.value.id, .invalid_params, "sessionName is required");
            const node_id = store.attachTty(session_name) catch
                return try buildError(allocator, parsed.value.id, .source_error, "unable to attach tty source");
            return try buildNodeAttached(allocator, parsed.value.id, node_id, kind);
        }

        return try buildError(allocator, parsed.value.id, .invalid_params, "unsupported leaf source kind");
    }

    return try buildError(allocator, parsed.value.id, .method_not_found, "unknown method");
}

fn buildNodeAttached(
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    node_id: u64,
    kind: []const u8,
) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try buffer.writer().writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    if (id) |value| {
        try std.json.stringify(value, .{}, buffer.writer());
    } else {
        try buffer.writer().writeAll("null");
    }
    try buffer.writer().print(",\"result\":{{\"nodeId\":{d},\"kind\":\"{s}\"}}}}", .{ node_id, kind });
    return try buffer.toOwnedSlice();
}

fn buildResult(
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    result_json: []const u8,
) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try protocol.writeSuccess(buffer.writer(), id, result_json);
    return try buffer.toOwnedSlice();
}

fn buildError(
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    code: errors.RpcErrorCode,
    message: []const u8,
) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try protocol.writeError(buffer.writer(), id, code, message);
    return try buffer.toOwnedSlice();
}
