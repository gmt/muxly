const std = @import("std");
const muxly = @import("muxly");
const cli_args = muxly.cli_args;
const admin_generate = @import("admin_generate.zig");
const cli_format = @import("format.zig");
const target_arg = @import("target_arg.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len <= 1) return printUsage();

    const transport_from_env = try muxly.api.transportSpecFromEnv(allocator);
    defer allocator.free(transport_from_env);
    const parsed = cli_args.parse(args, transport_from_env) catch |err| switch (err) {
        error.ShowUsage => return printUsage(),
        else => return err,
    };
    const transport_spec = if (parsed.allow_insecure_tcp)
        try muxly.transport.withUnsafeTcpPrefix(allocator, parsed.transport_spec)
    else
        try allocator.dupe(u8, parsed.transport_spec);
    defer allocator.free(transport_spec);
    const cursor = parsed.command_index;

    if (cursor >= args.len) return printUsage();

    if (std.mem.eql(u8, args[cursor], "transport") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "relay")) {
        return try runTransportRelay(allocator, transport_spec);
    }
    if (std.mem.eql(u8, args[cursor], "admin") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "generate-caddy")) {
        return try admin_generate.run(allocator, .caddy, args[cursor + 2 ..]);
    }
    if (std.mem.eql(u8, args[cursor], "admin") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "generate-systemd")) {
        return try admin_generate.run(allocator, .systemd, args[cursor + 2 ..]);
    }

    const response = if (std.mem.eql(u8, args[cursor], "ping"))
        try muxly.api.ping(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "initialize"))
        try muxly.api.initialize(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "capabilities") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try muxly.api.capabilitiesGet(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "node") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "get")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .document_or_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeGetTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "node") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "append")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .document_or_node_concrete);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeAppendInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.requireNodeId() catch return printUsage(),
            args[cursor + 3],
            args[cursor + 4],
        );
    } else if (std.mem.eql(u8, args[cursor], "node") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "update")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .explicit_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeUpdateTargetInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.node_target,
            if (std.mem.eql(u8, args[cursor + 3], "title")) args[cursor + 4] else null,
            if (std.mem.eql(u8, args[cursor + 3], "content")) args[cursor + 4] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "node") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "freeze")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .explicit_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeFreezeTargetInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.node_target,
            args[cursor + 3],
        );
    } else if (std.mem.eql(u8, args[cursor], "node") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "remove")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .explicit_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.nodeRemoveTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "session") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try muxly.api.sessionList(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "window") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try muxly.api.windowList(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "list"))
        try muxly.api.paneList(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "list"))
        try muxly.api.graphGet(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "split") and cursor + 2 < args.len) blk: {
        break :blk try muxly.api.paneSplit(
            allocator,
            transport_spec,
            args[cursor + 1],
            args[cursor + 2],
            if (cursor + 3 < args.len) args[cursor + 3] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "capture") and cursor + 1 < args.len) blk: {
        break :blk try muxly.api.paneCapture(allocator, transport_spec, args[cursor + 1]);
    } else if (std.mem.eql(u8, args[cursor], "session") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "create")) blk: {
        break :blk try muxly.api.sessionCreate(
            allocator,
            transport_spec,
            args[cursor + 2],
            if (cursor + 3 < args.len) args[cursor + 3] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "session") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "create-under")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .document_or_node_concrete);
        defer target.deinit(allocator);
        break :blk try muxly.api.sessionCreateAtInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.requireNodeId() catch return printUsage(),
            args[cursor + 3],
            if (cursor + 4 < args.len) args[cursor + 4] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "window") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "create")) blk: {
        break :blk try muxly.api.windowCreate(
            allocator,
            transport_spec,
            args[cursor + 2],
            if (cursor + 3 < args.len) args[cursor + 3] else null,
            if (cursor + 4 < args.len) args[cursor + 4] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "split")) blk: {
        break :blk try muxly.api.paneSplit(
            allocator,
            transport_spec,
            args[cursor + 2],
            args[cursor + 3],
            if (cursor + 4 < args.len) args[cursor + 4] else null,
        );
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "capture")) blk: {
        break :blk try muxly.api.paneCapture(allocator, transport_spec, args[cursor + 2]);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "scroll")) blk: {
        const start_line = try std.fmt.parseInt(i64, args[cursor + 3], 10);
        const end_line = try std.fmt.parseInt(i64, args[cursor + 4], 10);
        break :blk try muxly.api.paneScroll(allocator, transport_spec, args[cursor + 2], start_line, end_line);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 1], "resize")) blk: {
        const amount = try std.fmt.parseInt(i64, args[cursor + 4], 10);
        break :blk try muxly.api.paneResize(allocator, transport_spec, args[cursor + 2], args[cursor + 3], amount);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "focus")) blk: {
        break :blk try muxly.api.paneFocus(allocator, transport_spec, args[cursor + 2]);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "send-keys")) blk: {
        break :blk try muxly.api.paneSendKeys(
            allocator,
            transport_spec,
            args[cursor + 2],
            args[cursor + 3],
            if (cursor + 4 < args.len and std.mem.eql(u8, args[cursor + 4], "--enter")) true else false,
        );
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "close")) blk: {
        break :blk try muxly.api.paneClose(allocator, transport_spec, args[cursor + 2]);
    } else if (std.mem.eql(u8, args[cursor], "pane") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "follow-tail")) blk: {
        break :blk try muxly.api.paneFollowTail(
            allocator,
            transport_spec,
            args[cursor + 2],
            std.mem.eql(u8, args[cursor + 3], "true"),
        );
    } else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try muxly.api.documentGet(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "status"))
        try muxly.api.documentStatus(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "freeze"))
        try muxly.api.documentFreeze(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "document") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "serialize"))
        try muxly.api.documentSerialize(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "attach-file")) blk: {
        break :blk try muxly.api.leafAttachFile(allocator, transport_spec, args[cursor + 2], args[cursor + 3]);
    } else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "source-get")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .explicit_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.leafSourceGetTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "file") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "capture")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .explicit_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.fileCaptureTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "file") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "follow-tail")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .explicit_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.fileFollowTailTargetInDocument(
            allocator,
            target.transport_spec,
            target.document_path,
            target.node_target,
            std.mem.eql(u8, args[cursor + 3], "true"),
        );
    } else if (std.mem.eql(u8, args[cursor], "leaf") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "attach-tty")) blk: {
        break :blk try muxly.api.leafAttachTty(allocator, transport_spec, args[cursor + 2]);
    } else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "get"))
        try muxly.api.viewGet(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "projection") and cursor + 3 < args.len and std.mem.eql(u8, args[cursor + 1], "get")) blk: {
        const rows = try std.fmt.parseInt(u16, args[cursor + 2], 10);
        const cols = try std.fmt.parseInt(u16, args[cursor + 3], 10);
        var focused_target = if (cursor + 4 < args.len)
            try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 4], .document_or_node_concrete)
        else
            null;
        defer if (focused_target) |*value| value.deinit(allocator);
        break :blk try muxly.api.projectionGetInDocument(
            allocator,
            if (focused_target) |value| value.transport_spec else transport_spec,
            if (focused_target) |value| value.document_path else muxly.protocol.default_document_path,
            .{
                .rows = rows,
                .cols = cols,
                .local_state = .{
                    .focused_node_id = if (focused_target) |value| value.requireNodeId() catch return printUsage() else null,
                },
            },
        );
    } else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "reset"))
        try muxly.api.viewReset(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 1 < args.len and std.mem.eql(u8, args[cursor + 1], "clear-root"))
        try muxly.api.viewClearRoot(allocator, transport_spec)
    else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "set-root")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .document_or_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.viewSetRootTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "elide")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .explicit_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.viewElideTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else if (std.mem.eql(u8, args[cursor], "view") and cursor + 2 < args.len and std.mem.eql(u8, args[cursor + 1], "expand")) blk: {
        var target = try target_arg.resolve(allocator, transport_spec, muxly.protocol.default_document_path, args[cursor + 2], .explicit_node_lazy);
        defer target.deinit(allocator);
        break :blk try muxly.api.viewExpandTargetInDocument(allocator, target.transport_spec, target.document_path, target.node_target);
    } else return printUsage();
    defer allocator.free(response);

    try cli_format.writeResponse(std.fs.File.stdout().deprecatedWriter(), response);
}

fn printUsage() !void {
    try std.fs.File.stdout().writeAll(
        \\muxly usage:
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] ping
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] initialize
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] capabilities get
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] node get <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] node append <parent-id> <kind> <title>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] node update <node-id> <title|content> <value>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] node freeze <node-id> <text|surface>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] node remove <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] session list
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] window list
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] pane list
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] list
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] split <target-pane> <direction> [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] capture <pane-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] session create <session-name> [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] session create-under <parent-id> <session-name> [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] window create <target-session> [window-name] [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] pane split <target-pane> <direction> [command]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] pane capture <pane-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] pane scroll <pane-id> <start-line> <end-line>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] pane resize <pane-id> <direction> <amount>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] pane focus <pane-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] pane send-keys <pane-id> <keys> [--enter]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] pane close <pane-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] pane follow-tail <pane-id> <true|false>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] document get
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] document status
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] document freeze
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] document serialize
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] file capture <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] file follow-tail <node-id> <true|false>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] leaf attach-file <static-file|monitored-file> <path>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] leaf source-get <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] leaf attach-tty <session-name>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] view get
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] projection get <rows> <cols> [focused-node-id]
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] view reset
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] view clear-root
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] view set-root <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] view elide <node-id>
        \\  muxly [--transport SPEC|--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated] view expand <node-id>
        \\  muxly admin generate-caddy --descriptor TRDS --mode <user|system> --output-dir PATH [--upstream-port PORT] [--upstream-host HOST] [--upstream-path PATH] [--caddy-bin PATH] [--muxlyd-bin PATH]
        \\  muxly admin generate-systemd --descriptor TRDS --mode <user|system> --output-dir PATH [--upstream-port PORT] [--upstream-host HOST] [--upstream-path PATH] [--service-user USER] [--service-group GROUP] [--caddy-bin PATH] [--muxlyd-bin PATH]
        \\
        \\transport notes:
        \\  SPEC may be unix paths, tcp://, ssh://, http://, h2://, or h3wt://
        \\  bare/default sockets use ${XDG_RUNTIME_DIR}/muxly.sock or /run/user/<uid>/muxly.sock
        \\  document-or-node targets (trd://doc, trd://doc#node, trd:#node) are accepted by:
        \\    node get, node append, session create-under, projection get [focused target], view set-root
        \\  explicit-node targets (#selector or numeric id) are required by:
        \\    node update/freeze/remove, leaf source-get, file capture/follow-tail, view elide/expand
        \\  TRDS is a secure deployment descriptor like trds://host:8443/rpc//docs/demo#left
        \\
    );
}

fn runTransportRelay(allocator: std.mem.Allocator, transport_spec: []const u8) !void {
    var client = try muxly.client.Client.init(allocator, transport_spec);
    defer client.deinit();
    const runtime_limits = try muxly.runtime_config.loadClientLimits(allocator);
    var stdin_reader = muxly.transport.MessageReader.init(allocator);
    defer stdin_reader.deinit();

    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    while (true) {
        const request = try stdin_reader.readMessageLine(
            stdin_file,
            runtime_limits.max_message_bytes,
        ) orelse break;
        defer allocator.free(request);
        if (request.len == 0) continue;

        const response = try client.requestJson(request);
        defer allocator.free(response);
        try stdout_file.writeAll(response);
        try stdout_file.writeAll("\n");
    }
}
