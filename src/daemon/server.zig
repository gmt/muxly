const std = @import("std");
const muxly = @import("muxly");
const config_mod = @import("config.zig");
const router = @import("router.zig");
const store_mod = @import("state/store.zig");
const protocol = muxly.protocol;
const control_mode = muxly.daemon.tmux.control_mode;
const tmux_events = muxly.daemon.tmux.events;

const max_pending_requests_per_connection: usize = 32;
const max_tty_output_chunk_bytes: usize = 16 * 1024;
const max_tty_output_queue_bytes: usize = 4 * 1024 * 1024;
const max_capture_stream_chunk_bytes: usize = 32 * 1024;
const projection_pump_interval_ms: u64 = 40;

pub fn serve(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    var thread_safe_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
    const shared_allocator = thread_safe_allocator.allocator();

    var store = try store_mod.Store.initWithRuntimeLimits(shared_allocator, config.runtime_limits);
    defer store.deinit();

    const executor = try ServerExecutor.init(shared_allocator, &store);
    const tty_stream_registry = try TtyStreamRegistry.init(shared_allocator);
    defer tty_stream_registry.deinit();
    const projection_stream_registry = try ProjectionStreamRegistry.init(shared_allocator);
    defer projection_stream_registry.deinit();
    store.setProjectionNotifier(.{
        .context = projection_stream_registry,
        .on_invalidate = projectionStreamStoreInvalidate,
        .on_tty_data = projectionStreamStoreTtyData,
    });

    var listener = try muxly.transport.Listener.initWithMaxMessageBytes(
        allocator,
        &config.transport,
        config.runtime_limits.max_message_bytes,
    );
    defer listener.deinit();
    const single_request_per_connection = switch (listener.target) {
        .proxy => true,
        .unix, .tcp => false,
    };

    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.writeAll("muxlyd listening on ");
    try listener.writeDescription(stderr);
    try stderr.writeByte('\n');

    const pump_thread = try std.Thread.spawn(.{}, tmuxPumpMain, .{executor});
    pump_thread.detach();

    while (true) {
        const connection = try listener.accept();
        const thread = try std.Thread.spawn(.{}, serveConnection, .{ConnectionContext{
            .allocator = shared_allocator,
            .store = &store,
            .executor = executor,
            .tty_stream_registry = tty_stream_registry,
            .projection_stream_registry = projection_stream_registry,
            .connection = connection,
            .single_request_per_connection = single_request_per_connection,
            .max_message_bytes = config.runtime_limits.max_message_bytes,
        }});
        thread.detach();
    }
}

const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    executor: *ServerExecutor,
    tty_stream_registry: *TtyStreamRegistry,
    projection_stream_registry: *ProjectionStreamRegistry,
    connection: std.net.Server.Connection,
    single_request_per_connection: bool,
    max_message_bytes: usize,
};

const ConnectionSession = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    ref_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    write_mutex: std.Thread.Mutex = .{},
    state_mutex: std.Thread.Mutex = .{},
    pending_requests: usize = 0,
    closed: bool = false,

    fn init(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !*ConnectionSession {
        const session = try allocator.create(ConnectionSession);
        session.* = .{
            .allocator = allocator,
            .stream = connection.stream,
        };
        return session;
    }

    fn retain(self: *ConnectionSession) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    fn release(self: *ConnectionSession) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.markClosed();
            self.allocator.destroy(self);
        }
    }

    fn tryReservePendingSlot(self: *ConnectionSession) bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        if (self.closed or self.pending_requests >= max_pending_requests_per_connection) return false;
        self.pending_requests += 1;
        return true;
    }

    fn finishPendingRequest(self: *ConnectionSession) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        std.debug.assert(self.pending_requests > 0);
        self.pending_requests -= 1;
    }

    fn isClosed(self: *ConnectionSession) bool {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.closed;
    }

    fn markClosed(self: *ConnectionSession) void {
        self.state_mutex.lock();
        const should_close = !self.closed;
        self.closed = true;
        self.state_mutex.unlock();

        if (!should_close) return;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        self.stream.close();
    }

    fn writeFrame(self: *ConnectionSession, bytes: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();

        self.state_mutex.lock();
        const already_closed = self.closed;
        self.state_mutex.unlock();
        if (already_closed) return error.ConnectionClosed;

        try self.stream.writeAll(bytes);
        try self.stream.writeAll("\n");
    }
};

const TtyQueuedChunk = union(enum) {
    data: []u8,
    overflow: void,

    fn deinit(self: *TtyQueuedChunk, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .data => |bytes| allocator.free(bytes),
            .overflow => {},
        }
    }
};

const TtyStreamHandle = struct {
    allocator: std.mem.Allocator,
    conversation_id: []u8,
    session_name: []u8,
    pane_id: []u8,
    queue: std.array_list.Managed(TtyQueuedChunk),
    queued_bytes: usize = 0,
    overflow_pending: bool = false,
    closing: bool = false,
    reader_done: bool = false,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},

    const NextChunk = union(enum) {
        data: []u8,
        overflow,
        closed,
    };

    fn init(
        allocator: std.mem.Allocator,
        conversation_id: []const u8,
        session_name: []const u8,
        pane_id: []const u8,
    ) !*TtyStreamHandle {
        const handle = try allocator.create(TtyStreamHandle);
        errdefer allocator.destroy(handle);

        handle.* = .{
            .allocator = allocator,
            .conversation_id = try allocator.dupe(u8, conversation_id),
            .session_name = try allocator.dupe(u8, session_name),
            .pane_id = try allocator.dupe(u8, pane_id),
            .queue = std.array_list.Managed(TtyQueuedChunk).init(allocator),
        };
        return handle;
    }

    fn deinit(self: *TtyStreamHandle) void {
        self.mutex.lock();
        self.closing = true;
        self.clearQueueLocked();
        self.condition.broadcast();
        self.mutex.unlock();

        self.queue.deinit();
        self.allocator.free(self.conversation_id);
        self.allocator.free(self.session_name);
        self.allocator.free(self.pane_id);
        self.allocator.destroy(self);
    }

    fn requestClose(self: *TtyStreamHandle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closing = true;
        self.clearQueueLocked();
        self.condition.broadcast();
    }

    fn finishReader(self: *TtyStreamHandle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.reader_done = true;
        self.condition.broadcast();
    }

    fn enqueueNormalized(self: *TtyStreamHandle, chunk: []const u8) !void {
        if (chunk.len == 0) return;
        var start: usize = 0;
        while (start < chunk.len) {
            const end = @min(chunk.len, start + max_tty_output_chunk_bytes);
            const part = try self.allocator.dupe(u8, chunk[start..end]);
            errdefer self.allocator.free(part);
            try self.enqueueOwnedChunk(.{ .data = part });
            start = end;
        }
    }

    fn enqueueOwnedChunk(self: *TtyStreamHandle, chunk: TtyQueuedChunk) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.closing) {
            var owned = chunk;
            owned.deinit(self.allocator);
            return;
        }

        switch (chunk) {
            .data => |bytes| {
                while (self.queued_bytes + bytes.len > max_tty_output_queue_bytes) {
                    if (self.dropOldestDataLocked()) {
                        self.overflow_pending = true;
                    } else break;
                }
                if (self.overflow_pending) {
                    try self.queue.append(.{ .overflow = {} });
                    self.overflow_pending = false;
                }
                try self.queue.append(.{ .data = bytes });
                self.queued_bytes += bytes.len;
            },
            .overflow => {
                try self.queue.append(.{ .overflow = {} });
            },
        }
        self.condition.signal();
    }

    fn waitNextChunk(self: *TtyStreamHandle) !NextChunk {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.items.len == 0 and !self.closing and !self.reader_done) {
            self.condition.wait(&self.mutex);
        }

        if (self.queue.items.len == 0) return .closed;

        const queued = self.queue.orderedRemove(0);
        return switch (queued) {
            .data => |bytes| blk: {
                self.queued_bytes -= bytes.len;
                break :blk .{ .data = bytes };
            },
            .overflow => .overflow,
        };
    }

    fn dropOldestDataLocked(self: *TtyStreamHandle) bool {
        for (self.queue.items, 0..) |queued, index| {
            switch (queued) {
                .data => |bytes| {
                    self.queued_bytes -= bytes.len;
                    self.allocator.free(bytes);
                    _ = self.queue.orderedRemove(index);
                    return true;
                },
                .overflow => {},
            }
        }
        return false;
    }

    fn clearQueueLocked(self: *TtyStreamHandle) void {
        for (self.queue.items) |*queued| queued.deinit(self.allocator);
        self.queue.clearRetainingCapacity();
        self.queued_bytes = 0;
        self.overflow_pending = false;
    }
};

const TtyStreamRegistry = struct {
    allocator: std.mem.Allocator,
    streams: std.array_list.Managed(*TtyStreamHandle),
    mutex: std.Thread.Mutex = .{},

    fn init(allocator: std.mem.Allocator) !*TtyStreamRegistry {
        const registry = try allocator.create(TtyStreamRegistry);
        errdefer allocator.destroy(registry);
        registry.* = .{
            .allocator = allocator,
            .streams = std.array_list.Managed(*TtyStreamHandle).init(allocator),
        };
        return registry;
    }

    fn deinit(self: *TtyStreamRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.streams.items) |handle| handle.requestClose();
        self.streams.deinit();
        self.allocator.destroy(self);
    }

    fn register(self: *TtyStreamRegistry, handle: *TtyStreamHandle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.streams.append(handle);
    }

    fn unregister(self: *TtyStreamRegistry, conversation_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.streams.items, 0..) |handle, index| {
            if (std.mem.eql(u8, handle.conversation_id, conversation_id)) {
                _ = self.streams.orderedRemove(index);
                return;
            }
        }
    }

    fn requestClose(self: *TtyStreamRegistry, conversation_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.streams.items) |handle| {
            if (std.mem.eql(u8, handle.conversation_id, conversation_id)) {
                handle.requestClose();
                return true;
            }
        }
        return false;
    }
};

const ProjectionStreamHandle = struct {
    allocator: std.mem.Allocator,
    session: *ConnectionSession,
    conversation_id: []u8,
    target: ?protocol.RequestTarget,
    document_path: []u8,
    root_node_id: u64,

    fn init(
        allocator: std.mem.Allocator,
        session: *ConnectionSession,
        conversation_id: []const u8,
        target: ?protocol.RequestTarget,
        document_path: []const u8,
        root_node_id: u64,
    ) !*ProjectionStreamHandle {
        const handle = try allocator.create(ProjectionStreamHandle);
        errdefer allocator.destroy(handle);
        session.retain();
        handle.* = .{
            .allocator = allocator,
            .session = session,
            .conversation_id = try allocator.dupe(u8, conversation_id),
            .target = if (target) |value| try duplicateTarget(allocator, value) else null,
            .document_path = try allocator.dupe(u8, document_path),
            .root_node_id = root_node_id,
        };
        return handle;
    }

    fn deinit(self: *ProjectionStreamHandle) void {
        self.session.release();
        self.allocator.free(self.conversation_id);
        if (self.target) |target| {
            if (target.documentPath) |value| self.allocator.free(value);
            if (target.selector) |value| self.allocator.free(value);
        }
        self.allocator.free(self.document_path);
        self.allocator.destroy(self);
    }
};

const ProjectionStreamRegistry = struct {
    allocator: std.mem.Allocator,
    streams: std.array_list.Managed(*ProjectionStreamHandle),
    mutex: std.Thread.Mutex = .{},

    fn init(allocator: std.mem.Allocator) !*ProjectionStreamRegistry {
        const registry = try allocator.create(ProjectionStreamRegistry);
        errdefer allocator.destroy(registry);
        registry.* = .{
            .allocator = allocator,
            .streams = std.array_list.Managed(*ProjectionStreamHandle).init(allocator),
        };
        return registry;
    }

    fn deinit(self: *ProjectionStreamRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.streams.items) |handle| handle.deinit();
        self.streams.deinit();
        self.allocator.destroy(self);
    }

    fn register(self: *ProjectionStreamRegistry, handle: *ProjectionStreamHandle) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.streams.append(handle);
    }

    fn unregister(self: *ProjectionStreamRegistry, conversation_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.streams.items, 0..) |handle, index| {
            if (std.mem.eql(u8, handle.conversation_id, conversation_id)) {
                const removed = self.streams.orderedRemove(index);
                removed.deinit();
                return true;
            }
        }
        return false;
    }

    fn closeSession(self: *ProjectionStreamRegistry, session: *ConnectionSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var index: usize = 0;
        while (index < self.streams.items.len) {
            const handle = self.streams.items[index];
            if (handle.session == session) {
                const removed = self.streams.orderedRemove(index);
                removed.deinit();
                continue;
            }
            index += 1;
        }
    }

    fn notifyInvalidate(
        self: *ProjectionStreamRegistry,
        document_path: []const u8,
        document: *const muxly.document.Document,
        node_id: u64,
        reason: store_mod.ProjectionEventReason,
    ) void {
        self.broadcast(document_path, document, node_id, .invalidate, reason, null);
    }

    fn notifyTtyData(
        self: *ProjectionStreamRegistry,
        document_path: []const u8,
        document: *const muxly.document.Document,
        node_id: u64,
        chunk: []const u8,
    ) void {
        self.broadcast(document_path, document, node_id, .tty_data, null, chunk);
    }

    const BroadcastKind = enum {
        invalidate,
        tty_data,
    };

    fn broadcast(
        self: *ProjectionStreamRegistry,
        document_path: []const u8,
        document: *const muxly.document.Document,
        node_id: u64,
        kind: BroadcastKind,
        reason: ?store_mod.ProjectionEventReason,
        chunk: ?[]const u8,
    ) void {
        var stale = std.array_list.Managed([]u8).init(self.allocator);
        defer {
            for (stale.items) |conversation_id| self.allocator.free(conversation_id);
            stale.deinit();
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.streams.items) |handle| {
            if (!std.mem.eql(u8, handle.document_path, document_path)) continue;

            const target_gone = document.findNodeConst(handle.root_node_id) == null;
            if (target_gone) {
                if (!sendProjectionTargetGone(self.allocator, handle, node_id)) {
                    const owned = self.allocator.dupe(u8, handle.conversation_id) catch null;
                    if (owned) |value| stale.append(value) catch self.allocator.free(value);
                }
                continue;
            }

            if (!document.nodeWithinSubtree(handle.root_node_id, node_id)) continue;
            const sent = switch (kind) {
                .invalidate => sendProjectionInvalidate(self.allocator, handle, node_id, reason.?),
                .tty_data => sendProjectionTtyData(self.allocator, handle, node_id, chunk.?),
            };
            if (!sent) {
                const owned = self.allocator.dupe(u8, handle.conversation_id) catch null;
                if (owned) |value| stale.append(value) catch self.allocator.free(value);
            }
        }

        for (stale.items) |conversation_id| {
            var index: usize = 0;
            while (index < self.streams.items.len) : (index += 1) {
                if (std.mem.eql(u8, self.streams.items[index].conversation_id, conversation_id)) {
                    const removed = self.streams.orderedRemove(index);
                    removed.deinit();
                    break;
                }
            }
        }
    }
};

fn projectionStreamStoreInvalidate(
    context: *anyopaque,
    document_path: []const u8,
    document: *const muxly.document.Document,
    node_id: u64,
    reason: store_mod.ProjectionEventReason,
) void {
    const registry: *ProjectionStreamRegistry = @ptrCast(@alignCast(context));
    registry.notifyInvalidate(document_path, document, node_id, reason);
}

fn projectionStreamStoreTtyData(
    context: *anyopaque,
    document_path: []const u8,
    document: *const muxly.document.Document,
    node_id: u64,
    chunk: []const u8,
) void {
    const registry: *ProjectionStreamRegistry = @ptrCast(@alignCast(context));
    registry.notifyTtyData(document_path, document, node_id, chunk);
}

fn sendProjectionInvalidate(
    allocator: std.mem.Allocator,
    handle: *ProjectionStreamHandle,
    node_id: u64,
    reason: store_mod.ProjectionEventReason,
) bool {
    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"invalidate\",\"nodeId\":{d},\"reason\":\"{s}\"}}",
        .{ node_id, @tagName(reason) },
    ) catch return false;
    defer allocator.free(payload);

    const frame = protocol.allocConversationEnvelope(
        allocator,
        handle.conversation_id,
        null,
        handle.target,
        .projection_event,
        payload,
        false,
        null,
    ) catch return false;
    defer allocator.free(frame);

    handle.session.writeFrame(frame) catch return false;
    return true;
}

fn sendProjectionTtyData(
    allocator: std.mem.Allocator,
    handle: *ProjectionStreamHandle,
    node_id: u64,
    chunk: []const u8,
) bool {
    const chunk_json = std.json.Stringify.valueAlloc(allocator, chunk, .{}) catch return false;
    defer allocator.free(chunk_json);
    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"tty_data\",\"nodeId\":{d},\"chunk\":{s}}}",
        .{ node_id, chunk_json },
    ) catch return false;
    defer allocator.free(payload);

    const frame = protocol.allocConversationEnvelope(
        allocator,
        handle.conversation_id,
        null,
        handle.target,
        .projection_event,
        payload,
        false,
        null,
    ) catch return false;
    defer allocator.free(frame);

    handle.session.writeFrame(frame) catch return false;
    return true;
}

fn sendProjectionTargetGone(
    allocator: std.mem.Allocator,
    handle: *ProjectionStreamHandle,
    node_id: u64,
) bool {
    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"target_gone\",\"nodeId\":{d}}}",
        .{node_id},
    ) catch return false;
    defer allocator.free(payload);

    const frame = protocol.allocConversationEnvelope(
        allocator,
        handle.conversation_id,
        null,
        handle.target,
        .projection_event,
        payload,
        false,
        null,
    ) catch return false;
    defer allocator.free(frame);

    handle.session.writeFrame(frame) catch return false;
    return true;
}

fn duplicateTarget(
    allocator: std.mem.Allocator,
    target: protocol.RequestTarget,
) !protocol.RequestTarget {
    return .{
        .documentPath = if (target.documentPath) |value| try allocator.dupe(u8, value) else null,
        .nodeId = target.nodeId,
        .selector = if (target.selector) |value| try allocator.dupe(u8, value) else null,
    };
}

const MaintenanceKind = enum {
    pump_tmux,
};

const QueuedWork = union(enum) {
    request: struct {
        request: muxly.conversation_broker.DispatchRequest,
        session: *ConnectionSession,
    },
    maintenance: MaintenanceKind,
};

const Lane = struct {
    allocator: std.mem.Allocator,
    executor: *ServerExecutor,
    document_path: ?[]u8,
    domain_root_node_id: ?u64,
    queue: std.array_list.Managed(QueuedWork),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},

    fn initRoot(allocator: std.mem.Allocator, executor: *ServerExecutor) !*Lane {
        const lane = try allocator.create(Lane);
        errdefer allocator.destroy(lane);
        lane.* = .{
            .allocator = allocator,
            .executor = executor,
            .document_path = null,
            .domain_root_node_id = null,
            .queue = std.array_list.Managed(QueuedWork).init(allocator),
        };
        const thread = try std.Thread.spawn(.{}, workerMain, .{lane});
        thread.detach();
        return lane;
    }

    fn initDocumentLane(
        allocator: std.mem.Allocator,
        executor: *ServerExecutor,
        document_path: []u8,
        domain_root_node_id: ?u64,
    ) !*Lane {
        const lane = try allocator.create(Lane);
        errdefer allocator.destroy(lane);
        lane.* = .{
            .allocator = allocator,
            .executor = executor,
            .document_path = document_path,
            .domain_root_node_id = domain_root_node_id,
            .queue = std.array_list.Managed(QueuedWork).init(allocator),
        };
        const thread = try std.Thread.spawn(.{}, workerMain, .{lane});
        thread.detach();
        return lane;
    }

    fn enqueue(self: *Lane, queued: QueuedWork) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.queue.append(queued);
        self.condition.signal();
    }

    fn workerMain(self: *Lane) void {
        self.workerLoop() catch |err| {
            std.fs.File.stderr().deprecatedWriter().print("muxlyd lane worker error: {}\n", .{err}) catch {};
        };
    }

    fn workerLoop(self: *Lane) !void {
        while (true) {
            self.mutex.lock();
            while (self.queue.items.len == 0) {
                self.condition.wait(&self.mutex);
            }
            const queued = self.queue.orderedRemove(0);
            self.mutex.unlock();

            self.executor.executeQueuedWork(queued);
        }
    }
};

const ServerExecutor = struct {
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    lanes_mutex: std.Thread.Mutex = .{},
    root_lane: *Lane,
    document_lanes: std.array_list.Managed(*Lane),

    fn init(allocator: std.mem.Allocator, store: *store_mod.Store) !*ServerExecutor {
        const executor = try allocator.create(ServerExecutor);
        errdefer allocator.destroy(executor);

        executor.* = .{
            .allocator = allocator,
            .store = store,
            .root_lane = undefined,
            .document_lanes = std.array_list.Managed(*Lane).init(allocator),
        };
        errdefer executor.document_lanes.deinit();
        executor.root_lane = try Lane.initRoot(allocator, executor);
        return executor;
    }

    fn enqueue(
        self: *ServerExecutor,
        lane_key: router.ExecutionLane,
        request: muxly.conversation_broker.DispatchRequest,
        session: *ConnectionSession,
    ) !void {
        const lane = try self.resolveLane(lane_key);
        try lane.enqueue(.{
            .request = .{
                .request = request,
                .session = session,
            },
        });
    }

    fn enqueueRootMaintenance(self: *ServerExecutor, kind: MaintenanceKind) !void {
        try self.root_lane.enqueue(.{ .maintenance = kind });
    }

    fn resolveLane(self: *ServerExecutor, lane_key: router.ExecutionLane) !*Lane {
        return switch (lane_key) {
            .root => self.root_lane,
            .document_coordinator => |document_path| blk: {
                self.lanes_mutex.lock();
                defer self.lanes_mutex.unlock();

                for (self.document_lanes.items) |lane| {
                    if (lane.domain_root_node_id == null and std.mem.eql(u8, lane.document_path.?, document_path)) {
                        self.allocator.free(document_path);
                        break :blk lane;
                    }
                }

                const lane = try Lane.initDocumentLane(self.allocator, self, document_path, null);
                try self.document_lanes.append(lane);
                break :blk lane;
            },
            .document_domain => |domain| blk: {
                self.lanes_mutex.lock();
                defer self.lanes_mutex.unlock();

                for (self.document_lanes.items) |lane| {
                    if (lane.domain_root_node_id != null and
                        lane.domain_root_node_id.? == domain.root_node_id and
                        std.mem.eql(u8, lane.document_path.?, domain.document_path))
                    {
                        self.allocator.free(domain.document_path);
                        break :blk lane;
                    }
                }

                const lane = try Lane.initDocumentLane(
                    self.allocator,
                    self,
                    domain.document_path,
                    domain.root_node_id,
                );
                try self.document_lanes.append(lane);
                break :blk lane;
            },
        };
    }

    fn executeQueuedWork(self: *ServerExecutor, queued: QueuedWork) void {
        switch (queued) {
            .request => |request_item| self.executeQueuedRequest(request_item.request, request_item.session),
            .maintenance => |kind| self.executeMaintenance(kind),
        }
    }

    fn executeQueuedRequest(
        self: *ServerExecutor,
        request: muxly.conversation_broker.DispatchRequest,
        session: *ConnectionSession,
    ) void {
        var owned_request = request;
        defer owned_request.deinit();
        defer session.finishPendingRequest();
        defer session.release();

        if (session.isClosed()) return;

        const response_json = router.handleRequest(
            self.allocator,
            self.store,
            owned_request.request_json,
        ) catch |err| {
            const message = std.fmt.allocPrint(
                self.allocator,
                "daemon request failed: {s}",
                .{@errorName(err)},
            ) catch return;
            defer self.allocator.free(message);

            const frame = owned_request.buildFailureFrame(self.allocator, message) catch return;
            defer self.allocator.free(frame.bytes);
            session.writeFrame(frame.bytes) catch {
                session.markClosed();
            };
            return;
        };

        const frame = owned_request.buildSuccessFrameOwned(self.allocator, response_json) catch |err| {
            self.allocator.free(response_json);
            const message = std.fmt.allocPrint(
                self.allocator,
                "daemon response encode failed: {s}",
                .{@errorName(err)},
            ) catch return;
            defer self.allocator.free(message);

            const failure = owned_request.buildFailureFrame(self.allocator, message) catch return;
            defer self.allocator.free(failure.bytes);
            session.writeFrame(failure.bytes) catch {
                session.markClosed();
            };
            return;
        };
        defer self.allocator.free(frame.bytes);

        session.writeFrame(frame.bytes) catch {
            session.markClosed();
        };
    }

    fn executeMaintenance(self: *ServerExecutor, kind: MaintenanceKind) void {
        switch (kind) {
            .pump_tmux => {
                self.store.pumpTmuxBackend() catch |err| switch (err) {
                    error.FileNotFound,
                    error.TmuxCommandFailed,
                    error.ControlModeUnavailable,
                    error.ControlModeExited,
                    => {},
                    else => {
                        std.fs.File.stderr().deprecatedWriter().print("muxlyd tmux pump error: {}\n", .{err}) catch {};
                    },
                };
            },
        }
    }
};

fn tmuxPumpMain(executor: *ServerExecutor) void {
    while (true) {
        executor.enqueueRootMaintenance(.pump_tmux) catch {};
        std.Thread.sleep(projection_pump_interval_ms * std.time.ns_per_ms);
    }
}

const SpecialRequestKind = enum {
    none,
    tty_stream_open,
    tty_stream_close,
    pane_capture_stream_open,
    pane_scroll_stream_open,
    projection_stream_open,
    projection_stream_close,
};

const ResolvedTtyStreamTarget = struct {
    conversation_id: []const u8,
    request_id: ?u64,
    target: ?protocol.RequestTarget,
    document_path: []u8,
    node_id: u64,
    session_name: []u8,
    pane_id: []u8,

    fn deinit(self: *ResolvedTtyStreamTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.document_path);
        allocator.free(self.session_name);
        allocator.free(self.pane_id);
    }
};

fn specialRequestKind(allocator: std.mem.Allocator, request_json: []const u8) !SpecialRequestKind {
    const parsed = protocol.parseRequest(allocator, request_json) catch return .none;
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.method, "tty.stream.open")) return .tty_stream_open;
    if (std.mem.eql(u8, parsed.value.method, "tty.stream.close")) return .tty_stream_close;
    if (std.mem.eql(u8, parsed.value.method, "pane.capture.stream.open")) return .pane_capture_stream_open;
    if (std.mem.eql(u8, parsed.value.method, "pane.scroll.stream.open")) return .pane_scroll_stream_open;
    if (std.mem.eql(u8, parsed.value.method, "projection.stream.open")) return .projection_stream_open;
    if (std.mem.eql(u8, parsed.value.method, "projection.stream.close")) return .projection_stream_close;
    return .none;
}

fn handleTtyStreamOpen(
    context: ConnectionContext,
    session: *ConnectionSession,
    request: *muxly.conversation_broker.DispatchRequest,
) !void {
    const response = switch (request.response_mode) {
        .envelope => |value| value,
        .json_rpc => {
            const failure = try request.buildFailureFrame(
                context.allocator,
                "tty.stream.open requires a conversation transport",
            );
            defer context.allocator.free(failure.bytes);
            try session.writeFrame(failure.bytes);
            return;
        },
    };

    if (!session.tryReservePendingSlot()) {
        const failure = try request.buildFailureFrame(
            context.allocator,
            "connection has too many pending requests",
        );
        defer context.allocator.free(failure.bytes);
        try session.writeFrame(failure.bytes);
        return;
    }
    defer session.finishPendingRequest();

    var resolved = resolveTtyStreamTarget(context.allocator, context.store, response, request.request_json) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "unable to open tty stream: {s}",
            .{@errorName(err)},
        );
        defer context.allocator.free(message);

        const failure = try request.buildFailureFrame(context.allocator, message);
        defer context.allocator.free(failure.bytes);
        try session.writeFrame(failure.bytes);
        return;
    };
    defer resolved.deinit(context.allocator);

    const control = control_mode.ControlConnection.initAttach(
        context.allocator,
        resolved.session_name,
    ) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "unable to attach tty stream backend: {s}",
            .{@errorName(err)},
        );
        defer context.allocator.free(message);

        const failure = try request.buildFailureFrame(context.allocator, message);
        defer context.allocator.free(failure.bytes);
        try session.writeFrame(failure.bytes);
        return;
    };

    const handle = try TtyStreamHandle.init(
        context.allocator,
        response.conversation_id,
        resolved.session_name,
        resolved.pane_id,
    );
    errdefer handle.deinit();
    try context.tty_stream_registry.register(handle);
    defer context.tty_stream_registry.unregister(handle.conversation_id);
    defer handle.deinit();

    var ack_json = std.array_list.Managed(u8).init(context.allocator);
    defer ack_json.deinit();
    try protocol.writeSuccess(
        ack_json.writer(),
        if (response.request_id) |value| .{ .integer = @intCast(value) } else null,
        "{\"attached\":true,\"mode\":\"live-only\"}",
    );
    const ack = try protocol.allocConversationEnvelope(
        context.allocator,
        response.conversation_id,
        response.request_id,
        response.target,
        .rpc,
        ack_json.items,
        false,
        null,
    );
    defer context.allocator.free(ack);
    try session.writeFrame(ack);

    const reader_thread = try std.Thread.spawn(
        .{},
        ttyStreamReaderMain,
        .{ handle, control },
    );
    defer reader_thread.join();

    while (true) {
        switch (try handle.waitNextChunk()) {
            .closed => break,
            .overflow => {
                const frame = try protocol.allocConversationEnvelope(
                    context.allocator,
                    response.conversation_id,
                    null,
                    response.target,
                    .tty_data,
                    "{\"overflow\":true}",
                    false,
                    null,
                );
                defer context.allocator.free(frame);
                session.writeFrame(frame) catch {
                    handle.requestClose();
                    break;
                };
            },
            .data => |chunk| {
                defer context.allocator.free(chunk);

                const chunk_json = try std.json.Stringify.valueAlloc(context.allocator, chunk, .{});
                defer context.allocator.free(chunk_json);
                const payload_json = try std.fmt.allocPrint(
                    context.allocator,
                    "{{\"chunk\":{s}}}",
                    .{chunk_json},
                );
                defer context.allocator.free(payload_json);

                const frame = try protocol.allocConversationEnvelope(
                    context.allocator,
                    response.conversation_id,
                    null,
                    response.target,
                    .tty_data,
                    payload_json,
                    false,
                    null,
                );
                defer context.allocator.free(frame);
                session.writeFrame(frame) catch {
                    handle.requestClose();
                    break;
                };
            },
        }
    }

    const closed_frame = try protocol.allocConversationEnvelope(
        context.allocator,
        response.conversation_id,
        null,
        response.target,
        .tty_data,
        "null",
        true,
        null,
    );
    defer context.allocator.free(closed_frame);
    session.writeFrame(closed_frame) catch {};
}

fn handleTtyStreamClose(
    context: ConnectionContext,
    session: *ConnectionSession,
    request: *muxly.conversation_broker.DispatchRequest,
) !void {
    const parsed = try protocol.parseRequest(context.allocator, request.request_json);
    defer parsed.deinit();

    const stream_conversation_id = protocol.getString(parsed.value.params, "streamConversationId") orelse {
        const failure = try request.buildFailureFrame(
            context.allocator,
            "streamConversationId is required",
        );
        defer context.allocator.free(failure.bytes);
        try session.writeFrame(failure.bytes);
        return;
    };

    const closed = context.tty_stream_registry.requestClose(stream_conversation_id);
    const result_json = try std.fmt.allocPrint(
        context.allocator,
        "{{\"ok\":true,\"closed\":{s}}}",
        .{if (closed) "true" else "false"},
    );
    defer context.allocator.free(result_json);

    const success = try request.buildSuccessFrameOwned(
        context.allocator,
        try context.allocator.dupe(u8, result_json),
    );
    defer context.allocator.free(success.bytes);
    try session.writeFrame(success.bytes);
}

const PaneCaptureRequestKind = enum {
    capture,
    scroll,
};

const ResolvedPaneCaptureRequest = struct {
    pane_id: []u8,
    start_line: ?i64 = null,
    end_line: ?i64 = null,

    fn deinit(self: *ResolvedPaneCaptureRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.pane_id);
    }
};

fn resolvePaneCaptureRequest(
    allocator: std.mem.Allocator,
    request_json: []const u8,
    request_kind: PaneCaptureRequestKind,
) !ResolvedPaneCaptureRequest {
    const parsed = try protocol.parseRequest(allocator, request_json);
    defer parsed.deinit();

    const document_path = try protocol.requestDocumentPath(parsed.value);
    try protocol.validateRootDocumentOnlyTarget(document_path);

    const pane_id = protocol.getString(parsed.value.params, "paneId") orelse return error.MissingPaneId;
    var resolved = ResolvedPaneCaptureRequest{
        .pane_id = try allocator.dupe(u8, pane_id),
    };
    errdefer resolved.deinit(allocator);

    if (request_kind == .scroll) {
        resolved.start_line = protocol.getInteger(parsed.value.params, "startLine") orelse return error.MissingStartLine;
        resolved.end_line = protocol.getInteger(parsed.value.params, "endLine") orelse return error.MissingEndLine;
    }

    return resolved;
}

fn handlePaneCaptureStreamOpen(
    context: ConnectionContext,
    session: *ConnectionSession,
    request: *muxly.conversation_broker.DispatchRequest,
    request_kind: PaneCaptureRequestKind,
) !void {
    const response = switch (request.response_mode) {
        .envelope => |value| value,
        .json_rpc => {
            const failure = try request.buildFailureFrame(
                context.allocator,
                "pane capture streaming requires a conversation transport",
            );
            defer context.allocator.free(failure.bytes);
            try session.writeFrame(failure.bytes);
            return;
        },
    };

    if (!session.tryReservePendingSlot()) {
        const failure = try request.buildFailureFrame(
            context.allocator,
            "connection has too many pending requests",
        );
        defer context.allocator.free(failure.bytes);
        try session.writeFrame(failure.bytes);
        return;
    }
    defer session.finishPendingRequest();

    var resolved = resolvePaneCaptureRequest(context.allocator, request.request_json, request_kind) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "unable to open pane capture stream: {s}",
            .{@errorName(err)},
        );
        defer context.allocator.free(message);

        const failure = try request.buildFailureFrame(context.allocator, message);
        defer context.allocator.free(failure.bytes);
        try session.writeFrame(failure.bytes);
        return;
    };
    defer resolved.deinit(context.allocator);

    const capture = switch (request_kind) {
        .capture => context.store.captureTmuxPane(resolved.pane_id),
        .scroll => context.store.scrollTmuxPane(
            resolved.pane_id,
            resolved.start_line.?,
            resolved.end_line.?,
        ),
    } catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "unable to capture pane stream: {s}",
            .{@errorName(err)},
        );
        defer context.allocator.free(message);

        const failure = try request.buildFailureFrame(context.allocator, message);
        defer context.allocator.free(failure.bytes);
        try session.writeFrame(failure.bytes);
        return;
    };
    defer context.allocator.free(capture);

    var ack_json = std.array_list.Managed(u8).init(context.allocator);
    defer ack_json.deinit();
    try protocol.writeSuccess(
        ack_json.writer(),
        if (response.request_id) |value| .{ .integer = @intCast(value) } else null,
        "{\"attached\":true,\"mode\":\"chunked-finite\"}",
    );
    const ack = try protocol.allocConversationEnvelope(
        context.allocator,
        response.conversation_id,
        response.request_id,
        response.target,
        .rpc,
        ack_json.items,
        false,
        null,
    );
    defer context.allocator.free(ack);
    try session.writeFrame(ack);

    var offset: usize = 0;
    while (offset < capture.len) {
        const end = @min(capture.len, offset + max_capture_stream_chunk_bytes);
        const chunk_json = try std.json.Stringify.valueAlloc(context.allocator, capture[offset..end], .{});
        defer context.allocator.free(chunk_json);
        const payload_json = try std.fmt.allocPrint(
            context.allocator,
            "{{\"paneId\":{f},\"chunk\":{s}}}",
            .{ std.json.fmt(resolved.pane_id, .{}), chunk_json },
        );
        defer context.allocator.free(payload_json);

        const frame = try protocol.allocConversationEnvelope(
            context.allocator,
            response.conversation_id,
            null,
            response.target,
            .capture_data,
            payload_json,
            false,
            null,
        );
        defer context.allocator.free(frame);
        session.writeFrame(frame) catch {
            session.markClosed();
            return;
        };
        offset = end;
    }

    const closed_frame = try protocol.allocConversationEnvelope(
        context.allocator,
        response.conversation_id,
        null,
        response.target,
        .capture_data,
        "null",
        true,
        null,
    );
    defer context.allocator.free(closed_frame);
    session.writeFrame(closed_frame) catch {};
}

const ResolvedProjectionStreamTarget = struct {
    conversation_id: []const u8,
    request_id: ?u64,
    target: ?protocol.RequestTarget,
    document_path: []u8,
    root_node_id: u64,

    fn deinit(self: *ResolvedProjectionStreamTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.document_path);
    }
};

fn handleProjectionStreamOpen(
    context: ConnectionContext,
    session: *ConnectionSession,
    request: *muxly.conversation_broker.DispatchRequest,
) !void {
    const response = switch (request.response_mode) {
        .envelope => |value| value,
        .json_rpc => {
            const failure = try request.buildFailureFrame(
                context.allocator,
                "projection.stream.open requires a conversation transport",
            );
            defer context.allocator.free(failure.bytes);
            try session.writeFrame(failure.bytes);
            return;
        },
    };

    var resolved = resolveProjectionStreamTarget(context.allocator, context.store, response, request.request_json) catch |err| {
        const message = try std.fmt.allocPrint(
            context.allocator,
            "unable to open projection stream: {s}",
            .{@errorName(err)},
        );
        defer context.allocator.free(message);

        const failure = try request.buildFailureFrame(context.allocator, message);
        defer context.allocator.free(failure.bytes);
        try session.writeFrame(failure.bytes);
        return;
    };
    defer resolved.deinit(context.allocator);

    const handle = try ProjectionStreamHandle.init(
        context.allocator,
        session,
        response.conversation_id,
        response.target,
        resolved.document_path,
        resolved.root_node_id,
    );
    errdefer handle.deinit();
    try context.projection_stream_registry.register(handle);

    var ack_json = std.array_list.Managed(u8).init(context.allocator);
    defer ack_json.deinit();
    try protocol.writeSuccess(
        ack_json.writer(),
        if (response.request_id) |value| .{ .integer = @intCast(value) } else null,
        "{\"attached\":true,\"mode\":\"push\"}",
    );
    const ack = try protocol.allocConversationEnvelope(
        context.allocator,
        response.conversation_id,
        response.request_id,
        response.target,
        .rpc,
        ack_json.items,
        false,
        null,
    );
    defer context.allocator.free(ack);
    try session.writeFrame(ack);
}

fn handleProjectionStreamClose(
    context: ConnectionContext,
    session: *ConnectionSession,
    request: *muxly.conversation_broker.DispatchRequest,
) !void {
    const parsed = try protocol.parseRequest(context.allocator, request.request_json);
    defer parsed.deinit();

    const stream_conversation_id = protocol.getString(parsed.value.params, "streamConversationId") orelse {
        const failure = try request.buildFailureFrame(
            context.allocator,
            "streamConversationId is required",
        );
        defer context.allocator.free(failure.bytes);
        try session.writeFrame(failure.bytes);
        return;
    };

    const closed = context.projection_stream_registry.unregister(stream_conversation_id);
    const result_json = try std.fmt.allocPrint(
        context.allocator,
        "{{\"ok\":true,\"closed\":{s}}}",
        .{if (closed) "true" else "false"},
    );
    defer context.allocator.free(result_json);

    const success = try request.buildSuccessFrameOwned(
        context.allocator,
        try context.allocator.dupe(u8, result_json),
    );
    defer context.allocator.free(success.bytes);
    try session.writeFrame(success.bytes);
}

fn resolveProjectionStreamTarget(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    response: muxly.conversation_broker.DispatchRequest.EnvelopeResponse,
    request_json: []const u8,
) !ResolvedProjectionStreamTarget {
    const parsed = try protocol.parseRequest(allocator, request_json);
    defer parsed.deinit();

    const document_path_text = try protocol.requestDocumentPath(parsed.value);
    const document_entry = try store.documentEntryForPath(document_path_text);
    document_entry.mutex.lock();
    defer document_entry.mutex.unlock();

    const document = &document_entry.document;
    const root_node_id: u64 = if (parsed.value.target) |target| blk: {
        if (target.nodeId) |node_id| {
            _ = document.findNodeConst(@intCast(node_id)) orelse return error.UnknownNode;
            break :blk node_id;
        }
        if (target.selector) |selector| {
            break :blk try document.resolveSelector(selector);
        }
        if (document.view_root_node_id) |view_root_node_id| {
            break :blk view_root_node_id;
        }
        break :blk document.root_node_id;
    } else document.view_root_node_id orelse document.root_node_id;

    return .{
        .conversation_id = response.conversation_id,
        .request_id = response.request_id,
        .target = response.target,
        .document_path = try allocator.dupe(u8, document_path_text),
        .root_node_id = root_node_id,
    };
}

fn resolveTtyStreamTarget(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    response: muxly.conversation_broker.DispatchRequest.EnvelopeResponse,
    request_json: []const u8,
) !ResolvedTtyStreamTarget {
    const parsed = try protocol.parseRequest(allocator, request_json);
    defer parsed.deinit();

    const document_path = try allocator.dupe(u8, try protocol.requestDocumentPath(parsed.value));
    errdefer allocator.free(document_path);

    const node_id_value = try protocol.requestTargetNodeId(parsed.value, "nodeId");
    if (node_id_value < 0) return error.InvalidNodeTarget;
    const node_id: u64 = @intCast(node_id_value);

    const entry = try store.documentEntryForPath(document_path);
    entry.mutex.lock();
    defer entry.mutex.unlock();

    const node = entry.document.findNode(node_id) orelse return error.UnknownNode;
    const tty = switch (node.source) {
        .tty => |value| value,
        else => return error.InvalidSourceKind,
    };
    const pane_id = tty.pane_id orelse return error.MissingPaneId;

    return .{
        .conversation_id = response.conversation_id,
        .request_id = response.request_id,
        .target = response.target,
        .document_path = document_path,
        .node_id = node_id,
        .session_name = try allocator.dupe(u8, tty.session_name),
        .pane_id = try allocator.dupe(u8, pane_id),
    };
}

fn ttyStreamReaderMain(handle: *TtyStreamHandle, initial_control: control_mode.ControlConnection) void {
    var control = initial_control;
    defer control.deinit();
    defer handle.finishReader();

    ttyStreamReaderLoop(handle, &control) catch {
        handle.requestClose();
    };
}

fn ttyStreamReaderLoop(handle: *TtyStreamHandle, control: *control_mode.ControlConnection) !void {
    while (true) {
        handle.mutex.lock();
        const should_close = handle.closing;
        handle.mutex.unlock();
        if (should_close) return;

        control.drainEvents(100, handle, ttyStreamHandleEvent) catch |err| switch (err) {
            error.ControlModeExited => return,
            else => return err,
        };
    }
}

fn ttyStreamHandleEvent(handle: *TtyStreamHandle, event: tmux_events.Event) !void {
    switch (event) {
        .pane_output => |pane_output| {
            if (!std.mem.eql(u8, pane_output.pane_id, handle.pane_id)) return;
            const normalized = try normalizeTmuxOutputChunk(handle.allocator, pane_output.payload);
            defer handle.allocator.free(normalized);
            try handle.enqueueNormalized(normalized);
        },
        .exit => return error.ControlModeExited,
        else => {},
    }
}

fn serveConnection(context: ConnectionContext) void {
    serveConnectionImpl(context) catch |err| {
        std.fs.File.stderr().deprecatedWriter().print("muxlyd connection error: {}\n", .{err}) catch {};
    };
}

fn serveConnectionImpl(context: ConnectionContext) !void {
    var session = try ConnectionSession.init(context.allocator, context.connection);
    defer session.release();
    defer context.projection_stream_registry.closeSession(session);

    var request_reader = muxly.transport.MessageReader.init(context.allocator);
    defer request_reader.deinit();
    var broker = muxly.conversation_broker.Broker.init();

    while (true) {
        const request = try request_reader.readMessageLine(
            session.stream,
            context.max_message_bytes,
        ) orelse {
            session.markClosed();
            break;
        };
        {
            defer context.allocator.free(request);
            if (request.len == 0) continue;

            var handled = try broker.acceptLine(context.allocator, request);
            switch (handled) {
                .immediate => |*responses| {
                    defer responses.deinit();
                    for (responses.frames.items) |response| {
                        session.writeFrame(response.bytes) catch {
                            session.markClosed();
                            return;
                        };
                    }
                    if (context.single_request_per_connection) break;
                },
                .dispatch => |request_dispatch| {
                    var owned_dispatch = request_dispatch;
                    errdefer owned_dispatch.deinit();

                    const special = try specialRequestKind(context.allocator, owned_dispatch.request_json);
                    switch (special) {
                        .tty_stream_open => {
                            try handleTtyStreamOpen(context, session, &owned_dispatch);
                            owned_dispatch.deinit();
                            if (context.single_request_per_connection) break;
                            continue;
                        },
                        .tty_stream_close => {
                            try handleTtyStreamClose(context, session, &owned_dispatch);
                            owned_dispatch.deinit();
                            if (context.single_request_per_connection) break;
                            continue;
                        },
                        .pane_capture_stream_open => {
                            try handlePaneCaptureStreamOpen(context, session, &owned_dispatch, .capture);
                            owned_dispatch.deinit();
                            if (context.single_request_per_connection) break;
                            continue;
                        },
                        .pane_scroll_stream_open => {
                            try handlePaneCaptureStreamOpen(context, session, &owned_dispatch, .scroll);
                            owned_dispatch.deinit();
                            if (context.single_request_per_connection) break;
                            continue;
                        },
                        .projection_stream_open => {
                            try handleProjectionStreamOpen(context, session, &owned_dispatch);
                            owned_dispatch.deinit();
                            if (context.single_request_per_connection) break;
                            continue;
                        },
                        .projection_stream_close => {
                            try handleProjectionStreamClose(context, session, &owned_dispatch);
                            owned_dispatch.deinit();
                            if (context.single_request_per_connection) break;
                            continue;
                        },
                        .none => {},
                    }

                    if (!session.tryReservePendingSlot()) {
                        const failure = try owned_dispatch.buildFailureFrame(
                            context.allocator,
                            "connection has too many pending requests",
                        );
                        defer context.allocator.free(failure.bytes);
                        owned_dispatch.deinit();
                        session.writeFrame(failure.bytes) catch {
                            session.markClosed();
                            return;
                        };
                        if (context.single_request_per_connection) break;
                        continue;
                    }

                    var lane_key = try router.classifyExecutionLane(context.allocator, owned_dispatch.request_json);
                    errdefer lane_key.deinit(context.allocator);

                    session.retain();
                    context.executor.enqueue(lane_key, owned_dispatch, session) catch |err| {
                        session.finishPendingRequest();
                        session.release();
                        owned_dispatch.deinit();
                        return err;
                    };

                    if (context.single_request_per_connection) break;
                },
            }
        }
    }
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
            if (index + 3 < payload.len and
                isOctalDigit(next) and
                isOctalDigit(payload[index + 2]) and
                isOctalDigit(payload[index + 3]))
            {
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

fn isOctalDigit(byte: u8) bool {
    return byte >= '0' and byte <= '7';
}
