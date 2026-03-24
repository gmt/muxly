const std = @import("std");
const muxly = @import("muxly");
const capabilities_mod = muxly.capabilities;
const document_mod = muxly.document;
const ids = muxly.ids;
const runtime_config = muxly.runtime_config;
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
const tmux_control_poll_timeout_ms: i32 = 10;

const DomainLock = struct {
    mutex: std.Thread.Mutex = .{},
};

const StructuralLock = struct {
    mutex: std.Thread.Mutex = .{},
};

const DomainWritePlan = union(enum) {
    content: ids.NodeId,
    structural: struct {
        domain_id: ids.NodeId,
        parent_id: ids.NodeId,
    },
};

const RemoveExecutionMode = enum {
    leaf_domain_safe,
    leaf_coordinator,
    recursive_domain_safe,
    recursive_coordinator_safe,
    unsupported,
};

pub const RequestGuard = union(enum) {
    none,
    coordinator_exclusive: struct {
        runtime: *DocumentRuntime,
        domain_ids: []ids.NodeId,
    },
    quiescent_read: struct {
        runtime: *DocumentRuntime,
        domain_ids: []ids.NodeId,
    },
    domain_write: struct {
        runtime: *DocumentRuntime,
        domain_lock: *DomainLock,
    },
    structural_write: struct {
        runtime: *DocumentRuntime,
        domain_lock: *DomainLock,
        parent_lock: *StructuralLock,
    },

    pub fn release(self: *RequestGuard) void {
        switch (self.*) {
            .none => {},
            .coordinator_exclusive => |value| {
                value.runtime.unlockExistingDomainIds(value.domain_ids);
                value.runtime.allocator.free(value.domain_ids);
                value.runtime.coordinator_mutex.unlock();
            },
            .quiescent_read => |value| {
                value.runtime.unlockExistingDomainIds(value.domain_ids);
                value.runtime.allocator.free(value.domain_ids);
            },
            .domain_write => |value| {
                _ = value.runtime;
                value.domain_lock.mutex.unlock();
            },
            .structural_write => |value| {
                _ = value.runtime;
                value.parent_lock.mutex.unlock();
                value.domain_lock.mutex.unlock();
            },
        }
        self.* = .none;
    }
};

pub const DocumentRuntime = struct {
    allocator: std.mem.Allocator,
    coordinator_mutex: std.Thread.Mutex = .{},
    content_bytes_mutex: std.Thread.Mutex = .{},
    structure_registry_mutex: std.Thread.Mutex = .{},
    domains_mutex: std.Thread.Mutex = .{},
    domain_locks: std.AutoHashMapUnmanaged(ids.NodeId, *DomainLock) = .{},
    structural_locks_mutex: std.Thread.Mutex = .{},
    parent_locks: std.AutoHashMapUnmanaged(ids.NodeId, *StructuralLock) = .{},

    pub fn init(allocator: std.mem.Allocator) DocumentRuntime {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DocumentRuntime) void {
        var iterator = self.domain_locks.valueIterator();
        while (iterator.next()) |lock_ptr| {
            self.allocator.destroy(lock_ptr.*);
        }
        self.domain_locks.deinit(self.allocator);

        var structural_iterator = self.parent_locks.valueIterator();
        while (structural_iterator.next()) |lock_ptr| {
            self.allocator.destroy(lock_ptr.*);
        }
        self.parent_locks.deinit(self.allocator);
    }

    pub fn acquireCoordinatorExclusive(self: *DocumentRuntime) !RequestGuard {
        self.coordinator_mutex.lock();
        errdefer self.coordinator_mutex.unlock();

        const domain_ids = try self.snapshotDomainIds();
        errdefer self.allocator.free(domain_ids);
        self.lockExistingDomainIds(domain_ids);

        return .{ .coordinator_exclusive = .{
            .runtime = self,
            .domain_ids = domain_ids,
        } };
    }

    pub fn acquireQuiescentRead(self: *DocumentRuntime) !RequestGuard {
        self.coordinator_mutex.lock();
        errdefer self.coordinator_mutex.unlock();

        const domain_ids = try self.snapshotDomainIds();
        errdefer self.allocator.free(domain_ids);
        self.lockExistingDomainIds(domain_ids);
        self.coordinator_mutex.unlock();

        return .{ .quiescent_read = .{
            .runtime = self,
            .domain_ids = domain_ids,
        } };
    }

    pub fn acquireDomainWrite(self: *DocumentRuntime, domain_id: ids.NodeId) !RequestGuard {
        self.coordinator_mutex.lock();
        defer self.coordinator_mutex.unlock();

        const domain_lock = try self.ensureDomainLock(domain_id);
        domain_lock.mutex.lock();

        return .{ .domain_write = .{
            .runtime = self,
            .domain_lock = domain_lock,
        } };
    }

    fn ensureDomainLock(self: *DocumentRuntime, domain_id: ids.NodeId) !*DomainLock {
        self.domains_mutex.lock();
        defer self.domains_mutex.unlock();

        const entry = try self.domain_locks.getOrPut(self.allocator, domain_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = try self.allocator.create(DomainLock);
            entry.value_ptr.*.* = .{};
        }
        return entry.value_ptr.*;
    }

    fn ensureParentLock(self: *DocumentRuntime, parent_id: ids.NodeId) !*StructuralLock {
        self.structural_locks_mutex.lock();
        defer self.structural_locks_mutex.unlock();

        const entry = try self.parent_locks.getOrPut(self.allocator, parent_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = try self.allocator.create(StructuralLock);
            entry.value_ptr.*.* = .{};
        }
        return entry.value_ptr.*;
    }

    fn existingDomainLock(self: *DocumentRuntime, domain_id: ids.NodeId) ?*DomainLock {
        self.domains_mutex.lock();
        defer self.domains_mutex.unlock();
        return self.domain_locks.get(domain_id);
    }

    fn snapshotDomainIds(self: *DocumentRuntime) ![]ids.NodeId {
        self.domains_mutex.lock();
        defer self.domains_mutex.unlock();

        const result = try self.allocator.alloc(ids.NodeId, self.domain_locks.count());
        var index: usize = 0;
        var iterator = self.domain_locks.keyIterator();
        while (iterator.next()) |domain_id| : (index += 1) {
            result[index] = domain_id.*;
        }
        std.sort.heap(ids.NodeId, result, {}, comptime std.sort.asc(ids.NodeId));
        return result;
    }

    fn lockExistingDomainIds(self: *DocumentRuntime, domain_ids: []const ids.NodeId) void {
        for (domain_ids) |domain_id| {
            const domain_lock = self.existingDomainLock(domain_id) orelse continue;
            domain_lock.mutex.lock();
        }
    }

    fn unlockExistingDomainIds(self: *DocumentRuntime, domain_ids: []const ids.NodeId) void {
        var index = domain_ids.len;
        while (index != 0) {
            index -= 1;
            const domain_lock = self.existingDomainLock(domain_ids[index]) orelse continue;
            domain_lock.mutex.unlock();
        }
    }
};

pub const ProjectionEventReason = enum {
    content,
    metadata,
    structure,
    target_gone,
};

pub const ProjectionNotifier = struct {
    context: *anyopaque,
    on_invalidate: *const fn (
        context: *anyopaque,
        document_path: []const u8,
        document: *const document_mod.Document,
        node_id: ids.NodeId,
        reason: ProjectionEventReason,
    ) void,
    on_tty_data: *const fn (
        context: *anyopaque,
        document_path: []const u8,
        document: *const document_mod.Document,
        node_id: ids.NodeId,
        chunk: []const u8,
    ) void,
};

pub const DocumentEntry = struct {
    path: []u8,
    document: document_mod.Document,
    runtime: DocumentRuntime,

    fn deinit(self: *DocumentEntry, allocator: std.mem.Allocator) void {
        self.runtime.deinit();
        self.document.deinit();
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    runtime_limits: runtime_config.RuntimeLimits,
    capabilities: capabilities_mod.Capabilities = .{},
    documents: std.ArrayListUnmanaged(*DocumentEntry) = .{},
    documents_mutex: std.Thread.Mutex = .{},
    next_document_id: ids.DocumentId = 2,
    tmux_pane_snapshots: std.ArrayListUnmanaged(tmux_events.PaneSnapshot) = .{},
    control_connection: ?control_mode.ControlConnection = null,
    tmux_projection_state: TmuxProjectionState = .clean,
    projection_notifier: ?ProjectionNotifier = null,

    pub fn init(allocator: std.mem.Allocator) !Store {
        return try initWithRuntimeLimits(allocator, .{});
    }

    pub fn initWithRuntimeLimits(
        allocator: std.mem.Allocator,
        limits: runtime_config.RuntimeLimits,
    ) !Store {
        var document = try document_mod.Document.init(allocator, 1, "muxly");
        document.setMaxContentBytes(limits.max_document_content_bytes);
        const intro_id = try document.appendNode(document.root_node_id, .scroll_region, "welcome", .{ .none = {} });
        try document.setNodeContent(
            intro_id,
            "muxly bootstrap document\n- viewer uses public surfaces\n- append-friendly regions\n- mixed-source leaves\n",
        );

        var store = Store{
            .allocator = allocator,
            .runtime_limits = limits,
            .capabilities = .{
                .max_message_bytes = limits.max_message_bytes,
                .max_document_content_bytes = limits.max_document_content_bytes,
            },
        };
        errdefer store.deinit();

        const entry = try allocator.create(DocumentEntry);
        errdefer allocator.destroy(entry);
        entry.* = .{
            .path = try allocator.dupe(u8, root_document_path),
            .document = document,
            .runtime = DocumentRuntime.init(allocator),
        };
        try store.documents.append(allocator, entry);
        return store;
    }

    pub fn documentForPath(self: *Store, document_path: []const u8) !*document_mod.Document {
        const entry = try self.documentEntryForPath(document_path);
        return &entry.document;
    }

    pub fn documentEntryForPath(self: *Store, document_path: []const u8) !*DocumentEntry {
        self.documents_mutex.lock();
        defer self.documents_mutex.unlock();
        for (self.documents.items) |entry| {
            if (std.mem.eql(u8, entry.path, document_path)) return entry;
        }
        return error.UnsupportedDocumentPath;
    }

    pub fn snapshotDocumentEntries(self: *Store) ![]*DocumentEntry {
        self.documents_mutex.lock();
        defer self.documents_mutex.unlock();
        return try self.allocator.dupe(*DocumentEntry, self.documents.items);
    }

    pub fn acquireCoordinatorExclusiveGuardForEntry(
        self: *Store,
        entry: *DocumentEntry,
    ) !RequestGuard {
        _ = self;
        return try entry.runtime.acquireCoordinatorExclusive();
    }

    pub fn acquireCoordinatorExclusiveGuardForPath(
        self: *Store,
        document_path: []const u8,
    ) !RequestGuard {
        const entry = try self.documentEntryForPath(document_path);
        return try entry.runtime.acquireCoordinatorExclusive();
    }

    pub fn acquireQuiescentReadGuardForEntry(
        self: *Store,
        entry: *DocumentEntry,
    ) !RequestGuard {
        _ = self;
        return try entry.runtime.acquireQuiescentRead();
    }

    pub fn acquireQuiescentReadGuardForPath(
        self: *Store,
        document_path: []const u8,
    ) !RequestGuard {
        const entry = try self.documentEntryForPath(document_path);
        return try entry.runtime.acquireQuiescentRead();
    }

    pub fn resolveExecutionDomainRootForRequest(
        self: *Store,
        allocator: std.mem.Allocator,
        document_path: []const u8,
        request: muxly.protocol.RequestEnvelope,
    ) !?ids.NodeId {
        const entry = self.documentEntryForPath(document_path) catch |err| switch (err) {
            error.UnsupportedDocumentPath => return null,
            else => return err,
        };
        entry.runtime.coordinator_mutex.lock();
        defer entry.runtime.coordinator_mutex.unlock();
        if (try self.resolveDomainWritePlanWithStableTopology(allocator, entry, request)) |plan| {
            return switch (plan) {
                .content => |domain_id| domain_id,
                .structural => |value| value.domain_id,
            };
        }
        return null;
    }

    pub fn acquireRequestGuard(
        self: *Store,
        allocator: std.mem.Allocator,
        request_json: []const u8,
    ) !RequestGuard {
        const parsed = muxly.protocol.parseRequest(allocator, request_json) catch return .none;
        defer parsed.deinit();

        const document_path = muxly.protocol.requestDocumentPath(parsed.value) catch return .none;
        if (std.mem.eql(u8, document_path, root_document_path)) return .none;

        const entry = self.documentEntryForPath(document_path) catch |err| switch (err) {
            error.UnsupportedDocumentPath => return .none,
            else => return err,
        };

        if (requestSupportsDynamicDomainLane(parsed.value)) {
            entry.runtime.coordinator_mutex.lock();
            errdefer entry.runtime.coordinator_mutex.unlock();

            if (try self.resolveDomainWritePlanWithStableTopology(allocator, entry, parsed.value)) |plan| {
                switch (plan) {
                    .content => |domain_id| {
                        const domain_lock = try entry.runtime.ensureDomainLock(domain_id);
                        domain_lock.mutex.lock();
                        entry.runtime.coordinator_mutex.unlock();
                        return .{ .domain_write = .{
                            .runtime = &entry.runtime,
                            .domain_lock = domain_lock,
                        } };
                    },
                    .structural => |value| {
                        const domain_lock = try entry.runtime.ensureDomainLock(value.domain_id);
                        const parent_lock = try entry.runtime.ensureParentLock(value.parent_id);
                        domain_lock.mutex.lock();
                        parent_lock.mutex.lock();
                        entry.runtime.coordinator_mutex.unlock();
                        return .{ .structural_write = .{
                            .runtime = &entry.runtime,
                            .domain_lock = domain_lock,
                            .parent_lock = parent_lock,
                        } };
                    },
                }
            }

            entry.runtime.coordinator_mutex.unlock();
        }

        if (requestUsesQuiescentReadGuard(parsed.value.method)) {
            return try entry.runtime.acquireQuiescentRead();
        }

        return try entry.runtime.acquireCoordinatorExclusive();
    }

    pub fn createDocument(
        self: *Store,
        document_path: []const u8,
        title: ?[]const u8,
    ) !*document_mod.Document {
        if (!muxly.protocol.isCanonicalDocumentPath(document_path)) return error.InvalidDocumentPath;
        if (std.mem.eql(u8, document_path, root_document_path)) return error.DocumentAlreadyExists;

        self.documents_mutex.lock();
        defer self.documents_mutex.unlock();

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
        document.setMaxContentBytes(self.runtime_limits.max_document_content_bytes);

        const entry = try self.allocator.create(DocumentEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .path = try self.allocator.dupe(u8, document_path),
            .document = document,
            .runtime = DocumentRuntime.init(self.allocator),
        };
        try self.documents.append(self.allocator, entry);
        return &entry.document;
    }

    pub fn deinit(self: *Store) void {
        if (self.control_connection) |*connection| {
            connection.deinit();
            self.control_connection = null;
        }
        self.clearTmuxPaneSnapshots();
        for (self.documents.items) |entry| entry.deinit(self.allocator);
        self.documents.deinit(self.allocator);
    }

    pub fn setProjectionNotifier(self: *Store, notifier: ?ProjectionNotifier) void {
        self.projection_notifier = notifier;
    }

    pub fn pumpTmuxBackend(self: *Store) !void {
        try self.ensureControlConnectionForKnownTmuxState();
        if (self.control_connection) |*connection| {
            connection.drainEvents(tmux_control_poll_timeout_ms, self, struct {
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
        const entries = try self.snapshotDocumentEntries();
        defer self.allocator.free(entries);
        for (entries) |entry| {
            var guard = try entry.runtime.acquireCoordinatorExclusive();
            defer guard.release();
            try self.refreshSourcesForDocument(&entry.document);
        }
    }

    pub fn refreshSourcesForDocument(self: *Store, document: *document_mod.Document) !void {
        const document_path = self.documentPathFor(document);
        for (document.nodeIdsInOrder()) |node_id| {
            const node = document.findNode(node_id) orelse continue;
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
                            try self.setNodeContentFromSource(document_path, document, node_id, fallback.items);
                            continue;
                        };
                        defer self.allocator.free(capture);
                        try self.setNodeContentFromSource(document_path, document, node_id, capture);
                    } else {
                        var buffer = std.array_list.Managed(u8).init(self.allocator);
                        defer buffer.deinit();
                        try buffer.writer().print("live tty source attached to session {s}", .{tty.session_name});
                        try self.setNodeContentFromSource(document_path, document, node_id, buffer.items);
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
                        try self.setNodeContentFromSource(document_path, document, node_id, fallback.items);
                        continue;
                    };
                    defer self.allocator.free(content);
                    try self.setNodeContentFromSource(document_path, document, node_id, content);
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
        document_path: []const u8,
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
        try self.refreshSourcesForDocument(document);
        self.notifyInvalidate(document_path, document, node_id, .structure);
        return node_id;
    }

    pub fn attachTty(self: *Store, document_path: []const u8, document: *document_mod.Document, session_name: []const u8) !ids.NodeId {
        return try self.attachPaneRef(document_path, document, document.root_node_id, .{
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
        self.notifyInvalidate(root_document_path, self.rootDocument(), node_id, .structure);
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
        self.notifyInvalidate(root_document_path, self.rootDocument(), session_node_id, .structure);
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
        const node_id = try self.rebuildTmuxSessionProjectionForPane(self.rootDocument().root_node_id, pane_ref.pane_id);
        self.notifyInvalidate(root_document_path, self.rootDocument(), node_id, .structure);
        return node_id;
    }

    pub fn splitTmuxPane(self: *Store, target: []const u8, direction: []const u8, command: ?[]const u8) !ids.NodeId {
        var pane_ref = try tmux.splitPane(self.allocator, target, direction, command);
        defer pane_ref.deinit(self.allocator);
        const node_id = try self.rebuildTmuxSessionProjectionForPane(self.rootDocument().root_node_id, pane_ref.pane_id);
        self.notifyInvalidate(root_document_path, self.rootDocument(), node_id, .structure);
        return node_id;
    }

    pub fn captureTmuxPane(self: *Store, pane_id: []const u8) ![]u8 {
        const capture = try tmux.capturePaneWithLimit(
            self.allocator,
            pane_id,
            self.runtime_limits.max_document_content_bytes,
        );
        if (self.findNodeIdByPaneId(pane_id)) |node_id| {
            const document = self.rootDocument();
            if (document.findNodeConst(node_id) != null) {
                try self.setNodeContentFromSource(root_document_path, document, node_id, capture);
            }
        }
        return capture;
    }

    pub fn scrollTmuxPane(self: *Store, pane_id: []const u8, start_line: i64, end_line: i64) ![]u8 {
        return try tmux.capturePaneRangeWithLimit(
            self.allocator,
            pane_id,
            start_line,
            end_line,
            self.runtime_limits.max_document_content_bytes,
        );
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
        self.notifyInvalidate(root_document_path, self.rootDocument(), node_id, .metadata);
    }

    pub fn captureFileNode(self: *Store, document: *document_mod.Document, node_id: ids.NodeId) ![]u8 {
        try self.refreshSourcesForDocument(document);
        const node = document.findNode(node_id) orelse return error.UnknownNode;
        switch (node.source) {
            .file => {},
            else => return error.InvalidSourceKind,
        }
        return try self.allocator.dupe(u8, node.content);
    }

    pub fn setFileFollowTail(self: *Store, document: *document_mod.Document, node_id: ids.NodeId, enabled: bool) !void {
        const node = document.findNode(node_id) orelse return error.UnknownNode;
        switch (node.source) {
            .file => {},
            else => return error.InvalidSourceKind,
        }
        node.follow_tail = enabled;
        self.notifyInvalidate(self.documentPathFor(document), document, node_id, .metadata);
    }

    pub fn resetView(self: *Store, document: *document_mod.Document) void {
        _ = self;
        document.resetView();
    }

    pub fn appendNode(self: *Store, document_path: []const u8, document: *document_mod.Document, parent_id: ids.NodeId, kind: types.NodeKind, title: []const u8) !ids.NodeId {
        const entry = try self.documentEntryForPath(document_path);
        entry.runtime.structure_registry_mutex.lock();
        defer entry.runtime.structure_registry_mutex.unlock();
        const node_id = try document.appendNode(parent_id, kind, title, .{ .none = {} });
        self.notifyInvalidate(document_path, document, node_id, .structure);
        return node_id;
    }

    pub fn updateNode(self: *Store, document_path: []const u8, document: *document_mod.Document, node_id: ids.NodeId, title: ?[]const u8, content: ?[]const u8) !void {
        if (title) |value| try document.setNodeTitle(node_id, value);
        if (content) |value| {
            const entry = try self.documentEntryForPath(document_path);
            entry.runtime.content_bytes_mutex.lock();
            defer entry.runtime.content_bytes_mutex.unlock();
            try document.setNodeContent(node_id, value);
        }
        self.notifyInvalidate(
            document_path,
            document,
            node_id,
            if (content != null) .content else .metadata,
        );
    }

    pub fn appendTextChunk(
        self: *Store,
        document_path: []const u8,
        document: *document_mod.Document,
        node_id: ids.NodeId,
        chunk: []const u8,
    ) !void {
        const entry = try self.documentEntryForPath(document_path);
        entry.runtime.content_bytes_mutex.lock();
        defer entry.runtime.content_bytes_mutex.unlock();
        try document.appendTextToNode(node_id, chunk);
        self.notifyInvalidate(document_path, document, node_id, .content);
    }

    pub fn attachSyntheticTty(
        self: *Store,
        document_path: []const u8,
        document: *document_mod.Document,
        parent_id: ids.NodeId,
        title: []const u8,
        session_name: []const u8,
    ) !ids.NodeId {
        const entry = try self.documentEntryForPath(document_path);
        entry.runtime.structure_registry_mutex.lock();
        defer entry.runtime.structure_registry_mutex.unlock();
        const node_id = try document.appendNode(
            parent_id,
            .tty_leaf,
            title,
            .{ .tty = .{
                .session_name = @constCast(session_name),
                .window_id = null,
                .pane_id = null,
            } },
        );
        self.notifyInvalidate(document_path, document, node_id, .structure);
        return node_id;
    }

    pub fn pushSyntheticTtyChunk(
        self: *Store,
        document_path: []const u8,
        document: *document_mod.Document,
        node_id: ids.NodeId,
        chunk: []const u8,
    ) !void {
        const node = document.findNode(node_id) orelse return error.UnknownNode;
        switch (node.source) {
            .tty => |tty| {
                if (tty.pane_id != null) return error.InvalidSourceKind;
            },
            else => return error.InvalidSourceKind,
        }

        const entry = try self.documentEntryForPath(document_path);
        entry.runtime.content_bytes_mutex.lock();
        defer entry.runtime.content_bytes_mutex.unlock();
        try document.appendTextToNode(node_id, chunk);
        self.notifyInvalidate(document_path, document, node_id, .content);
        self.notifyTtyData(document_path, document, node_id, chunk);
    }

    pub fn validateDocument(
        self: *Store,
        document: *const document_mod.Document,
    ) !document_mod.Document.ValidationSummary {
        _ = self;
        return try document.validate();
    }

    pub fn freezeTerminalNode(
        self: *Store,
        document: *document_mod.Document,
        node_id: ids.NodeId,
        artifact_kind: source_mod.TerminalArtifactKind,
    ) !void {
        const sections = try self.captureTerminalArtifact(document, node_id, artifact_kind);
        try document.freezeTtyNodeAsArtifact(node_id, artifact_kind, sections);
        self.notifyInvalidate(self.documentPathFor(document), document, node_id, .structure);
    }

    pub fn removeNode(self: *Store, document_path: []const u8, document: *document_mod.Document, node_id: ids.NodeId) !void {
        const entry = try self.documentEntryForPath(document_path);
        const mode = try classifyRemoveExecutionMode(document, node_id);
        entry.runtime.structure_registry_mutex.lock();
        defer entry.runtime.structure_registry_mutex.unlock();
        entry.runtime.content_bytes_mutex.lock();
        defer entry.runtime.content_bytes_mutex.unlock();
        switch (mode) {
            .leaf_domain_safe, .leaf_coordinator => try document.removeNode(node_id),
            .recursive_domain_safe, .recursive_coordinator_safe => try document.removeSubtree(node_id),
            .unsupported => return error.NodeHasChildren,
        }
        self.notifyInvalidate(document_path, document, node_id, .structure);
    }

    pub fn clearViewRoot(self: *Store, document: *document_mod.Document) void {
        _ = self;
        document.clearViewRoot();
    }

    pub fn expandNode(self: *Store, document: *document_mod.Document, node_id: ids.NodeId) !void {
        _ = self;
        try document.setElided(node_id, false);
    }

    fn attachPaneRef(self: *Store, document_path: []const u8, document: *document_mod.Document, parent_id: ids.NodeId, pane_ref: tmux.PaneRef) !ids.NodeId {
        const entry = try self.documentEntryForPath(document_path);
        entry.runtime.structure_registry_mutex.lock();
        defer entry.runtime.structure_registry_mutex.unlock();
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
        try self.refreshSourcesForDocument(document);
        self.notifyInvalidate(document_path, document, node_id, .structure);
        return node_id;
    }

    pub fn findNodeIdByPaneId(self: *Store, pane_id: []const u8) ?ids.NodeId {
        for (self.rootDocument().nodeIdsInOrder()) |node_id| {
            const node = self.rootDocument().findNodeConst(node_id) orelse continue;
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
        self.notifyInvalidate(root_document_path, self.rootDocument(), node.id, .metadata);
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
        self.notifyInvalidate(root_document_path, self.rootDocument(), node_id, .structure);
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
        self.notifyInvalidate(root_document_path, self.rootDocument(), node_id, .content);
        self.notifyTtyData(root_document_path, self.rootDocument(), node_id, normalized);
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
        try document.setNodeContent(node_id, capture.content);
        return capture.sections;
    }

    pub fn rootDocument(self: *Store) *document_mod.Document {
        return self.documentForPath(root_document_path) catch unreachable;
    }

    fn resolveDomainWritePlanWithStableTopology(
        self: *Store,
        allocator: std.mem.Allocator,
        entry: *DocumentEntry,
        request: muxly.protocol.RequestEnvelope,
    ) !?DomainWritePlan {
        if (requestIsStructuralDomainWrite(request)) {
            return try self.resolveStructuralDomainWritePlanWithStableTopology(allocator, entry, request);
        }

        const node_id = resolveRequestNodeIdWithStableTopology(allocator, &entry.document, request) catch |err| switch (err) {
            error.MissingNodeTarget,
            error.InvalidNodeTarget,
            error.UnknownResourceSelectorSegment,
            error.AmbiguousResourceSelector,
            error.InvalidResourceSelector,
            error.ResourceSelectorEscapesRoot,
            => return null,
            else => return err,
        };

        const node = entry.document.findNodeConst(node_id) orelse return null;
        if (node.kind == .h_container or node.kind == .v_container) return null;

        const domain_id = entry.document.concurrentContainerDomainRoot(node_id, enabledConcurrentContainerKinds()) catch |err| switch (err) {
            error.UnknownNode,
            error.UnknownParent,
            => null,
            else => return err,
        };
        return if (domain_id) |value| .{ .content = value } else null;
    }

    fn resolveStructuralDomainWritePlanWithStableTopology(
        self: *Store,
        allocator: std.mem.Allocator,
        entry: *DocumentEntry,
        request: muxly.protocol.RequestEnvelope,
    ) !?DomainWritePlan {
        _ = self;

        if (requestIsAppendLike(request.method)) {
            const parent_value = muxly.protocol.getInteger(request.params, "parentId") orelse return null;
            if (parent_value < 0) return null;

            const parent_id: ids.NodeId = @intCast(parent_value);
            if (parent_id == entry.document.root_node_id) return null;
            const parent = entry.document.findNodeConst(parent_id) orelse return null;
            if (parent.kind == .h_container or parent.kind == .v_container) return null;

            const domain_id = entry.document.concurrentContainerDomainRoot(parent_id, enabledConcurrentContainerKinds()) catch |err| switch (err) {
                error.UnknownNode,
                error.UnknownParent,
                => return null,
                else => return err,
            } orelse return null;

            return .{ .structural = .{
                .domain_id = domain_id,
                .parent_id = parent_id,
            } };
        }

        const node_id = resolveRequestNodeIdWithStableTopology(allocator, &entry.document, request) catch |err| switch (err) {
            error.MissingNodeTarget,
            error.InvalidNodeTarget,
            error.UnknownResourceSelectorSegment,
            error.AmbiguousResourceSelector,
            error.InvalidResourceSelector,
            error.ResourceSelectorEscapesRoot,
            => return null,
            else => return err,
        };

        if (node_id == entry.document.root_node_id) return null;
        const node = entry.document.findNodeConst(node_id) orelse return null;
        const mode = classifyRemoveExecutionMode(&entry.document, node_id) catch |err| switch (err) {
            error.UnknownNode,
            error.UnknownParent,
            => return null,
            else => return err,
        };
        switch (mode) {
            .leaf_domain_safe, .recursive_domain_safe => {},
            .leaf_coordinator,
            .recursive_coordinator_safe,
            .unsupported,
            => return null,
        }

        const parent_id = node.parent_id orelse return null;
        const domain_id = entry.document.concurrentContainerDomainRoot(node_id, enabledConcurrentContainerKinds()) catch |err| switch (err) {
            error.UnknownNode,
            error.UnknownParent,
            => return null,
            else => return err,
        } orelse return null;

        return .{ .structural = .{
            .domain_id = domain_id,
            .parent_id = parent_id,
        } };
    }

    fn documentPathFor(self: *Store, document: *const document_mod.Document) []const u8 {
        self.documents_mutex.lock();
        defer self.documents_mutex.unlock();
        for (self.documents.items) |entry| {
            if (&entry.document == document) return entry.path;
        }
        return root_document_path;
    }

    fn notifyInvalidate(
        self: *Store,
        document_path: []const u8,
        document: *const document_mod.Document,
        node_id: ids.NodeId,
        reason: ProjectionEventReason,
    ) void {
        if (self.projection_notifier) |notifier| {
            notifier.on_invalidate(notifier.context, document_path, document, node_id, reason);
        }
    }

    fn notifyTtyData(
        self: *Store,
        document_path: []const u8,
        document: *const document_mod.Document,
        node_id: ids.NodeId,
        chunk: []const u8,
    ) void {
        if (self.projection_notifier) |notifier| {
            notifier.on_tty_data(notifier.context, document_path, document, node_id, chunk);
        }
    }

    fn setNodeContentFromSource(
        self: *Store,
        document_path: []const u8,
        document: *document_mod.Document,
        node_id: ids.NodeId,
        content: []const u8,
    ) !void {
        const node = document.findNodeConst(node_id) orelse return error.UnknownNode;
        const changed = !std.mem.eql(u8, node.content, content);
        if (!changed) return;
        try document.setNodeContent(node_id, content);
        self.notifyInvalidate(document_path, document, node_id, .content);
    }
};

fn resolveRequestNodeIdWithStableTopology(
    allocator: std.mem.Allocator,
    document: *const document_mod.Document,
    request: muxly.protocol.RequestEnvelope,
) !ids.NodeId {
    _ = allocator;
    if (request.target) |target| {
        if (target.nodeId) |node_id| return node_id;
        if (target.selector) |selector| return try document.resolveSelector(selector);
    }

    const node_id = muxly.protocol.getInteger(request.params, "nodeId") orelse return error.MissingNodeTarget;
    if (node_id < 0) return error.InvalidNodeTarget;
    return @intCast(node_id);
}

fn enabledConcurrentContainerKinds() document_mod.Document.ConcurrentContainerKinds {
    return .{
        .horizontal = true,
        .vertical = true,
    };
}

fn classifyRemoveExecutionMode(
    document: *const document_mod.Document,
    node_id: ids.NodeId,
) !RemoveExecutionMode {
    if (node_id == document.root_node_id) return .unsupported;

    const node = document.findNodeConst(node_id) orelse return error.UnknownNode;
    const parent_id = node.parent_id orelse return error.UnknownParent;
    const parent = document.findNodeConst(parent_id) orelse return error.UnknownParent;

    if (node.children.items.len == 0) {
        if (parent_id == document.root_node_id) return .leaf_coordinator;
        if (parent.kind == .h_container or parent.kind == .v_container) return .leaf_coordinator;
        return .leaf_domain_safe;
    }

    if (parent_id == document.root_node_id) return .unsupported;
    if (parent.kind == .h_container or parent.kind == .v_container) return .unsupported;

    const concurrent_kinds = enabledConcurrentContainerKinds();
    const domain_id = try document.concurrentContainerDomainRoot(node_id, concurrent_kinds) orelse return .unsupported;
    if (domain_id == node_id) return .unsupported;

    if (try document.subtreeContainsEnabledContainerKinds(node_id, concurrent_kinds)) {
        return .recursive_coordinator_safe;
    }

    return .recursive_domain_safe;
}

pub fn requestSupportsDynamicDomainLane(request: muxly.protocol.RequestEnvelope) bool {
    if (std.mem.eql(u8, request.method, "debug.sleep") or
        std.mem.eql(u8, request.method, "debug.text.append") or
        std.mem.eql(u8, request.method, "debug.tty.push"))
    {
        return true;
    }

    return requestIsContentOnlyNodeUpdate(request) or
        requestIsStructuralDomainWrite(request);
}

fn requestIsStructuralDomainWrite(request: muxly.protocol.RequestEnvelope) bool {
    return requestIsAppendLike(request.method) or requestIsRemoveLike(request.method);
}

fn requestIsAppendLike(method: []const u8) bool {
    return std.mem.eql(u8, method, "node.append") or
        std.mem.eql(u8, method, "debug.node.append");
}

fn requestIsRemoveLike(method: []const u8) bool {
    return std.mem.eql(u8, method, "node.remove") or
        std.mem.eql(u8, method, "debug.node.remove");
}

fn requestIsContentOnlyNodeUpdate(request: muxly.protocol.RequestEnvelope) bool {
    if (!std.mem.eql(u8, request.method, "node.update")) return false;

    const content = muxly.protocol.getString(request.params, "content");
    if (content == null) return false;

    const title = muxly.protocol.getString(request.params, "title");
    if (title != null) return false;

    return true;
}

fn requestUsesQuiescentReadGuard(method: []const u8) bool {
    return std.mem.eql(u8, method, "document.get") or
        std.mem.eql(u8, method, "graph.get") or
        std.mem.eql(u8, method, "view.get") or
        std.mem.eql(u8, method, "projection.get") or
        std.mem.eql(u8, method, "document.status") or
        std.mem.eql(u8, method, "document.serialize") or
        std.mem.eql(u8, method, "debug.document.validate") or
        std.mem.eql(u8, method, "node.get") or
        std.mem.eql(u8, method, "leaf.source.get") or
        std.mem.eql(u8, method, "file.capture");
}

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
