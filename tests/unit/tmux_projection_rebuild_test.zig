const std = @import("std");
const builtin = @import("builtin");
const muxly = @import("muxly");
const tmux_client = muxly.daemon.tmux.client;
const reconcile = muxly.daemon.tmux.reconcile;

test "tmux snapshots can rebuild projected subtree from external tmux state" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const session_name = "muxly-projection-rebuild-test";
    cleanupSession(session_name);

    try createExternalSession(allocator, session_name);
    defer cleanupSession(session_name);

    const snapshots = try tmux_client.listPaneSnapshots(allocator);
    defer {
        for (snapshots) |*snapshot| snapshot.deinit(allocator);
        allocator.free(snapshots);
    }

    var filtered = std.array_list.Managed(muxly.daemon.tmux.events.PaneSnapshot).init(allocator);
    defer filtered.deinit();
    for (snapshots) |snapshot| {
        if (std.mem.eql(u8, snapshot.session_name, session_name)) {
            try filtered.append(snapshot);
        }
    }

    try std.testing.expect(filtered.items.len >= 2);

    var document = try muxly.document.Document.init(allocator, 1, "demo");
    defer document.deinit();

    const parent_id = try document.appendNode(document.root_node_id, .subdocument, "projection-scope", .{ .none = {} });
    const session_node_id = try reconcile.reconcileSessionSnapshots(&document, parent_id, filtered.items);

    const session_node = document.findNode(session_node_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(muxly.types.NodeKind.subdocument, session_node.kind);
    try std.testing.expectEqualStrings(session_name, session_node.title);
    try std.testing.expectEqual(parent_id, session_node.parent_id.?);
    try std.testing.expect(session_node.children.items.len >= 1);

    var pane_count: usize = 0;
    for (document.nodes.items) |node| {
        if (node.kind != .tty_leaf) continue;
        switch (node.source) {
            .tty => |tty| {
                if (std.mem.eql(u8, tty.session_name, session_name)) pane_count += 1;
            },
            else => {},
        }
    }
    try std.testing.expect(pane_count >= 2);
}

fn createExternalSession(allocator: std.mem.Allocator, session_name: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "tmux",
            "new-session",
            "-d",
            "-s",
            session_name,
            "sh -lc 'printf external-base\\n; sleep 5'",
        },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    try expectSuccess(result.term);

    const split = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "tmux",
            "split-window",
            "-d",
            "-t",
            session_name,
            "-h",
            "sh -lc 'printf external-split\\n; sleep 5'",
        },
    });
    defer {
        allocator.free(split.stdout);
        allocator.free(split.stderr);
    }
    try expectSuccess(split.term);
}

fn expectSuccess(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.TmuxCommandFailed;
        },
        else => return error.TmuxCommandFailed,
    }
}

fn cleanupSession(session_name: []const u8) void {
    var child = std.process.Child.init(&[_][]const u8{ "tmux", "kill-session", "-t", session_name }, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch {};
}
