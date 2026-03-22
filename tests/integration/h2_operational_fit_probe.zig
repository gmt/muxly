const std = @import("std");
const muxly = @import("muxly");

const request_gap_ms: u64 = 20;
const poll_interval_ms: u64 = 10;
const stream_timeout_ms: u64 = 10_000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try writeUsage(std.fs.File.stderr().deprecatedWriter());
        return error.InvalidArguments;
    }

    if (std.mem.eql(u8, args[1], "ping-loop")) {
        try runPingLoop(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "sleep-overlap")) {
        try runSleepOverlap(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "mixed-load")) {
        try runMixedLoad(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "reconnect-loop")) {
        try runReconnectLoop(allocator, args[2..]);
        return;
    }

    try writeUsage(std.fs.File.stderr().deprecatedWriter());
    return error.InvalidArguments;
}

fn writeUsage(writer: anytype) !void {
    try writer.writeAll(
        \\usage:
        \\  h2_operational_fit_probe ping-loop --transport SPEC --count N
        \\  h2_operational_fit_probe sleep-overlap --transport SPEC --slow-doc PATH --fast-doc PATH --slow-ms N --fast-ms N
        \\  h2_operational_fit_probe mixed-load --transport SPEC --node-id ID --rpc-count N
        \\  h2_operational_fit_probe reconnect-loop --transport SPEC --count N
        \\
    );
}

fn runPingLoop(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const transport_spec = try requireFlagValue(args, "--transport");
    const count = try parseUsizeFlag(args, "--count");

    var client = try muxly.client.ConversationClient.init(allocator, transport_spec);
    defer client.deinit();

    var latencies = std.array_list.Managed(u64).init(allocator);
    defer latencies.deinit();

    const started = try std.time.Instant.now();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const request_started = try std.time.Instant.now();
        const response = try client.request("ping", "{}");
        defer allocator.free(response);
        try expectPong(allocator, response);
        try latencies.append(try elapsedMsSince(request_started));
    }

    const total_ms = try elapsedMsSince(started);
    try writeLatencySummaryJson(allocator, std.fs.File.stdout().deprecatedWriter(), "ping-loop", latencies.items, total_ms, null);
}

fn runSleepOverlap(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const transport_spec = try requireFlagValue(args, "--transport");
    const slow_doc = try requireFlagValue(args, "--slow-doc");
    const fast_doc = try requireFlagValue(args, "--fast-doc");
    const slow_ms = try parseU32Flag(args, "--slow-ms");
    const fast_ms = try parseU32Flag(args, "--fast-ms");

    var client = try muxly.client.ConversationClient.init(allocator, transport_spec);
    defer client.deinit();

    const slow_params = try debugSleepParams(allocator, slow_ms);
    defer allocator.free(slow_params);
    const fast_params = try debugSleepParams(allocator, fast_ms);
    defer allocator.free(fast_params);

    const started = try std.time.Instant.now();

    var slow = try client.startRequest(.{ .documentPath = slow_doc }, "debug.sleep", slow_params);
    defer slow.deinit();

    std.Thread.sleep(request_gap_ms * std.time.ns_per_ms);

    var fast = try client.startRequest(.{ .documentPath = fast_doc }, "debug.sleep", fast_params);
    defer fast.deinit();

    const first_ready = try waitForEitherReady(&slow, &fast, 3_000);
    var first_completed: []const u8 = undefined;
    switch (first_ready) {
        .first => |bytes| {
            defer allocator.free(bytes);
            first_completed = "slow";
            try expectSleptMs(allocator, bytes, slow_ms);

            const fast_response = try waitForReady(&fast, 3_000);
            defer allocator.free(fast_response);
            try expectSleptMs(allocator, fast_response, fast_ms);
        },
        .second => |bytes| {
            defer allocator.free(bytes);
            first_completed = "fast";
            try expectSleptMs(allocator, bytes, fast_ms);

            const slow_response = try waitForReady(&slow, 3_000);
            defer allocator.free(slow_response);
            try expectSleptMs(allocator, slow_response, slow_ms);
        },
    }

    const wall_ms = try elapsedMsSince(started);

    try std.fs.File.stdout().deprecatedWriter().print(
        "{{\"kind\":\"sleep-overlap\",\"firstCompleted\":{f},\"slowMs\":{d},\"fastMs\":{d},\"wallMs\":{d}}}\n",
        .{
            std.json.fmt(first_completed, .{}),
            slow_ms,
            fast_ms,
            wall_ms,
        },
    );
}

fn runMixedLoad(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const transport_spec = try requireFlagValue(args, "--transport");
    const node_id = try parseU64Flag(args, "--node-id");
    const rpc_count = try parseUsizeFlag(args, "--rpc-count");

    var client = try muxly.client.ConversationClient.init(allocator, transport_spec);
    defer client.deinit();

    const pane_id = try resolvePaneIdForNode(allocator, &client, node_id);
    defer allocator.free(pane_id);

    var ping_latencies = std.array_list.Managed(u64).init(allocator);
    defer ping_latencies.deinit();
    var status_latencies = std.array_list.Managed(u64).init(allocator);
    defer status_latencies.deinit();

    const started = try std.time.Instant.now();

    if (std.mem.startsWith(u8, transport_spec, "h2://") or std.mem.startsWith(u8, transport_spec, "h3wt://")) {
        var stream = try client.openPaneCaptureStream(pane_id);
        defer stream.deinit();

        var chunk_count: usize = 0;
        var byte_count: usize = 0;
        var saw_data = false;
        const first_chunk_deadline = try std.time.Instant.now();
        while ((try elapsedMsSince(first_chunk_deadline)) < 5_000) {
            switch (try stream.pollChunk()) {
                .pending => std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms),
                .data => |bytes| {
                    saw_data = true;
                    byte_count += bytes.len;
                    chunk_count += 1;
                    allocator.free(bytes);
                    break;
                },
                .closed => break,
            }
            if (saw_data) break;
        }

        var i: usize = 0;
        while (i < rpc_count) : (i += 1) {
            try drainCaptureStream(allocator, &stream, &chunk_count, &byte_count);

            if ((i % 2) == 0) {
                const rpc_started = try std.time.Instant.now();
                const response = try client.request("ping", "{}");
                defer allocator.free(response);
                try expectPong(allocator, response);
                try ping_latencies.append(try elapsedMsSince(rpc_started));
            } else {
                const rpc_started = try std.time.Instant.now();
                const response = try client.request("document.status", "{}");
                defer allocator.free(response);
                try expectDocumentStatus(allocator, response);
                try status_latencies.append(try elapsedMsSince(rpc_started));
            }
        }

        try collectRemainingCaptureStream(allocator, &stream, &chunk_count, &byte_count);
        const total_ms = try elapsedMsSince(started);
    try writeMixedLoadSummary(
        allocator,
        std.fs.File.stdout().deprecatedWriter(),
        "native-pane-stream",
        ping_latencies.items,
            status_latencies.items,
            total_ms,
            chunk_count,
            byte_count,
            0,
        );
        return;
    }

    const params_json = try paneCaptureParams(allocator, pane_id);
    defer allocator.free(params_json);

    var active_capture: ?muxly.client.PendingRpcRequest = try startPaneCaptureRequest(&client, params_json);
    defer if (active_capture) |*capture| capture.deinit();

    var capture_count: usize = 0;
    var capture_bytes: usize = 0;

    var i: usize = 0;
    while (i < rpc_count) : (i += 1) {
        if (try pollActivePaneCapture(&active_capture)) |bytes| {
            defer allocator.free(bytes);
            capture_count += 1;
            capture_bytes += bytes.len;
            if (capture_count < 3) {
                active_capture = try startPaneCaptureRequest(&client, params_json);
            }
        }

        if ((i % 2) == 0) {
            const rpc_started = try std.time.Instant.now();
            const response = try client.request("ping", "{}");
            defer allocator.free(response);
            try expectPong(allocator, response);
            try ping_latencies.append(try elapsedMsSince(rpc_started));
        } else {
            const rpc_started = try std.time.Instant.now();
            const response = try client.request("document.status", "{}");
            defer allocator.free(response);
            try expectDocumentStatus(allocator, response);
            try status_latencies.append(try elapsedMsSince(rpc_started));
        }
    }

    while (capture_count < 3) {
        const capture_bytes_value = try waitForActivePaneCapture(&active_capture, 5_000);
        defer allocator.free(capture_bytes_value);
        capture_count += 1;
        capture_bytes += capture_bytes_value.len;
        if (capture_count < 3) {
            active_capture = try startPaneCaptureRequest(&client, params_json);
        }
    }

    const total_ms = try elapsedMsSince(started);
    try writeMixedLoadSummary(
        allocator,
        std.fs.File.stdout().deprecatedWriter(),
        "buffered-pane-capture",
        ping_latencies.items,
        status_latencies.items,
        total_ms,
        0,
        capture_bytes,
        capture_count,
    );
}

fn runReconnectLoop(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const transport_spec = try requireFlagValue(args, "--transport");
    const count = try parseUsizeFlag(args, "--count");

    var latencies = std.array_list.Managed(u64).init(allocator);
    defer latencies.deinit();

    const started = try std.time.Instant.now();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const request_started = try std.time.Instant.now();
        var client = try muxly.client.ConversationClient.init(allocator, transport_spec);
        const response = try client.request("ping", "{}");
        defer allocator.free(response);
        try expectPong(allocator, response);
        client.deinit();
        try latencies.append(try elapsedMsSince(request_started));
    }
    const total_ms = try elapsedMsSince(started);
    try writeLatencySummaryJson(allocator, std.fs.File.stdout().deprecatedWriter(), "reconnect-loop", latencies.items, total_ms, null);
}

fn requireFlagValue(args: []const []const u8, flag: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return error.InvalidArguments;
}

fn parseUsizeFlag(args: []const []const u8, flag: []const u8) !usize {
    return try std.fmt.parseInt(usize, try requireFlagValue(args, flag), 10);
}

fn parseU32Flag(args: []const []const u8, flag: []const u8) !u32 {
    return try std.fmt.parseInt(u32, try requireFlagValue(args, flag), 10);
}

fn parseU64Flag(args: []const []const u8, flag: []const u8) !u64 {
    return try std.fmt.parseInt(u64, try requireFlagValue(args, flag), 10);
}

fn debugSleepParams(allocator: std.mem.Allocator, ms: u32) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{{\"ms\":{d}}}", .{ms});
}

fn paneCaptureParams(allocator: std.mem.Allocator, pane_id: []const u8) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{{\"paneId\":{f}}}",
        .{std.json.fmt(pane_id, .{})},
    );
}

fn startPaneCaptureRequest(
    client: *muxly.client.ConversationClient,
    params_json: []const u8,
) !muxly.client.PendingRpcRequest {
    return try client.startRequest(.{ .documentPath = "/" }, "pane.capture", params_json);
}

fn pollActivePaneCapture(
    active_capture: *?muxly.client.PendingRpcRequest,
) !?[]u8 {
    if (active_capture.*) |*capture| {
        switch (try capture.poll()) {
            .pending => return null,
            .canceled => return error.UnexpectedCanceledRequest,
            .ready => |bytes| {
                capture.deinit();
                active_capture.* = null;
                return bytes;
            },
        }
    }
    return null;
}

fn waitForActivePaneCapture(
    active_capture: *?muxly.client.PendingRpcRequest,
    timeout_ms: u64,
) ![]u8 {
    const started = try std.time.Instant.now();
    while ((try elapsedMsSince(started)) < timeout_ms) {
        if (try pollActivePaneCapture(active_capture)) |bytes| return bytes;
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
    }
    return error.TestTimeout;
}

fn drainCaptureStream(
    allocator: std.mem.Allocator,
    stream: *muxly.client.PaneCaptureStream,
    chunk_count: *usize,
    byte_count: *usize,
) !void {
    while (true) {
        switch (try stream.pollChunk()) {
            .pending => return,
            .closed => return,
            .data => |bytes| {
                defer allocator.free(bytes);
                byte_count.* += bytes.len;
                chunk_count.* += 1;
            },
        }
    }
}

fn collectRemainingCaptureStream(
    allocator: std.mem.Allocator,
    stream: *muxly.client.PaneCaptureStream,
    chunk_count: *usize,
    byte_count: *usize,
) !void {
    const started = try std.time.Instant.now();
    while ((try elapsedMsSince(started)) < stream_timeout_ms) {
        switch (try stream.pollChunk()) {
            .pending => std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms),
            .closed => return,
            .data => |bytes| {
                defer allocator.free(bytes);
                byte_count.* += bytes.len;
                chunk_count.* += 1;
            },
        }
    }
    return error.TestTimeout;
}

fn writeMixedLoadSummary(
    allocator: std.mem.Allocator,
    writer: anytype,
    mode: []const u8,
    ping_latencies: []const u64,
    status_latencies: []const u64,
    total_ms: u64,
    stream_chunk_count: usize,
    stream_byte_count: usize,
    eager_capture_count: usize,
) !void {
    try writer.print(
        "{{\"kind\":\"mixed-load\",\"mode\":{f},\"rpcCount\":{d},\"ping\":",
        .{
            std.json.fmt(mode, .{}),
            ping_latencies.len + status_latencies.len,
        },
    );
    try writeStatsObject(allocator, writer, ping_latencies);
    try writer.writeAll(",\"documentStatus\":");
    try writeStatsObject(allocator, writer, status_latencies);
    try writer.print(
        ",\"streamChunkCount\":{d},\"streamByteCount\":{d},\"eagerCaptureCount\":{d},\"totalMs\":{d}}}\n",
        .{
            stream_chunk_count,
            stream_byte_count,
            eager_capture_count,
            total_ms,
        },
    );
}

fn writeLatencySummaryJson(
    allocator: std.mem.Allocator,
    writer: anytype,
    kind: []const u8,
    latencies: []const u64,
    total_ms: u64,
    extra_field: ?[]const u8,
) !void {
    try writer.print("{{\"kind\":{f},\"count\":{d},\"stats\":", .{
        std.json.fmt(kind, .{}),
        latencies.len,
    });
    try writeStatsObject(allocator, writer, latencies);
    if (extra_field) |value| {
        try writer.print(",\"mode\":{f}", .{std.json.fmt(value, .{})});
    }
    try writer.print(",\"totalMs\":{d}}}\n", .{total_ms});
}

fn writeStatsObject(allocator: std.mem.Allocator, writer: anytype, latencies: []const u64) !void {
    if (latencies.len == 0) {
        try writer.writeAll("{\"count\":0,\"minMs\":0,\"p50Ms\":0,\"p95Ms\":0,\"maxMs\":0}");
        return;
    }

    const scratch = try allocator.alloc(u64, latencies.len);
    defer allocator.free(scratch);
    @memcpy(scratch, latencies);
    std.sort.heap(u64, scratch, {}, comptime std.sort.asc(u64));

    const min_ms = scratch[0];
    const p50_ms = scratch[(scratch.len - 1) / 2];
    const p95_index = @min(scratch.len - 1, @as(usize, @intCast((scratch.len * 95 + 99) / 100 - 1)));
    const p95_ms = scratch[p95_index];
    const max_ms = scratch[scratch.len - 1];

    try writer.print(
        "{{\"count\":{d},\"minMs\":{d},\"p50Ms\":{d},\"p95Ms\":{d},\"maxMs\":{d}}}",
        .{
            scratch.len,
            min_ms,
            p50_ms,
            p95_ms,
            max_ms,
        },
    );
}

const FirstReady = union(enum) {
    first: []u8,
    second: []u8,
};

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
    if (parsed.value.object.get("error")) |_| return error.RequestFailed;
    _ = parsed.value.object.get("result") orelse return error.InvalidResponse;
    return parsed;
}

fn parsePaneIdFromNodeGetResponse(
    allocator: std.mem.Allocator,
    response: []const u8,
) ![]u8 {
    const parsed = parseSuccessResponse(allocator, response) catch |err| switch (err) {
        error.RequestFailed => {
            try std.fs.File.stderr().deprecatedWriter().print("node.get failed: {s}\n", .{response});
            return err;
        },
        else => return err,
    };
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

fn resolvePaneIdForNode(
    allocator: std.mem.Allocator,
    client: *muxly.client.ConversationClient,
    node_id: u64,
) ![]u8 {
    const response = try client.requestTarget(.{
        .documentPath = "/",
        .nodeId = node_id,
    }, "node.get", "{}");
    defer allocator.free(response);
    return try parsePaneIdFromNodeGetResponse(allocator, response);
}

fn expectSleptMs(allocator: std.mem.Allocator, response: []const u8, expected_ms: u32) !void {
    const parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const slept = result.object.get("sleptMs") orelse return error.InvalidResponse;
    if (slept != .integer) return error.InvalidResponse;
    if (slept.integer != expected_ms) return error.InvalidResponse;
}

fn expectPong(allocator: std.mem.Allocator, response: []const u8) !void {
    const parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const pong = result.object.get("pong") orelse return error.InvalidResponse;
    if (pong != .bool or !pong.bool) return error.InvalidResponse;
}

fn expectDocumentStatus(allocator: std.mem.Allocator, response: []const u8) !void {
    const parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const root_node_id = result.object.get("rootNodeId") orelse return error.InvalidResponse;
    if (root_node_id != .integer or root_node_id.integer != 1) return error.InvalidResponse;
}
