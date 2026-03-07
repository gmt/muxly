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

pub fn paneScroll(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: []const u8,
    start_line: i64,
    end_line: i64,
) ![]u8 {
    const pane_id_json = try std.json.stringifyAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"startLine\":{d},\"endLine\":{d}}}",
        .{ pane_id_json, start_line, end_line },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.scroll", params_json);
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

pub fn paneResize(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: []const u8,
    direction: []const u8,
    amount: i64,
) ![]u8 {
    const pane_id_json = try std.json.stringifyAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const direction_json = try std.json.stringifyAlloc(allocator, direction, .{});
    defer allocator.free(direction_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"direction\":{s},\"amount\":{d}}}",
        .{ pane_id_json, direction_json, amount },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.resize", params_json);
}

pub fn paneFocus(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8) ![]u8 {
    const pane_id_json = try std.json.stringifyAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.focus", params_json);
}

pub fn paneSendKeys(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    pane_id: []const u8,
    keys: []const u8,
    press_enter: bool,
) ![]u8 {
    const pane_id_json = try std.json.stringifyAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const keys_json = try std.json.stringifyAlloc(allocator, keys, .{});
    defer allocator.free(keys_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"keys\":{s},\"enter\":{s}}}",
        .{ pane_id_json, keys_json, if (press_enter) "true" else "false" },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.sendKeys", params_json);
}

pub fn paneClose(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8) ![]u8 {
    const pane_id_json = try std.json.stringifyAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.close", params_json);
}

pub fn paneFollowTail(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8, enabled: bool) ![]u8 {
    const pane_id_json = try std.json.stringifyAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"enabled\":{s}}}",
        .{ pane_id_json, if (enabled) "true" else "false" },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.followTail", params_json);
}

pub fn windowCreate(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    target: []const u8,
    window_name: ?[]const u8,
    command: ?[]const u8,
) ![]u8 {
    const target_json = try std.json.stringifyAlloc(allocator, target, .{});
    defer allocator.free(target_json);

    const params_json = if (window_name) |name| blk: {
        const name_json = try std.json.stringifyAlloc(allocator, name, .{});
        defer allocator.free(name_json);
        if (command) |value| {
            const command_json = try std.json.stringifyAlloc(allocator, value, .{});
            defer allocator.free(command_json);
            break :blk try std.fmt.allocPrint(
                allocator,
                "{{\"target\":{s},\"windowName\":{s},\"command\":{s}}}",
                .{ target_json, name_json, command_json },
            );
        }
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"target\":{s},\"windowName\":{s}}}",
            .{ target_json, name_json },
        );
    } else try std.fmt.allocPrint(allocator, "{{\"target\":{s}}}", .{target_json});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "window.create", params_json);
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

pub fn fileCapture(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "file.capture", params_json);
}

pub fn fileFollowTail(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64, enabled: bool) ![]u8 {
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"nodeId\":{d},\"enabled\":{s}}}",
        .{ node_id, if (enabled) "true" else "false" },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "file.followTail", params_json);
}

pub fn capabilitiesGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "capabilities.get", "{}");
}

pub fn viewReset(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "view.reset", "{}");
}

pub fn nodeGet(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "node.get", params_json);
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
