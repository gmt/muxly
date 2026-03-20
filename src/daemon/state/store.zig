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

const TerminalArtifactCapture = struct {
    content: []u8,
    sections: source_mod.TerminalArtifactSections = .{},
};

const TmuxProjectionState = enum {
    clean,
    invalidated_by_notification,
    invalidated_by_control_disconnect,
};

const root_document_path = "/";

const DocumentEntry = struct {
    path: []u8,
    document: document_mod.Document,

    fn deinit(self: *DocumentEntry, allocator: std.mem.Allocator) void {
        self.document.deinit();
        allocator.free(self.path);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    capabilities: capabilities_mod.Capabilities = .{},
    documents: std.ArrayListUnmanaged(DocumentEntry) = .{},
    next_document_id: ids.DocumentId = 2,
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

        var store = Store{
            .allocator = allocator,
        };
        errdefer store.deinit();

        try store.documents.append(allocator, .{
            .path = try allocator.dupe(u8, root_document_path),
            .document = document,
        });
        return store;
    }

    pub fn documentForPath(self: *Store, document_path: []const u8) !*document_mod.Document {
        for (self.documents.items) |*entry| {
            if (std.mem.eql(u8, entry.path, document_path)) return &entry.document;
        }
        return error.UnsupportedDocumentPath;
    }

    pub fn createDocument(
        self: *Store,
        document_path: []const u8,
        title: ?[]const u8,
    ) !*document_mod.Document {
        if (document_path.len == 0 or document_path[0] != '/') return error.InvalidDocumentPath;
        if (std.mem.eql(u8, document_path, root_document_path)) return error.DocumentAlreadyExists;
        if (document_path.len > 1 and document_path[document_path.len - 1] == '/') return error.InvalidDocumentPath;

        for (self.documents.items) |entry| {
            if (std.mem.eql(u8, entry.path, document_path)) return error.DocumentAlreadyExists;
        }

        const owned_title = if (title == null) try defaultDocumentTitleFromPath(self.allocator, document_path) else null;
        defer if (owned_title) |value| self.allocator.free(value);
        const resolved_title = title orelse owned_title.?;

        const document_id = self.next_document_id;
        self.next_document_id += 1;

        var document = try document_mod.Document.init(self.allocator, document_id, resolved_title);
        errdefer document.deinit();

        try self.documents.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, document_path),
            .document = document,
        });
        return &self.documents.items[self.documents.items.len - 1].document;
    }

    pub fn deinit(self: *Store) void {
        if (self.control_connection) |*connection| {
            connection.deinit();
            self.control_connection = null;
        }
        self.clearTmuxPaneSnapshots();
        for (self.documents.items) |*entry| entry.deinit(self.allocator);
        self.documents.deinit(self.allocator);
    }

    pub fn pumpTmuxBackend(self: *Store) !void {
        try self.ensureControlConnectionForKnownTmuxState();
        if (self.control_connection) |*connection| {
            connection.drainEvents(0, self, struct {
                fn handle(store: *Store, event: tmux_events.Event) !void {
                    switch (event) {
                        .pane_output => |pane_output| {
                            store.appendTmuxPaneOutput(pane_output.pane_id, pane_output.payload) catch {
                                store.invalidateTmuxProjection(.invalidated_by_notification);
                            };
                        },
                        .notification => |notification| {
                            if (!store.tryApplyIncrementalNotification(notification)) {
                                if (isStateInvalidatingNotification(notification.name)) {
                                    store.invalidateTmuxProjection(.invalidated_by_notification);
                                }
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
        for (self.documents.items) |*entry| {
            for (entry.document.nodes.items) |*node| {
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
                    .terminal_artifact => {},
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
        document: *document_mod.Document,
        path: []const u8,
        mode: source_mod.FileMode,
    ) !ids.NodeId {
        const node_kind: types.NodeKind = switch (mode) {
            .monitored => .monitored_file_leaf,
            .static => .static_file_leaf,
        };
        const node_id = try document.appendNode(
            document.root_node_id,
            node_kind,
            path,
            .{ .file = .{ .path = @constCast(path), .mode = mode } },
        );
        try self.refreshSources();
        return node_id;
    }

    pub fn attachTty(self: *Store, document: *document_mod.Document, session_name: []const u8) !ids.NodeId {
        return try self.attachPaneRef(document, document.root_node_id, .{
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
        const session_node_id = try tmux_reconcile.reconcileSessionSnapshots(self.rootDocument(), parent_id, snapshots);
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
        return try self.rebuildTmuxSessionProjectionForPane(self.rootDocument().root_node_id, pane_ref.pane_id);
    }

    pub fn splitTmuxPane(self: *Store, target: []const u8, direction: []const u8, command: ?[]const u8) !ids.NodeId {
        var pane_ref = try tmux.splitPane(self.allocator, target, direction, command);
        defer pane_ref.deinit(self.allocator);
        return try self.rebuildTmuxSessionProjectionForPane(self.rootDocument().root_node_id, pane_ref.pane_id);
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
            break :blk tmux_reconcile.findSessionIdForPaneNode(self.rootDocument(), known_node_id);
        };

        try tmux.closePane(self.allocator, pane_id);
        if (node_id) |known_node_id| {
            _ = self.rootDocument().removeNode(known_node_id) catch {};
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
                _ = try self.rebuildTmuxSessionProjectionForPane(self.rootDocument().root_node_id, surviving_pane_id_copy);
            } else {
                _ = try tmux_reconcile.removeSessionProjection(self.rootDocument(), known_session_id);
            }
        }
        try self.refreshSources();
    }

    pub fn setPaneFollowTail(self: *Store, pane_id: []const u8, enabled: bool) !void {
        const node_id = self.findNodeIdByPaneId(pane_id) orelse return error.UnknownNode;
        try self.rootDocument().setFollowTail(node_id, enabled);
    }

    pub fn captureFileNode(self: *Store, document: *document_mod.Document, node_id: ids.NodeId) ![]u8 {
        try self.refreshSources();
        const node = document.findNode(node_id) orelse return error.UnknownNode;
        switch (node.source) {
            .file => {},
            else => return error.InvalidSourceKind,
        }
        return try self.allocator.dupe(u8, node.content);
    }

    pub fn setFileFollowTail(self: *Store, document: *document_mod.Document, node_id: ids.NodeId, enabled: bool) !void {
        _ = self;
        const node = document.findNode(node_id) orelse return error.UnknownNode;
        switch (node.source) {
            .file => {},
            else => return error.InvalidSourceKind,
        }
        node.follow_tail = enabled;
    }

    pub fn resetView(self: *Store, document: *document_mod.Document) void {
        _ = self;
        document.resetView();
    }

    pub fn appendNode(self: *Store, document: *document_mod.Document, parent_id: ids.NodeId, kind: types.NodeKind, title: []const u8) !ids.NodeId {
        _ = self;
        const node_id = try document.appendNode(parent_id, kind, title, .{ .none = {} });
        return node_id;
    }

    pub fn updateNode(self: *Store, document: *document_mod.Document, node_id: ids.NodeId, title: ?[]const u8, content: ?[]const u8) !void {
        _ = self;
        if (title) |value| try document.setNodeTitle(node_id, value);
        if (content) |value| try document.setNodeContent(node_id, value);
    }

    pub fn freezeTerminalNode(
        self: *Store,
        document: *document_mod.Document,
        node_id: ids.NodeId,
        artifact_kind: source_mod.TerminalArtifactKind,
    ) !void {
        const sections = try self.captureTerminalArtifact(document, node_id, artifact_kind);
        try document.freezeTtyNodeAsArtifact(node_id, artifact_kind, sections);
    }

    pub fn removeNode(self: *Store, document: *document_mod.Document, node_id: ids.NodeId) !void {
        _ = self;
        try document.removeNode(node_id);
    }

    pub fn clearViewRoot(self: *Store, document: *document_mod.Document) void {
        _ = self;
        document.clearViewRoot();
    }

    pub fn expandNode(self: *Store, document: *document_mod.Document, node_id: ids.NodeId) !void {
        _ = self;
        try document.setElided(node_id, false);
    }

    fn attachPaneRef(self: *Store, document: *document_mod.Document, parent_id: ids.NodeId, pane_ref: tmux.PaneRef) !ids.NodeId {
        const node_id = try document.appendNode(
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
        for (self.rootDocument().nodes.items) |node| {
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
        const session_node_id = tmux_reconcile.findSessionProjectionNode(self.rootDocument(), session_id) orelse return null;
        const session_node = self.rootDocument().findNode(session_node_id) orelse return null;
        return session_node.parent_id;
    }

    fn reconcileKnownTmuxProjections(self: *Store) !void {
        const projections = try tmux_reconcile.listSessionProjections(self.rootDocument(), self.allocator);
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
                _ = try tmux_reconcile.removeSessionProjection(self.rootDocument(), projection.session_id);
                continue;
            }

            _ = try tmux_reconcile.reconcileSessionSnapshots(self.rootDocument(), projection.parent_id, snapshots.items);
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

    fn tryApplyIncrementalNotification(self: *Store, notification: tmux_events.Notification) bool {
        if (std.mem.eql(u8, notification.name, "window-renamed")) {
            return self.tryApplyWindowRenamed(notification.payload);
        }
        if (std.mem.eql(u8, notification.name, "window-close")) {
            self.tryApplyWindowClose(notification.payload);
            // Keep the invalidation path: a close can still require broader
            // tmux topology cleanup than this local subtree removal handles.
            return false;
        }
        return false;
    }

    fn tryApplyWindowRenamed(self: *Store, payload: []const u8) bool {
        const parsed = parseWindowNotificationPayload(payload) orelse return false;
        const bid = std.fmt.allocPrint(self.allocator, "tmux-window:{s}", .{parsed.window_id}) catch return false;
        defer self.allocator.free(bid);

        const node = self.rootDocument().findNodeByBackendId(bid) orelse return false;
        node.setTitle(self.allocator, parsed.name) catch return false;
        return true;
    }

    fn tryApplyWindowClose(self: *Store, payload: []const u8) void {
        const parsed = parseWindowNotificationPayload(payload) orelse return;
        const bid = std.fmt.allocPrint(self.allocator, "tmux-window:{s}", .{parsed.window_id}) catch return;
        defer self.allocator.free(bid);

        const node = self.rootDocument().findNodeByBackendId(bid) orelse return;
        const node_id = node.id;
        const child_ids = self.allocator.dupe(ids.NodeId, node.children.items) catch return;
        defer self.allocator.free(child_ids);
        for (child_ids) |child_id| {
            self.rootDocument().removeNode(child_id) catch {};
        }
        self.rootDocument().removeNode(node_id) catch {};
    }

    const WindowNotification = struct {
        window_id: []const u8,
        name: []const u8,
    };

    fn parseWindowNotificationPayload(payload: []const u8) ?WindowNotification {
        if (payload.len == 0) return null;
        if (std.mem.indexOfScalar(u8, payload, ' ')) |space| {
            return .{ .window_id = payload[0..space], .name = payload[space + 1 ..] };
        }
        return .{ .window_id = payload, .name = "" };
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

    fn appendTmuxPaneOutput(self: *Store, pane_id: []const u8, payload: []const u8) !void {
        const node_id = self.findNodeIdByPaneId(pane_id) orelse return error.UnknownPane;
        const node = self.rootDocument().findNode(node_id) orelse return error.UnknownNode;
        if (!node.follow_tail) return;
        const normalized = try normalizeTmuxOutputChunk(self.allocator, payload);
        defer self.allocator.free(normalized);
        try self.rootDocument().appendTextToNode(node_id, normalized);
    }

    fn captureTerminalArtifact(
        self: *Store,
        document: *document_mod.Document,
        node_id: ids.NodeId,
        artifact_kind: source_mod.TerminalArtifactKind,
    ) !source_mod.TerminalArtifactSections {
        const node = document.findNode(node_id) orelse return error.UnknownNode;
        const tty = switch (node.source) {
            .tty => |value| value,
            else => return error.InvalidSourceKind,
        };
        const pane_id = tty.pane_id orelse return error.MissingPaneId;

        const capture: TerminalArtifactCapture = switch (artifact_kind) {
            .text => .{
                .content = try tmux.capturePane(self.allocator, pane_id),
                .sections = source_mod.TerminalArtifactSections{},
            },
            .surface => try captureSurfaceArtifact(self.allocator, pane_id),
        };
        defer self.allocator.free(capture.content);
        try node.setContent(self.allocator, capture.content);
        return capture.sections;
    }

    pub fn rootDocument(self: *Store) *document_mod.Document {
        return self.documentForPath(root_document_path) catch unreachable;
    }
};

fn defaultDocumentTitleFromPath(allocator: std.mem.Allocator, document_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(document_path);
    if (base.len != 0 and !std.mem.eql(u8, base, "/")) {
        return try allocator.dupe(u8, base);
    }

    const trimmed = std.mem.trimRight(u8, document_path, "/");
    const trimmed_base = std.fs.path.basename(trimmed);
    if (trimmed_base.len != 0 and !std.mem.eql(u8, trimmed_base, "/")) {
        return try allocator.dupe(u8, trimmed_base);
    }

    return try allocator.dupe(u8, "document");
}

fn normalizeTmuxOutputChunk(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    var index: usize = 0;
    while (index < payload.len) {
        const char = payload[index];
        if (char == '\\' and index + 1 < payload.len) {
            const next = payload[index + 1];
            if (next == 'n') {
                try buffer.append('\n');
                index += 2;
                continue;
            }
            if (next == 'r') {
                try buffer.append('\r');
                index += 2;
                continue;
            }
            if (next == 't') {
                try buffer.append('\t');
                index += 2;
                continue;
            }
            if (next == '\\') {
                try buffer.append('\\');
                index += 2;
                continue;
            }
            if (index + 3 < payload.len and isOctalDigit(next) and isOctalDigit(payload[index + 2]) and isOctalDigit(payload[index + 3])) {
                const byte = try std.fmt.parseInt(u8, payload[index + 1 .. index + 4], 8);
                try buffer.append(byte);
                index += 4;
                continue;
            }
        }
        try buffer.append(char);
        index += 1;
    }

    return try buffer.toOwnedSlice();
}

fn captureSurfaceArtifact(allocator: std.mem.Allocator, pane_id: []const u8) !TerminalArtifactCapture {
    const visible = try tmux.capturePaneVisible(allocator, pane_id);
    defer allocator.free(visible);

    const alternate = try tmux.capturePaneAlternate(allocator, pane_id);
    defer allocator.free(alternate);

    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    var sections = source_mod.TerminalArtifactSections{ .surface = true };

    try buffer.appendSlice("[surface]\n");
    try buffer.appendSlice(visible);
    const trimmed_alternate = std.mem.trim(u8, alternate, "\r\n\t ");
    if (trimmed_alternate.len != 0) {
        sections.alternate = true;
        if (visible.len != 0 and visible[visible.len - 1] != '\n') {
            try buffer.append('\n');
        }
        try buffer.appendSlice("\n[alternate]\n");
        try buffer.appendSlice(alternate);
    }

    return .{
        .content = try buffer.toOwnedSlice(),
        .sections = sections,
    };
}

fn isOctalDigit(char: u8) bool {
    return char >= '0' and char <= '7';
}

fn readPathAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }

    return try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}
