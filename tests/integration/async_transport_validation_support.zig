const std = @import("std");
const muxly = @import("muxly");

const daemon_ready_prefix = "muxlyd listening on ";
const same_lane_sleep_ms: u32 = 240;
const overlap_slow_ms: u32 = 320;
const overlap_fast_ms: u32 = 120;
const disconnect_sleep_ms: u32 = 400;
const cancel_sleep_ms: u32 = 400;
const listen_timeout_ms: i32 = 20_000;
const request_gap_ms: u64 = 20;
const poll_interval_ms: u64 = 10;
const stderr_drain_poll_ms: i32 = 100;

pub const TransportKind = enum {
    tcp,
    http,
    h2,
    h3wt,

    pub fn parse(text: []const u8) !TransportKind {
        if (std.mem.eql(u8, text, "tcp")) return .tcp;
        if (std.mem.eql(u8, text, "http")) return .http;
        if (std.mem.eql(u8, text, "h2")) return .h2;
        if (std.mem.eql(u8, text, "h3wt")) return .h3wt;
        return error.InvalidTransportKind;
    }

    pub fn name(self: TransportKind) []const u8 {
        return switch (self) {
            .tcp => "tcp",
            .http => "http",
            .h2 => "h2",
            .h3wt => "h3wt",
        };
    }

    pub fn requestedTransportSpec(self: TransportKind) []const u8 {
        return switch (self) {
            .tcp => "tcp://127.0.0.1:0",
            .http => "http://127.0.0.1:0/rpc",
            .h2 => "h2://127.0.0.1:0/rpc",
            .h3wt => "h3wt://127.0.0.1:0/mux",
        };
    }
};

pub const Scenario = enum {
    full,
    different_document_overlap,
    same_document_serialization,
    root_vs_document_overlap,
    cancel_and_follow_on,
    disconnect_reconnect,
};

const FirstReady = union(enum) {
    first: []u8,
    second: []u8,
};

const DaemonInstance = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stderr_drain: *DaemonStderrDrain,
    actual_spec: []u8,
    tmp_dir: std.testing.TmpDir,
    identity_path: []u8,
    preserve_tmp: bool = false,

    fn deinit(self: *DaemonInstance) void {
        _ = self.child.kill() catch |err| switch (err) {
            error.AlreadyTerminated => {},
            else => {},
        };
        _ = self.child.wait() catch {};
        self.stderr_drain.deinit();
        self.allocator.free(self.actual_spec);
        self.allocator.free(self.identity_path);
        if (!self.preserve_tmp) self.tmp_dir.cleanup();
    }

    fn preserveArtifacts(self: *DaemonInstance) void {
        self.preserve_tmp = true;
    }
};

const DaemonStderrDrain = struct {
    allocator: std.mem.Allocator,
    stderr_file: std.fs.File,
    log_file: std.fs.File,
    log_path: []u8,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    fn init(
        allocator: std.mem.Allocator,
        dir: std.fs.Dir,
        stderr_file: std.fs.File,
    ) !*DaemonStderrDrain {
        const log_file = try dir.createFile("daemon-stderr.log", .{ .truncate = true, .read = true });
        errdefer log_file.close();
        const log_path = try dir.realpathAlloc(allocator, "daemon-stderr.log");
        errdefer allocator.free(log_path);

        const drain = try allocator.create(DaemonStderrDrain);
        errdefer allocator.destroy(drain);
        drain.* = .{
            .allocator = allocator,
            .stderr_file = stderr_file,
            .log_file = log_file,
            .log_path = log_path,
        };
        errdefer drain.stderr_file.close();
        errdefer drain.log_file.close();

        drain.thread = try std.Thread.spawn(.{}, drainDaemonStderr, .{drain});
        return drain;
    }

    fn deinit(self: *DaemonStderrDrain) void {
        self.shutdown.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.allocator.free(self.log_path);
        self.allocator.destroy(self);
    }
};

pub fn runTransportValidation(
    allocator: std.mem.Allocator,
    kind: TransportKind,
) !void {
    return runTransportScenario(allocator, kind, .full);
}

pub fn runTransportScenario(
    allocator: std.mem.Allocator,
    kind: TransportKind,
    scenario: Scenario,
) !void {
    var daemon = try startDaemon(allocator, kind.requestedTransportSpec());
    defer daemon.deinit();
    errdefer {
        daemon.preserveArtifacts();
        std.debug.print(
            "transport validation failure preserved daemon stderr at {s}\n",
            .{daemon.stderr_drain.log_path},
        );
    }

    var admin = try muxly.client.ConversationClient.init(allocator, daemon.actual_spec);
    defer admin.deinit();

    try createDocument(allocator, &admin, "/a");
    try createDocument(allocator, &admin, "/b");

    switch (scenario) {
        .full => {
            try runDifferentDocumentOverlap(allocator, kind, daemon.actual_spec);
            try runSameDocumentSerialization(allocator, kind, daemon.actual_spec);
            try runRootVsDocumentOverlap(allocator, kind, daemon.actual_spec);
            try runCancelAndFollowOn(allocator, daemon.actual_spec);
            try runDisconnectReconnect(allocator, daemon.actual_spec);
        },
        .different_document_overlap => try runDifferentDocumentOverlap(allocator, kind, daemon.actual_spec),
        .same_document_serialization => try runSameDocumentSerialization(allocator, kind, daemon.actual_spec),
        .root_vs_document_overlap => try runRootVsDocumentOverlap(allocator, kind, daemon.actual_spec),
        .cancel_and_follow_on => try runCancelAndFollowOn(allocator, daemon.actual_spec),
        .disconnect_reconnect => try runDisconnectReconnect(allocator, daemon.actual_spec),
    }
}

fn runDifferentDocumentOverlap(
    allocator: std.mem.Allocator,
    kind: TransportKind,
    actual_spec: []const u8,
) !void {
    var first_client = try muxly.client.ConversationClient.init(allocator, actual_spec);
    defer first_client.deinit();

    var second_client_storage: muxly.client.ConversationClient = undefined;
    const second_client: *muxly.client.ConversationClient = if (kind == .tcp) blk: {
        second_client_storage = try muxly.client.ConversationClient.init(allocator, actual_spec);
        break :blk &second_client_storage;
    } else &first_client;
    defer if (kind == .tcp) second_client_storage.deinit();

    const slow_params = try debugSleepParams(allocator, overlap_slow_ms);
    defer allocator.free(slow_params);
    const fast_params = try debugSleepParams(allocator, overlap_fast_ms);
    defer allocator.free(fast_params);

    const started = try std.time.Instant.now();

    var slow = try first_client.startRequest(.{ .documentPath = "/a" }, "debug.sleep", slow_params);
    defer slow.deinit();

    std.Thread.sleep(request_gap_ms * std.time.ns_per_ms);

    var fast = try second_client.startRequest(.{ .documentPath = "/b" }, "debug.sleep", fast_params);
    defer fast.deinit();

    const first_ready = try waitForEitherReady(&slow, &fast, 3_000);
    switch (first_ready) {
        .first => |bytes| {
            defer allocator.free(bytes);
            return error.ExpectedFastDocumentToCompleteFirst;
        },
        .second => |bytes| {
            defer allocator.free(bytes);
            try expectSleptMs(allocator, bytes, overlap_fast_ms);
        },
    }

    const slow_response = try waitForReady(&slow, 3_000);
    defer allocator.free(slow_response);
    try expectSleptMs(allocator, slow_response, overlap_slow_ms);

    try std.testing.expect((try elapsedMsSince(started)) < 500);
}

fn runSameDocumentSerialization(
    allocator: std.mem.Allocator,
    kind: TransportKind,
    actual_spec: []const u8,
) !void {
    var first_client = try muxly.client.ConversationClient.init(allocator, actual_spec);
    defer first_client.deinit();

    var second_client_storage: muxly.client.ConversationClient = undefined;
    const second_client: *muxly.client.ConversationClient = if (kind == .tcp) blk: {
        second_client_storage = try muxly.client.ConversationClient.init(allocator, actual_spec);
        break :blk &second_client_storage;
    } else &first_client;
    defer if (kind == .tcp) second_client_storage.deinit();

    const params = try debugSleepParams(allocator, same_lane_sleep_ms);
    defer allocator.free(params);

    const started = try std.time.Instant.now();

    var first = try first_client.startRequest(.{ .documentPath = "/a" }, "debug.sleep", params);
    defer first.deinit();

    std.Thread.sleep(100 * std.time.ns_per_ms);

    var second = try second_client.startRequest(.{ .documentPath = "/a" }, "debug.sleep", params);
    defer second.deinit();

    const first_ready = try waitForEitherReady(&first, &second, 3_000);
    switch (first_ready) {
        .first => |bytes| {
            defer allocator.free(bytes);
            try expectSleptMs(allocator, bytes, same_lane_sleep_ms);
        },
        .second => |bytes| {
            defer allocator.free(bytes);
            return error.ExpectedSameDocumentRequestsToStayFIFO;
        },
    }

    const second_response = try waitForReady(&second, 3_000);
    defer allocator.free(second_response);
    try expectSleptMs(allocator, second_response, same_lane_sleep_ms);

    try std.testing.expect((try elapsedMsSince(started)) > 430);
}

fn runRootVsDocumentOverlap(
    allocator: std.mem.Allocator,
    kind: TransportKind,
    actual_spec: []const u8,
) !void {
    var first_client = try muxly.client.ConversationClient.init(allocator, actual_spec);
    defer first_client.deinit();

    var second_client_storage: muxly.client.ConversationClient = undefined;
    const second_client: *muxly.client.ConversationClient = if (kind == .tcp) blk: {
        second_client_storage = try muxly.client.ConversationClient.init(allocator, actual_spec);
        break :blk &second_client_storage;
    } else &first_client;
    defer if (kind == .tcp) second_client_storage.deinit();

    const root_params = try debugSleepParams(allocator, overlap_slow_ms);
    defer allocator.free(root_params);
    const doc_params = try debugSleepParams(allocator, overlap_fast_ms);
    defer allocator.free(doc_params);

    const started = try std.time.Instant.now();

    var root_request = try first_client.startRequest(.{ .documentPath = "/" }, "debug.sleep", root_params);
    defer root_request.deinit();

    std.Thread.sleep(request_gap_ms * std.time.ns_per_ms);

    var doc_request = try second_client.startRequest(.{ .documentPath = "/a" }, "debug.sleep", doc_params);
    defer doc_request.deinit();

    const first_ready = try waitForEitherReady(&root_request, &doc_request, 3_000);
    switch (first_ready) {
        .first => |bytes| {
            defer allocator.free(bytes);
            return error.ExpectedDocumentLaneToCompleteBeforeRootLane;
        },
        .second => |bytes| {
            defer allocator.free(bytes);
            try expectSleptMs(allocator, bytes, overlap_fast_ms);
        },
    }

    const root_response = try waitForReady(&root_request, 3_000);
    defer allocator.free(root_response);
    try expectSleptMs(allocator, root_response, overlap_slow_ms);

    try std.testing.expect((try elapsedMsSince(started)) < 500);
}

fn runCancelAndFollowOn(allocator: std.mem.Allocator, actual_spec: []const u8) !void {
    var client = try muxly.client.ConversationClient.init(allocator, actual_spec);
    defer client.deinit();

    const slow_params = try debugSleepParams(allocator, cancel_sleep_ms);
    defer allocator.free(slow_params);

    var slow = try client.startRequest(.{ .documentPath = "/a" }, "debug.sleep", slow_params);
    defer slow.deinit();

    try expectPending(try slow.poll());
    slow.cancel();
    try expectCanceled(try slow.poll());
    try std.testing.expectError(error.RequestCanceled, slow.wait());

    var ping = try client.startRequest(.{ .documentPath = "/" }, "ping", "{}");
    defer ping.deinit();
    const ping_response = try waitForReady(&ping, 2_000);
    defer allocator.free(ping_response);
    try expectPong(allocator, ping_response);

    std.Thread.sleep((cancel_sleep_ms + 80) * std.time.ns_per_ms);

    const status_response = try client.request("document.status", "{}");
    defer allocator.free(status_response);
    try expectDocumentStatus(allocator, status_response);
}

fn runDisconnectReconnect(allocator: std.mem.Allocator, actual_spec: []const u8) !void {
    const params_json = try debugSleepParams(allocator, disconnect_sleep_ms);
    defer allocator.free(params_json);

    var request_json = std.array_list.Managed(u8).init(allocator);
    defer request_json.deinit();
    try muxly.protocol.writeClientRequestTarget(
        request_json.writer(),
        9001,
        .{ .documentPath = "/a" },
        "debug.sleep",
        params_json,
    );

    var address = try muxly.transport.Address.parse(allocator, actual_spec);
    defer address.deinit(allocator);

    var connection = try muxly.transport.connect(allocator, &address);
    try connection.writeAll(request_json.items);
    try connection.writeAll("\n");
    std.Thread.sleep(50 * std.time.ns_per_ms);
    connection.close();

    var client = try muxly.client.ConversationClient.init(allocator, actual_spec);
    defer client.deinit();

    const ping_response = try client.request("ping", "{}");
    defer allocator.free(ping_response);
    try expectPong(allocator, ping_response);

    const status_response = try client.request("document.status", "{}");
    defer allocator.free(status_response);
    try expectDocumentStatus(allocator, status_response);
}

fn createDocument(
    allocator: std.mem.Allocator,
    client: *muxly.client.ConversationClient,
    path: []const u8,
) !void {
    const path_json = try std.json.Stringify.valueAlloc(allocator, path, .{});
    defer allocator.free(path_json);

    const params_json = try std.fmt.allocPrint(allocator, "{{\"path\":{s}}}", .{path_json});
    defer allocator.free(params_json);

    const response = try client.request("document.create", params_json);
    defer allocator.free(response);
    var parsed = try parseSuccessResponse(allocator, response);
    parsed.deinit();
}

fn startDaemon(allocator: std.mem.Allocator, requested_transport: []const u8) !DaemonInstance {
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("identity");
    const identity_path = try tmp_dir.dir.realpathAlloc(allocator, "identity");
    errdefer allocator.free(identity_path);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("MUXLY_ENABLE_DEBUG_RPC", "1");
    try env_map.put("MUXLY_H3WT_IDENTITY_DIR", identity_path);
    const daemon_binary = try daemonBinaryPath(allocator);
    defer allocator.free(daemon_binary);
    const daemon_transport = try normalizedDaemonTransportSpec(allocator, requested_transport);
    defer allocator.free(daemon_transport);

    var child = std.process.Child.init(
        &.{ daemon_binary, "--transport", daemon_transport },
        allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    child.env_map = &env_map;

    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }
    try child.waitForSpawn();

    const stderr_file = child.stderr orelse return error.MissingChildPipe;
    child.stderr = null;

    const actual_spec = try readListeningSpec(allocator, stderr_file, listen_timeout_ms);
    errdefer allocator.free(actual_spec);
    const stderr_drain = try DaemonStderrDrain.init(allocator, tmp_dir.dir, stderr_file);
    errdefer stderr_drain.deinit();

    return .{
        .allocator = allocator,
        .child = child,
        .stderr_drain = stderr_drain,
        .actual_spec = actual_spec,
        .tmp_dir = tmp_dir,
        .identity_path = identity_path,
    };
}

fn drainDaemonStderr(drain: *DaemonStderrDrain) void {
    defer drain.stderr_file.close();
    defer drain.log_file.close();

    var buffer: [4096]u8 = undefined;
    while (true) {
        if (drain.shutdown.load(.acquire)) return;

        var pollfds = [_]std.posix.pollfd{
            .{
                .fd = drain.stderr_file.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            },
        };
        const ready = std.posix.poll(&pollfds, stderr_drain_poll_ms) catch return;
        if (ready == 0) continue;

        if ((pollfds[0].revents & std.posix.POLL.IN) != 0) {
            const bytes_read = drain.stderr_file.read(&buffer) catch return;
            if (bytes_read == 0) return;
            drain.log_file.writeAll(buffer[0..bytes_read]) catch return;
            continue;
        }

        if ((pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            const bytes_read = drain.stderr_file.read(&buffer) catch return;
            if (bytes_read == 0) return;
            drain.log_file.writeAll(buffer[0..bytes_read]) catch return;
        }
    }
}

fn readListeningSpec(
    allocator: std.mem.Allocator,
    stderr_file: std.fs.File,
    timeout_ms: i32,
) ![]u8 {
    var pending = std.array_list.Managed(u8).init(allocator);
    defer pending.deinit();

    const started = try std.time.Instant.now();
    while ((try elapsedMsSince(started)) < @as(u64, @intCast(timeout_ms))) {
        var pollfds = [_]std.posix.pollfd{
            .{
                .fd = stderr_file.handle,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                .revents = 0,
            },
        };

        const ready = try std.posix.poll(&pollfds, 200);
        if (ready == 0) continue;

        if ((pollfds[0].revents & std.posix.POLL.IN) != 0) {
            var buffer: [1024]u8 = undefined;
            const bytes_read = try stderr_file.read(&buffer);
            if (bytes_read == 0) continue;
            try pending.appendSlice(buffer[0..bytes_read]);

            while (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline_index| {
                const line = pending.items[0..newline_index];
                if (std.mem.startsWith(u8, line, daemon_ready_prefix)) {
                    return try allocator.dupe(u8, line[daemon_ready_prefix.len..]);
                }

                const remaining_len = pending.items.len - newline_index - 1;
                std.mem.copyForwards(
                    u8,
                    pending.items[0..remaining_len],
                    pending.items[newline_index + 1 ..],
                );
                pending.items.len = remaining_len;
            }
        }

        if ((pollfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            if (pending.items.len > 0) {
                std.debug.print("daemon stderr before early exit: {s}\n", .{pending.items});
            }
            return error.DaemonExitedEarly;
        }
    }

    if (pending.items.len > 0) {
        std.debug.print("daemon stderr before readiness timeout: {s}\n", .{pending.items});
    }
    return error.TestTimeout;
}

fn debugSleepParams(allocator: std.mem.Allocator, ms: u32) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"ms\":{d}}}", .{ms});
}

fn waitForEitherReady(
    first: *muxly.client.PendingRpcRequest,
    second: *muxly.client.PendingRpcRequest,
    timeout_ms: u64,
) !FirstReady {
    const started = try std.time.Instant.now();
    while ((try elapsedMsSince(started)) < timeout_ms) {
        switch (try first.poll()) {
            .pending => {},
            .canceled => return error.UnexpectedCanceledRequest,
            .ready => |bytes| return .{ .first = bytes },
        }

        switch (try second.poll()) {
            .pending => {},
            .canceled => return error.UnexpectedCanceledRequest,
            .ready => |bytes| return .{ .second = bytes },
        }

        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn waitForReady(
    pending: *muxly.client.PendingRpcRequest,
    timeout_ms: u64,
) ![]u8 {
    const started = try std.time.Instant.now();
    while ((try elapsedMsSince(started)) < timeout_ms) {
        switch (try pending.poll()) {
            .pending => {},
            .canceled => return error.UnexpectedCanceledRequest,
            .ready => |bytes| return bytes,
        }
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn elapsedMsSince(started: std.time.Instant) !u64 {
    const now = try std.time.Instant.now();
    return now.since(started) / std.time.ns_per_ms;
}

fn parseSuccessResponse(
    allocator: std.mem.Allocator,
    response: []const u8,
) !std.json.Parsed(std.json.Value) {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    if (parsed.value.object.get("error")) |value| {
        std.debug.print("unexpected error response: {f}\n", .{std.json.fmt(value, .{})});
        return error.RequestFailed;
    }
    _ = parsed.value.object.get("result") orelse return error.InvalidResponse;
    return parsed;
}

fn expectSleptMs(allocator: std.mem.Allocator, response: []const u8, expected_ms: u32) !void {
    const parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const slept = result.object.get("sleptMs") orelse return error.InvalidResponse;
    if (slept != .integer) return error.InvalidResponse;
    try std.testing.expectEqual(@as(i64, expected_ms), slept.integer);
}

fn expectPong(allocator: std.mem.Allocator, response: []const u8) !void {
    const parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const pong = result.object.get("pong") orelse return error.InvalidResponse;
    if (pong != .bool) return error.InvalidResponse;
    try std.testing.expect(pong.bool);
}

fn expectDocumentStatus(allocator: std.mem.Allocator, response: []const u8) !void {
    const parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const root_node_id = result.object.get("rootNodeId") orelse return error.InvalidResponse;
    if (root_node_id != .integer) return error.InvalidResponse;
    try std.testing.expectEqual(@as(i64, 1), root_node_id.integer);
}

fn expectPending(result: muxly.client.RpcRequestPoll) !void {
    switch (result) {
        .pending => {},
        else => return error.ExpectedPendingPoll,
    }
}

fn expectCanceled(result: muxly.client.RpcRequestPoll) !void {
    switch (result) {
        .canceled => {},
        else => return error.ExpectedCanceledPoll,
    }
}

fn daemonBinaryPath(allocator: std.mem.Allocator) ![]u8 {
    return try std.process.getEnvVarOwned(allocator, "MUXLY_TEST_DAEMON_BINARY");
}

fn normalizedDaemonTransportSpec(allocator: std.mem.Allocator, requested_transport: []const u8) ![]u8 {
    if (!std.mem.eql(u8, requested_transport, "tcp://127.0.0.1:0")) {
        return try allocator.dupe(u8, requested_transport);
    }

    const localhost = try std.net.Address.parseIp("127.0.0.1", 0);
    var probe = try localhost.listen(.{ .reuse_address = true });
    defer probe.deinit();

    return try std.fmt.allocPrint(
        allocator,
        "tcp://127.0.0.1:{d}",
        .{probe.listen_address.getPort()},
    );
}
