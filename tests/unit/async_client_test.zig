const std = @import("std");
const muxly = @import("muxly");

test "conversation client async rpc handles support poll cancel and late-response drop" {
    const MockServer = struct {
        allocator: std.mem.Allocator,
        listener: std.net.Server,
        request_count: usize = 0,
        first_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        allow_first_response: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        second_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        allow_second_response: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            self.runImpl() catch |err| {
                self.failure = err;
            };
        }

        fn runImpl(self: *@This()) !void {
            var connection = try self.listener.accept();
            defer connection.stream.close();

            var reader = muxly.transport.MessageReader.init(self.allocator);
            defer reader.deinit();

            try self.handleOne(
                &reader,
                connection.stream,
                "slow.one",
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"value\":1}}",
                &self.first_received,
                &self.allow_first_response,
            );

            try self.handleOne(
                &reader,
                connection.stream,
                "slow.cancel",
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"value\":2}}",
                &self.second_received,
                &self.allow_second_response,
            );

            try self.handleOne(
                &reader,
                connection.stream,
                "fast.after_cancel",
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"value\":3}}",
                null,
                null,
            );
        }

        fn handleOne(
            self: *@This(),
            reader: *muxly.transport.MessageReader,
            stream: std.net.Stream,
            expected_method: []const u8,
            response_payload: []const u8,
            received_flag: ?*std.atomic.Value(bool),
            release_flag: ?*std.atomic.Value(bool),
        ) !void {
            const request = (try reader.readMessageLine(
                stream,
                muxly.transport.max_message_bytes,
            )) orelse return error.EndOfStream;
            defer self.allocator.free(request);
            self.request_count += 1;

            const envelope = try muxly.protocol.parseConversationEnvelope(self.allocator, request);
            defer envelope.deinit();

            try std.testing.expectEqual(muxly.protocol.ConversationKind.rpc, envelope.value.kind);
            try std.testing.expectEqualStrings(
                expected_method,
                envelope.value.payload.object.get("method").?.string,
            );

            if (received_flag) |flag| flag.store(true, .release);
            if (release_flag) |flag| try waitForAtomicFlag(flag, true);

            const response = try muxly.protocol.allocConversationEnvelope(
                self.allocator,
                envelope.value.conversationId,
                envelope.value.requestId,
                envelope.value.target,
                envelope.value.kind,
                response_payload,
                true,
                null,
            );
            defer self.allocator.free(response);
            try stream.writeAll(response);
            try stream.writeAll("\n");
        }
    };

    const localhost = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = MockServer{
        .allocator = std.testing.allocator,
        .listener = try localhost.listen(.{ .reuse_address = true }),
    };
    defer server.listener.deinit();

    var thread = try std.Thread.spawn(.{}, MockServer.run, .{&server});
    defer thread.join();

    const port = server.listener.listen_address.getPort();
    const spec = try std.fmt.allocPrint(std.testing.allocator, "tcp://127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(spec);

    var client = try muxly.client.ConversationClient.init(std.testing.allocator, spec);
    defer client.deinit();

    var first = try client.startRequest(.{ .documentPath = "/" }, "slow.one", "{}");
    defer first.deinit();
    try std.testing.expect(first.conversation_id.len > 0);
    try std.testing.expectEqual(@as(u64, 1), first.request_id);
    try waitForAtomicFlag(&server.first_received, true);
    try expectPending(try first.poll());

    var second = try client.startRequest(.{ .documentPath = "/" }, "slow.cancel", "{}");
    defer second.deinit();
    try std.testing.expect(second.conversation_id.len > 0);
    try std.testing.expectEqual(@as(u64, 2), second.request_id);
    try expectPending(try second.poll());
    second.cancel();
    try expectCanceled(try second.poll());
    try std.testing.expectError(error.RequestCanceled, second.wait());

    server.allow_first_response.store(true, .release);
    const first_response = try first.wait();
    defer std.testing.allocator.free(first_response);
    try std.testing.expect(std.mem.indexOf(u8, first_response, "\"value\":1") != null);
    try std.testing.expectError(error.RequestResultConsumed, first.poll());

    try waitForAtomicFlag(&server.second_received, true);

    var third = try client.startRequest(.{ .documentPath = "/" }, "fast.after_cancel", "{}");
    defer third.deinit();
    try std.testing.expectEqual(@as(u64, 3), third.request_id);
    try expectPending(try third.poll());

    server.allow_second_response.store(true, .release);
    const third_response = try third.wait();
    defer std.testing.allocator.free(third_response);
    try std.testing.expect(std.mem.indexOf(u8, third_response, "\"value\":3") != null);

    if (server.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 3), server.request_count);
}

fn waitForAtomicFlag(flag: *std.atomic.Value(bool), expected: bool) !void {
    var attempts: usize = 0;
    while (attempts < 400) : (attempts += 1) {
        if (flag.load(.acquire) == expected) return;
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    return error.TestTimeout;
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
