const std = @import("std");
const ids = @import("ids.zig");
const muxml = @import("muxml.zig");
const source_mod = @import("source.zig");
const types = @import("types.zig");

pub const Document = struct {
    allocator: std.mem.Allocator,
    id: ids.DocumentId,
    title: []u8,
    lifecycle: types.LifecycleState = .live,
    root_node_id: ids.NodeId,
    view_root_node_id: ?ids.NodeId = null,
    nodes: std.ArrayListUnmanaged(muxml.Node) = .{},
    elided_node_ids: std.ArrayListUnmanaged(ids.NodeId) = .{},
    next_node_id: ids.NodeId,

    pub fn init(allocator: std.mem.Allocator, id: ids.DocumentId, title: []const u8) !Document {
        var document = Document{
            .allocator = allocator,
            .id = id,
            .title = try allocator.dupe(u8, title),
            .root_node_id = 1,
            .next_node_id = 2,
        };
        var root_node = try muxml.Node.init(
            allocator,
            1,
            .document,
            title,
            null,
            .{ .none = {} },
        );
        root_node.follow_tail = false;
        try document.nodes.append(allocator, root_node);
        return document;
    }

    pub fn deinit(self: *Document) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.elided_node_ids.deinit(self.allocator);
        self.allocator.free(self.title);
    }

    pub fn appendNode(
        self: *Document,
        parent_id: ids.NodeId,
        kind: types.NodeKind,
        title: []const u8,
        source: source_mod.Source,
    ) !ids.NodeId {
        const parent_index = self.findNodeIndex(parent_id) orelse return error.UnknownParent;
        const node_id = self.nextNodeId();
        var node = try muxml.Node.init(self.allocator, node_id, kind, title, parent_id, source);
        if (kind == .static_file_leaf) node.follow_tail = false;
        try self.nodes.append(self.allocator, node);
        try self.nodes.items[parent_index].children.append(self.allocator, node_id);
        return node_id;
    }

    pub fn appendTextToNode(self: *Document, node_id: ids.NodeId, chunk: []const u8) !void {
        const index = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        try self.nodes.items[index].appendContent(self.allocator, chunk);
    }

    pub fn setNodeContent(self: *Document, node_id: ids.NodeId, content: []const u8) !void {
        const index = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        try self.nodes.items[index].setContent(self.allocator, content);
    }

    pub fn setNodeTitle(self: *Document, node_id: ids.NodeId, title: []const u8) !void {
        const index = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        try self.nodes.items[index].setTitle(self.allocator, title);
    }

    pub fn findNode(self: *Document, node_id: ids.NodeId) ?*muxml.Node {
        const index = self.findNodeIndex(node_id) orelse return null;
        return &self.nodes.items[index];
    }

    pub fn removeNode(self: *Document, node_id: ids.NodeId) !void {
        const index = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        if (self.nodes.items[index].children.items.len != 0) return error.NodeHasChildren;

        if (self.nodes.items[index].parent_id) |parent_id| {
            const parent_index = self.findNodeIndex(parent_id) orelse return error.UnknownParent;
            var child_index: ?usize = null;
            for (self.nodes.items[parent_index].children.items, 0..) |child_id, idx| {
                if (child_id == node_id) {
                    child_index = idx;
                    break;
                }
            }
            if (child_index) |idx| {
                _ = self.nodes.items[parent_index].children.swapRemove(idx);
            }
        }

        self.nodes.items[index].deinit(self.allocator);
        _ = self.nodes.swapRemove(index);

        if (self.view_root_node_id != null and self.view_root_node_id.? == node_id) {
            self.view_root_node_id = null;
        }

        for (self.elided_node_ids.items, 0..) |elided_id, idx| {
            if (elided_id == node_id) {
                _ = self.elided_node_ids.swapRemove(idx);
                break;
            }
        }
    }

    pub fn freeze(self: *Document) void {
        self.lifecycle = .frozen;
    }

    pub fn freezeTtyNodeAsArtifact(
        self: *Document,
        node_id: ids.NodeId,
        artifact_kind: source_mod.TerminalArtifactKind,
        sections: source_mod.TerminalArtifactSections,
    ) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        const artifact = switch (node.source) {
            .tty => |tty| try source_mod.TerminalArtifactSource.fromTty(self.allocator, tty, artifact_kind, sections),
            else => return error.InvalidSourceKind,
        };
        node.source.deinit(self.allocator);
        node.source = .{ .terminal_artifact = artifact };
        node.lifecycle = .frozen;
    }

    pub fn thawDetached(self: *Document) void {
        self.lifecycle = .detached;
    }

    pub fn setViewRoot(self: *Document, node_id: ids.NodeId) !void {
        _ = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        self.view_root_node_id = node_id;
    }

    pub fn clearViewRoot(self: *Document) void {
        self.view_root_node_id = null;
    }

    pub fn resetView(self: *Document) void {
        self.view_root_node_id = null;
        self.elided_node_ids.clearRetainingCapacity();
    }

    pub fn toggleElided(self: *Document, node_id: ids.NodeId) !void {
        _ = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        for (self.elided_node_ids.items, 0..) |existing, index| {
            if (existing == node_id) {
                _ = self.elided_node_ids.swapRemove(index);
                return;
            }
        }
        try self.elided_node_ids.append(self.allocator, node_id);
    }

    pub fn setElided(self: *Document, node_id: ids.NodeId, enabled: bool) !void {
        _ = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        for (self.elided_node_ids.items, 0..) |existing, index| {
            if (existing == node_id) {
                if (!enabled) _ = self.elided_node_ids.swapRemove(index);
                return;
            }
        }
        if (enabled) try self.elided_node_ids.append(self.allocator, node_id);
    }

    pub fn setFollowTail(self: *Document, node_id: ids.NodeId, enabled: bool) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        node.follow_tail = enabled;
    }

    pub fn writeJson(self: *const Document, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"id\":{d},", .{self.id});
        try writer.writeAll("\"title\":");
        try writer.print("{f}", .{std.json.fmt(self.title, .{})});
        try writer.print(",\"lifecycle\":\"{s}\",", .{@tagName(self.lifecycle)});
        try writer.print("\"rootNodeId\":{d},", .{self.root_node_id});
        if (self.view_root_node_id) |view_root_node_id| {
            try writer.print("\"viewRootNodeId\":{d},", .{view_root_node_id});
        } else {
            try writer.writeAll("\"viewRootNodeId\":null,");
        }
        try writer.writeAll("\"elidedNodeIds\":[");
        for (self.elided_node_ids.items, 0..) |elided, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.print("{d}", .{elided});
        }
        try writer.writeAll("],\"nodes\":[");
        for (self.nodes.items, 0..) |node, index| {
            if (index != 0) try writer.writeAll(",");
            try node.writeJson(writer);
        }
        try writer.writeAll("]}");
    }

    pub fn writeStatusJson(self: *const Document, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"id\":{d},", .{self.id});
        try writer.print("\"lifecycle\":\"{s}\",", .{@tagName(self.lifecycle)});
        try writer.print("\"rootNodeId\":{d},", .{self.root_node_id});
        if (self.view_root_node_id) |view_root_node_id| {
            try writer.print("\"viewRootNodeId\":{d},", .{view_root_node_id});
        } else {
            try writer.writeAll("\"viewRootNodeId\":null,");
        }
        try writer.print("\"nodeCount\":{d},", .{self.nodes.items.len});
        try writer.print("\"elidedCount\":{d}", .{self.elided_node_ids.items.len});
        try writer.writeAll("}");
    }

    pub fn writeXml(self: *const Document, writer: anytype) !void {
        try writer.print("<muxml id=\"{d}\" lifecycle=\"{s}\">", .{
            self.id,
            @tagName(self.lifecycle),
        });
        try writer.writeAll("<title>");
        try writeEscapedXml(writer, self.title);
        try writer.writeAll("</title><nodes>");
        for (self.nodes.items) |node| try node.writeXml(writer);
        try writer.writeAll("</nodes></muxml>");
    }

    fn findNodeIndex(self: *Document, node_id: ids.NodeId) ?usize {
        for (self.nodes.items, 0..) |node, index| {
            if (node.id == node_id) return index;
        }
        return null;
    }

    fn nextNodeId(self: *Document) ids.NodeId {
        const id = self.next_node_id;
        self.next_node_id += 1;
        return id;
    }
};

fn writeEscapedXml(writer: anytype, value: []const u8) !void {
    for (value) |char| switch (char) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        else => try writer.writeByte(char),
    };
}
