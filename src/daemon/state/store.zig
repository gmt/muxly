const std = @import("std");
const muxly = @import("muxly");
const capabilities_mod = muxly.capabilities;
const document_mod = muxly.document;
const ids = muxly.ids;
const source_mod = muxly.source;
const types = muxly.types;
const tmux = @import("../tmux/client.zig");

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
                    if (tty.pane_id) |pane_id| {
                        const capture = tmux.capturePane(self.allocator, pane_id) catch {
                            var fallback = std.ArrayList(u8).init(self.allocator);
                            defer fallback.deinit();
                            try fallback.writer().print("tty source unavailable for pane {s} in session {s}", .{
                                pane_id,
                                tty.session_name,
                            });
                            try node.setContent(self.allocator, fallback.items);
                            continue;
                        };
                        defer self.allocator.free(capture);
                        try node.setContent(self.allocator, capture);
                    } else {
                        var buffer = std.ArrayList(u8).init(self.allocator);
                        defer buffer.deinit();
                        try buffer.writer().print("live tty source attached to session {s}", .{tty.session_name});
                        try node.setContent(self.allocator, buffer.items);
                    }
                },
                .file => |file| {
                    const content = readPathAlloc(self.allocator, file.path, 1 << 20) catch |err| {
                        var fallback = std.ArrayList(u8).init(self.allocator);
                        defer fallback.deinit();
                        try fallback.writer().print("file source unavailable at {s}: {s}", .{
                            file.path,
                            @errorName(err),
                        });
                        try node.setContent(self.allocator, fallback.items);
                        node.follow_tail = file.mode == .monitored;
                        continue;
                    };
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
        return try self.attachPaneRef(.{
            .pane_id = try self.allocator.dupe(u8, ""),
            .window_id = try self.allocator.dupe(u8, ""),
            .session_name = try self.allocator.dupe(u8, session_name),
        });
    }

    pub fn createTmuxSession(self: *Store, session_name: []const u8, command: ?[]const u8) !ids.NodeId {
        var pane_ref = try tmux.createSession(self.allocator, session_name, command);
        defer pane_ref.deinit(self.allocator);
        return try self.attachPaneRef(pane_ref);
    }

    pub fn createTmuxWindow(
        self: *Store,
        target: []const u8,
        window_name: ?[]const u8,
        command: ?[]const u8,
    ) !ids.NodeId {
        var pane_ref = try tmux.createWindow(self.allocator, target, window_name, command);
        defer pane_ref.deinit(self.allocator);
        return try self.attachPaneRef(pane_ref);
    }

    pub fn splitTmuxPane(self: *Store, target: []const u8, direction: []const u8, command: ?[]const u8) !ids.NodeId {
        var pane_ref = try tmux.splitPane(self.allocator, target, direction, command);
        defer pane_ref.deinit(self.allocator);
        return try self.attachPaneRef(pane_ref);
    }

    pub fn captureTmuxPane(self: *Store, pane_id: []const u8) ![]u8 {
        return try tmux.capturePane(self.allocator, pane_id);
    }

    pub fn resizeTmuxPane(self: *Store, pane_id: []const u8, direction: []const u8, amount: i64) !void {
        try tmux.resizePane(self.allocator, pane_id, direction, amount);
        try self.refreshSources();
    }

    pub fn focusTmuxPane(self: *Store, pane_id: []const u8) !void {
        try tmux.focusPane(self.allocator, pane_id);
        try self.refreshSources();
    }

    pub fn sendKeysTmuxPane(self: *Store, pane_id: []const u8, keys: []const u8, press_enter: bool) !void {
        try tmux.sendKeys(self.allocator, pane_id, keys, press_enter);
        try self.refreshSources();
    }

    pub fn closeTmuxPane(self: *Store, pane_id: []const u8) !void {
        try tmux.closePane(self.allocator, pane_id);
        if (self.findNodeIdByPaneId(pane_id)) |node_id| {
            _ = self.document.removeNode(node_id) catch {};
        }
        try self.refreshSources();
    }

    fn attachPaneRef(self: *Store, pane_ref: tmux.PaneRef) !ids.NodeId {
        const node_id = try self.document.appendNode(
            self.document.root_node_id,
            .tty_leaf,
            pane_ref.session_name,
            .{ .tty = .{
                .session_name = pane_ref.session_name,
                .window_id = if (pane_ref.window_id.len == 0) null else pane_ref.window_id,
                .pane_id = if (pane_ref.pane_id.len == 0) null else pane_ref.pane_id,
            } },
        );
        try self.refreshSources();
        return node_id;
    }

    fn findNodeIdByPaneId(self: *Store, pane_id: []const u8) ?ids.NodeId {
        for (self.document.nodes.items) |node| {
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
};

fn readPathAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }

    return try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}
