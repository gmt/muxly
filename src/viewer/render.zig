const std = @import("std");

pub const Renderer = struct {
    supports_mouse: bool = false,
};

pub fn renderDocumentValue(
    allocator: std.mem.Allocator,
    document_value: std.json.Value,
    writer: anytype,
) !void {
    if (document_value != .object) return error.InvalidDocument;

    const title = document_value.object.get("title") orelse return error.InvalidDocument;
    const root_node_id = document_value.object.get("rootNodeId") orelse return error.InvalidDocument;
    const view_root_node_id = document_value.object.get("viewRootNodeId") orelse return error.InvalidDocument;
    const elided_node_ids = document_value.object.get("elidedNodeIds") orelse return error.InvalidDocument;
    const nodes = document_value.object.get("nodes") orelse return error.InvalidDocument;

    if (title != .string or root_node_id != .integer or nodes != .array or elided_node_ids != .array) return error.InvalidDocument;

    try writer.print("muxview :: {s}\n", .{title.string});
    try writer.writeAll("view-state :: shared-document\n");
    try writer.writeAll("follow-tail :: stored-node-preference\n");
    try writer.writeAll("tmux-backend :: hybrid-control-invalidation\n");
    const start_node_id: u64 = if (view_root_node_id == .integer)
        @intCast(view_root_node_id.integer)
    else
        @intCast(root_node_id.integer);
    if (view_root_node_id == .integer) {
        const scope_node = findNode(nodes.array.items, start_node_id) orelse return error.InvalidDocument;
        const scope_title = scope_node.object.get("title") orelse return error.InvalidDocument;
        if (scope_title != .string) return error.InvalidDocument;

        try writer.print("scope :: node {d} ({s})\n", .{ start_node_id, scope_title.string });
        try writer.writeAll("path :: ");
        try writeBreadcrumb(allocator, nodes.array.items, start_node_id, writer);
        try writer.writeAll("\n");
        try writer.writeAll("back-out :: muxly view clear-root | muxly view reset\n");
    } else {
        try writer.writeAll("scope :: document root\n");
    }
    try writer.writeAll("\n");
    try renderNodeTree(nodes.array.items, elided_node_ids.array.items, start_node_id, 0, writer);
}

fn renderNodeTree(
    nodes: []const std.json.Value,
    elided_node_ids: []const std.json.Value,
    node_id: u64,
    depth: usize,
    writer: anytype,
) !void {
    const node = findNode(nodes, node_id) orelse return error.InvalidDocument;
    const id = node.object.get("id") orelse return error.InvalidDocument;
    const title = node.object.get("title") orelse return error.InvalidDocument;
    const kind = node.object.get("kind") orelse return error.InvalidDocument;
    const lifecycle = node.object.get("lifecycle") orelse return error.InvalidDocument;
    const content = node.object.get("content") orelse return error.InvalidDocument;
    const follow_tail = node.object.get("followTail") orelse return error.InvalidDocument;
    const source = node.object.get("source") orelse return error.InvalidDocument;
    const children = node.object.get("children") orelse return error.InvalidDocument;

    if (id != .integer or title != .string or kind != .string or lifecycle != .string or content != .string or follow_tail != .bool or source != .object or children != .array) return error.InvalidDocument;

    const lifecycle_name = try validateLifecycle(lifecycle.string);
    const source_label = try describeSourceLabel(source);

    for (0..depth) |_| try writer.writeAll("  ");
    try writer.print("- {s} [id={d}, kind={s}, lifecycle={s}, source={s}, tail={s}]\n", .{
        title.string,
        @as(u64, @intCast(id.integer)),
        kind.string,
        lifecycle_name,
        source_label,
        if (follow_tail.bool) "follow" else "manual",
    });

    try writeSourceMetadata(source, lifecycle_name, depth + 1, writer);

    if (content.string.len != 0 and shouldRenderContent(kind.string, children.array.items.len)) {
        var line_it = std.mem.splitScalar(u8, content.string, '\n');
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            for (0..depth + 1) |_| try writer.writeAll("  ");
            try writer.print("> {s}\n", .{line});
        }
    }

    if (isElided(elided_node_ids, node_id)) {
        for (0..depth + 1) |_| try writer.writeAll("  ");
        try writer.writeAll("… elided by shared view state …\n");
        return;
    }

    for (children.array.items) |child| {
        if (child != .integer) return error.InvalidDocument;
        try renderNodeTree(nodes, elided_node_ids, @intCast(child.integer), depth + 1, writer);
    }
}

fn findNode(nodes: []const std.json.Value, node_id: u64) ?std.json.Value {
    for (nodes) |node| {
        if (node != .object) continue;
        const id_value = node.object.get("id") orelse continue;
        if (id_value != .integer) continue;
        if (@as(u64, @intCast(id_value.integer)) == node_id) return node;
    }
    return null;
}

fn isElided(elided_node_ids: []const std.json.Value, node_id: u64) bool {
    for (elided_node_ids) |value| {
        if (value != .integer) continue;
        if (@as(u64, @intCast(value.integer)) == node_id) return true;
    }
    return false;
}

fn writeBreadcrumb(
    allocator: std.mem.Allocator,
    nodes: []const std.json.Value,
    start_node_id: u64,
    writer: anytype,
) !void {
    var chain = std.array_list.Managed(u64).init(allocator);
    defer chain.deinit();

    var cursor: ?u64 = start_node_id;
    while (cursor) |current| {
        try chain.append(current);
        const node = findNode(nodes, current) orelse return error.InvalidDocument;
        const parent_id = node.object.get("parentId") orelse break;
        if (parent_id != .integer) break;
        cursor = @intCast(parent_id.integer);
    }

    var index = chain.items.len;
    while (index > 0) {
        index -= 1;
        const node = findNode(nodes, chain.items[index]) orelse return error.InvalidDocument;
        const title = node.object.get("title") orelse return error.InvalidDocument;
        if (title != .string) return error.InvalidDocument;
        if (index != chain.items.len - 1) try writer.writeAll(" / ");
        try writer.writeAll(title.string);
    }
}

fn describeSourceLabel(source: std.json.Value) ![]const u8 {
    const kind = source.object.get("kind") orelse return error.InvalidDocument;
    if (kind != .string) return error.InvalidDocument;

    if (std.mem.eql(u8, kind.string, "none")) return "synthetic";

    if (std.mem.eql(u8, kind.string, "tty")) {
        if (source.object.get("paneId")) |pane_id| {
            if (pane_id != .string) return error.InvalidDocument;
            return pane_id.string;
        }
        const session_name = source.object.get("sessionName") orelse return error.InvalidDocument;
        if (session_name != .string) return error.InvalidDocument;
        return session_name.string;
    }

    if (std.mem.eql(u8, kind.string, "terminal_artifact")) {
        const artifact_kind = source.object.get("artifactKind") orelse return error.InvalidDocument;
        if (artifact_kind != .string) return error.InvalidDocument;
        if (std.mem.eql(u8, artifact_kind.string, "text")) return "artifact:text";
        if (std.mem.eql(u8, artifact_kind.string, "surface")) return "artifact:surface";
        return error.InvalidDocument;
    }

    if (std.mem.eql(u8, kind.string, "file")) {
        const path = source.object.get("path") orelse return error.InvalidDocument;
        if (path != .string) return error.InvalidDocument;
        return path.string;
    }

    return kind.string;
}

fn shouldRenderContent(kind: []const u8, child_count: usize) bool {
    if (std.mem.eql(u8, kind, "scroll_region")) return true;
    return child_count == 0;
}

fn validateLifecycle(lifecycle: []const u8) ![]const u8 {
    if (std.mem.eql(u8, lifecycle, "live")) return "live";
    if (std.mem.eql(u8, lifecycle, "read_only")) return "read_only";
    if (std.mem.eql(u8, lifecycle, "frozen")) return "frozen";
    if (std.mem.eql(u8, lifecycle, "detached")) return "detached";
    return error.InvalidDocument;
}

fn writeSourceMetadata(
    source: std.json.Value,
    lifecycle: []const u8,
    depth: usize,
    writer: anytype,
) !void {
    const kind = source.object.get("kind") orelse return error.InvalidDocument;
    if (kind != .string) return error.InvalidDocument;

    if (std.mem.eql(u8, kind.string, "tty") and std.mem.eql(u8, lifecycle, "detached")) {
        try writeIndentedPrefix(depth, writer);
        try writer.writeAll("state :: detached tty source\n");
        return;
    }

    if (!std.mem.eql(u8, kind.string, "terminal_artifact")) return;

    const artifact_kind = try requireEnumString(source, "artifactKind", &.{ "text", "surface" });
    _ = artifact_kind;
    const content_format = try requireEnumString(source, "contentFormat", &.{ "plain_text", "sectioned_text" });
    const origin = try requireEnumString(source, "origin", &.{ "tty" });
    const sections = source.object.get("sections") orelse return error.InvalidDocument;
    if (sections != .array) return error.InvalidDocument;

    try writeIndentedPrefix(depth, writer);
    try writer.print("artifact :: origin={s}", .{origin});
    if (source.object.get("sessionName")) |session_name| {
        if (session_name != .string) return error.InvalidDocument;
        try writer.print(", session={s}", .{session_name.string});
    }
    if (source.object.get("windowId")) |window_id| {
        if (window_id != .string) return error.InvalidDocument;
        try writer.print(", window={s}", .{window_id.string});
    }
    if (source.object.get("paneId")) |pane_id| {
        if (pane_id != .string) return error.InvalidDocument;
        try writer.print(", pane={s}", .{pane_id.string});
    }
    try writer.print(", format={s}, sections=", .{content_format});
    try writeArtifactSections(sections.array.items, writer);
    try writer.writeAll("\n");
}

fn requireEnumString(source: std.json.Value, field_name: []const u8, valid_values: []const []const u8) ![]const u8 {
    const value = source.object.get(field_name) orelse return error.InvalidDocument;
    if (value != .string) return error.InvalidDocument;
    for (valid_values) |valid_value| {
        if (std.mem.eql(u8, value.string, valid_value)) return value.string;
    }
    return error.InvalidDocument;
}

fn writeArtifactSections(sections: []const std.json.Value, writer: anytype) !void {
    if (sections.len == 0) {
        try writer.writeAll("none");
        return;
    }

    for (sections, 0..) |section, index| {
        if (section != .string) return error.InvalidDocument;
        if (!std.mem.eql(u8, section.string, "surface") and !std.mem.eql(u8, section.string, "alternate")) {
            return error.InvalidDocument;
        }
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll(section.string);
    }
}

fn writeIndentedPrefix(depth: usize, writer: anytype) !void {
    for (0..depth) |_| try writer.writeAll("  ");
}
