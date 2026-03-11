const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");

pub fn ping(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "ping", "{}");
}

pub fn initialize(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "initialize", "{}");
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

pub fn nodeAppend(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    parent_id: u64,
    kind: []const u8,
    title: []const u8,
) ![]u8 {
    const kind_json = try std.json.Stringify.valueAlloc(allocator, kind, .{});
    defer allocator.free(kind_json);
    const title_json = try std.json.Stringify.valueAlloc(allocator, title, .{});
    defer allocator.free(title_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"parentId\":{d},\"kind\":{s},\"title\":{s}}}",
        .{ parent_id, kind_json, title_json },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "node.append", params_json);
}

pub fn nodeUpdate(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    node_id: u64,
    title: ?[]const u8,
    content: ?[]const u8,
) ![]u8 {
    if (title) |value| {
        const title_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(title_json);
        const params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"nodeId\":{d},\"title\":{s}}}",
            .{ node_id, title_json },
        );
        defer allocator.free(params_json);
        return try request(allocator, socket_path, "node.update", params_json);
    }
    if (content) |value| {
        const content_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(content_json);
        const params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"nodeId\":{d},\"content\":{s}}}",
            .{ node_id, content_json },
        );
        defer allocator.free(params_json);
        return try request(allocator, socket_path, "node.update", params_json);
    }
    return error.InvalidArguments;
}

pub fn nodeFreeze(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    node_id: u64,
    artifact_kind: []const u8,
) ![]u8 {
    const artifact_kind_json = try std.json.Stringify.valueAlloc(allocator, artifact_kind, .{});
    defer allocator.free(artifact_kind_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"nodeId\":{d},\"artifactKind\":{s}}}",
        .{ node_id, artifact_kind_json },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "node.freeze", params_json);
}

pub fn nodeRemove(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "node.remove", params_json);
}

pub fn documentFreeze(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "document.freeze", "{}");
}

pub fn documentSerialize(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "document.serialize", "{}");
}

pub fn viewGet(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "view.get", "{}");
}

pub fn viewClearRoot(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "view.clearRoot", "{}");
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

pub fn viewExpand(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "view.expand", params_json);
}

pub fn paneCapture(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8) ![]u8 {
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
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
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
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
    const target_json = try std.json.Stringify.valueAlloc(allocator, target, .{});
    defer allocator.free(target_json);
    const direction_json = try std.json.Stringify.valueAlloc(allocator, direction, .{});
    defer allocator.free(direction_json);

    const params_json = if (command) |value| blk: {
        const command_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
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
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const direction_json = try std.json.Stringify.valueAlloc(allocator, direction, .{});
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
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
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
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const keys_json = try std.json.Stringify.valueAlloc(allocator, keys, .{});
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
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "pane.close", params_json);
}

pub fn paneFollowTail(allocator: std.mem.Allocator, socket_path: []const u8, pane_id: []const u8, enabled: bool) ![]u8 {
    const pane_id_json = try std.json.Stringify.valueAlloc(allocator, pane_id, .{});
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
    const target_json = try std.json.Stringify.valueAlloc(allocator, target, .{});
    defer allocator.free(target_json);

    const params_json = if (window_name) |name| blk: {
        const name_json = try std.json.Stringify.valueAlloc(allocator, name, .{});
        defer allocator.free(name_json);
        if (command) |value| {
            const command_json = try std.json.Stringify.valueAlloc(allocator, value, .{});
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
    return try sessionCreateAt(allocator, socket_path, null, session_name, command);
}

pub fn sessionCreateAt(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    parent_id: ?u64,
    session_name: []const u8,
    command: ?[]const u8,
) ![]u8 {
    const session_name_json = try std.json.Stringify.valueAlloc(allocator, session_name, .{});
    defer allocator.free(session_name_json);

    const params_json = if (parent_id) |value|
        if (command) |command_value| blk: {
            const command_json = try std.json.Stringify.valueAlloc(allocator, command_value, .{});
            defer allocator.free(command_json);
            break :blk try std.fmt.allocPrint(
                allocator,
                "{{\"parentId\":{d},\"sessionName\":{s},\"command\":{s}}}",
                .{ value, session_name_json, command_json },
            );
        } else try std.fmt.allocPrint(
            allocator,
            "{{\"parentId\":{d},\"sessionName\":{s}}}",
            .{ value, session_name_json },
        )
    else if (command) |command_value| blk: {
        const command_json = try std.json.Stringify.valueAlloc(allocator, command_value, .{});
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

pub fn sessionList(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "session.list", "{}");
}

pub fn windowList(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "window.list", "{}");
}

pub fn paneList(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    return try request(allocator, socket_path, "pane.list", "{}");
}

pub fn leafSourceGet(allocator: std.mem.Allocator, socket_path: []const u8, node_id: u64) ![]u8 {
    const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{d}}}", .{node_id});
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "leaf.source.get", params_json);
}

pub fn leafAttachFile(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    kind: []const u8,
    path: []const u8,
) ![]u8 {
    const path_json = try std.json.Stringify.valueAlloc(allocator, path, .{});
    defer allocator.free(path_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"{s}\",\"path\":{s}}}",
        .{ kind, path_json },
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "leaf.source.attach", params_json);
}

pub fn leafAttachTty(allocator: std.mem.Allocator, socket_path: []const u8, session_name: []const u8) ![]u8 {
    const session_name_json = try std.json.Stringify.valueAlloc(allocator, session_name, .{});
    defer allocator.free(session_name_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"kind\":\"tty\",\"sessionName\":{s}}}",
        .{session_name_json},
    );
    defer allocator.free(params_json);
    return try request(allocator, socket_path, "leaf.source.attach", params_json);
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
