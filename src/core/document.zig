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
    const NodeSlots = std.SegmentedList(?*muxml.Node, 256);

    allocator: std.mem.Allocator,
    id: ids.DocumentId,
    title: []u8,
    lifecycle: types.LifecycleState = .live,
    root_node_id: ids.NodeId,
    view_root_node_id: ?ids.NodeId = null,
    node_slots: NodeSlots = .{},
    live_node_count: usize = 0,
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

        try document.setNodeSlot(root_node_ptr.id, root_node_ptr);
        document.live_node_count = 1;
        return document;
    }

    /// Releases all document-owned nodes and shared view state.
    pub fn deinit(self: *Document) void {
        for (0..self.node_slots.count()) |slot_index| {
            const node = self.node_slots.at(slot_index).* orelse continue;
            node.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.node_slots.deinit(self.allocator);
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
        const node_id = self.reserveNodeId();
        const node_ptr = try self.prepareNodeWithId(node_id, parent_id, kind, title, source);
        errdefer self.destroyPreparedNode(node_ptr);
        try self.commitPreparedNode(parent_id, node_ptr);
        return node_id;
    }

    /// Reserves the next stable node id.
    pub fn reserveNodeId(self: *Document) ids.NodeId {
        return self.nextNodeId();
    }

    /// Allocates one node payload using a caller-chosen id without mutating
    /// global document registries or parent child lists.
    pub fn prepareNodeWithId(
        self: *Document,
        node_id: ids.NodeId,
        parent_id: ids.NodeId,
        kind: types.NodeKind,
        title: []const u8,
        source: source_mod.Source,
    ) !*muxml.Node {
        _ = self.findNode(parent_id) orelse return error.UnknownParent;

        var node = try muxml.Node.init(self.allocator, node_id, kind, title, parent_id, source);
        errdefer node.deinit(self.allocator);
        node.name = try self.defaultChildName(parent_id, title);
        if (kind == .static_file_leaf) node.follow_tail = false;

        const node_ptr = try self.allocator.create(muxml.Node);
        errdefer self.allocator.destroy(node_ptr);
        node_ptr.* = node;
        return node_ptr;
    }

    /// Releases a node prepared by `prepareNodeWithId` that was never committed.
    pub fn destroyPreparedNode(self: *Document, node_ptr: *muxml.Node) void {
        node_ptr.deinit(self.allocator);
        self.allocator.destroy(node_ptr);
    }

    /// Commits one previously prepared node into the document registry and
    /// parent child list.
    pub fn commitPreparedNode(
        self: *Document,
        parent_id: ids.NodeId,
        node_ptr: *muxml.Node,
    ) !void {
        const parent = self.findNode(parent_id) orelse return error.UnknownParent;

        try parent.children.append(self.allocator, node_ptr.id);
        errdefer _ = parent.children.pop();

        try self.setNodeSlot(node_ptr.id, node_ptr);
        self.live_node_count += 1;
    }

    /// Appends text to an existing node content buffer.
    pub fn appendTextToNode(self: *Document, node_id: ids.NodeId, chunk: []const u8) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        try self.appendTextToStableNode(node, chunk);
    }

    /// Appends text to one stable node pointer that the caller has already
    /// resolved safely.
    pub fn appendTextToStableNode(self: *Document, node: *muxml.Node, chunk: []const u8) !void {
        try self.reserveAdditionalContentBytes(chunk.len, self.max_content_bytes);
        try node.appendContent(self.allocator, chunk);
        self.content_bytes += chunk.len;
    }

    /// Replaces a node's content.
    pub fn setNodeContent(self: *Document, node_id: ids.NodeId, content: []const u8) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        try self.setStableNodeContent(node, content);
    }

    /// Replaces content on one stable node pointer that the caller has already
    /// resolved safely.
    pub fn setStableNodeContent(self: *Document, node: *muxml.Node, content: []const u8) !void {
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
        const slot = self.nodeSlotPtr(node_id) orelse return null;
        return slot.*;
    }

    /// Finds an immutable node pointer by id.
    ///
    /// The returned pointer remains stable across unrelated document mutations
    /// and becomes invalid only after the pointed-at node is removed.
    pub fn findNodeConst(self: *const Document, node_id: ids.NodeId) ?*const muxml.Node {
        const slot = self.nodeSlotPtrConst(node_id) orelse return null;
        return slot.*;
    }

    pub fn nodeCount(self: *const Document) usize {
        return self.live_node_count;
    }

    pub fn walkPreorder(
        self: *const Document,
        context: anytype,
        comptime visit: fn (@TypeOf(context), ids.NodeId, *const muxml.Node) anyerror!void,
    ) !void {
        _ = self.findNodeConst(self.root_node_id) orelse return error.MissingRootNode;

        var stack = std.ArrayListUnmanaged(ids.NodeId){};
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, self.root_node_id);

        while (stack.items.len != 0) {
            const node_id = stack.pop().?;
            const node = self.findNodeConst(node_id) orelse return error.UnknownNode;
            try visit(context, node_id, node);

            var index = node.children.items.len;
            while (index != 0) {
                index -= 1;
                try stack.append(self.allocator, node.children.items[index]);
            }
        }
    }

    pub fn collectPreorderNodeIdsAlloc(
        self: *const Document,
        allocator: std.mem.Allocator,
    ) ![]ids.NodeId {
        const CollectContext = struct {
            allocator: std.mem.Allocator,
            node_ids: *std.ArrayListUnmanaged(ids.NodeId),
        };

        var node_ids = std.ArrayListUnmanaged(ids.NodeId){};
        defer node_ids.deinit(allocator);

        var context = CollectContext{
            .allocator = allocator,
            .node_ids = &node_ids,
        };
        try self.walkPreorder(&context, struct {
            fn visit(ctx: *CollectContext, node_id: ids.NodeId, _: *const muxml.Node) !void {
                try ctx.node_ids.append(ctx.allocator, node_id);
            }
        }.visit);

        return try node_ids.toOwnedSlice(allocator);
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

    /// Returns the first-layer child beneath the document root that contains
    /// `node_id`, or `null` when `node_id` is the root itself.
    pub fn firstLayerAncestor(self: *const Document, node_id: ids.NodeId) !?ids.NodeId {
        if (node_id == self.root_node_id) return null;

        var current_id = node_id;
        while (true) {
            const node = self.findNodeConst(current_id) orelse return error.UnknownNode;
            const parent_id = node.parent_id orelse return error.UnknownParent;
            if (parent_id == self.root_node_id) return current_id;
            current_id = parent_id;
        }
    }

    pub const ConcurrentContainerKinds = struct {
        horizontal: bool = false,
        vertical: bool = false,
    };

    /// Returns the nearest enabled concurrent domain root for `node_id`.
    ///
    /// Enabled container kinds contribute their direct children as valid domain
    /// roots; otherwise the first-layer child beneath the document root remains
    /// the fallback domain root.
    pub fn concurrentContainerDomainRoot(
        self: *const Document,
        node_id: ids.NodeId,
        enabled: ConcurrentContainerKinds,
    ) !?ids.NodeId {
        if (node_id == self.root_node_id) return null;

        var current_id = node_id;
        while (true) {
            const node = self.findNodeConst(current_id) orelse return error.UnknownNode;
            const parent_id = node.parent_id orelse return error.UnknownParent;
            if (parent_id == self.root_node_id) return current_id;

            const parent = self.findNodeConst(parent_id) orelse return error.UnknownParent;
            if (containerChildDomainsEnabled(parent.kind, enabled)) return current_id;
            current_id = parent_id;
        }
    }

    fn containerChildDomainsEnabled(kind: types.NodeKind, enabled: ConcurrentContainerKinds) bool {
        return switch (kind) {
            .h_container => enabled.horizontal,
            .v_container => enabled.vertical,
            else => false,
        };
    }

    pub fn subtreeContainsEnabledContainerKinds(
        self: *const Document,
        node_id: ids.NodeId,
        enabled: ConcurrentContainerKinds,
    ) !bool {
        const node = self.findNodeConst(node_id) orelse return error.UnknownNode;
        if (containerChildDomainsEnabled(node.kind, enabled)) return true;

        var stack = std.ArrayListUnmanaged(ids.NodeId){};
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, node_id);

        while (stack.items.len != 0) {
            const current_id = stack.pop().?;
            const current = self.findNodeConst(current_id) orelse return error.UnknownNode;
            for (current.children.items) |child_id| {
                const child = self.findNodeConst(child_id) orelse return error.UnknownChild;
                if (containerChildDomainsEnabled(child.kind, enabled)) return true;
                try stack.append(self.allocator, child_id);
            }
        }

        return false;
    }

    /// Removes a leaf node from the document.
    ///
    /// Callers must remove descendants before removing a parent node.
    pub fn removeNode(self: *Document, node_id: ids.NodeId) !void {
        const node = self.findNode(node_id) orelse return error.UnknownNode;
        if (node.children.items.len != 0) return error.NodeHasChildren;
        const total_content_bytes = try self.totalContentBytesForNodes(&.{node_id});
        if (node.parent_id) |parent_id| try self.detachChildFromParent(parent_id, node_id);
        try self.removeDetachedPostorder(&.{node_id}, total_content_bytes);
    }

    pub fn removeSubtree(self: *Document, node_id: ids.NodeId) !void {
        if (node_id == self.root_node_id) return error.NodeHasChildren;
        const target = self.findNodeConst(node_id) orelse return error.UnknownNode;
        const postorder = try self.collectSubtreePostorderAlloc(self.allocator, node_id);
        defer self.allocator.free(postorder);

        const total_content_bytes = try self.totalContentBytesForNodes(postorder);
        const parent_id = target.parent_id orelse return error.UnknownParent;
        try self.detachChildFromParent(parent_id, node_id);
        try self.removeDetachedPostorder(postorder, total_content_bytes);
    }

    /// Collects one subtree in descendant-first postorder.
    pub fn collectSubtreePostorderAlloc(
        self: *const Document,
        allocator: std.mem.Allocator,
        node_id: ids.NodeId,
    ) ![]ids.NodeId {
        _ = self.findNodeConst(node_id) orelse return error.UnknownNode;

        const Frame = struct {
            node_id: ids.NodeId,
            expanded: bool,
        };

        var stack = std.ArrayListUnmanaged(Frame){};
        defer stack.deinit(allocator);
        var postorder = std.ArrayListUnmanaged(ids.NodeId){};
        defer postorder.deinit(allocator);

        try stack.append(allocator, .{
            .node_id = node_id,
            .expanded = false,
        });

        while (stack.items.len != 0) {
            const frame = stack.pop().?;
            const current = self.findNodeConst(frame.node_id) orelse return error.UnknownNode;
            if (frame.expanded) {
                try postorder.append(allocator, frame.node_id);
                continue;
            }

            try stack.append(allocator, .{
                .node_id = frame.node_id,
                .expanded = true,
            });
            var index = current.children.items.len;
            while (index != 0) {
                index -= 1;
                try stack.append(allocator, .{
                    .node_id = current.children.items[index],
                    .expanded = false,
                });
            }
        }

        return try postorder.toOwnedSlice(allocator);
    }

    /// Returns the aggregate content bytes for one planned set of nodes.
    pub fn totalContentBytesForNodes(
        self: *const Document,
        node_ids: []const ids.NodeId,
    ) !usize {
        var total: usize = 0;
        for (node_ids) |node_id| {
            const node = self.findNodeConst(node_id) orelse return error.UnknownNode;
            total = std.math.add(usize, total, node.content.len) catch return error.ContentAccountingDrift;
        }
        return total;
    }

    /// Removes one child reference from its parent without touching registries.
    pub fn detachChildFromParent(
        self: *Document,
        parent_id: ids.NodeId,
        child_id: ids.NodeId,
    ) !void {
        const parent = self.findNode(parent_id) orelse return error.UnknownParent;
        for (parent.children.items, 0..) |listed_child_id, idx| {
            if (listed_child_id == child_id) {
                _ = parent.children.swapRemove(idx);
                break;
            }
        }
    }

    /// Removes one planned postorder subtree after the caller has already
    /// detached the root from its immediate parent.
    pub fn removeDetachedPostorder(
        self: *Document,
        postorder: []const ids.NodeId,
        total_content_bytes: usize,
    ) !void {
        if (total_content_bytes > self.content_bytes) return error.ContentAccountingDrift;
        for (postorder) |node_id| {
            try self.removeNodeRegistryOnly(node_id);
        }
        self.content_bytes -= total_content_bytes;
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
        var stack = std.ArrayListUnmanaged(ids.NodeId){};
        defer stack.deinit(self.allocator);
        stack.append(self.allocator, self.root_node_id) catch return null;

        while (stack.items.len != 0) {
            const node_id = stack.pop().?;
            const node = self.findNode(node_id) orelse continue;
            if (node.backend_id) |bid| {
                if (std.mem.eql(u8, bid, backend_id)) return node;
            }
            var index = node.children.items.len;
            while (index != 0) {
                index -= 1;
                stack.append(self.allocator, node.children.items[index]) catch return null;
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
        const Writer = @TypeOf(writer);
        const Context = struct {
            writer: Writer,
            first: bool = true,
        };

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
        var context = Context{ .writer = writer };
        try self.walkPreorder(&context, struct {
            fn visit(ctx: *Context, _: ids.NodeId, node: *const muxml.Node) !void {
                if (!ctx.first) try ctx.writer.writeAll(",");
                ctx.first = false;
                try node.writeJson(ctx.writer);
            }
        }.visit);
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
        try writer.print("\"nodeCount\":{d},", .{self.live_node_count});
        try writer.print("\"elidedCount\":{d}", .{self.elided_node_ids.items.len});
        try writer.writeAll("}");
    }

    /// Serializes the document as muxml/XML.
    pub fn writeXml(self: *const Document, writer: anytype) !void {
        const Writer = @TypeOf(writer);
        const Context = struct {
            writer: Writer,
        };

        try writer.print("<muxml id=\"{d}\" lifecycle=\"{s}\">", .{
            self.id,
            @tagName(self.lifecycle),
        });
        try writer.writeAll("<title>");
        try writeEscapedXml(writer, self.title);
        try writer.writeAll("</title><nodes>");
        var context = Context{ .writer = writer };
        try self.walkPreorder(&context, struct {
            fn visit(ctx: *Context, _: ids.NodeId, node: *const muxml.Node) !void {
                try node.writeXml(ctx.writer);
            }
        }.visit);
        try writer.writeAll("</nodes></muxml>");
    }

    pub fn validate(self: *const Document) !ValidationSummary {
        const ValidateContext = struct {
            document: *const Document,
            seen: *std.AutoHashMap(ids.NodeId, void),
            computed_content_bytes: *usize,
            visited_count: *usize,
        };

        var seen = std.AutoHashMap(ids.NodeId, void).init(self.allocator);
        defer seen.deinit();

        var computed_content_bytes: usize = 0;
        var visited_count: usize = 0;

        _ = self.findNodeConst(self.root_node_id) orelse return error.MissingRootNode;
        var context = ValidateContext{
            .document = self,
            .seen = &seen,
            .computed_content_bytes = &computed_content_bytes,
            .visited_count = &visited_count,
        };
        try self.walkPreorder(&context, struct {
            fn visit(ctx: *ValidateContext, _: ids.NodeId, node: *const muxml.Node) !void {
                const entry = try ctx.seen.getOrPut(node.id);
                if (entry.found_existing) return error.DuplicateNodeId;
                ctx.computed_content_bytes.* = std.math.add(
                    usize,
                    ctx.computed_content_bytes.*,
                    node.content.len,
                ) catch return error.ContentAccountingDrift;
                ctx.visited_count.* += 1;

                if (node.id == ctx.document.root_node_id) {
                    if (node.parent_id != null) return error.RootNodeHasParent;
                    if (node.kind != .document) return error.RootNodeKindMismatch;
                } else {
                    const parent_id = node.parent_id orelse return error.NonRootNodeMissingParent;
                    const parent = ctx.document.findNodeConst(parent_id) orelse return error.UnknownParent;

                    var linked_from_parent = false;
                    for (parent.children.items) |child_id| {
                        if (child_id == node.id) {
                            linked_from_parent = true;
                            break;
                        }
                    }
                    if (!linked_from_parent) return error.ParentMissingChildLink;
                }

                var child_seen = std.AutoHashMap(ids.NodeId, void).init(ctx.document.allocator);
                defer child_seen.deinit();
                for (node.children.items) |child_id| {
                    const child_entry = try child_seen.getOrPut(child_id);
                    if (child_entry.found_existing) return error.DuplicateChildLink;

                    const child = ctx.document.findNodeConst(child_id) orelse return error.UnknownChild;
                    if (child.parent_id == null or child.parent_id.? != node.id) {
                        return error.ChildParentMismatch;
                    }
                }
            }
        }.visit);

        if (visited_count != self.live_node_count) return error.UnreachableNode;
        for (0..self.node_slots.count()) |slot_index| {
            const node = self.node_slots.at(slot_index).* orelse continue;
            if (!seen.contains(node.id)) return error.UnreachableNode;
        }
        if (computed_content_bytes != self.content_bytes) return error.ContentAccountingDrift;

        if (self.view_root_node_id) |view_root_node_id| {
            _ = self.findNodeConst(view_root_node_id) orelse return error.UnknownViewRootNode;
        }

        for (self.elided_node_ids.items) |node_id| {
            _ = self.findNodeConst(node_id) orelse return error.UnknownElidedNode;
        }

        return .{
            .node_count = self.live_node_count,
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

    fn slotIndexForNodeId(node_id: ids.NodeId) usize {
        std.debug.assert(node_id != 0);
        return @intCast(node_id - 1);
    }

    fn ensureNodeSlotForId(self: *Document, node_id: ids.NodeId) !void {
        const slot_index = slotIndexForNodeId(node_id);
        while (self.node_slots.count() <= slot_index) {
            const slot = try self.node_slots.addOne(self.allocator);
            slot.* = null;
        }
    }

    fn nodeSlotPtr(self: *Document, node_id: ids.NodeId) ?*?*muxml.Node {
        const slot_index = slotIndexForNodeId(node_id);
        if (slot_index >= self.node_slots.count()) return null;
        return self.node_slots.at(slot_index);
    }

    fn nodeSlotPtrConst(self: *const Document, node_id: ids.NodeId) ?*const ?*muxml.Node {
        const slot_index = slotIndexForNodeId(node_id);
        if (slot_index >= self.node_slots.count()) return null;
        return self.node_slots.at(slot_index);
    }

    fn setNodeSlot(self: *Document, node_id: ids.NodeId, node_ptr: ?*muxml.Node) !void {
        try self.ensureNodeSlotForId(node_id);
        const slot = self.nodeSlotPtr(node_id).?;
        slot.* = node_ptr;
    }

    fn removeNodeRegistryOnly(self: *Document, node_id: ids.NodeId) !void {
        const slot = self.nodeSlotPtr(node_id) orelse return error.UnknownNode;
        const node = slot.* orelse return error.UnknownNode;
        slot.* = null;
        self.live_node_count -= 1;

        if (self.view_root_node_id != null and self.view_root_node_id.? == node_id) {
            self.view_root_node_id = null;
        }

        for (self.elided_node_ids.items, 0..) |elided_id, idx| {
            if (elided_id == node_id) {
                _ = self.elided_node_ids.swapRemove(idx);
                break;
            }
        }

        node.deinit(self.allocator);
        self.allocator.destroy(node);
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

test "removeSubtree removes descendants, content accounting, and shared view state" {
    var document = try Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const island_id = try document.appendNode(
        document.root_node_id,
        .subdocument,
        "island",
        .{ .none = {} },
    );
    const subtree_id = try document.appendNode(
        island_id,
        .container,
        "subtree",
        .{ .none = {} },
    );
    const nested_id = try document.appendNode(
        subtree_id,
        .container,
        "nested",
        .{ .none = {} },
    );
    const doomed_leaf = try document.appendNode(
        nested_id,
        .text_leaf,
        "doomed",
        .{ .none = {} },
    );
    const survivor_leaf = try document.appendNode(
        island_id,
        .text_leaf,
        "survivor",
        .{ .none = {} },
    );

    try document.setNodeContent(doomed_leaf, "doomed-content");
    try document.setNodeContent(survivor_leaf, "survivor");
    try document.setViewRoot(doomed_leaf);
    try document.setElided(doomed_leaf, true);

    const expected_content_bytes = document.findNode(survivor_leaf).?.content.len;

    try document.removeSubtree(subtree_id);

    try std.testing.expect(document.findNode(subtree_id) == null);
    try std.testing.expect(document.findNode(nested_id) == null);
    try std.testing.expect(document.findNode(doomed_leaf) == null);
    try std.testing.expect(document.findNode(survivor_leaf) != null);
    try std.testing.expectEqual(expected_content_bytes, document.content_bytes);
    try std.testing.expect(document.view_root_node_id == null);
    try std.testing.expectEqual(@as(usize, 0), document.elided_node_ids.items.len);
}

test "subtreeContainsEnabledContainerKinds reports nested concurrent boundaries" {
    var document = try Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const island_id = try document.appendNode(
        document.root_node_id,
        .subdocument,
        "island",
        .{ .none = {} },
    );
    const plain_container = try document.appendNode(
        island_id,
        .container,
        "plain",
        .{ .none = {} },
    );
    const nested_h = try document.appendNode(
        plain_container,
        .h_container,
        "nested-h",
        .{ .none = {} },
    );
    const nested_child = try document.appendNode(
        nested_h,
        .scroll_region,
        "child",
        .{ .none = {} },
    );
    _ = try document.appendNode(
        nested_child,
        .text_leaf,
        "leaf",
        .{ .none = {} },
    );

    const enabled: Document.ConcurrentContainerKinds = .{
        .horizontal = true,
        .vertical = true,
    };

    try std.testing.expect(!(try document.subtreeContainsEnabledContainerKinds(island_id, .{})));
    try std.testing.expect(try document.subtreeContainsEnabledContainerKinds(plain_container, enabled));
}

test "document serialization uses stable preorder tree order" {
    var document = try Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const left = try document.appendNode(
        document.root_node_id,
        .subdocument,
        "left",
        .{ .none = {} },
    );
    const right = try document.appendNode(
        document.root_node_id,
        .text_leaf,
        "right",
        .{ .none = {} },
    );
    const nested = try document.appendNode(
        left,
        .text_leaf,
        "nested",
        .{ .none = {} },
    );

    const preorder = try document.collectPreorderNodeIdsAlloc(std.testing.allocator);
    defer std.testing.allocator.free(preorder);
    try std.testing.expectEqualSlices(ids.NodeId, &.{ document.root_node_id, left, nested, right }, preorder);

    var json = std.array_list.Managed(u8).init(std.testing.allocator);
    defer json.deinit();
    try document.writeJson(json.writer());

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json.items, .{});
    defer parsed.deinit();
    const nodes = parsed.value.object.get("nodes").?.array.items;
    try std.testing.expectEqual(@as(i64, @intCast(document.root_node_id)), nodes[0].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(left)), nodes[1].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(nested)), nodes[2].object.get("id").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(right)), nodes[3].object.get("id").?.integer);
}

test "document storage keeps monotonic ids with holes after deletion" {
    var document = try Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const survivor = try document.appendNode(
        document.root_node_id,
        .text_leaf,
        "survivor",
        .{ .none = {} },
    );
    const removed = try document.appendNode(
        document.root_node_id,
        .text_leaf,
        "removed",
        .{ .none = {} },
    );

    try document.removeNode(removed);
    const newcomer = try document.appendNode(
        document.root_node_id,
        .text_leaf,
        "newcomer",
        .{ .none = {} },
    );

    try std.testing.expectEqual(@as(ids.NodeId, 4), newcomer);
    try std.testing.expect(document.findNode(removed) == null);
    try std.testing.expect(document.findNode(newcomer) != null);
    try std.testing.expectEqual(@as(usize, 3), document.nodeCount());
    try std.testing.expectEqual(@as(usize, 4), document.node_slots.count());
    try std.testing.expect(document.nodeSlotPtrConst(removed).?.* == null);
    _ = survivor;
}

test "validate rejects unreachable live node slots" {
    var document = try Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const orphan_id = document.reserveNodeId();
    const orphan = try document.prepareNodeWithId(
        orphan_id,
        document.root_node_id,
        .text_leaf,
        "orphan",
        .{ .none = {} },
    );
    try document.setNodeSlot(orphan_id, orphan);
    document.live_node_count += 1;

    try std.testing.expectError(error.UnreachableNode, document.validate());
}
