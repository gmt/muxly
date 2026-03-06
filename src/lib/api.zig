const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");

pub fn ping(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "ping", "{}");
}

pub fn documentGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "document.get", "{}");
}

pub fn graphGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "graph.get", "{}");
}

pub fn documentStatus(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "document.status", "{}");
}

pub fn viewGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "view.get", "{}");
}

pub fn viewSetRoot(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "view.setRoot", params_json);
}

pub fn viewElide(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "view.elide", params_json);
}

pub fn paneCapture(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8) ![]u8 {
    const pane_id_json = try std.json.stringifyAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.capture", params_json);
}

pub fn paneSplit(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    target: []const u8,
    direction: []const u8,
    command: ?[]const u8,
) ![]u8 {
    const target_json = try std.json.stringifyAlloc(allocator, target, .{});
    defer allocator.free(target_json);
    const direction_json = try std.json.stringifyAlloc(allocator, direction, .{});
    defer allocator.free(direction_json);

    const params_json = if (command) |value| blk: {
        const command_json = try std.json.stringifyAlloc(allocator, value, .{});
        defer allocator.free(command_json);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"target\":{s},\"direction\":{s},\"command\":{s}}}",
            .{ target_json, direction_json, command_json },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "{{\"target\":{s},\"direction\":{s}}}",
        .{ target_json, direction_json },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.split", params_json);
}

pub fn sessionCreate(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    session_name: []const u8,
    command: ?[]const u8,
) ![]u8 {
    const session_name_json = try std.json.stringifyAlloc(allocator, session_name, .{});
    defer allocator.free(session_name_json);

    const params_json = if (command) |value| blk: {
        const command_json = try std.json.stringifyAlloc(allocator, value, .{});
        defer allocator.free(command_json);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"sessionName\":{s},\"command\":{s}}}",
            .{ session_name_json, command_json },
        );
    } else try std.fmt.allocPrint(
        allocator,
        "{{\"sessionName\":{s}}}",
        .{session_name_json},
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "session.create", params_json);
}

pub fn leafSourceGet(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "leaf.source.get", params_json);
}

pub fn capabilitiesGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "capabilities.get", "{}");
}

pub fn request(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    var client = try client_mod.Client.init(allocator, socket_path);
    defer client.deinit();
    return try client.request(method, params_json);
}

pub fn socketPathFromEnv(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "MUXLY_SOCKET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, defaultSocketPath()),
        else => return err,
    };
}

pub fn defaultSocketPath() []const u8 {
    return if (builtin.os.tag == .windows)
        "\\\\.\\pipe\\muxly"
    else
        "/tmp/muxly.sock";
}
