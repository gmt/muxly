const builtin = @import("builtin");
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

const TransportKind = enum {
    tcp,
    http,
    h2,
    h3wt,
};

const FirstReady = union(enum) {
    first: []u8,
    second: []u8,
};

const DaemonInstance = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stderr_file: std.fs.File,
    actual_spec: []u8,
    tmp_dir: std.testing.TmpDir,
    identity_path: []u8,

    fn deinit(self: *DaemonInstance) void {
        self.stderr_file.close();
        _ = self.child.kill() catch |err| switch (err) {
            error.AlreadyTerminated => {},
            else => {},
        };
        _ = self.child.wait() catch {};
        self.allocator.free(self.actual_spec);
        self.allocator.free(self.identity_path);
        self.tmp_dir.cleanup();
    }
};

test "async validation matrix over tcp transport" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try runRpcValidationMatrix(std.testing.allocator, .tcp, "tcp://127.0.0.1:0");
}

test "async validation matrix over http transport" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try runRpcValidationMatrix(std.testing.allocator, .http, "http://127.0.0.1:0/rpc");
}

test "async validation matrix over h2 transport" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try runRpcValidationMatrix(std.testing.allocator, .h2, "h2://127.0.0.1:0/rpc");
}

test "async validation matrix over h3wt transport" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try runRpcValidationMatrix(std.testing.allocator, .h3wt, "h3wt://127.0.0.1:0/mux");
}

test "async validation keeps h3wt tty streams isolated and reattachable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try ensureTmuxAvailable(std.testing.allocator);

    var daemon = try startDaemon(std.testing.allocator, "h3wt://127.0.0.1:0/mux");
    defer daemon.deinit();

    const hot_session_name = try uniqueSessionName(std.testing.allocator, "muxly-async-hot");
    defer std.testing.allocator.free(hot_session_name);
    defer cleanupTmuxSession(std.testing.allocator, hot_session_name);

    const quiet_session_name = try uniqueSessionName(std.testing.allocator, "muxly-async-quiet");
    defer std.testing.allocator.free(quiet_session_name);
    defer cleanupTmuxSession(std.testing.allocator, quiet_session_name);

    const hot_command =
        "sh -lc 'i=0; while [ \"$i\" -lt 300 ]; do printf \"hot-%03d\\n\" \"$i\"; i=$((i+1)); sleep 0.02; done; sleep 10'";
    const quiet_command =
        "sh -lc 'i=0; while [ \"$i\" -lt 80 ]; do printf \"quiet-%03d\\n\" \"$i\"; i=$((i+1)); sleep 0.20; done; sleep 10'";

    const hot_node_id = try createTmuxSessionNode(
        std.testing.allocator,
        daemon.actual_spec,
        hot_session_name,
        hot_command,
    );
    const quiet_node_id = try createTmuxSessionNode(
        std.testing.allocator,
        daemon.actual_spec,
        quiet_session_name,
        quiet_command,
    );

    {
        var client = try muxly.client.ConversationClient.init(std.testing.allocator, daemon.actual_spec);
        defer client.deinit();

        var hot_tty = try client.openTty(.{
            .documentPath = "/",
            .nodeId = hot_node_id,
        }, .{});
        defer hot_tty.deinit();

        var quiet_tty = try client.openTty(.{
            .documentPath = "/",
            .nodeId = quiet_node_id,
        }, .{});
        defer quiet_tty.deinit();

        var hot_stream = try hot_tty.openOutputStream();
        defer hot_stream.deinit();

        var quiet_stream = try quiet_tty.openOutputStream();
        defer quiet_stream.deinit();

        const hot_first = try waitForAnyStreamData(&hot_stream, 5_000);
        defer std.testing.allocator.free(hot_first);
        try std.testing.expect(std.mem.indexOf(u8, hot_first, "hot-") != null);

        const quiet_first = try waitForAnyStreamData(&quiet_stream, 5_000);
        defer std.testing.allocator.free(quiet_first);
        try std.testing.expect(std.mem.indexOf(u8, quiet_first, "quiet-") != null);

        const ping_started = try std.time.Instant.now();
        const ping_response = try client.request("ping", "{}");
        defer std.testing.allocator.free(ping_response);
        try expectPong(std.testing.allocator, ping_response);
        try std.testing.expect((try elapsedMsSince(ping_started)) < 1_500);

        const status_response = try client.request("document.status", "{}");
        defer std.testing.allocator.free(status_response);
        try expectDocumentStatus(std.testing.allocator, status_response);

        try quiet_tty.setFollowTail(false);
        try quiet_tty.setFollowTail(true);

        const hot_next = try waitForAnyStreamData(&hot_stream, 5_000);
        defer std.testing.allocator.free(hot_next);
        try std.testing.expect(std.mem.indexOf(u8, hot_next, "hot-") != null);

        const quiet_next = try waitForAnyStreamData(&quiet_stream, 5_000);
        defer std.testing.allocator.free(quiet_next);
        try std.testing.expect(std.mem.indexOf(u8, quiet_next, "quiet-") != null);
    }

    std.Thread.sleep(150 * std.time.ns_per_ms);

    {
        var client = try muxly.client.ConversationClient.init(std.testing.allocator, daemon.actual_spec);
        defer client.deinit();

        var hot_tty = try client.openTty(.{
            .documentPath = "/",
            .nodeId = hot_node_id,
        }, .{});
        defer hot_tty.deinit();

        var hot_stream = try hot_tty.openOutputStream();
        defer hot_stream.deinit();

        const reattached = try waitForAnyStreamData(&hot_stream, 5_000);
        defer std.testing.allocator.free(reattached);
        try std.testing.expect(std.mem.indexOf(u8, reattached, "hot-") != null);
    }
}

test "async validation streams pane capture and scroll over h2" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try ensureTmuxAvailable(std.testing.allocator);
    try runPaneCaptureStreamValidation(std.testing.allocator, "h2://127.0.0.1:0/rpc");
}

test "async validation streams pane capture and scroll over h3wt" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try ensureTmuxAvailable(std.testing.allocator);
    try runPaneCaptureStreamValidation(std.testing.allocator, "h3wt://127.0.0.1:0/mux");
}

test "async validation surfaces node.get rpc failure instead of InvalidResponse" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var daemon = try startDaemon(std.testing.allocator, "tcp://127.0.0.1:0");
    defer daemon.deinit();

    var client = try muxly.client.ConversationClient.init(std.testing.allocator, daemon.actual_spec);
    defer client.deinit();

    try std.testing.expectError(
        error.RequestFailed,
        client.openTty(.{
            .documentPath = "/",
            .nodeId = 999_999,
        }, .{}),
    );
}

fn runPaneCaptureStreamValidation(
    allocator: std.mem.Allocator,
    transport_spec: []const u8,
) !void {
    var daemon = try startDaemon(allocator, transport_spec);
    defer daemon.deinit();

    const session_name = try uniqueSessionName(allocator, "muxly-capture");
    defer allocator.free(session_name);
    defer cleanupTmuxSession(allocator, session_name);

    const command =
        "sh -lc 'i=0; while [ \"$i\" -lt 1400 ]; do printf \"cap-%04d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n\" \"$i\"; i=$((i+1)); if [ $((i % 25)) -eq 0 ]; then sleep 0.01; fi; done; sleep 10'";
    const node_id = try createTmuxSessionNode(
        allocator,
        daemon.actual_spec,
        session_name,
        command,
    );

    var client = try muxly.client.ConversationClient.init(allocator, daemon.actual_spec);
    defer client.deinit();

    const pane_id = try resolveTtyPaneId(
        allocator,
        &client,
        node_id,
    );
    defer allocator.free(pane_id);

    std.Thread.sleep(800 * std.time.ns_per_ms);

    var capture_stream = try client.openPaneCaptureStream(pane_id);
    defer capture_stream.deinit();
    const ping_response = try client.request("ping", "{}");
    defer allocator.free(ping_response);
    try expectPong(allocator, ping_response);

    const capture = try collectPaneCaptureStream(allocator, &capture_stream, 10_000);
    defer allocator.free(capture.bytes);

    try std.testing.expect(capture.chunk_count > 1);
    try std.testing.expect(std.mem.indexOf(u8, capture.bytes, "cap-0000") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.bytes, "cap-0100") != null);

    var scroll_stream = try client.openPaneScrollStream(pane_id, 0, 20);
    defer scroll_stream.deinit();
    const scroll = try collectPaneCaptureStream(allocator, &scroll_stream, 10_000);
    defer allocator.free(scroll.bytes);

    try std.testing.expect(scroll.chunk_count >= 1);
    try std.testing.expect(std.mem.indexOf(u8, scroll.bytes, "cap-") != null);
}

fn runRpcValidationMatrix(
    allocator: std.mem.Allocator,
    kind: TransportKind,
    requested_transport: []const u8,
) !void {
    var daemon = try startDaemon(allocator, requested_transport);
    defer daemon.deinit();

    var admin = try muxly.client.ConversationClient.init(allocator, daemon.actual_spec);
    defer admin.deinit();

    try createDocument(&admin, "/a");
    try createDocument(&admin, "/b");

    try runDifferentDocumentOverlap(allocator, kind, daemon.actual_spec);
    try runSameDocumentSerialization(allocator, kind, daemon.actual_spec);
    try runRootVsDocumentOverlap(allocator, kind, daemon.actual_spec);
    try runCancelAndFollowOn(allocator, daemon.actual_spec);
    try runDisconnectReconnect(allocator, daemon.actual_spec);
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

fn createDocument(client: *muxly.client.ConversationClient, path: []const u8) !void {
    const path_json = try std.json.Stringify.valueAlloc(std.testing.allocator, path, .{});
    defer std.testing.allocator.free(path_json);

    const params_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":{s}}}", .{path_json});
    defer std.testing.allocator.free(params_json);

    const response = try client.request("document.create", params_json);
    defer std.testing.allocator.free(response);
    var parsed = try parseSuccessResponse(std.testing.allocator, response);
    parsed.deinit();
}

fn createTmuxSessionNode(
    allocator: std.mem.Allocator,
    actual_spec: []const u8,
    session_name: []const u8,
    command: []const u8,
) !u64 {
    var client = try muxly.client.ConversationClient.init(allocator, actual_spec);
    defer client.deinit();

    const session_json = try std.json.Stringify.valueAlloc(allocator, session_name, .{});
    defer allocator.free(session_json);
    const command_json = try std.json.Stringify.valueAlloc(allocator, command, .{});
    defer allocator.free(command_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"sessionName\":{s},\"command\":{s}}}",
        .{ session_json, command_json },
    );
    defer allocator.free(params_json);

    const response = try client.request("session.create", params_json);
    defer allocator.free(response);
    return try extractNodeId(allocator, response);
}

fn resolveTtyPaneId(
    allocator: std.mem.Allocator,
    client: *muxly.client.ConversationClient,
    node_id: u64,
) ![]u8 {
    const response = try client.requestTarget(.{
        .documentPath = "/",
        .nodeId = node_id,
    }, "node.get", "{}");
    defer allocator.free(response);

    const parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;

    const source_value = result.object.get("source") orelse return error.InvalidResponse;
    if (source_value != .object) return error.InvalidResponse;

    const kind_value = source_value.object.get("kind") orelse return error.InvalidResponse;
    if (kind_value != .string) return error.InvalidResponse;
    if (!std.mem.eql(u8, kind_value.string, "tty")) return error.InvalidTtyTarget;

    const pane_id_value = source_value.object.get("paneId") orelse return error.InvalidTtyTarget;
    if (pane_id_value != .string) return error.InvalidResponse;
    return try allocator.dupe(u8, pane_id_value.string);
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
    errdefer stderr_file.close();

    return .{
        .allocator = allocator,
        .child = child,
        .stderr_file = stderr_file,
        .actual_spec = actual_spec,
        .tmp_dir = tmp_dir,
        .identity_path = identity_path,
    };
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

fn waitForAnyStreamData(
    stream: *muxly.client.TtyOutputStream,
    timeout_ms: u64,
) ![]u8 {
    const started = try std.time.Instant.now();
    while ((try elapsedMsSince(started)) < timeout_ms) {
        switch (try stream.pollChunk()) {
            .pending => {},
            .overflow => {},
            .closed => return error.EndOfStream,
            .data => |bytes| return bytes,
        }
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn collectPaneCaptureStream(
    allocator: std.mem.Allocator,
    stream: *muxly.client.PaneCaptureStream,
    timeout_ms: u64,
) !struct { bytes: []u8, chunk_count: usize } {
    var collected = std.array_list.Managed(u8).init(allocator);
    errdefer collected.deinit();

    const started = try std.time.Instant.now();
    var chunk_count: usize = 0;
    while ((try elapsedMsSince(started)) < timeout_ms) {
        switch (try stream.pollChunk()) {
            .pending => {},
            .data => |bytes| {
                defer allocator.free(bytes);
                try collected.appendSlice(bytes);
                chunk_count += 1;
            },
            .closed => {
                return .{
                    .bytes = try collected.toOwnedSlice(),
                    .chunk_count = chunk_count,
                };
            },
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

fn extractNodeId(allocator: std.mem.Allocator, response: []const u8) !u64 {
    const parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const node_id_value = result.object.get("nodeId") orelse return error.InvalidResponse;
    if (node_id_value != .integer or node_id_value.integer < 0) return error.InvalidResponse;
    return @intCast(node_id_value.integer);
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

fn ensureTmuxAvailable(allocator: std.mem.Allocator) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tmux", "-V" },
        .max_output_bytes = 4096,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn cleanupTmuxSession(allocator: std.mem.Allocator, session_name: []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tmux", "kill-session", "-t", session_name },
        .max_output_bytes = 0,
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn uniqueSessionName(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}-{x}",
        .{ prefix, std.crypto.random.int(u32) },
    );
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
