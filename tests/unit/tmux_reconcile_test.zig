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
