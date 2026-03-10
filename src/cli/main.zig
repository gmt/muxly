const std = @import("std");
const muxly = @import("muxly");
const cli_args = @import("args.zig");
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

    const response = if (std.mem.eql(u8, args[cursor], "ping"))
        try muxly.api.ping(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "initialize"))
        try muxly.api.initialize(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "capabilities") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try muxly.api.capabilitiesGet(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        blk: {
            const node_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.nodeGet(allocator, socket_path, node_id);
        }
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "append"))
        blk: {
            const parent_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.nodeAppend(allocator, socket_path, parent_id, args[cursor + 3], args[cursor + 4]);
        }
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "update"))
        blk: {
            const node_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.nodeUpdate(
                allocator,
                socket_path,
                node_id,
                if (std.mem.eql(u8, args[cursor + 3], "title")) args[cursor + 4] else null,
                if (std.mem.eql(u8, args[cursor + 3], "content")) args[cursor + 4] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "remove"))
        blk: {
            const node_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.nodeRemove(allocator, socket_path, node_id);
        }
    else if (std.mem.eql(u8, args[cursor], "session") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try muxly.api.sessionList(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "window") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try muxly.api.windowList(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try muxly.api.paneList(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "list"))
        try muxly.api.graphGet(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "split") and cursor + 2 < args.len)
        blk: {
            break :blk try muxly.api.paneSplit(
                allocator,
                socket_path,
                args[cursor + 1],
                args[cursor + 2],
                if (cursor + 3 < args.len) args[cursor + 3] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "capture") and cursor + 1 < args.len)
        blk: {
            break :blk try muxly.api.paneCapture(allocator, socket_path, args[cursor + 1]);
        }
    else if (std.mem.eql(u8, args[cursor], "session") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "create"))
        blk: {
            break :blk try muxly.api.sessionCreate(
                allocator,
                socket_path,
                args[cursor + 2],
                if (cursor + 3 < args.len) args[cursor + 3] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "session") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "create-under"))
        blk: {
            const parent_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.sessionCreateAt(
                allocator,
                socket_path,
                parent_id,
                args[cursor + 3],
                if (cursor + 4 < args.len) args[cursor + 4] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "window") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "create"))
        blk: {
            break :blk try muxly.api.windowCreate(
                allocator,
                socket_path,
                args[cursor + 2],
                if (cursor + 3 < args.len) args[cursor + 3] else null,
                if (cursor + 4 < args.len) args[cursor + 4] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "split"))
        blk: {
            break :blk try muxly.api.paneSplit(
                allocator,
                socket_path,
                args[cursor + 2],
                args[cursor + 3],
                if (cursor + 4 < args.len) args[cursor + 4] else null,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "capture"))
        blk: {
            break :blk try muxly.api.paneCapture(allocator, socket_path, args[cursor + 2]);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "scroll"))
        blk: {
            const start_line = try std.fmt.parseInt(i64, args[cursor + 3], 10);
            const end_line = try std.fmt.parseInt(i64, args[cursor + 4], 10);
            break :blk try muxly.api.paneScroll(allocator, socket_path, args[cursor + 2], start_line, end_line);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "resize"))
        blk: {
            const amount = try std.fmt.parseInt(i64, args[cursor + 4], 10);
            break :blk try muxly.api.paneResize(allocator, socket_path, args[cursor + 2], args[cursor + 3], amount);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "focus"))
        blk: {
            break :blk try muxly.api.paneFocus(allocator, socket_path, args[cursor + 2]);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "send-keys"))
        blk: {
            break :blk try muxly.api.paneSendKeys(
                allocator,
                socket_path,
                args[cursor + 2],
                args[cursor + 3],
                if (cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 4], "--enter")) true else false,
            );
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "close"))
        blk: {
            break :blk try muxly.api.paneClose(allocator, socket_path, args[cursor + 2]);
        }
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "follow-tail"))
        blk: {
            break :blk try muxly.api.paneFollowTail(
                allocator,
                socket_path,
                args[cursor + 2],
                std.mem.eql(u8, args[cursor + 3], "true"),
            );
        }
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try muxly.api.documentGet(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "status"))
        try muxly.api.documentStatus(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "freeze"))
        try muxly.api.documentFreeze(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "serialize"))
        try muxly.api.documentSerialize(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "attach-file"))
        blk: {
            break :blk try muxly.api.leafAttachFile(allocator, socket_path, args[cursor + 2], args[cursor + 3]);
        }
    else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "source-get"))
        blk: {
            const node_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.leafSourceGet(allocator, socket_path, node_id);
        }
    else if (std.mem.eql(u8, args[cursor], "file") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "capture"))
        blk: {
            const node_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.fileCapture(allocator, socket_path, node_id);
        }
    else if (std.mem.eql(u8, args[cursor], "file") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "follow-tail"))
        blk: {
            const node_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.fileFollowTail(
                allocator,
                socket_path,
                node_id,
                std.mem.eql(u8, args[cursor + 3], "true"),
            );
        }
    else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "attach-tty"))
        blk: {
            break :blk try muxly.api.leafAttachTty(allocator, socket_path, args[cursor + 2]);
        }
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try muxly.api.viewGet(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "reset"))
        try muxly.api.viewReset(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "clear-root"))
        try muxly.api.viewClearRoot(allocator, socket_path)
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "set-root"))
        blk: {
            const node_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.viewSetRoot(allocator, socket_path, node_id);
        }
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "elide"))
        blk: {
            const node_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.viewElide(allocator, socket_path, node_id);
        }
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "expand"))
        blk: {
            const node_id = try std.fmt.parseInt(u64, args[cursor + 2], 10);
            break :blk try muxly.api.viewExpand(allocator, socket_path, node_id);
        }
    else
        return printUsage();
    defer allocator.free(response);

    try cli_format.writeResponse(std.fs.File.stdout().deprecatedWriter(), response);
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
        \\  muxly [--socket PATH] session create-under <parent-id> <session-name> [command]
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
