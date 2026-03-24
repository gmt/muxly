const std = @import("std");
const muxly = @import("muxly");

const document_path = "/hot";
const default_runtime_seconds: u64 = 600;
const listen_timeout_ms: i32 = 30_000;
const monitor_poll_ms: u64 = 1_000;
const progress_stall_seconds: u64 = 10;
const validation_interval_seconds: u64 = 3;
const island_count: usize = 8;
const text_leaves_per_island: usize = 4;
const tty_leaves_per_island: usize = 3;

const WorkerKind = enum {
    child_container,
    tty,
    text,
    parent_container,

    fn name(self: WorkerKind) []const u8 {
        return switch (self) {
            .child_container => "child-container",
            .tty => "tty",
            .text => "text",
            .parent_container => "parent-container",
        };
    }
};

const Config = struct {
    seconds: u64 = default_runtime_seconds,
    seed: u64 = 0,
    worker_count: usize = 0,
};

const Island = struct {
    root_id: u64,
    child_arena_id: u64,
    h_container_id: u64,
    v_container_id: u64,
    text_leaf_ids: [text_leaves_per_island]u64,
    tty_leaf_ids: [tty_leaves_per_island]u64,
};

const Topology = struct {
    root_id: u64 = 1,
    islands: [island_count]Island,
};

const Shared = struct {
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    total_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    child_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tty_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    text_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    parent_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failure: FailureState = .{},
};

const FailureState = struct {
    mutex: std.Thread.Mutex = .{},
    message: ?[]u8 = null,

    fn set(self: *FailureState, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.message != null) return;
        self.message = std.fmt.allocPrint(allocator, fmt, args) catch return;
    }
};

const WorkerContext = struct {
    worker_id: usize,
    kind: WorkerKind,
    seed: u64,
    spec: []const u8,
    topology: *const Topology,
    shared: *Shared,
};

const DaemonInstance = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stderr_drain: *DaemonStderrDrain,
    actual_spec: []u8,
    tmp_dir: std.testing.TmpDir,
    socket_path: []u8,
    preserve_tmp: bool = false,

    fn deinit(self: *DaemonInstance) void {
        _ = self.child.kill() catch |err| switch (err) {
            error.AlreadyTerminated => {},
            else => {},
        };
        _ = self.child.wait() catch {};
        self.stderr_drain.deinit();
        self.allocator.free(self.actual_spec);
        self.allocator.free(self.socket_path);
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

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const config = try parseArgs(allocator);

    var daemon = try startDaemon(allocator);
    defer daemon.deinit();
    errdefer {
        daemon.preserveArtifacts();
        std.debug.print(
            "unix contention stress failure preserved daemon stderr at {s}\n",
            .{daemon.stderr_drain.log_path},
        );
    }

    var admin = try muxly.client.ConversationClient.init(allocator, daemon.actual_spec);
    defer admin.deinit();

    try createDocument(allocator, &admin, document_path);
    var topology = try buildTopology(allocator, &admin);
    try validateDocument(allocator, &admin);

    const resolved_worker_count = if (config.worker_count != 0)
        config.worker_count
    else
        computeWorkerCount(osCpuCount());

    std.debug.print(
        "unix-contention-stress seed={d} seconds={d} workers={d} transport={s}\n",
        .{ config.seed, config.seconds, resolved_worker_count, daemon.actual_spec },
    );

    var shared = Shared{};
    const started = try std.time.Instant.now();
    const deadline_ns = config.seconds * std.time.ns_per_s;

    const worker_contexts = try allocator.alloc(WorkerContext, resolved_worker_count);
    defer allocator.free(worker_contexts);
    var worker_threads = try allocator.alloc(std.Thread, resolved_worker_count);
    defer allocator.free(worker_threads);

    for (worker_contexts, 0..) |*context, index| {
        context.* = .{
            .worker_id = index,
            .kind = switch (index % 4) {
                0 => .child_container,
                1 => .tty,
                2 => .text,
                else => .parent_container,
            },
            .seed = config.seed +% @as(u64, @intCast(index * 977)),
            .spec = daemon.actual_spec,
            .topology = &topology,
            .shared = &shared,
        };
        worker_threads[index] = try std.Thread.spawn(.{}, workerMain, .{context});
    }

    var last_total_ops = shared.total_ops.load(.monotonic);
    var last_progress_check = started;
    var last_validation_second: u64 = 0;

    while ((try elapsedNsSince(started)) < deadline_ns and !shared.stop.load(.acquire)) {
        std.Thread.sleep(monitor_poll_ms * std.time.ns_per_ms);

        const elapsed_seconds = (try elapsedNsSince(started)) / std.time.ns_per_s;
        if (elapsed_seconds >= last_validation_second + validation_interval_seconds) {
            last_validation_second = elapsed_seconds;
            validateDocument(allocator, &admin) catch |err| {
                shared.failure.set(allocator, "document validation failed during stress: {s}", .{@errorName(err)});
                shared.stop.store(true, .release);
                break;
            };
        }

        const total_ops = shared.total_ops.load(.monotonic);
        if (total_ops != last_total_ops) {
            last_total_ops = total_ops;
            last_progress_check = try std.time.Instant.now();
            continue;
        }

        if ((try elapsedNsSince(last_progress_check)) >= progress_stall_seconds * std.time.ns_per_s) {
            shared.failure.set(
                allocator,
                "stress progress stalled for {d}s with totals child={d} tty={d} text={d} parent={d}",
                .{
                    progress_stall_seconds,
                    shared.child_ops.load(.monotonic),
                    shared.tty_ops.load(.monotonic),
                    shared.text_ops.load(.monotonic),
                    shared.parent_ops.load(.monotonic),
                },
            );
            shared.stop.store(true, .release);
            break;
        }
    }

    shared.stop.store(true, .release);
    for (worker_threads) |thread| thread.join();

    if (shared.failure.message) |message| {
        std.debug.print("{s}\n", .{message});
        return error.StressFailed;
    }

    try validateDocument(allocator, &admin);
    std.debug.print(
        "unix-contention-stress complete total={d} child={d} tty={d} text={d} parent={d}\n",
        .{
            shared.total_ops.load(.monotonic),
            shared.child_ops.load(.monotonic),
            shared.tty_ops.load(.monotonic),
            shared.text_ops.load(.monotonic),
            shared.parent_ops.load(.monotonic),
        },
    );
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var config = Config{
        .seed = @as(u64, @intCast(std.time.nanoTimestamp())),
    };

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--seconds")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            config.seconds = try std.fmt.parseInt(u64, argv[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--seed")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            config.seed = try std.fmt.parseInt(u64, argv[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--workers")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            config.worker_count = try std.fmt.parseInt(usize, argv[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\usage: muxly-unix-contention-stress-probe [--seconds N] [--seed N] [--workers N]
                \\
            , .{});
            std.process.exit(0);
        }
        return error.InvalidArguments;
    }

    return config;
}

fn osCpuCount() usize {
    return @intCast(std.Thread.getCpuCount() catch 1);
}

fn computeWorkerCount(cpu_count: usize) usize {
    const logical = @max(cpu_count, 1);
    return @max(@min(logical * 3, 64), 16);
}

fn workerMain(context: *const WorkerContext) void {
    var client = muxly.client.ConversationClient.init(std.heap.page_allocator, context.spec) catch |err| {
        context.shared.failure.set(std.heap.page_allocator, "worker {d} failed to init client: {s}", .{ context.worker_id, @errorName(err) });
        context.shared.stop.store(true, .release);
        return;
    };
    defer client.deinit();

    var prng = std.Random.DefaultPrng.init(context.seed);
    const random = prng.random();
    var local_iteration: u64 = 0;

    while (!context.shared.stop.load(.acquire)) : (local_iteration += 1) {
        const burst = 1 + random.uintLessThan(u8, 4);
        var inner: u8 = 0;
        while (inner < burst and !context.shared.stop.load(.acquire)) : (inner += 1) {
            const result = switch (context.kind) {
                .child_container => runChildContainerChurn(&client, context, &prng, local_iteration),
                .tty => runTtyChurn(&client, context, &prng, local_iteration),
                .text => runTextChurn(&client, context, &prng, local_iteration),
                .parent_container => runParentContainerChurn(&client, context, &prng, local_iteration),
            };
            if (result) |_| {
                _ = context.shared.total_ops.fetchAdd(1, .monotonic);
                const counter = switch (context.kind) {
                    .child_container => &context.shared.child_ops,
                    .tty => &context.shared.tty_ops,
                    .text => &context.shared.text_ops,
                    .parent_container => &context.shared.parent_ops,
                };
                _ = counter.fetchAdd(1, .monotonic);
            } else |err| {
                context.shared.failure.set(
                    std.heap.page_allocator,
                    "worker {d} ({s}) failed: {s}",
                    .{ context.worker_id, context.kind.name(), @errorName(err) },
                );
                context.shared.stop.store(true, .release);
                return;
            }
        }

        const jitter_ms = 5 + random.uintLessThan(u8, 35);
        std.Thread.sleep(@as(u64, jitter_ms) * std.time.ns_per_ms);
    }
}

fn runChildContainerChurn(
    client: *muxly.client.ConversationClient,
    context: *const WorkerContext,
    prng: *std.Random.DefaultPrng,
    iteration: u64,
) !void {
    const random = prng.random();
    const island = &context.topology.islands[random.uintLessThan(u8, island_count)];

    var container_title: [96]u8 = undefined;
    const container_title_text = try std.fmt.bufPrint(
        &container_title,
        "child-arena-{d}-{d}-{d}",
        .{ context.worker_id, iteration, random.uintLessThan(u16, 10_000) },
    );
    const container_id = try appendNode(client, document_path, island.child_arena_id, "container", container_title_text);

    var leaf_title: [96]u8 = undefined;
    const leaf_title_text = try std.fmt.bufPrint(
        &leaf_title,
        "leaf-{d}-{d}-{d}",
        .{ context.worker_id, iteration, random.uintLessThan(u16, 10_000) },
    );
    const leaf_id = try appendNode(client, document_path, container_id, "text_leaf", leaf_title_text);

    var chunk_buffer: [96]u8 = undefined;
    const chunk = try std.fmt.bufPrint(&chunk_buffer, "child-churn worker={d} iter={d}\n", .{ context.worker_id, iteration });
    try appendTextChunk(client, document_path, leaf_id, chunk);
    try removeNode(client, document_path, leaf_id);
    try removeNode(client, document_path, container_id);
}

fn runTtyChurn(
    client: *muxly.client.ConversationClient,
    context: *const WorkerContext,
    prng: *std.Random.DefaultPrng,
    iteration: u64,
) !void {
    const random = prng.random();
    const island = &context.topology.islands[random.uintLessThan(u8, island_count)];
    const tty_id = island.tty_leaf_ids[random.uintLessThan(u8, tty_leaves_per_island)];

    var chunk_buffer: [96]u8 = undefined;
    const chunk = try std.fmt.bufPrint(&chunk_buffer, "tty worker={d} iter={d}\n", .{ context.worker_id, iteration });
    try pushSyntheticTtyChunk(client, document_path, tty_id, chunk);
}

fn runTextChurn(
    client: *muxly.client.ConversationClient,
    context: *const WorkerContext,
    prng: *std.Random.DefaultPrng,
    iteration: u64,
) !void {
    const random = prng.random();
    const island = &context.topology.islands[random.uintLessThan(u8, island_count)];
    const leaf_id = island.text_leaf_ids[random.uintLessThan(u8, text_leaves_per_island)];

    if ((iteration % 3) == 0) {
        var replacement_buffer: [96]u8 = undefined;
        const replacement = try std.fmt.bufPrint(
            &replacement_buffer,
            "text-reset worker={d} iter={d}",
            .{ context.worker_id, iteration },
        );
        try updateNodeContent(client, document_path, leaf_id, replacement);
        return;
    }

    var chunk_buffer: [96]u8 = undefined;
    const chunk = try std.fmt.bufPrint(&chunk_buffer, "text-append worker={d} iter={d}\n", .{ context.worker_id, iteration });
    try appendTextChunk(client, document_path, leaf_id, chunk);
}

fn runParentContainerChurn(
    client: *muxly.client.ConversationClient,
    context: *const WorkerContext,
    prng: *std.Random.DefaultPrng,
    iteration: u64,
) !void {
    const random = prng.random();
    var title_buffer: [96]u8 = undefined;
    const title = try std.fmt.bufPrint(
        &title_buffer,
        "root-temp-{d}-{d}-{d}",
        .{ context.worker_id, iteration, random.uintLessThan(u16, 10_000) },
    );
    const container_id = try appendNode(client, document_path, context.topology.root_id, "subdocument", title);

    var child_title_buffer: [96]u8 = undefined;
    const child_title = try std.fmt.bufPrint(&child_title_buffer, "root-temp-child-{d}", .{iteration});
    const leaf_id = try appendNode(client, document_path, container_id, "text_leaf", child_title);

    var chunk_buffer: [96]u8 = undefined;
    const chunk = try std.fmt.bufPrint(&chunk_buffer, "parent-churn worker={d} iter={d}\n", .{ context.worker_id, iteration });
    try appendTextChunk(client, document_path, leaf_id, chunk);
    try removeNode(client, document_path, leaf_id);
    try removeNode(client, document_path, container_id);
}

fn buildTopology(
    allocator: std.mem.Allocator,
    client: *muxly.client.ConversationClient,
) !Topology {
    _ = allocator;
    var topology: Topology = undefined;
    topology.root_id = 1;

    for (&topology.islands, 0..) |*island, index| {
        var island_title: [64]u8 = undefined;
        const island_title_text = try std.fmt.bufPrint(&island_title, "island-{d}", .{index});
        island.root_id = try appendNode(client, document_path, topology.root_id, "subdocument", island_title_text);

        var child_title: [64]u8 = undefined;
        const child_title_text = try std.fmt.bufPrint(&child_title, "arena-{d}", .{index});
        island.child_arena_id = try appendNode(client, document_path, island.root_id, "container", child_title_text);

        var h_title: [64]u8 = undefined;
        const h_title_text = try std.fmt.bufPrint(&h_title, "h-{d}", .{index});
        island.h_container_id = try appendNode(client, document_path, island.root_id, "h_container", h_title_text);

        var v_title: [64]u8 = undefined;
        const v_title_text = try std.fmt.bufPrint(&v_title, "v-{d}", .{index});
        island.v_container_id = try appendNode(client, document_path, island.root_id, "v_container", v_title_text);

        const left_region = try appendNode(client, document_path, island.h_container_id, "scroll_region", "left-region");
        const right_region = try appendNode(client, document_path, island.h_container_id, "scroll_region", "right-region");
        const top_region = try appendNode(client, document_path, island.v_container_id, "scroll_region", "top-region");
        const bottom_region = try appendNode(client, document_path, island.v_container_id, "scroll_region", "bottom-region");

        island.text_leaf_ids[0] = try appendNode(client, document_path, left_region, "text_leaf", "left-text");
        island.text_leaf_ids[1] = try appendNode(client, document_path, right_region, "text_leaf", "right-text");
        island.text_leaf_ids[2] = try appendNode(client, document_path, top_region, "text_leaf", "top-text");
        island.text_leaf_ids[3] = try appendNode(client, document_path, bottom_region, "text_leaf", "bottom-text");

        const tty_region = try appendNode(client, document_path, island.root_id, "container", "tty-region");
        island.tty_leaf_ids[0] = try attachSyntheticTty(client, document_path, tty_region, "tty-a", "synthetic-a");
        island.tty_leaf_ids[1] = try attachSyntheticTty(client, document_path, tty_region, "tty-b", "synthetic-b");
        island.tty_leaf_ids[2] = try attachSyntheticTty(client, document_path, tty_region, "tty-c", "synthetic-c");
    }

    return topology;
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

fn appendNode(
    client: *muxly.client.ConversationClient,
    doc_path: []const u8,
    parent_id: u64,
    kind: []const u8,
    title: []const u8,
) !u64 {
    const allocator = std.heap.page_allocator;
    const kind_json = try std.json.Stringify.valueAlloc(allocator, kind, .{});
    defer allocator.free(kind_json);
    const title_json = try std.json.Stringify.valueAlloc(allocator, title, .{});
    defer allocator.free(title_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"parentId\":{d},\"kind\":{s},\"title\":{s}}}",
        .{ parent_id, kind_json, title_json },
    );
    defer allocator.free(params_json);

    const response = try requestForDocument(client, doc_path, "node.append", params_json);
    defer allocator.free(response);
    return try parseNodeIdResult(allocator, response);
}

fn updateNodeContent(
    client: *muxly.client.ConversationClient,
    doc_path: []const u8,
    node_id: u64,
    content: []const u8,
) !void {
    const allocator = std.heap.page_allocator;
    const content_json = try std.json.Stringify.valueAlloc(allocator, content, .{});
    defer allocator.free(content_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"content\":{s}}}", .{content_json});
    defer allocator.free(params_json);
    const response = try requestForNode(client, doc_path, node_id, "node.update", params_json);
    defer allocator.free(response);
    var parsed = try parseSuccessResponse(allocator, response);
    parsed.deinit();
}

fn removeNode(
    client: *muxly.client.ConversationClient,
    doc_path: []const u8,
    node_id: u64,
) !void {
    const allocator = std.heap.page_allocator;
    const response = try requestForNode(client, doc_path, node_id, "node.remove", "{}");
    defer allocator.free(response);
    var parsed = try parseSuccessResponse(allocator, response);
    parsed.deinit();
}

fn appendTextChunk(
    client: *muxly.client.ConversationClient,
    doc_path: []const u8,
    node_id: u64,
    chunk: []const u8,
) !void {
    const allocator = std.heap.page_allocator;
    const chunk_json = try std.json.Stringify.valueAlloc(allocator, chunk, .{});
    defer allocator.free(chunk_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"chunk\":{s}}}", .{chunk_json});
    defer allocator.free(params_json);
    const response = try requestForNode(client, doc_path, node_id, "debug.text.append", params_json);
    defer allocator.free(response);
    var parsed = try parseSuccessResponse(allocator, response);
    parsed.deinit();
}

fn attachSyntheticTty(
    client: *muxly.client.ConversationClient,
    doc_path: []const u8,
    parent_id: u64,
    title: []const u8,
    session_name: []const u8,
) !u64 {
    const allocator = std.heap.page_allocator;
    const title_json = try std.json.Stringify.valueAlloc(allocator, title, .{});
    defer allocator.free(title_json);
    const session_json = try std.json.Stringify.valueAlloc(allocator, session_name, .{});
    defer allocator.free(session_json);
    const params_json = try std.fmt.allocPrint(
        allocator,
        "{{\"parentId\":{d},\"title\":{s},\"sessionName\":{s}}}",
        .{ parent_id, title_json, session_json },
    );
    defer allocator.free(params_json);
    const response = try requestForDocument(client, doc_path, "debug.tty.attach", params_json);
    defer allocator.free(response);
    return try parseNodeIdResult(allocator, response);
}

fn pushSyntheticTtyChunk(
    client: *muxly.client.ConversationClient,
    doc_path: []const u8,
    node_id: u64,
    chunk: []const u8,
) !void {
    const allocator = std.heap.page_allocator;
    const chunk_json = try std.json.Stringify.valueAlloc(allocator, chunk, .{});
    defer allocator.free(chunk_json);
    const params_json = try std.fmt.allocPrint(allocator, "{{\"chunk\":{s}}}", .{chunk_json});
    defer allocator.free(params_json);
    const response = try requestForNode(client, doc_path, node_id, "debug.tty.push", params_json);
    defer allocator.free(response);
    var parsed = try parseSuccessResponse(allocator, response);
    parsed.deinit();
}

fn validateDocument(allocator: std.mem.Allocator, client: *muxly.client.ConversationClient) !void {
    const response = try requestForDocument(client, document_path, "debug.document.validate", "{}");
    defer allocator.free(response);
    var parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const ok_value = result.object.get("ok") orelse return error.InvalidResponse;
    if (ok_value != .bool or !ok_value.bool) return error.InvalidResponse;
}

fn requestForDocument(
    client: *muxly.client.ConversationClient,
    doc_path: []const u8,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    return try client.requestTarget(.{ .documentPath = doc_path }, method, params_json);
}

fn requestForNode(
    client: *muxly.client.ConversationClient,
    doc_path: []const u8,
    node_id: u64,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    return try client.requestTarget(.{
        .documentPath = doc_path,
        .nodeId = node_id,
    }, method, params_json);
}

fn parseNodeIdResult(
    allocator: std.mem.Allocator,
    response: []const u8,
) !u64 {
    var parsed = try parseSuccessResponse(allocator, response);
    defer parsed.deinit();

    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const node_id = result.object.get("nodeId") orelse return error.InvalidResponse;
    if (node_id != .integer or node_id.integer < 0) return error.InvalidResponse;
    return @intCast(node_id.integer);
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

fn startDaemon(allocator: std.mem.Allocator) !DaemonInstance {
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    const tmp_root = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_root);
    const socket_path = try std.fs.path.join(allocator, &.{ tmp_root, "muxly.sock" });
    errdefer allocator.free(socket_path);

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    try env_map.put("MUXLY_ENABLE_DEBUG_RPC", "1");

    const daemon_binary = try daemonBinaryPath(allocator);
    defer allocator.free(daemon_binary);

    var child = std.process.Child.init(
        &.{ daemon_binary, "--transport", socket_path },
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
        .socket_path = socket_path,
    };
}

fn daemonBinaryPath(allocator: std.mem.Allocator) ![]u8 {
    return try std.process.getEnvVarOwned(allocator, "MUXLY_TEST_DAEMON_BINARY");
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
                if (std.mem.startsWith(u8, line, "muxlyd listening on ")) {
                    return try allocator.dupe(u8, line["muxlyd listening on ".len..]);
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
        const ready = std.posix.poll(&pollfds, 100) catch return;
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

fn elapsedMsSince(started: std.time.Instant) !u64 {
    const now = try std.time.Instant.now();
    return now.since(started) / std.time.ns_per_ms;
}

fn elapsedNsSince(started: std.time.Instant) !u64 {
    const now = try std.time.Instant.now();
    return now.since(started);
}
