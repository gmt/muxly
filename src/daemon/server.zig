const std = @import("std");
const muxly = @import("muxly");
const config_mod = @import("config.zig");
const router = @import("router.zig");
const store_mod = @import("state/store.zig");

const max_pending_requests_per_connection: usize = 32;

pub fn serve(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    var thread_safe_allocator = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
    const shared_allocator = thread_safe_allocator.allocator();

    var store = try store_mod.Store.init(shared_allocator);
    defer store.deinit();

    const executor = try ServerExecutor.init(shared_allocator, &store);

    var listener = try muxly.transport.Listener.init(allocator, &config.transport);
    defer listener.deinit();
    const single_request_per_connection = switch (listener.target) {
        .proxy => true,
        .unix, .tcp => false,
    };

    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.writeAll("muxlyd listening on ");
    try listener.writeDescription(stderr);
    try stderr.writeByte('\n');

    while (true) {
        const connection = try listener.accept();
        const thread = try std.Thread.spawn(.{}, serveConnection, .{ConnectionContext{
            .allocator = shared_allocator,
            .store = &store,
            .executor = executor,
            .connection = connection,
            .single_request_per_connection = single_request_per_connection,
        }});
        thread.detach();
    }
}

const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    executor: *ServerExecutor,
    connection: std.net.Server.Connection,
    single_request_per_connection: bool,
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

const QueuedRequest = struct {
    request: muxly.conversation_broker.DispatchRequest,
    session: *ConnectionSession,
};

const Lane = struct {
    allocator: std.mem.Allocator,
    executor: *ServerExecutor,
    document_path: ?[]u8,
    queue: std.array_list.Managed(QueuedRequest),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},

    fn initRoot(allocator: std.mem.Allocator, executor: *ServerExecutor) !*Lane {
        const lane = try allocator.create(Lane);
        errdefer allocator.destroy(lane);
        lane.* = .{
            .allocator = allocator,
            .executor = executor,
            .document_path = null,
            .queue = std.array_list.Managed(QueuedRequest).init(allocator),
        };
        const thread = try std.Thread.spawn(.{}, workerMain, .{lane});
        thread.detach();
        return lane;
    }

    fn initDocument(
        allocator: std.mem.Allocator,
        executor: *ServerExecutor,
        document_path: []u8,
    ) !*Lane {
        const lane = try allocator.create(Lane);
        errdefer allocator.destroy(lane);
        lane.* = .{
            .allocator = allocator,
            .executor = executor,
            .document_path = document_path,
            .queue = std.array_list.Managed(QueuedRequest).init(allocator),
        };
        const thread = try std.Thread.spawn(.{}, workerMain, .{lane});
        thread.detach();
        return lane;
    }

    fn enqueue(self: *Lane, queued: QueuedRequest) !void {
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

            self.executor.executeQueuedRequest(queued);
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
            .request = request,
            .session = session,
        });
    }

    fn resolveLane(self: *ServerExecutor, lane_key: router.ExecutionLane) !*Lane {
        return switch (lane_key) {
            .root => self.root_lane,
            .document => |document_path| blk: {
                self.lanes_mutex.lock();
                defer self.lanes_mutex.unlock();

                for (self.document_lanes.items) |lane| {
                    if (std.mem.eql(u8, lane.document_path.?, document_path)) {
                        self.allocator.free(document_path);
                        break :blk lane;
                    }
                }

                const lane = try Lane.initDocument(self.allocator, self, document_path);
                try self.document_lanes.append(lane);
                break :blk lane;
            },
        };
    }

    fn executeQueuedRequest(self: *ServerExecutor, queued: QueuedRequest) void {
        var request = queued.request;
        defer request.deinit();
        defer queued.session.finishPendingRequest();
        defer queued.session.release();

        if (queued.session.isClosed()) return;

        const response_json = router.handleRequest(
            self.allocator,
            self.store,
            request.request_json,
        ) catch |err| {
            const message = std.fmt.allocPrint(
                self.allocator,
                "daemon request failed: {s}",
                .{@errorName(err)},
            ) catch return;
            defer self.allocator.free(message);

            const frame = request.buildFailureFrame(self.allocator, message) catch return;
            defer self.allocator.free(frame.bytes);
            queued.session.writeFrame(frame.bytes) catch {
                queued.session.markClosed();
            };
            return;
        };

        const frame = request.buildSuccessFrameOwned(self.allocator, response_json) catch |err| {
            self.allocator.free(response_json);
            const message = std.fmt.allocPrint(
                self.allocator,
                "daemon response encode failed: {s}",
                .{@errorName(err)},
            ) catch return;
            defer self.allocator.free(message);

            const failure = request.buildFailureFrame(self.allocator, message) catch return;
            defer self.allocator.free(failure.bytes);
            queued.session.writeFrame(failure.bytes) catch {
                queued.session.markClosed();
            };
            return;
        };
        defer self.allocator.free(frame.bytes);

        queued.session.writeFrame(frame.bytes) catch {
            queued.session.markClosed();
        };
    }
};

fn serveConnection(context: ConnectionContext) void {
    serveConnectionImpl(context) catch |err| {
        std.fs.File.stderr().deprecatedWriter().print("muxlyd connection error: {}\n", .{err}) catch {};
    };
}

fn serveConnectionImpl(context: ConnectionContext) !void {
    var session = try ConnectionSession.init(context.allocator, context.connection);
    defer session.release();

    var request_reader = muxly.transport.MessageReader.init(context.allocator);
    defer request_reader.deinit();
    var broker = muxly.conversation_broker.Broker.init();

    while (true) {
        const request = try request_reader.readMessageLine(
            session.stream,
            muxly.transport.max_message_bytes,
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
