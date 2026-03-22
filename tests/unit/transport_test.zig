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

test "http transport parses, validates local-only defaults, and round-trips" {
    var safe_address = try muxly.transport.Address.parse(
        std.testing.allocator,
        "http://127.0.0.1:8080/rpc",
    );
    defer safe_address.deinit(std.testing.allocator);

    try safe_address.validateForClient();

    switch (safe_address.target) {
        .http => |http| {
            try std.testing.expectEqualStrings("127.0.0.1", http.host);
            try std.testing.expectEqual(@as(u16, 8080), http.port);
            try std.testing.expectEqualStrings("/rpc", http.path);
        },
        else => try std.testing.expect(false),
    }

    var unsafe_http = try muxly.transport.Address.parse(
        std.testing.allocator,
        "unsafe+http://10.0.0.5:9000/api",
    );
    defer unsafe_http.deinit(std.testing.allocator);
    try unsafe_http.validateForClient();

    var serialized = std.array_list.Managed(u8).init(std.testing.allocator);
    defer serialized.deinit();
    try unsafe_http.write(serialized.writer());
    try std.testing.expectEqualStrings("unsafe+http://10.0.0.5:9000/api", serialized.items);
}

test "h2 transport parses, validates local-only defaults, and round-trips" {
    var safe_address = try muxly.transport.Address.parse(
        std.testing.allocator,
        "h2://127.0.0.1:8080/rpc",
    );
    defer safe_address.deinit(std.testing.allocator);

    try safe_address.validateForClient();

    switch (safe_address.target) {
        .h2 => |h2| {
            try std.testing.expectEqualStrings("127.0.0.1", h2.host);
            try std.testing.expectEqual(@as(u16, 8080), h2.port);
            try std.testing.expectEqualStrings("/rpc", h2.path);
        },
        else => try std.testing.expect(false),
    }

    var unsafe_h2 = try muxly.transport.Address.parse(
        std.testing.allocator,
        "unsafe+h2://10.0.0.5:9000/api",
    );
    defer unsafe_h2.deinit(std.testing.allocator);
    try unsafe_h2.validateForClient();

    var serialized = std.array_list.Managed(u8).init(std.testing.allocator);
    defer serialized.deinit();
    try unsafe_h2.write(serialized.writer());
    try std.testing.expectEqualStrings("unsafe+h2://10.0.0.5:9000/api", serialized.items);
}

test "h3wt transport parses sha256 pins and round-trips" {
    var address = try muxly.transport.Address.parse(
        std.testing.allocator,
        "h3wt://127.0.0.1:4433/mux?sha256=deadbeef",
    );
    defer address.deinit(std.testing.allocator);

    switch (address.target) {
        .h3wt => |h3wt| {
            try std.testing.expectEqualStrings("127.0.0.1", h3wt.host);
            try std.testing.expectEqual(@as(u16, 4433), h3wt.port);
            try std.testing.expectEqualStrings("/mux", h3wt.path);
            try std.testing.expectEqualStrings("deadbeef", h3wt.certificate_hash.?);
        },
        else => try std.testing.expect(false),
    }

    var serialized = std.array_list.Managed(u8).init(std.testing.allocator);
    defer serialized.deinit();
    try address.write(serialized.writer());
    try std.testing.expectEqualStrings(
        "h3wt://127.0.0.1:4433/mux?sha256=deadbeef",
        serialized.items,
    );
}

test "ssh transport without remote spec uses the remote default transport" {
    var address = try muxly.transport.Address.parse(
        std.testing.allocator,
        "ssh://alice@example.com",
    );
    defer address.deinit(std.testing.allocator);

    switch (address.target) {
        .ssh => |ssh| {
            try std.testing.expectEqualStrings("alice@example.com", ssh.destination);
            try std.testing.expectEqual(@as(?u16, null), ssh.port);
            try std.testing.expectEqualStrings("", ssh.remote_spec);
        },
        else => try std.testing.expect(false),
    }

    var serialized = std.array_list.Managed(u8).init(std.testing.allocator);
    defer serialized.deinit();
    try address.write(serialized.writer());
    try std.testing.expectEqualStrings("ssh://alice@example.com", serialized.items);
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

test "conversation client opens rpc and tty conversations over one compatibility transport" {
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

            while (self.request_count < 4) : (self.request_count += 1) {
                const request = try request_reader.readMessageLine(
                    connection.stream,
                    muxly.transport.max_message_bytes,
                ) orelse break;
                defer self.allocator.free(request);

                const envelope = try muxly.protocol.parseConversationEnvelope(self.allocator, request);
                defer envelope.deinit();

                switch (self.request_count) {
                    0 => {
                        try std.testing.expectEqual(muxly.protocol.ConversationKind.rpc, envelope.value.kind);
                        try std.testing.expect(envelope.value.payload == .object);
                        try std.testing.expect(std.mem.eql(
                            u8,
                            envelope.value.payload.object.get("method").?.string,
                            "ping",
                        ));
                        const response = try muxly.protocol.allocConversationEnvelope(
                            self.allocator,
                            envelope.value.conversationId,
                            envelope.value.requestId,
                            envelope.value.target,
                            envelope.value.kind,
                            \\{"jsonrpc":"2.0","id":1,"result":{"pong":true}}
                        ,
                            true,
                            null,
                        );
                        defer self.allocator.free(response);
                        try connection.stream.writeAll(response);
                        try connection.stream.writeAll("\n");
                    },
                    1 => {
                        try std.testing.expectEqual(muxly.protocol.ConversationKind.rpc, envelope.value.kind);
                        try std.testing.expect(std.mem.eql(
                            u8,
                            envelope.value.payload.object.get("method").?.string,
                            "node.get",
                        ));
                        try std.testing.expectEqual(@as(u64, 7), envelope.value.target.?.nodeId.?);
                        const response = try muxly.protocol.allocConversationEnvelope(
                            self.allocator,
                            envelope.value.conversationId,
                            envelope.value.requestId,
                            envelope.value.target,
                            envelope.value.kind,
                            \\{"jsonrpc":"2.0","id":2,"result":{"id":7,"kind":"tty_leaf","title":"shell","content":"","followTail":false,"lifecycle":"live","source":{"kind":"tty","sessionName":"demo","paneId":"%1"},"children":[],"parentId":1}}
                        ,
                            true,
                            null,
                        );
                        defer self.allocator.free(response);
                        try connection.stream.writeAll(response);
                        try connection.stream.writeAll("\n");
                    },
                    2 => {
                        try std.testing.expectEqual(muxly.protocol.ConversationKind.tty_data, envelope.value.kind);
                        try std.testing.expect(std.mem.eql(
                            u8,
                            envelope.value.payload.object.get("paneId").?.string,
                            "%1",
                        ));
                        const response = try muxly.protocol.allocConversationEnvelope(
                            self.allocator,
                            envelope.value.conversationId,
                            envelope.value.requestId,
                            envelope.value.target,
                            envelope.value.kind,
                            \\{"jsonrpc":"2.0","id":3,"result":{"ok":true}}
                        ,
                            true,
                            null,
                        );
                        defer self.allocator.free(response);
                        try connection.stream.writeAll(response);
                        try connection.stream.writeAll("\n");
                    },
                    3 => {
                        try std.testing.expectEqual(muxly.protocol.ConversationKind.tty_control, envelope.value.kind);
                        try std.testing.expect(envelope.value.payload.object.get("enabled").?.bool);
                        const response = try muxly.protocol.allocConversationEnvelope(
                            self.allocator,
                            envelope.value.conversationId,
                            envelope.value.requestId,
                            envelope.value.target,
                            envelope.value.kind,
                            \\{"jsonrpc":"2.0","id":4,"result":{"ok":true}}
                        ,
                            true,
                            null,
                        );
                        defer self.allocator.free(response);
                        try connection.stream.writeAll(response);
                        try connection.stream.writeAll("\n");
                    },
                    else => unreachable,
                }
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

    var client = try muxly.client.ConversationClient.init(std.testing.allocator, spec);
    defer client.deinit();

    const ping = try client.request("ping", "{}");
    defer std.testing.allocator.free(ping);
    try std.testing.expect(std.mem.indexOf(u8, ping, "\"pong\":true") != null);

    var tty = try client.openTty(.{
        .documentPath = "/",
        .nodeId = 7,
    }, .{
        .rows = 40,
        .cols = 120,
    });
    defer tty.deinit();

    try std.testing.expectEqual(@as(u64, 7), tty.info.node_id);
    try std.testing.expectEqual(@as(u16, 40), tty.info.size.rows);
    try std.testing.expectEqual(@as(u16, 120), tty.info.size.cols);
    try std.testing.expectEqualStrings("/", tty.info.document_path);

    try tty.sendInput("ls\n");
    try tty.setFollowTail(true);

    thread.join();
    if (server.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), server.accept_count);
    try std.testing.expectEqual(@as(usize, 4), server.request_count);
}
