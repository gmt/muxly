const std = @import("std");
const muxly = @import("muxly");
const capabilities_mod = muxly.capabilities;
const document_mod = muxly.document;
const ids = muxly.ids;
const source_mod = muxly.source;
const types = muxly.types;

pub const Store = struct {
    allocator: std.mem.Allocator,
    capabilities: capabilities_mod.Capabilities = .{},
    document: document_mod.Document,

    pub fn init(allocator: std.mem.Allocator) !Store {
        var document = try document_mod.Document.init(allocator, 1, "muxly");
        const intro_id = try document.appendNode(document.root_node_id, .scroll_region, "welcome", .{ .none = {} });
        try document.setNodeContent(
            intro_id,
            "muxly bootstrap document\n- ordinary client viewer\n- append-friendly regions\n- mixed-source leaves\n",
        );

        return .{
            .allocator = allocator,
            .document = document,
        };
    }

    pub fn deinit(self: *Store) void {
        self.document.deinit();
    }

    pub fn refreshSources(self: *Store) !void {
        for (self.document.nodes.items) |*node| {
            switch (node.source) {
                .none => {},
                .tty => |tty| {
                    var buffer = std.ArrayList(u8).init(self.allocator);
                    defer buffer.deinit();
                    try buffer.writer().print("live tty source attached to session {s}", .{tty.session_name});
                    try node.setContent(self.allocator, buffer.items);
                },
                .file => |file| {
                    const content = try std.fs.cwd().readFileAlloc(self.allocator, file.path, 1 << 20);
                    defer self.allocator.free(content);
                    try node.setContent(self.allocator, content);
                    node.follow_tail = file.mode == .monitored;
                },
            }
        }
    }

    pub fn attachFile(
        self: *Store,
        path: []const u8,
        mode: source_mod.FileMode,
    ) !ids.NodeId {
        const node_kind: types.NodeKind = switch (mode) {
            .monitored => .monitored_file_leaf,
            .static => .static_file_leaf,
        };
        const node_id = try self.document.appendNode(
            self.document.root_node_id,
            node_kind,
            path,
            .{ .file = .{ .path = @constCast(path), .mode = mode } },
        );
        try self.refreshSources();
        return node_id;
    }

    pub fn attachTty(self: *Store, session_name: []const u8) !ids.NodeId {
        const node_id = try self.document.appendNode(
            self.document.root_node_id,
            .tty_leaf,
            session_name,
            .{ .tty = .{ .session_name = @constCast(session_name) } },
        );
        try self.refreshSources();
        return node_id;
    }
};
