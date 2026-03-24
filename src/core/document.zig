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
    nodes_by_id: std.AutoHashMapUnmanaged(ids.NodeId, *muxml.Node) = .{},
    node_order: std.ArrayListUnmanaged(ids.NodeId) = .{},
    elided_node_ids: std.ArrayListUnmanaged(ids.NodeId) = .{},
    content_bytes: usize = 0,
    max_content_bytes: usize = limits.default_max_document_content_bytes,
    next_node_id: ids.NodeId,

    pub const ValidationSummary = struct {
        node_count: usize,
        content_bytes: usize,
    };

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
        const root_node_ptr = try allocator.create(muxml.Node);
        errdefer allocator.destroy(root_node_ptr);
        root_node_ptr.* = root_node;

        try document.nodes_by_id.put(allocator, root_node_ptr.id, root_node_ptr);
        errdefer _ = document.nodes_by_id.remove(root_node_ptr.id);
        try document.node_order.append(allocator, root_node_ptr.id);
        return document;
    }

    /// Releases all document-owned nodes and shared view state.
    pub fn deinit(self: *Document) void {
        for (self.node_order.items) |node_id| {
            const node = self.findNode(node_id) orelse continue;
            node.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.nodes_by_id.deinit(self.allocator);
        self.node_order.deinit(self.allocator);
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
        const parent = self.findNode(parent_id) orelse return error.UnknownParent;
        const node_id = self.nextNodeId();
        var node = try muxml.Node.init(self.allocator, node_id, kind, title, parent_id, source);
        node.name = try self.defaultChildName(parent_id, title);
        if (kind == .static_file_leaf) node.follow_tail = false;
        const node_ptr = try self.allocator.create(muxml.Node);
        errdefer self.allocator.destroy(node_ptr);
        node_ptr.* = node;

        try self.nodes_by_id.put(self.allocator, node_id, node_ptr);
        errdefer _ = self.nodes_by_id.remove(node_id);
        try self.node_order.append(self.allocator, node_id);
        errdefer _ = self.node_order.pop();
        try parent.children.append(self.allocator, node_id);
        return node_id;
    }

    /// Appends text to an existing node content buffer.
    pub fn appendTextToNode(self: *Document, node_id: ids.NodeId, chunk: []const u8) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        try self.reserveAdditionalContentBytes(chunk.len, self.max_content_bytes);
        try node.appendContent(self.allocator, chunk);
        self.content_bytes += chunk.len;
    }

    /// Replaces a node's content.
    pub fn setNodeContent(self: *Document, node_id: ids.NodeId, content: []const u8) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        const existing_len = node.content.len;
        try self.reserveReplacementContentBytes(existing_len, content.len, self.max_content_bytes);
        try node.setContent(self.allocator, content);
        self.content_bytes = self.content_bytes - existing_len + content.len;
    }

    /// Updates the document-wide aggregate content cap used for node content mutations.
    pub fn setMaxContentBytes(self: *Document, max_content_bytes: usize) void {
        self.max_content_bytes = max_content_bytes;
    }

    /// Replaces a node's title.
    pub fn setNodeTitle(self: *Document, node_id: ids.NodeId, title: []const u8) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        try node.setTitle(self.allocator, title);
    }

    /// Replaces a node's stable URL-segment name.
    pub fn setNodeName(self: *Document, node_id: ids.NodeId, name: ?[]const u8) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        if (name) |value| {
            if (self.siblingNameInUse(node.parent_id, node_id, value)) {
                return error.DuplicateNodeName;
            }
        }
        try node.setName(self.allocator, name);
    }

    /// Finds a mutable node pointer by id.
    ///
    /// The returned pointer remains stable across unrelated document mutations
    /// and becomes invalid only after the pointed-at node is removed.
    pub fn findNode(self: *Document, node_id: ids.NodeId) ?*muxml.Node {
        return self.nodes_by_id.get(node_id);
    }

    /// Finds an immutable node pointer by id.
    ///
    /// The returned pointer remains stable across unrelated document mutations
    /// and becomes invalid only after the pointed-at node is removed.
    pub fn findNodeConst(self: *const Document, node_id: ids.NodeId) ?*const muxml.Node {
        return self.nodes_by_id.get(node_id);
    }

    pub fn nodeCount(self: *const Document) usize {
        return self.node_order.items.len;
    }

    pub fn nodeIdsInOrder(self: *const Document) []const ids.NodeId {
        return self.node_order.items;
    }

    /// Returns whether `candidate_id` is `root_id` or a descendant of it.
    pub fn nodeWithinSubtree(self: *const Document, root_id: ids.NodeId, candidate_id: ids.NodeId) bool {
        var current_id = candidate_id;
        while (true) {
            if (current_id == root_id) return true;
            const node = self.findNodeConst(current_id) orelse return false;
            current_id = node.parent_id orelse return false;
        }
    }

    /// Removes a leaf node from the document.
    ///
    /// Callers must remove descendants before removing a parent node.
    pub fn removeNode(self: *Document, node_id: ids.NodeId) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        if (node.children.items.len != 0) return error.NodeHasChildren;
        const node_content_len = node.content.len;
        if (node_content_len > self.content_bytes) return error.ContentAccountingDrift;

        if (node.parent_id) |parent_id| {
            const parent = self.findNode(parent_id) orelse return error.UnknownParent;
            var child_index: ?usize = null;
            for (parent.children.items, 0..) |child_id, idx| {
                if (child_id == node_id) {
                    child_index = idx;
                    break;
                }
            }
            if (child_index) |idx| {
                _ = parent.children.swapRemove(idx);
            }
        }

        self.content_bytes -= node_content_len;
        _ = self.nodes_by_id.remove(node_id);
        if (self.findNodeOrderIndex(node_id)) |order_index| {
            _ = self.node_order.orderedRemove(order_index);
        }
        node.deinit(self.allocator);
        self.allocator.destroy(node);

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

    /// Sets the current shared document-scoped view root.
    pub fn setViewRoot(self: *Document, node_id: ids.NodeId) !void {
        _ = self.findNode(node_id) orelse return error.UnknownNode;
        self.view_root_node_id = node_id;
    }

    /// Clears the current shared document-scoped view root.
    pub fn clearViewRoot(self: *Document) void {
        self.view_root_node_id = null;
    }

    /// Clears the current shared document-scoped root and elision state.
    pub fn resetView(self: *Document) void {
        self.view_root_node_id = null;
        self.elided_node_ids.clearRetainingCapacity();
    }

    /// Toggles whether a node is hidden by shared document elision state.
    pub fn toggleElided(self: *Document, node_id: ids.NodeId) !void {
        _ = self.findNode(node_id) orelse return error.UnknownNode;
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
        _ = self.findNode(node_id) orelse return error.UnknownNode;
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
        for (self.node_order.items) |node_id| {
            const node = self.findNode(node_id) orelse continue;
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
        for (self.node_order.items, 0..) |node_id, index| {
            const node = self.findNodeConst(node_id) orelse continue;
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
        try writer.print("\"nodeCount\":{d},", .{self.node_order.items.len});
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
        for (self.node_order.items) |node_id| {
            const node = self.findNodeConst(node_id) orelse continue;
            try node.writeXml(writer);
        }
        try writer.writeAll("</nodes></muxml>");
    }

    pub fn validate(self: *const Document) !ValidationSummary {
        var seen = std.AutoHashMap(ids.NodeId, void).init(self.allocator);
        defer seen.deinit();

        var computed_content_bytes: usize = 0;
        var root_found = false;

        for (self.node_order.items) |node_id| {
            const node = self.findNodeConst(node_id) orelse return error.UnknownNode;
            const entry = try seen.getOrPut(node.id);
            if (entry.found_existing) return error.DuplicateNodeId;
            computed_content_bytes += node.content.len;

            if (node.id == self.root_node_id) {
                root_found = true;
                if (node.parent_id != null) return error.RootNodeHasParent;
                if (node.kind != .document) return error.RootNodeKindMismatch;
            } else {
                const parent_id = node.parent_id orelse return error.NonRootNodeMissingParent;
                const parent = self.findNodeConst(parent_id) orelse return error.UnknownParent;

                var linked_from_parent = false;
                for (parent.children.items) |child_id| {
                    if (child_id == node.id) {
                        linked_from_parent = true;
                        break;
                    }
                }
                if (!linked_from_parent) return error.ParentMissingChildLink;
            }

            var child_seen = std.AutoHashMap(ids.NodeId, void).init(self.allocator);
            defer child_seen.deinit();
            for (node.children.items) |child_id| {
                const child_entry = try child_seen.getOrPut(child_id);
                if (child_entry.found_existing) return error.DuplicateChildLink;

                const child = self.findNodeConst(child_id) orelse return error.UnknownChild;
                if (child.parent_id == null or child.parent_id.? != node.id) {
                    return error.ChildParentMismatch;
                }
            }
        }

        if (!root_found) return error.MissingRootNode;
        if (computed_content_bytes != self.content_bytes) return error.ContentAccountingDrift;

        if (self.view_root_node_id) |view_root_node_id| {
            _ = self.findNodeConst(view_root_node_id) orelse return error.UnknownViewRootNode;
        }

        for (self.elided_node_ids.items) |node_id| {
            _ = self.findNodeConst(node_id) orelse return error.UnknownElidedNode;
        }

        return .{
            .node_count = self.node_order.items.len,
            .content_bytes = computed_content_bytes,
        };
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

    fn findNodeOrderIndex(self: *const Document, node_id: ids.NodeId) ?usize {
        for (self.node_order.items, 0..) |listed_id, index| {
            if (listed_id == node_id) return index;
        }
        return null;
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
    document.setMaxContentBytes(6);

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

    try document.setNodeContent(first, "abcd");
    try std.testing.expectEqual(@as(usize, 4), document.content_bytes);

    try std.testing.expectError(
        error.DocumentTooLarge,
        document.setNodeContent(second, "xyz"),
    );
    try std.testing.expectEqual(@as(usize, 4), document.content_bytes);
    try std.testing.expectEqualStrings("", document.findNode(second).?.content);

    try std.testing.expectError(
        error.DocumentTooLarge,
        document.appendTextToNode(first, "123"),
    );
    try std.testing.expectEqual(@as(usize, 4), document.content_bytes);
    try std.testing.expectEqualStrings("abcd", document.findNode(first).?.content);
}

test "removeNode reports content accounting drift instead of underflowing" {
    var document = try Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const node_id = try document.appendNode(
        document.root_node_id,
        .scroll_region,
        "drift",
        .{ .none = {} },
    );

    const node = document.findNode(node_id) orelse return error.TestExpectedEqual;
    try node.setContent(std.testing.allocator, "untracked-content");

    try std.testing.expectError(
        error.ContentAccountingDrift,
        document.removeNode(node_id),
    );
    try std.testing.expect(document.findNode(node_id) != null);
}
