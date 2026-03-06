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
    else if (std.mem.eql(u8, args[cursor], "session") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "create"))
        blk: {
            break :blk try requestWithOptionalCommand(allocator, &client, "session.create", args[cursor + 2], if (cursor + 3 < args.len) args[cursor + 3] else null);
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
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try client.request("document.get", "{}")
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "status"))
        try client.request("document.status", "{}")
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
    else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "attach-tty"))
        blk: {
            const request_json = try buildAttachTtyRequest(allocator, args[cursor + 2]);
            defer allocator.free(request_json);
            break :blk try client.requestJson(request_json);
        }
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try client.request("view.get", "{}")
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
    else
        return printUsage();
    defer allocator.free(response);

    try cli_format.writeResponse(std.io.getStdOut().writer(), response);
}

fn jsonStringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    errdefer buffer.deinit();
    try std.json.stringify(value, .{}, buffer.writer());
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

fn printUsage() !void {
    try std.io.getStdOut().writer().writeAll(
        \\muxly usage:
        \\  muxly [--socket PATH] ping
        \\  muxly [--socket PATH] initialize
        \\  muxly [--socket PATH] capabilities get
        \\  muxly [--socket PATH] session create <session-name> [command]
        \\  muxly [--socket PATH] pane split <target-pane> <direction> [command]
        \\  muxly [--socket PATH] pane capture <pane-id>
        \\  muxly [--socket PATH] document get
        \\  muxly [--socket PATH] document status
        \\  muxly [--socket PATH] document serialize
        \\  muxly [--socket PATH] leaf attach-file <static-file|monitored-file> <path>
        \\  muxly [--socket PATH] leaf source-get <node-id>
        \\  muxly [--socket PATH] leaf attach-tty <session-name>
        \\  muxly [--socket PATH] view get
        \\  muxly [--socket PATH] view set-root <node-id>
        \\  muxly [--socket PATH] view elide <node-id>
        \\
    );
}
