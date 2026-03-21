//! Live TOM document ownership and mutation helpers.
//!
//! A `Document` is the daemon-owned root of one live Terminal Object Model. It
//! owns node identity, parent/child linkage, lifecycle, and the current
//! document-scoped view state such as shared root and elision.

const std = @import("std");
const ids = @import("ids.zig");
const limits = @import("limits.zig");
const muxml = @import("muxml.zig");
const source_mod = @import("source.zig");
const types = @import("types.zig");

/// Daemon-owned live TOM document.
pub const Document = struct {
    allocator: std.mem.Allocator,
    id: ids.DocumentId,
    title: []u8,
    lifecycle: types.LifecycleState = .live,
    root_node_id: ids.NodeId,
    view_root_node_id: ?ids.NodeId = null,
    nodes: std.ArrayListUnmanaged(muxml.Node) = .{},
    elided_node_ids: std.ArrayListUnmanaged(ids.NodeId) = .{},
    content_bytes: usize = 0,
    next_node_id: ids.NodeId,

    /// Initializes a new live document with a root `document` node.
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
        root_node.name = try muxml.defaultNodeName(allocator, title);
        root_node.follow_tail = false;
        try document.nodes.append(allocator, root_node);
        return document;
    }

    /// Releases all document-owned nodes and shared view state.
    pub fn deinit(self: *Document) void {
        for (self.nodes.items) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.elided_node_ids.deinit(self.allocator);
        self.allocator.free(self.title);
    }

    /// Appends a child node beneath `parent_id`.
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
        node.name = try self.defaultChildName(parent_id, title);
        if (kind == .static_file_leaf) node.follow_tail = false;
        try self.nodes.append(self.allocator, node);
        try self.nodes.items[parent_index].children.append(self.allocator, node_id);
        return node_id;
    }

    /// Appends text to an existing node content buffer.
    pub fn appendTextToNode(self: *Document, node_id: ids.NodeId, chunk: []const u8) !void {
        return try self.appendTextToNodeWithLimit(
            node_id,
            chunk,
            limits.default_max_document_content_bytes,
        );
    }

    fn appendTextToNodeWithLimit(
        self: *Document,
        node_id: ids.NodeId,
        chunk: []const u8,
        max_content_bytes: usize,
    ) !void {
        const index = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        try self.reserveAdditionalContentBytes(chunk.len, max_content_bytes);
        try self.nodes.items[index].appendContent(self.allocator, chunk);
        self.content_bytes += chunk.len;
    }

    /// Replaces a node's content.
    pub fn setNodeContent(self: *Document, node_id: ids.NodeId, content: []const u8) !void {
        return try self.setNodeContentWithLimit(
            node_id,
            content,
            limits.default_max_document_content_bytes,
        );
    }

    fn setNodeContentWithLimit(
        self: *Document,
        node_id: ids.NodeId,
        content: []const u8,
        max_content_bytes: usize,
    ) !void {
        const index = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        const existing_len = self.nodes.items[index].content.len;
        try self.reserveReplacementContentBytes(existing_len, content.len, max_content_bytes);
        try self.nodes.items[index].setContent(self.allocator, content);
        self.content_bytes = self.content_bytes - existing_len + content.len;
    }

    /// Replaces a node's title.
    pub fn setNodeTitle(self: *Document, node_id: ids.NodeId, title: []const u8) !void {
        const index = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        try self.nodes.items[index].setTitle(self.allocator, title);
    }

    /// Replaces a node's stable URL-segment name.
    pub fn setNodeName(self: *Document, node_id: ids.NodeId, name: ?[]const u8) !void {
        const index = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        if (name) |value| {
            if (self.siblingNameInUse(self.nodes.items[index].parent_id, node_id, value)) {
                return error.DuplicateNodeName;
            }
        }
        try self.nodes.items[index].setName(self.allocator, name);
    }

    /// Finds a mutable node pointer by id.
    ///
    /// The returned pointer borrows from `self.nodes` and must not be retained
    /// across document mutations that can move or remove nodes.
    pub fn findNode(self: *Document, node_id: ids.NodeId) ?*muxml.Node {
        const index = self.findNodeIndex(node_id) orelse return null;
        return &self.nodes.items[index];
    }

    /// Finds an immutable node pointer by id.
    ///
    /// The returned pointer borrows from `self.nodes` and must not be retained
    /// across document mutations that can move or remove nodes.
    pub fn findNodeConst(self: *const Document, node_id: ids.NodeId) ?*const muxml.Node {
        const index = self.findNodeIndexConst(node_id) orelse return null;
        return &self.nodes.items[index];
    }

    /// Removes a leaf node from the document.
    ///
    /// Callers must remove descendants before removing a parent node.
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

        self.content_bytes -= self.nodes.items[index].content.len;
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

    /// Marks the entire document as frozen.
    pub fn freeze(self: *Document) void {
        self.lifecycle = .frozen;
    }

    /// Converts a live tty-backed node into a terminal artifact while
    /// preserving logical node identity and position in the tree.
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

    /// Marks the document as detached from its live backend pump.
    pub fn thawDetached(self: *Document) void {
        self.lifecycle = .detached;
    }

    /// Sets the shared document-scoped view root.
    pub fn setViewRoot(self: *Document, node_id: ids.NodeId) !void {
        _ = self.findNodeIndex(node_id) orelse return error.UnknownNode;
        self.view_root_node_id = node_id;
    }

    /// Clears the shared document-scoped view root.
    pub fn clearViewRoot(self: *Document) void {
        self.view_root_node_id = null;
    }

    /// Clears the shared document-scoped root and elision state.
    pub fn resetView(self: *Document) void {
        self.view_root_node_id = null;
        self.elided_node_ids.clearRetainingCapacity();
    }

    /// Toggles whether a node is hidden by shared document elision state.
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

    /// Sets whether a node is hidden by shared document elision state.
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

    /// Stores the follow-tail preference on one node.
    pub fn setFollowTail(self: *Document, node_id: ids.NodeId, enabled: bool) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        node.follow_tail = enabled;
    }

    pub fn setNodeBackendId(self: *Document, node_id: ids.NodeId, backend_id: []const u8) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        try node.setBackendId(self.allocator, backend_id);
    }

    pub fn findNodeByBackendId(self: *Document, backend_id: []const u8) ?*muxml.Node {
        for (self.nodes.items) |*node| {
            if (node.backend_id) |bid| {
                if (std.mem.eql(u8, bid, backend_id)) return node;
            }
        }
        return null;
    }

    pub fn findChildByBackendId(self: *Document, parent_id: ids.NodeId, kind: types.NodeKind, backend_id: []const u8) ?ids.NodeId {
        const parent = self.findNode(parent_id) orelse return null;
        for (parent.children.items) |child_id| {
            const child = self.findNode(child_id) orelse continue;
            if (child.kind != kind) continue;
            if (child.backend_id) |bid| {
                if (std.mem.eql(u8, bid, backend_id)) return child_id;
            }
        }
        return null;
    }

    /// Resolves a document-local selector to one node id.
    ///
    /// Selectors follow the same segment rules as TRD selectors:
    /// - empty or `/` => document root
    /// - `.` => current node
    /// - `..` => parent node
    /// - `@42`, `42`, `node-42` => direct node id references
    /// - otherwise sibling `name` matches beneath the current node
    pub fn resolveSelector(self: *const Document, selector: ?[]const u8) !ids.NodeId {
        const selector_text = selector orelse return self.root_node_id;
        if (selector_text.len == 0 or std.mem.eql(u8, selector_text, "/")) {
            return self.root_node_id;
        }

        var current_id = self.root_node_id;
        var segments = std.mem.splitScalar(u8, selector_text, '/');
        while (segments.next()) |segment_raw| {
            if (segment_raw.len == 0 or std.mem.eql(u8, segment_raw, ".")) continue;
            if (std.mem.eql(u8, segment_raw, "..")) {
                const current_node = self.findNodeConst(current_id) orelse return error.InvalidResourceSelector;
                current_id = current_node.parent_id orelse return error.ResourceSelectorEscapesRoot;
                continue;
            }

            if (parseDirectNodeReference(segment_raw)) |direct_id| {
                _ = self.findNodeConst(direct_id) orelse return error.UnknownResourceSelectorSegment;
                current_id = direct_id;
                continue;
            }

            current_id = try self.resolveChildBySegment(current_id, segment_raw);
        }

        return current_id;
    }

    /// Writes the full document payload as JSON.
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

    /// Writes a smaller lifecycle/count-oriented status payload as JSON.
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

    /// Serializes the document as muxml/XML.
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

    fn findNodeIndexConst(self: *const Document, node_id: ids.NodeId) ?usize {
        for (self.nodes.items, 0..) |node, index| {
            if (node.id == node_id) return index;
        }
        return null;
    }

    fn reserveAdditionalContentBytes(
        self: *const Document,
        additional_bytes: usize,
        max_content_bytes: usize,
    ) !void {
        if (self.content_bytes > max_content_bytes) return error.DocumentTooLarge;
        if (additional_bytes > max_content_bytes - self.content_bytes) {
            return error.DocumentTooLarge;
        }
    }

    fn reserveReplacementContentBytes(
        self: *const Document,
        existing_bytes: usize,
        replacement_bytes: usize,
        max_content_bytes: usize,
    ) !void {
        if (existing_bytes > self.content_bytes) return error.DocumentTooLarge;
        const retained_bytes = self.content_bytes - existing_bytes;
        if (retained_bytes > max_content_bytes) return error.DocumentTooLarge;
        if (replacement_bytes > max_content_bytes - retained_bytes) {
            return error.DocumentTooLarge;
        }
    }

    fn nextNodeId(self: *Document) ids.NodeId {
        const id = self.next_node_id;
        self.next_node_id += 1;
        return id;
    }

    fn defaultChildName(self: *const Document, parent_id: ids.NodeId, title: []const u8) !?[]u8 {
        const base_name = try muxml.defaultNodeName(self.allocator, title) orelse return null;
        if (!self.siblingNameInUse(parent_id, null, base_name)) return base_name;

        var suffix: usize = 2;
        while (true) : (suffix += 1) {
            const candidate = try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ base_name, suffix });
            if (!self.siblingNameInUse(parent_id, null, candidate)) {
                self.allocator.free(base_name);
                return candidate;
            }
            self.allocator.free(candidate);
        }
    }

    fn siblingNameInUse(
        self: *const Document,
        parent_id: ?ids.NodeId,
        exempt_node_id: ?ids.NodeId,
        name: []const u8,
    ) bool {
        const resolved_parent_id = parent_id orelse return false;
        const parent = self.findNodeConst(resolved_parent_id) orelse return false;
        for (parent.children.items) |child_id| {
            if (exempt_node_id != null and child_id == exempt_node_id.?) continue;
            const child = self.findNodeConst(child_id) orelse continue;
            const child_name = child.name orelse continue;
            if (std.mem.eql(u8, child_name, name)) return true;
        }
        return false;
    }

    fn resolveChildBySegment(self: *const Document, parent_id: ids.NodeId, segment: []const u8) !ids.NodeId {
        const parent = self.findNodeConst(parent_id) orelse return error.InvalidResourceSelector;

        var match_count: usize = 0;
        var matched_id: ids.NodeId = 0;

        for (parent.children.items) |child_id| {
            const child = self.findNodeConst(child_id) orelse continue;
            if (nodeMatchesSegment(child, segment)) {
                match_count += 1;
                matched_id = child_id;
            }
        }

        return switch (match_count) {
            0 => error.UnknownResourceSelectorSegment,
            1 => matched_id,
            else => error.AmbiguousResourceSelector,
        };
    }
};

fn parseDirectNodeReference(segment: []const u8) ?ids.NodeId {
    if (segment.len == 0) return null;

    if (segment[0] == '@') {
        return std.fmt.parseInt(ids.NodeId, segment[1..], 10) catch null;
    }

    if (std.mem.startsWith(u8, segment, "node-")) {
        return std.fmt.parseInt(ids.NodeId, segment["node-".len..], 10) catch null;
    }

    return std.fmt.parseInt(ids.NodeId, segment, 10) catch null;
}

fn nodeMatchesSegment(node: *const muxml.Node, segment: []const u8) bool {
    if (node.name) |name| {
        if (std.mem.eql(u8, name, segment)) return true;
    }

    var buffer: [32]u8 = undefined;
    const direct = std.fmt.bufPrint(&buffer, "{d}", .{node.id}) catch return false;
    if (std.mem.eql(u8, direct, segment)) return true;
    const with_prefix = std.fmt.bufPrint(&buffer, "node-{d}", .{node.id}) catch return false;
    return std.mem.eql(u8, with_prefix, segment);
}

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

test "document content cap is enforced across node updates and appends" {
    var document = try Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const first = try document.appendNode(
        document.root_node_id,
        .scroll_region,
        "first",
        .{ .none = {} },
    );
    const second = try document.appendNode(
        document.root_node_id,
        .scroll_region,
        "second",
        .{ .none = {} },
    );

    try document.setNodeContentWithLimit(first, "abcd", 6);
    try std.testing.expectEqual(@as(usize, 4), document.content_bytes);

    try std.testing.expectError(
        error.DocumentTooLarge,
        document.setNodeContentWithLimit(second, "xyz", 6),
    );
    try std.testing.expectEqual(@as(usize, 4), document.content_bytes);
    try std.testing.expectEqualStrings("", document.findNode(second).?.content);

    try std.testing.expectError(
        error.DocumentTooLarge,
        document.appendTextToNodeWithLimit(first, "123", 6),
    );
    try std.testing.expectEqual(@as(usize, 4), document.content_bytes);
    try std.testing.expectEqualStrings("abcd", document.findNode(first).?.content);
}
