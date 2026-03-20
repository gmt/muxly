const std = @import("std");
const muxly = @import("muxly");

test "transport parser keeps unsafe ssh relay metadata" {
    var address = try muxly.transport.Address.parse(
        std.testing.allocator,
        "unsafe+ssh://alice@example.com:2222/tcp://169.254.10.2:4488",
    );
    defer address.deinit(std.testing.allocator);

    try std.testing.expect(address.allow_insecure_tcp);

    switch (address.target) {
        .ssh => |ssh| {
            try std.testing.expectEqualStrings("alice@example.com", ssh.destination);
            try std.testing.expectEqual(@as(?u16, 2222), ssh.port);
            try std.testing.expectEqualStrings("tcp://169.254.10.2:4488", ssh.remote_spec);
        },
        else => try std.testing.expect(false),
    }
}

test "tcp transport rejects non-local-only endpoints without override" {
    var safe_address = try muxly.transport.Address.parse(
        std.testing.allocator,
        "tcp://10.0.0.5:4488",
    );
    defer safe_address.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InsecureTcpAddressRequiresExplicitOverride,
        safe_address.validateForClient(),
    );

    var unsafe_address = try muxly.transport.Address.parse(
        std.testing.allocator,
        "unsafe+tcp://10.0.0.5:4488",
    );
    defer unsafe_address.deinit(std.testing.allocator);

    try unsafe_address.validateForClient();
}

test "persistent client reuses one tcp connection for multiple requests" {
    const MockServer = struct {
        allocator: std.mem.Allocator,
        listener: std.net.Server,
        accept_count: usize = 0,
        request_count: usize = 0,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.runImpl() catch |err| {
                self.failure = err;
            };
        }

        fn runImpl(self: *@This()) !void {
            var connection = try self.listener.accept();
            self.accept_count += 1;
            defer connection.stream.close();
            var request_reader = muxly.transport.MessageReader.init(self.allocator);
            defer request_reader.deinit();

            while (self.request_count < 2) : (self.request_count += 1) {
                const request = try request_reader.readMessageLine(
                    connection.stream,
                    muxly.transport.max_message_bytes,
                ) orelse break;
                defer self.allocator.free(request);

                try std.testing.expect(std.mem.indexOf(u8, request, "\"jsonrpc\":\"2.0\"") != null);
                try connection.stream.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":true}\n");
            }
        }
    };

    const localhost = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = MockServer{
        .allocator = std.testing.allocator,
        .listener = try localhost.listen(.{ .reuse_address = true }),
    };
    defer server.listener.deinit();

    var thread = try std.Thread.spawn(.{}, MockServer.run, .{&server});
    errdefer thread.join();

    const port = server.listener.listen_address.getPort();
    const spec = try std.fmt.allocPrint(std.testing.allocator, "tcp://127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(spec);

    var client = try muxly.client.Client.init(std.testing.allocator, spec);
    defer client.deinit();

    const first = try client.request("ping", "{}");
    defer std.testing.allocator.free(first);
    const second = try client.request("initialize", "{}");
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":true}", first);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":true}", second);

    thread.join();
    if (server.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), server.accept_count);
    try std.testing.expectEqual(@as(usize, 2), server.request_count);
}
