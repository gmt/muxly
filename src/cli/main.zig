const std = @import("std");
const muxly = @import("muxly");
const cli_args = @import("args.zig");
const cli_client = @import("client.zig");
const cli_format = @import("format.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len <= 1) return printUsage();

    const socket_path_from_env = try muxly.api.socketPathFromEnv(allocator);
    const parsed = cli_args.parse(args, socket_path_from_env);
    const socket_path = parsed.socket_path;
    const cursor = parsed.command_index;

    if (cursor >= args.len) return printUsage();

    var client = try cli_client.init(allocator, socket_path);
    defer client.deinit();

    const response = if (std.mem.eql(u8, args[cursor], "ping"))
        try client.request("ping", "{}")
    else if (std.mem.eql(u8, args[cursor], "initialize"))
        try client.request("initialize", "{}")
    else if (std.mem.eql(u8, args[cursor], "capabilities") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try client.request("capabilities.get", "{}")
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        blk: {
            const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{s}}}", .{args[cursor + 2]});
            defer allocator.free(params_json);
            break :blk try client.request("node.get", params_json);
        }
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "append"))
        blk: {
            break :blk try requestNodeAppend(allocator, &client, args[cursor + 2], args[cursor + 3], args[cursor + 4]);
        }
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "update"))
        blk: {
            break :blk try requestNodeUpdate(
                allocator,
                &client,
                args[cursor + 2],
                if (std.mem.eql(u8, args[cursor + 3], "title")) args[cursor + 4] else null,
                if (std.mem.eql(u8, args[cursor + 3], "content")) args[cursor + 4] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "remove"))
        blk: {
            const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{s}}}", .{args[cursor + 2]});
            defer allocator.free(params_json);
            break :blk try client.request("node.remove", params_json);
        }
    else if (std.mem.eql(u8, args[cursor], "session") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try client.request("session.list", "{}")
    else if (std.mem.eql(u8, args[cursor], "window") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try client.request("window.list", "{}")
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try client.request("pane.list", "{}")
    else if (std.mem.eql(u8, args[cursor], "list"))
        try client.request("graph.get", "{}")
    else if (std.mem.eql(u8, args[cursor], "split") and cursor + 2 < args.len)
        blk: {
            break :blk try requestSplitPane(
                allocator,
                &client,
                args[cursor + 1],
                args[cursor + 2],
                if (cursor + 3 < args.len) args[cursor + 3] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "capture") and cursor + 1 < args.len)
        blk: {
            const pane_id_json = try jsonStringAlloc(allocator, args[cursor + 1]);
            defer allocator.free(pane_id_json);
            const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
            defer allocator.free(params_json);
            break :blk try client.request("pane.capture", params_json);
        }
    else if (std.mem.eql(u8, args[cursor], "session") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "create"))
        blk: {
            break :blk try requestWithOptionalCommand(allocator, &client, "session.create", args[cursor + 2], if (cursor + 3 < args.len) args[cursor + 3] else null);
        }
    else if (std.mem.eql(u8, args[cursor], "window") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "create"))
        blk: {
            break :blk try requestWindowCreate(
                allocator,
                &client,
                args[cursor + 2],
                if (cursor + 3 < args.len) args[cursor + 3] else null,
                if (cursor + 4 < args.len) args[cursor + 4] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "split"))
        blk: {
            break :blk try requestSplitPane(
                allocator,
                &client,
                args[cursor + 2],
                args[cursor + 3],
                if (cursor + 4 < args.len) args[cursor + 4] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "capture"))
        blk: {
            const pane_id_json = try jsonStringAlloc(allocator, args[cursor + 2]);
            defer allocator.free(pane_id_json);
            const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
            defer allocator.free(params_json);
            break :blk try client.request("pane.capture", params_json);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "scroll"))
        blk: {
            break :blk try requestPaneScroll(allocator, &client, args[cursor + 2], args[cursor + 3], args[cursor + 4]);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "resize"))
        blk: {
            break :blk try requestPaneResize(allocator, &client, args[cursor + 2], args[cursor + 3], args[cursor + 4]);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "focus"))
        blk: {
            break :blk try requestPaneIdOnly(allocator, &client, "pane.focus", args[cursor + 2]);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "send-keys"))
        blk: {
            break :blk try requestPaneSendKeys(
                allocator,
                &client,
                args[cursor + 2],
                args[cursor + 3],
                if (cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 4], "--enter")) true else false,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "close"))
        blk: {
            break :blk try requestPaneIdOnly(allocator, &client, "pane.close", args[cursor + 2]);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "follow-tail"))
        blk: {
            break :blk try requestEnabledByPaneId(allocator, &client, "pane.followTail", args[cursor + 2], args[cursor + 3]);
        }
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try client.request("document.get", "{}")
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "status"))
        try client.request("document.status", "{}")
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "freeze"))
        try client.request("document.freeze", "{}")
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "serialize"))
        try client.request("document.serialize", "{}")
    else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "attach-file"))
        blk: {
            const request_json = try buildAttachFileRequest(allocator, args[cursor + 2], args[cursor + 3]);
            defer allocator.free(request_json);
            break :blk try client.requestJson(request_json);
        }
    else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "source-get"))
        blk: {
            const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{s}}}", .{args[cursor + 2]});
            defer allocator.free(params_json);
            break :blk try client.request("leaf.source.get", params_json);
        }
    else if (std.mem.eql(u8, args[cursor], "file") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "capture"))
        blk: {
            const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{s}}}", .{args[cursor + 2]});
            defer allocator.free(params_json);
            break :blk try client.request("file.capture", params_json);
        }
    else if (std.mem.eql(u8, args[cursor], "file") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "follow-tail"))
        blk: {
            break :blk try requestEnabledByNodeId(allocator, &client, "file.followTail", args[cursor + 2], args[cursor + 3]);
        }
    else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "attach-tty"))
        blk: {
            const request_json = try buildAttachTtyRequest(allocator, args[cursor + 2]);
            defer allocator.free(request_json);
            break :blk try client.requestJson(request_json);
        }
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try client.request("view.get", "{}")
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "reset"))
        try client.request("view.reset", "{}")
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "clear-root"))
        try client.request("view.clearRoot", "{}")
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "set-root"))
        blk: {
            const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{s}}}", .{args[cursor + 2]});
            defer allocator.free(params_json);
            break :blk try client.request("view.setRoot", params_json);
        }
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "elide"))
        blk: {
            const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{s}}}", .{args[cursor + 2]});
            defer allocator.free(params_json);
            break :blk try client.request("view.elide", params_json);
        }
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "expand"))
        blk: {
            const params_json = try std.fmt.allocPrint(allocator, "{{\"nodeId\":{s}}}", .{args[cursor + 2]});
            defer allocator.free(params_json);
            break :blk try client.request("view.expand", params_json);
        }
    else
        return printUsage();
    defer allocator.free(response);

    try cli_format.writeResponse(std.fs.File.stdout().deprecatedWriter(), response);
}

fn jsonStringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();
    try buffer.writer().print("{f}", .{std.json.fmt(value, .{})});
    return try buffer.toOwnedSlice();
}

fn buildAttachFileRequest(allocator: std.mem.Allocator, kind: []const u8, path: []const u8) ![]u8 {
    const path_json = try jsonStringAlloc(allocator, path);
    defer allocator.free(path_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"leaf.source.attach\",\"params\":{{\"kind\":\"{s}\",\"path\":{s}}}}}",
        .{ kind, path_json },
    );
}

fn buildAttachTtyRequest(allocator: std.mem.Allocator, session_name: []const u8) ![]u8 {
    const session_name_json = try jsonStringAlloc(allocator, session_name);
    defer allocator.free(session_name_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"leaf.source.attach\",\"params\":{{\"kind\":\"tty\",\"sessionName\":{s}}}}}",
        .{session_name_json},
    );
}

fn requestWithOptionalCommand(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    method: []const u8,
    name: []const u8,
    command: ?[]const u8,
) ![]u8 {
    const name_json = try jsonStringAlloc(allocator, name);
    defer allocator.free(name_json);

    if (command) |value| {
        const command_json = try jsonStringAlloc(allocator, value);
        defer allocator.free(command_json);
        const params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"sessionName\":{s},\"command\":{s}}}",
            .{ name_json, command_json },
        );
        defer allocator.free(params_json);
        return try client.request(method, params_json);
    }

    const params_json = try std.fmt.allocPrint(allocator, "{{\"sessionName\":{s}}}", .{name_json});
    defer allocator.free(params_json);
    return try client.request(method, params_json);
}

fn requestNodeAppend(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    parent_id_text: []const u8,
    kind: []const u8,
    title: []const u8,
) ![]u8 {
    const kind_json = try jsonStringAlloc(allocator, kind);
    defer allocator.free(kind_json);
    const title_json = try jsonStringAlloc(allocator, title);
    defer allocator.free(title_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"parentId\":{s},\"kind\":{s},\"title\":{s}}}",
        .{ parent_id_text, kind_json, title_json },
    );
    defer allocator.free(params_json);
    return try client.request("node.append", params_json);
}

fn requestNodeUpdate(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    node_id_text: []const u8,
    title: ?[]const u8,
    content: ?[]const u8,
) ![]u8 {
    if (title) |value| {
        const title_json = try jsonStringAlloc(allocator, value);
        defer allocator.free(title_json);
        const params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"nodeId\":{s},\"title\":{s}}}",
            .{ node_id_text, title_json },
        );
        defer allocator.free(params_json);
        return try client.request("node.update", params_json);
    }
    if (content) |value| {
        const content_json = try jsonStringAlloc(allocator, value);
        defer allocator.free(content_json);
        const params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"nodeId\":{s},\"content\":{s}}}",
            .{ node_id_text, content_json },
        );
        defer allocator.free(params_json);
        return try client.request("node.update", params_json);
    }
    return error.InvalidArguments;
}

fn requestSplitPane(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    target: []const u8,
    direction: []const u8,
    command: ?[]const u8,
) ![]u8 {
    const target_json = try jsonStringAlloc(allocator, target);
    defer allocator.free(target_json);
    const direction_json = try jsonStringAlloc(allocator, direction);
    defer allocator.free(direction_json);

    if (command) |value| {
        const command_json = try jsonStringAlloc(allocator, value);
        defer allocator.free(command_json);
        const params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"target\":{s},\"direction\":{s},\"command\":{s}}}",
            .{ target_json, direction_json, command_json },
        );
        defer allocator.free(params_json);
        return try client.request("pane.split", params_json);
    }

    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"target\":{s},\"direction\":{s}}}",
        .{ target_json, direction_json },
    );
    defer allocator.free(params_json);
    return try client.request("pane.split", params_json);
}

fn requestWindowCreate(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    target: []const u8,
    window_name: ?[]const u8,
    command: ?[]const u8,
) ![]u8 {
    const target_json = try jsonStringAlloc(allocator, target);
    defer allocator.free(target_json);

    if (window_name) |name| {
        const name_json = try jsonStringAlloc(allocator, name);
        defer allocator.free(name_json);
        if (command) |value| {
            const command_json = try jsonStringAlloc(allocator, value);
            defer allocator.free(command_json);
            const params_json = try std.fmt.allocPrint(
                allocator,
                "{{\"target\":{s},\"windowName\":{s},\"command\":{s}}}",
                .{ target_json, name_json, command_json },
            );
            defer allocator.free(params_json);
            return try client.request("window.create", params_json);
        }
        const params_json = try std.fmt.allocPrint(
            allocator,
            "{{\"target\":{s},\"windowName\":{s}}}",
            .{ target_json, name_json },
        );
        defer allocator.free(params_json);
        return try client.request("window.create", params_json);
    }

    const params_json = try std.fmt.allocPrint(allocator, "{{\"target\":{s}}}", .{target_json});
    defer allocator.free(params_json);
    return try client.request("window.create", params_json);
}

fn requestPaneResize(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    pane_id: []const u8,
    direction: []const u8,
    amount_text: []const u8,
) ![]u8 {
    const pane_id_json = try jsonStringAlloc(allocator, pane_id);
    defer allocator.free(pane_id_json);
    const direction_json = try jsonStringAlloc(allocator, direction);
    defer allocator.free(direction_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"direction\":{s},\"amount\":{s}}}",
        .{ pane_id_json, direction_json, amount_text },
    );
    defer allocator.free(params_json);
    return try client.request("pane.resize", params_json);
}

fn requestPaneScroll(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    pane_id: []const u8,
    start_line: []const u8,
    end_line: []const u8,
) ![]u8 {
    const pane_id_json = try jsonStringAlloc(allocator, pane_id);
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"startLine\":{s},\"endLine\":{s}}}",
        .{ pane_id_json, start_line, end_line },
    );
    defer allocator.free(params_json);
    return try client.request("pane.scroll", params_json);
}

fn requestPaneIdOnly(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    method: []const u8,
    pane_id: []const u8,
) ![]u8 {
    const pane_id_json = try jsonStringAlloc(allocator, pane_id);
    defer allocator.free(pane_id_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"paneId\":{s}}}", .{pane_id_json});
    defer allocator.free(params_json);
    return try client.request(method, params_json);
}

fn requestEnabledByPaneId(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    method: []const u8,
    pane_id: []const u8,
    enabled_text: []const u8,
) ![]u8 {
    const pane_id_json = try jsonStringAlloc(allocator, pane_id);
    defer allocator.free(pane_id_json);
    const enabled = if (std.mem.eql(u8, enabled_text, "true")) "true" else "false";
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"enabled\":{s}}}",
        .{ pane_id_json, enabled },
    );
    defer allocator.free(params_json);
    return try client.request(method, params_json);
}

fn requestEnabledByNodeId(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    method: []const u8,
    node_id_text: []const u8,
    enabled_text: []const u8,
) ![]u8 {
    const enabled = if (std.mem.eql(u8, enabled_text, "true")) "true" else "false";
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"nodeId\":{s},\"enabled\":{s}}}",
        .{ node_id_text, enabled },
    );
    defer allocator.free(params_json);
    return try client.request(method, params_json);
}

fn requestPaneSendKeys(
    allocator: std.mem.Allocator,
    client: *muxly.client.Client,
    pane_id: []const u8,
    keys: []const u8,
    press_enter: bool,
) ![]u8 {
    const pane_id_json = try jsonStringAlloc(allocator, pane_id);
    defer allocator.free(pane_id_json);
    const keys_json = try jsonStringAlloc(allocator, keys);
    defer allocator.free(keys_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{s},\"keys\":{s},\"enter\":{s}}}",
        .{ pane_id_json, keys_json, if (press_enter) "true" else "false" },
    );
    defer allocator.free(params_json);
    return try client.request("pane.sendKeys", params_json);
}

fn printUsage() !void {
    try std.fs.File.stdout().writeAll(
        \\muxly usage:
        \\  muxly [--socket PATH] ping
        \\  muxly [--socket PATH] initialize
        \\  muxly [--socket PATH] capabilities get
        \\  muxly [--socket PATH] node get <node-id>
        \\  muxly [--socket PATH] node append <parent-id> <kind> <title>
        \\  muxly [--socket PATH] node update <node-id> <title|content> <value>
        \\  muxly [--socket PATH] node remove <node-id>
        \\  muxly [--socket PATH] session list
        \\  muxly [--socket PATH] window list
        \\  muxly [--socket PATH] pane list
        \\  muxly [--socket PATH] list
        \\  muxly [--socket PATH] split <target-pane> <direction> [command]
        \\  muxly [--socket PATH] capture <pane-id>
        \\  muxly [--socket PATH] session create <session-name> [command]
        \\  muxly [--socket PATH] window create <target-session> [window-name] [command]
        \\  muxly [--socket PATH] pane split <target-pane> <direction> [command]
        \\  muxly [--socket PATH] pane capture <pane-id>
        \\  muxly [--socket PATH] pane scroll <pane-id> <start-line> <end-line>
        \\  muxly [--socket PATH] pane resize <pane-id> <direction> <amount>
        \\  muxly [--socket PATH] pane focus <pane-id>
        \\  muxly [--socket PATH] pane send-keys <pane-id> <keys> [--enter]
        \\  muxly [--socket PATH] pane close <pane-id>
        \\  muxly [--socket PATH] pane follow-tail <pane-id> <true|false>
        \\  muxly [--socket PATH] document get
        \\  muxly [--socket PATH] document status
        \\  muxly [--socket PATH] document freeze
        \\  muxly [--socket PATH] document serialize
        \\  muxly [--socket PATH] file capture <node-id>
        \\  muxly [--socket PATH] file follow-tail <node-id> <true|false>
        \\  muxly [--socket PATH] leaf attach-file <static-file|monitored-file> <path>
        \\  muxly [--socket PATH] leaf source-get <node-id>
        \\  muxly [--socket PATH] leaf attach-tty <session-name>
        \\  muxly [--socket PATH] view get
        \\  muxly [--socket PATH] view reset
        \\  muxly [--socket PATH] view clear-root
        \\  muxly [--socket PATH] view set-root <node-id>
        \\  muxly [--socket PATH] view elide <node-id>
        \\  muxly [--socket PATH] view expand <node-id>
        \\
    );
}
