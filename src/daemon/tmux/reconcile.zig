const std = @import("std");
const document_mod = @import("../../core/document.zig");
const ids = @import("../../core/ids.zig");
const muxml = @import("../../core/muxml.zig");
const source_mod = @import("../../core/source.zig");
const types = @import("../../core/types.zig");
const events = @import("events.zig");

const session_marker_prefix = "tmux-session:";
const window_marker_prefix = "tmux-window:";

pub const SessionProjectionRef = struct {
    node_id: ids.NodeId,
    parent_id: ids.NodeId,
    session_id: []u8,

    pub fn deinit(self: *SessionProjectionRef, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
    }
};

pub fn reconcileSessionSnapshots(
    document: *document_mod.Document,
    parent_id: ids.NodeId,
    snapshots: []const events.PaneSnapshot,
) !ids.NodeId {
    if (snapshots.len == 0) return error.EmptySnapshot;

    const first = snapshots[0];
    for (snapshots[1..]) |snapshot| {
        if (!std.mem.eql(u8, snapshot.session_id, first.session_id)) return error.MixedSessionSnapshot;
    }

    const session_node_id = try ensureSessionNode(document, parent_id, first);

    var desired_window_ids = std.array_list.Managed([]const u8).init(document.allocator);
    defer desired_window_ids.deinit();

    for (snapshots) |snapshot| {
        if (!containsString(desired_window_ids.items, snapshot.window_id)) {
            try desired_window_ids.append(snapshot.window_id);
        }
        const window_node_id = try ensureWindowNode(document, session_node_id, snapshot);
        _ = try ensurePaneNode(document, window_node_id, snapshot);
    }

    const session_node = document.findNode(session_node_id) orelse return error.UnknownNode;
    const window_children = try document.allocator.dupe(ids.NodeId, session_node.children.items);
    defer document.allocator.free(window_children);

    for (window_children) |window_node_id| {
        const window_node = document.findNode(window_node_id) orelse continue;
        if (!isWindowProjection(window_node)) continue;

        const window_marker = markerSuffix(window_node.content, window_marker_prefix) orelse continue;
        if (!containsString(desired_window_ids.items, window_marker)) {
            try removeSubtree(document, window_node_id);
            continue;
        }

        try pruneMissingPanes(document, window_node_id, snapshots);
    }

    return session_node_id;
}

pub fn findSessionProjectionNode(
    document: *document_mod.Document,
    session_id: []const u8,
) ?ids.NodeId {
    return findProjectedChild(document, document.root_node_id, .subdocument, session_marker_prefix, session_id) orelse blk: {
        for (document.nodes.items) |node| {
            if (node.kind != .subdocument) continue;
            if (markerMatches(node.content, session_marker_prefix, session_id)) break :blk node.id;
        }
        break :blk null;
    };
}

pub fn removeSessionProjection(
    document: *document_mod.Document,
    session_id: []const u8,
) !bool {
    const session_node_id = findSessionProjectionNode(document, session_id) orelse return false;
    try removeSubtree(document, session_node_id);
    return true;
}

pub fn listSessionProjections(
    document: *document_mod.Document,
    allocator: std.mem.Allocator,
) ![]SessionProjectionRef {
    var projections = std.array_list.Managed(SessionProjectionRef).init(allocator);
    errdefer {
        for (projections.items) |*projection| projection.deinit(allocator);
        projections.deinit();
    }

    for (document.nodes.items) |node| {
        if (node.kind != .subdocument) continue;
        const session_id = markerSuffix(node.content, session_marker_prefix) orelse continue;
        const parent_id = node.parent_id orelse continue;
        try projections.append(.{
            .node_id = node.id,
            .parent_id = parent_id,
            .session_id = try allocator.dupe(u8, session_id),
        });
    }

    return try projections.toOwnedSlice();
}

pub fn findSessionIdForPaneNode(
    document: *document_mod.Document,
    pane_node_id: ids.NodeId,
) ?[]const u8 {
    var cursor = pane_node_id;
    while (true) {
        const node = document.findNode(cursor) orelse return null;
        if (markerSuffix(node.content, session_marker_prefix)) |session_id| return session_id;
        cursor = node.parent_id orelse return null;
    }
}

fn ensureSessionNode(
    document: *document_mod.Document,
    parent_id: ids.NodeId,
    snapshot: events.PaneSnapshot,
) !ids.NodeId {
    if (findProjectedChild(document, parent_id, .subdocument, session_marker_prefix, snapshot.session_id)) |node_id| {
        const node = document.findNode(node_id) orelse return error.UnknownNode;
        try node.setTitle(document.allocator, snapshot.session_name);
        try setMarkerContent(document, node_id, session_marker_prefix, snapshot.session_id);
        return node_id;
    }

    const node_id = try document.appendNode(parent_id, .subdocument, snapshot.session_name, .{ .none = {} });
    try setMarkerContent(document, node_id, session_marker_prefix, snapshot.session_id);
    return node_id;
}

fn ensureWindowNode(
    document: *document_mod.Document,
    session_node_id: ids.NodeId,
    snapshot: events.PaneSnapshot,
) !ids.NodeId {
    const window_title = if (snapshot.window_name.len != 0) snapshot.window_name else snapshot.window_id;
    if (findProjectedChild(document, session_node_id, .subdocument, window_marker_prefix, snapshot.window_id)) |node_id| {
        const node = document.findNode(node_id) orelse return error.UnknownNode;
        try node.setTitle(document.allocator, window_title);
        try setMarkerContent(document, node_id, window_marker_prefix, snapshot.window_id);
        return node_id;
    }

    const node_id = try document.appendNode(session_node_id, .subdocument, window_title, .{ .none = {} });
    try setMarkerContent(document, node_id, window_marker_prefix, snapshot.window_id);
    return node_id;
}

fn ensurePaneNode(
    document: *document_mod.Document,
    window_node_id: ids.NodeId,
    snapshot: events.PaneSnapshot,
) !ids.NodeId {
    const pane_title = if (snapshot.pane_title.len != 0) snapshot.pane_title else snapshot.pane_id;
    if (findPaneChild(document, window_node_id, snapshot.pane_id)) |node_id| {
        const node = document.findNode(node_id) orelse return error.UnknownNode;
        try node.setTitle(document.allocator, pane_title);
        try setPaneSource(document, node_id, snapshot);
        return node_id;
    }

    const source: source_mod.Source = .{ .tty = .{
        .session_name = @constCast(snapshot.session_name),
        .window_id = @constCast(snapshot.window_id),
        .pane_id = @constCast(snapshot.pane_id),
    } };
    const node_id = try document.appendNode(window_node_id, .tty_leaf, pane_title, source);
    return node_id;
}

fn pruneMissingPanes(
    document: *document_mod.Document,
    window_node_id: ids.NodeId,
    snapshots: []const events.PaneSnapshot,
) !void {
    const window_node = document.findNode(window_node_id) orelse return error.UnknownNode;
    const child_ids = try document.allocator.dupe(ids.NodeId, window_node.children.items);
    defer document.allocator.free(child_ids);

    for (child_ids) |child_id| {
        const child = document.findNode(child_id) orelse continue;
        if (child.kind != .tty_leaf) continue;

        const pane_id = switch (child.source) {
            .tty => |tty| tty.pane_id orelse continue,
            else => continue,
        };
        if (!snapshotContainsPane(snapshots, pane_id)) {
            try removeSubtree(document, child_id);
        }
    }
}

fn setPaneSource(
    document: *document_mod.Document,
    node_id: ids.NodeId,
    snapshot: events.PaneSnapshot,
) !void {
    const node = document.findNode(node_id) orelse return error.UnknownNode;
    node.source.deinit(document.allocator);
    node.source = .{ .tty = .{
        .session_name = try document.allocator.dupe(u8, snapshot.session_name),
        .window_id = try document.allocator.dupe(u8, snapshot.window_id),
        .pane_id = try document.allocator.dupe(u8, snapshot.pane_id),
    } };
}

fn findProjectedChild(
    document: *document_mod.Document,
    parent_id: ids.NodeId,
    kind: types.NodeKind,
    marker_prefix: []const u8,
    marker_value: []const u8,
) ?ids.NodeId {
    const parent = document.findNode(parent_id) orelse return null;
    for (parent.children.items) |child_id| {
        const child = document.findNode(child_id) orelse continue;
        if (child.kind != kind) continue;
        if (markerMatches(child.content, marker_prefix, marker_value)) return child_id;
    }
    return null;
}

fn findPaneChild(
    document: *document_mod.Document,
    parent_id: ids.NodeId,
    pane_id: []const u8,
) ?ids.NodeId {
    const parent = document.findNode(parent_id) orelse return null;
    for (parent.children.items) |child_id| {
        const child = document.findNode(child_id) orelse continue;
        if (child.kind != .tty_leaf) continue;
        switch (child.source) {
            .tty => |tty| {
                if (tty.pane_id) |value| {
                    if (std.mem.eql(u8, value, pane_id)) return child_id;
                }
            },
            else => {},
        }
    }
    return null;
}

fn isWindowProjection(node: *const muxml.Node) bool {
    return node.kind == .subdocument and std.mem.startsWith(u8, node.content, window_marker_prefix);
}

fn removeSubtree(document: *document_mod.Document, node_id: ids.NodeId) !void {
    const node = document.findNode(node_id) orelse return error.UnknownNode;
    const child_ids = try document.allocator.dupe(ids.NodeId, node.children.items);
    defer document.allocator.free(child_ids);

    for (child_ids) |child_id| try removeSubtree(document, child_id);
    try document.removeNode(node_id);
}

fn setMarkerContent(
    document: *document_mod.Document,
    node_id: ids.NodeId,
    marker_prefix: []const u8,
    marker_value: []const u8,
) !void {
    const marker = try std.fmt.allocPrint(document.allocator, "{s}{s}", .{ marker_prefix, marker_value });
    defer document.allocator.free(marker);
    try document.setNodeContent(node_id, marker);
}

fn markerMatches(content: []const u8, marker_prefix: []const u8, marker_value: []const u8) bool {
    return content.len == marker_prefix.len + marker_value.len and
        std.mem.startsWith(u8, content, marker_prefix) and
        std.mem.eql(u8, content[marker_prefix.len..], marker_value);
}

fn markerSuffix(content: []const u8, marker_prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, marker_prefix)) return null;
    return content[marker_prefix.len..];
}

fn containsString(items: []const []const u8, target: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, target)) return true;
    }
    return false;
}

fn snapshotContainsPane(snapshots: []const events.PaneSnapshot, pane_id: []const u8) bool {
    for (snapshots) |snapshot| {
        if (std.mem.eql(u8, snapshot.pane_id, pane_id)) return true;
    }
    return false;
}
