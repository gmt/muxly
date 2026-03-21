const std = @import("std");
const muxly = @import("muxly");

test "compatibility client pool selects pooled mode for http and ssh" {
    var http_pool = try muxly.client.CompatibilityClientPool.init(
        std.testing.allocator,
        "http://127.0.0.1:8080/rpc",
        "/",
    );
    defer http_pool.deinit();
    try std.testing.expectEqual(
        muxly.client.CompatibilityTransportMode.pooled_connections,
        http_pool.mode,
    );

    var ssh_pool = try muxly.client.CompatibilityClientPool.init(
        std.testing.allocator,
        "ssh://alice@example.com",
        "/",
    );
    defer ssh_pool.deinit();
    try std.testing.expectEqual(
        muxly.client.CompatibilityTransportMode.pooled_connections,
        ssh_pool.mode,
    );

    var tcp_pool = try muxly.client.CompatibilityClientPool.init(
        std.testing.allocator,
        "tcp://127.0.0.1:4488",
        "/",
    );
    defer tcp_pool.deinit();
    try std.testing.expectEqual(
        muxly.client.CompatibilityTransportMode.shared_connection,
        tcp_pool.mode,
    );
}

test "pooled compatibility client pool hands out distinct clients" {
    var pool = try muxly.client.CompatibilityClientPool.init(
        std.testing.allocator,
        "http://127.0.0.1:8080/rpc",
        "/",
    );
    defer pool.deinit();

    var first = try pool.checkout();
    defer first.deinit();
    var second = try pool.checkout();
    defer second.deinit();

    try std.testing.expect(first.client != second.client);
    try std.testing.expectEqualStrings("/", first.client.document_path);
    try std.testing.expectEqualStrings("/", second.client.document_path);
}

test "shared compatibility client pool reuses one client after release" {
    var pool = try muxly.client.CompatibilityClientPool.init(
        std.testing.allocator,
        "tcp://127.0.0.1:4488",
        "/",
    );
    defer pool.deinit();

    var first = try pool.checkout();
    const first_client = first.client;
    first.deinit();

    var second = try pool.checkout();
    defer second.deinit();
    try std.testing.expect(first_client == second.client);
}

test "pooled compatibility client pool applies backpressure at the connection limit" {
    const Waiter = struct {
        pool: *muxly.client.CompatibilityClientPool,
        acquired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.runImpl() catch |err| {
                self.failure = err;
            };
        }

        fn runImpl(self: *@This()) !void {
            var lease = try self.pool.checkout();
            defer lease.deinit();
            self.acquired.store(true, .monotonic);
        }
    };

    var pool = try muxly.client.CompatibilityClientPool.init(
        std.testing.allocator,
        "http://127.0.0.1:8080/rpc",
        "/",
    );
    defer pool.deinit();
    pool.max_connections = 1;

    var first = try pool.checkout();
    defer first.deinit();

    var waiter = Waiter{ .pool = &pool };
    var thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});

    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!waiter.acquired.load(.monotonic));

    first.deinit();
    thread.join();

    if (waiter.failure) |err| return err;
    try std.testing.expect(waiter.acquired.load(.monotonic));
}
