const std = @import("std");
const muxly = @import("muxly");
const reconcile = muxly.daemon.tmux.reconcile;
const events = muxly.daemon.tmux.events;

test "tmux snapshot reconcile builds and updates one session subtree deterministically" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const initial = [_]events.PaneSnapshot{
        .{
            .session_name = "demo-session",
            .session_id = "$0",
            .window_id = "@1",
            .window_name = "editor",
            .pane_id = "%1",
            .pane_title = "left",
            .pane_active = true,
        },
        .{
            .session_name = "demo-session",
            .session_id = "$0",
            .window_id = "@1",
            .window_name = "editor",
            .pane_id = "%2",
            .pane_title = "right",
            .pane_active = false,
        },
        .{
            .session_name = "demo-session",
            .session_id = "$0",
            .window_id = "@2",
            .window_name = "logs",
            .pane_id = "%3",
            .pane_title = "tail",
            .pane_active = true,
        },
    };

    const session_node_id = try reconcile.reconcileSessionSnapshots(&document, document.root_node_id, &initial);
    const pane_one_node_id = findPaneNodeId(&document, "%1") orelse return error.TestExpectedEqual;
    const pane_three_node_id = findPaneNodeId(&document, "%3") orelse return error.TestExpectedEqual;

    const session_node = document.findNode(session_node_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(muxly.types.NodeKind.subdocument, session_node.kind);
    try std.testing.expectEqualStrings("demo-session", session_node.title);
    try std.testing.expectEqual(@as(usize, 2), session_node.children.items.len);

    const updated = [_]events.PaneSnapshot{
        .{
            .session_name = "demo-session",
            .session_id = "$0",
            .window_id = "@1",
            .window_name = "editor",
            .pane_id = "%1",
            .pane_title = "left-renamed",
            .pane_active = false,
        },
        .{
            .session_name = "demo-session",
            .session_id = "$0",
            .window_id = "@2",
            .window_name = "logs",
            .pane_id = "%3",
            .pane_title = "tail",
            .pane_active = true,
        },
        .{
            .session_name = "demo-session",
            .session_id = "$0",
            .window_id = "@2",
            .window_name = "logs",
            .pane_id = "%4",
            .pane_title = "fresh",
            .pane_active = false,
        },
    };

    const session_node_id_again = try reconcile.reconcileSessionSnapshots(&document, document.root_node_id, &updated);
    try std.testing.expectEqual(session_node_id, session_node_id_again);

    try std.testing.expectEqual(pane_one_node_id, findPaneNodeId(&document, "%1").?);
    try std.testing.expectEqual(pane_three_node_id, findPaneNodeId(&document, "%3").?);
    try std.testing.expect(findPaneNodeId(&document, "%2") == null);
    try std.testing.expect(findPaneNodeId(&document, "%4") != null);

    const preserved_pane = document.findNode(pane_one_node_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("left-renamed", preserved_pane.title);
}

test "projected tmux identity keeps backend_id internal and publishes stable names" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const snapshots = [_]events.PaneSnapshot{
        .{
            .session_name = "test-session",
            .session_id = "$5",
            .window_id = "@10",
            .window_name = "main",
            .pane_id = "%20",
            .pane_title = "shell",
            .pane_active = true,
        },
    };

    const session_node_id = try reconcile.reconcileSessionSnapshots(&document, document.root_node_id, &snapshots);
    const session_node = document.findNode(session_node_id) orelse return error.TestExpectedEqual;

    try std.testing.expectEqualStrings("", session_node.content);
    try std.testing.expect(session_node.backend_id != null);
    try std.testing.expectEqualStrings("tmux-session:$5", session_node.backend_id.?);

    const window_node_id = session_node.children.items[0];
    const window_node = document.findNode(window_node_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("", window_node.content);
    try std.testing.expect(window_node.backend_id != null);
    try std.testing.expectEqualStrings("tmux-window:@10", window_node.backend_id.?);

    var json = std.array_list.Managed(u8).init(std.testing.allocator);
    defer json.deinit();
    try session_node.writeJson(json.writer());
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"name\":\"test-session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"backendId\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"content\":\"\"") != null);

    const session_node_id_again = try reconcile.reconcileSessionSnapshots(&document, document.root_node_id, &snapshots);
    try std.testing.expectEqual(session_node_id, session_node_id_again);
}

test "findChildByBackendId matches projected window nodes" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const snapshots = [_]events.PaneSnapshot{
        .{
            .session_name = "s",
            .session_id = "$0",
            .window_id = "@1",
            .window_name = "win",
            .pane_id = "%1",
            .pane_title = "p",
            .pane_active = true,
        },
    };

    const session_id = try reconcile.reconcileSessionSnapshots(&document, document.root_node_id, &snapshots);
    const found = document.findChildByBackendId(session_id, .subdocument, "tmux-window:@1");
    try std.testing.expect(found != null);
    const node = document.findNode(found.?) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("win", node.title);

    try node.setTitle(std.testing.allocator, "renamed-win");
    try std.testing.expectEqualStrings("renamed-win", node.title);
    try std.testing.expectEqualStrings("", node.content);
}

test "tmux snapshot reconcile rejects empty snapshots" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    try std.testing.expectError(
        error.EmptySnapshot,
        reconcile.reconcileSessionSnapshots(&document, document.root_node_id, &.{}),
    );
}

test "tmux snapshot reconcile rejects mixed-session snapshots" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const mixed = [_]events.PaneSnapshot{
        .{
            .session_name = "demo-session-a",
            .session_id = "$0",
            .window_id = "@1",
            .window_name = "editor",
            .pane_id = "%1",
            .pane_title = "left",
            .pane_active = true,
        },
        .{
            .session_name = "demo-session-b",
            .session_id = "$1",
            .window_id = "@2",
            .window_name = "logs",
            .pane_id = "%2",
            .pane_title = "right",
            .pane_active = false,
        },
    };

    try std.testing.expectError(
        error.MixedSessionSnapshot,
        reconcile.reconcileSessionSnapshots(&document, document.root_node_id, &mixed),
    );
}

fn findPaneNodeId(document: *muxly.document.Document, pane_id: []const u8) ?muxly.ids.NodeId {
    for (document.nodes.items) |node| {
        if (node.kind != .tty_leaf) continue;
        switch (node.source) {
            .tty => |tty| {
                if (tty.pane_id) |value| {
                    if (std.mem.eql(u8, value, pane_id)) return node.id;
                }
            },
            else => {},
        }
    }
    return null;
}
