const std = @import("std");
const muxly = @import("muxly");
const capabilities_mod = muxly.capabilities;
const document_mod = muxly.document;
const ids = muxly.ids;
const source_mod = muxly.source;
const types = muxly.types;
const tmux = muxly.daemon.tmux.client;
const control_mode = muxly.daemon.tmux.control_mode;
const tmux_events = muxly.daemon.tmux.events;
const tmux_reconcile = muxly.daemon.tmux.reconcile;

const TmuxProjectionState = enum {
    clean,
    invalidated_by_notification,
    invalidated_by_control_disconnect,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    capabilities: capabilities_mod.Capabilities = .{},
    document: document_mod.Document,
    tmux_pane_snapshots: std.ArrayListUnmanaged(tmux_events.PaneSnapshot) = .{},
    control_connection: ?control_mode.ControlConnection = null,
    tmux_projection_state: TmuxProjectionState = .clean,

    pub fn init(allocator: std.mem.Allocator) !Store {
        var document = try document_mod.Document.init(allocator, 1, "muxly");
        const intro_id = try document.appendNode(document.root_node_id, .scroll_region, "welcome", .{ .none = {} });
        try document.setNodeContent(
            intro_id,
            "muxly bootstrap document\n- viewer uses public surfaces\n- append-friendly regions\n- mixed-source leaves\n",
        );

        return .{
            .allocator = allocator,
            .document = document,
        };
    }

    pub fn deinit(self: *Store) void {
        if (self.control_connection) |*connection| {
            connection.deinit();
            self.control_connection = null;
        }
        self.clearTmuxPaneSnapshots();
        self.document.deinit();
    }

    pub fn pumpTmuxBackend(self: *Store) !void {
        try self.ensureControlConnectionForKnownTmuxState();
        if (self.control_connection) |*connection| {
            connection.drainEvents(0, self, struct {
                fn handle(store: *Store, event: tmux_events.Event) !void {
                    switch (event) {
                        .notification => |notification| {
                            if (isStateInvalidatingNotification(notification.name)) {
                                store.invalidateTmuxProjection(.invalidated_by_notification);
                            }
                        },
                        .exit => {
                            store.invalidateTmuxProjection(.invalidated_by_control_disconnect);
                            return error.ControlModeExited;
                        },
                        else => {},
                    }
                }
            }.handle) catch |err| switch (err) {
                error.ControlModeExited => {
                    connection.deinit();
                    self.control_connection = null;
                },
                else => return err,
            };
        }

        if (self.tmux_projection_state == .clean) return;
        try self.refreshTmuxPaneSnapshots();
        if (self.control_connection == null and self.tmux_projection_state == .invalidated_by_control_disconnect) {
            try self.ensureControlConnectionForKnownTmuxState();
        }
        try self.reconcileKnownTmuxProjections();
        try self.refreshSources();
        if (self.control_connection != null) {
            self.tmux_projection_state = .clean;
        }
    }

    pub fn refreshSources(self: *Store) !void {
        for (self.document.nodes.items) |*node| {
            switch (node.source) {
                .none => {},
                .tty => |tty| {
                    if (tty.pane_id) |pane_id| {
                        const capture = tmux.capturePane(self.allocator, pane_id) catch {
                            var fallback = std.array_list.Managed(u8).init(self.allocator);
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
                        var buffer = std.array_list.Managed(u8).init(self.allocator);
                        defer buffer.deinit();
                        try buffer.writer().print("live tty source attached to session {s}", .{tty.session_name});
                        try node.setContent(self.allocator, buffer.items);
                    }
                },
                .file => |file| {
                    const content = readPathAlloc(self.allocator, file.path, 1 << 20) catch |err| {
                        var fallback = std.array_list.Managed(u8).init(self.allocator);
                        defer fallback.deinit();
                        try fallback.writer().print("file source unavailable at {s}: {s}", .{
                            file.path,
                            @errorName(err),
                        });
                        try node.setContent(self.allocator, fallback.items);
                        continue;
                    };
                    defer self.allocator.free(content);
                    try node.setContent(self.allocator, content);
                },
            }
        }
    }

    pub fn refreshTmuxPaneSnapshots(self: *Store) !void {
        self.clearTmuxPaneSnapshots();
        const snapshots = try tmux.listPaneSnapshots(self.allocator);
        defer self.allocator.free(snapshots);

        try self.tmux_pane_snapshots.ensureTotalCapacity(self.allocator, snapshots.len);
        for (snapshots) |snapshot| {
            self.tmux_pane_snapshots.appendAssumeCapacity(snapshot);
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
        return try self.attachPaneRef(self.document.root_node_id, .{
            .pane_id = try self.allocator.dupe(u8, ""),
            .window_id = try self.allocator.dupe(u8, ""),
            .session_name = try self.allocator.dupe(u8, session_name),
        });
    }

    pub fn createTmuxSession(
        self: *Store,
        parent_id: ids.NodeId,
        session_name: []const u8,
        command: ?[]const u8,
    ) !ids.NodeId {
        var pane_ref = try tmux.createSession(self.allocator, session_name, command);
        defer pane_ref.deinit(self.allocator);
        const node_id = try self.rebuildTmuxSessionProjectionForPane(parent_id, pane_ref.pane_id);
        try self.ensureControlConnection(session_name);
        return node_id;
    }

    pub fn rebuildTmuxSessionProjection(
        self: *Store,
        parent_id: ids.NodeId,
        snapshots: []const tmux_events.PaneSnapshot,
    ) !ids.NodeId {
        const session_node_id = try tmux_reconcile.reconcileSessionSnapshots(&self.document, parent_id, snapshots);
        self.tmux_projection_state = .clean;
        try self.refreshSources();
        return session_node_id;
    }

    pub fn rebuildTmuxSessionProjectionForPane(
        self: *Store,
        preferred_parent_id: ids.NodeId,
        pane_id: []const u8,
    ) !ids.NodeId {
        try self.refreshTmuxPaneSnapshots();

        const snapshot = self.findTmuxPaneSnapshot(pane_id) orelse return error.UnknownPane;
        var session_snapshots = std.array_list.Managed(tmux_events.PaneSnapshot).init(self.allocator);
        defer session_snapshots.deinit();

        for (self.tmux_pane_snapshots.items) |item| {
            if (std.mem.eql(u8, item.session_id, snapshot.session_id)) {
                try session_snapshots.append(item);
            }
        }

        const parent_id = self.findProjectionParentForSession(snapshot.session_id) orelse preferred_parent_id;
        _ = try self.rebuildTmuxSessionProjection(parent_id, session_snapshots.items);
        try self.ensureControlConnection(snapshot.session_name);
        return self.findNodeIdByPaneId(pane_id) orelse return error.UnknownNode;
    }

    pub fn createTmuxWindow(
        self: *Store,
        target: []const u8,
        window_name: ?[]const u8,
        command: ?[]const u8,
    ) !ids.NodeId {
        var pane_ref = try tmux.createWindow(self.allocator, target, window_name, command);
        defer pane_ref.deinit(self.allocator);
        return try self.rebuildTmuxSessionProjectionForPane(self.document.root_node_id, pane_ref.pane_id);
    }

    pub fn splitTmuxPane(self: *Store, target: []const u8, direction: []const u8, command: ?[]const u8) !ids.NodeId {
        var pane_ref = try tmux.splitPane(self.allocator, target, direction, command);
        defer pane_ref.deinit(self.allocator);
        return try self.rebuildTmuxSessionProjectionForPane(self.document.root_node_id, pane_ref.pane_id);
    }

    pub fn captureTmuxPane(self: *Store, pane_id: []const u8) ![]u8 {
        return try tmux.capturePane(self.allocator, pane_id);
    }

    pub fn scrollTmuxPane(self: *Store, pane_id: []const u8, start_line: i64, end_line: i64) ![]u8 {
        return try tmux.capturePaneRange(self.allocator, pane_id, start_line, end_line);
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
        const node_id = self.findNodeIdByPaneId(pane_id);
        const session_id = blk: {
            const known_node_id = node_id orelse break :blk null;
            break :blk tmux_reconcile.findSessionIdForPaneNode(&self.document, known_node_id);
        };

        try tmux.closePane(self.allocator, pane_id);
        if (node_id) |known_node_id| {
            _ = self.document.removeNode(known_node_id) catch {};
        }
        if (session_id) |known_session_id| {
            try self.refreshTmuxPaneSnapshots();

            var remaining_pane_id: ?[]const u8 = null;
            for (self.tmux_pane_snapshots.items) |snapshot| {
                if (std.mem.eql(u8, snapshot.session_id, known_session_id)) {
                    remaining_pane_id = snapshot.pane_id;
                    break;
                }
            }

            if (remaining_pane_id) |surviving_pane_id| {
                const surviving_pane_id_copy = try self.allocator.dupe(u8, surviving_pane_id);
                defer self.allocator.free(surviving_pane_id_copy);
                _ = try self.rebuildTmuxSessionProjectionForPane(self.document.root_node_id, surviving_pane_id_copy);
            } else {
                _ = try tmux_reconcile.removeSessionProjection(&self.document, known_session_id);
            }
        }
        try self.refreshSources();
    }

    pub fn setPaneFollowTail(self: *Store, pane_id: []const u8, enabled: bool) !void {
        const node_id = self.findNodeIdByPaneId(pane_id) orelse return error.UnknownNode;
        try self.document.setFollowTail(node_id, enabled);
    }

    pub fn captureFileNode(self: *Store, node_id: ids.NodeId) ![]u8 {
        try self.refreshSources();
        const node = self.document.findNode(node_id) orelse return error.UnknownNode;
        switch (node.source) {
            .file => {},
            else => return error.InvalidSourceKind,
        }
        return try self.allocator.dupe(u8, node.content);
    }

    pub fn setFileFollowTail(self: *Store, node_id: ids.NodeId, enabled: bool) !void {
        const node = self.document.findNode(node_id) orelse return error.UnknownNode;
        switch (node.source) {
            .file => {},
            else => return error.InvalidSourceKind,
        }
        node.follow_tail = enabled;
    }

    pub fn resetView(self: *Store) void {
        self.document.resetView();
    }

    pub fn appendNode(self: *Store, parent_id: ids.NodeId, kind: types.NodeKind, title: []const u8) !ids.NodeId {
        const node_id = try self.document.appendNode(parent_id, kind, title, .{ .none = {} });
        return node_id;
    }

    pub fn updateNode(self: *Store, node_id: ids.NodeId, title: ?[]const u8, content: ?[]const u8) !void {
        if (title) |value| try self.document.setNodeTitle(node_id, value);
        if (content) |value| try self.document.setNodeContent(node_id, value);
    }

    pub fn removeNode(self: *Store, node_id: ids.NodeId) !void {
        try self.document.removeNode(node_id);
    }

    pub fn clearViewRoot(self: *Store) void {
        self.document.clearViewRoot();
    }

    pub fn expandNode(self: *Store, node_id: ids.NodeId) !void {
        try self.document.setElided(node_id, false);
    }

    fn attachPaneRef(self: *Store, parent_id: ids.NodeId, pane_ref: tmux.PaneRef) !ids.NodeId {
        const node_id = try self.document.appendNode(
            parent_id,
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

    pub fn findNodeIdByPaneId(self: *Store, pane_id: []const u8) ?ids.NodeId {
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

    fn findTmuxPaneSnapshot(self: *Store, pane_id: []const u8) ?tmux_events.PaneSnapshot {
        for (self.tmux_pane_snapshots.items) |snapshot| {
            if (std.mem.eql(u8, snapshot.pane_id, pane_id)) return snapshot;
        }
        return null;
    }

    fn findProjectionParentForSession(self: *Store, session_id: []const u8) ?ids.NodeId {
        const session_node_id = tmux_reconcile.findSessionProjectionNode(&self.document, session_id) orelse return null;
        const session_node = self.document.findNode(session_node_id) orelse return null;
        return session_node.parent_id;
    }

    fn reconcileKnownTmuxProjections(self: *Store) !void {
        const projections = try tmux_reconcile.listSessionProjections(&self.document, self.allocator);
        defer {
            for (projections) |*projection| projection.deinit(self.allocator);
            self.allocator.free(projections);
        }

        for (projections) |projection| {
            var snapshots = std.array_list.Managed(tmux_events.PaneSnapshot).init(self.allocator);
            defer snapshots.deinit();

            for (self.tmux_pane_snapshots.items) |snapshot| {
                if (std.mem.eql(u8, snapshot.session_id, projection.session_id)) {
                    try snapshots.append(snapshot);
                }
            }

            if (snapshots.items.len == 0) {
                _ = try tmux_reconcile.removeSessionProjection(&self.document, projection.session_id);
                continue;
            }

            _ = try tmux_reconcile.reconcileSessionSnapshots(&self.document, projection.parent_id, snapshots.items);
        }
    }

    fn ensureControlConnectionForKnownTmuxState(self: *Store) !void {
        if (self.control_connection != null) return;
        if (self.tmux_pane_snapshots.items.len == 0) {
            try self.refreshTmuxPaneSnapshots();
        }
        if (self.tmux_pane_snapshots.items.len == 0) return;
        try self.ensureControlConnection(self.tmux_pane_snapshots.items[0].session_name);
    }

    fn ensureControlConnection(self: *Store, session_name: []const u8) !void {
        if (self.control_connection != null) return;
        self.control_connection = control_mode.ControlConnection.initAttach(self.allocator, session_name) catch |err| switch (err) {
            error.FileNotFound, error.ControlModeUnavailable => null,
            else => return err,
        };
    }

    fn invalidateTmuxProjection(self: *Store, state: TmuxProjectionState) void {
        if (state == .invalidated_by_control_disconnect) {
            self.tmux_projection_state = state;
            return;
        }
        if (self.tmux_projection_state == .clean) {
            self.tmux_projection_state = state;
        }
    }

    fn isStateInvalidatingNotification(name: []const u8) bool {
        return std.mem.eql(u8, name, "sessions-changed") or
            std.mem.eql(u8, name, "session-changed") or
            std.mem.eql(u8, name, "session-renamed") or
            std.mem.eql(u8, name, "window-add") or
            std.mem.eql(u8, name, "window-close") or
            std.mem.eql(u8, name, "window-renamed") or
            std.mem.eql(u8, name, "windows-changed") or
            std.mem.eql(u8, name, "layout-change") or
            std.mem.eql(u8, name, "pane-mode-changed") or
            std.mem.eql(u8, name, "unlinked-window-add") or
            std.mem.eql(u8, name, "unlinked-window-close");
    }

    fn clearTmuxPaneSnapshots(self: *Store) void {
        for (self.tmux_pane_snapshots.items) |*snapshot| snapshot.deinit(self.allocator);
        self.tmux_pane_snapshots.deinit(self.allocator);
        self.tmux_pane_snapshots = .{};
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
