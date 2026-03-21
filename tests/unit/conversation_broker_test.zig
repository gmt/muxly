const std = @import("std");
const muxly = @import("muxly");
const daemon_router = @import("daemon_router");

fn routeDaemonRequest(
    allocator: std.mem.Allocator,
    store: *daemon_router.Store,
    request_json: []const u8,
) ![]u8 {
    return try daemon_router.handleRequest(allocator, store, request_json);
}

const EchoContext = struct {};

fn echoRequest(
    allocator: std.mem.Allocator,
    _: *EchoContext,
    request_json: []const u8,
) ![]u8 {
    const parsed = try muxly.protocol.parseRequest(allocator, request_json);
    defer parsed.deinit();

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();
    try result.writer().writeAll("{\"method\":");
    try result.writer().print("{f}", .{std.json.fmt(parsed.value.method, .{})});
    try result.writer().writeAll("}");

    var response = std.array_list.Managed(u8).init(allocator);
    errdefer response.deinit();
    try muxly.protocol.writeSuccess(response.writer(), parsed.value.id, result.items);
    return try response.toOwnedSlice();
}

fn allocEnvelope(
    allocator: std.mem.Allocator,
    conversation_id: []const u8,
    request_id: ?u64,
    kind: muxly.protocol.ConversationKind,
    payload_json: []const u8,
) ![]u8 {
    return try muxly.protocol.allocConversationEnvelope(
        allocator,
        conversation_id,
        request_id,
        .{ .documentPath = "/" },
        kind,
        payload_json,
        true,
        null,
    );
}

test "conversation router routes interleaved rpc responses by conversation and request id" {
    var router = muxly.conversation_router.ConversationRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.registerConversation("c-1");
    try router.registerConversation("c-2");

    const c1_second = try allocEnvelope(
        std.testing.allocator,
        "c-1",
        2,
        .rpc,
        \\{"jsonrpc":"2.0","id":2,"result":{"slot":"second"}}
    );
    defer std.testing.allocator.free(c1_second);
    const c2_first = try allocEnvelope(
        std.testing.allocator,
        "c-2",
        1,
        .rpc,
        \\{"jsonrpc":"2.0","id":1,"result":{"slot":"other"}}
    );
    defer std.testing.allocator.free(c2_first);
    const c1_first = try allocEnvelope(
        std.testing.allocator,
        "c-1",
        1,
        .rpc,
        \\{"jsonrpc":"2.0","id":1,"result":{"slot":"first"}}
    );
    defer std.testing.allocator.free(c1_first);

    try router.pushEnvelopeBytes(c1_second);
    try router.pushEnvelopeBytes(c2_first);
    try router.pushEnvelopeBytes(c1_first);

    const first_payload = try router.takePayloadForRequest("c-1", 1);
    defer std.testing.allocator.free(first_payload);
    try std.testing.expect(std.mem.indexOf(u8, first_payload, "\"slot\":\"first\"") != null);

    const second_payload = try router.takePayloadForRequest("c-1", 2);
    defer std.testing.allocator.free(second_payload);
    try std.testing.expect(std.mem.indexOf(u8, second_payload, "\"slot\":\"second\"") != null);

    const other_payload = try router.takePayloadForRequest("c-2", 1);
    defer std.testing.allocator.free(other_payload);
    try std.testing.expect(std.mem.indexOf(u8, other_payload, "\"slot\":\"other\"") != null);
}

test "conversation router keeps tty control and data envelopes separated" {
    var router = muxly.conversation_router.ConversationRouter.init(std.testing.allocator);
    defer router.deinit();

    try router.registerConversation("c-tty-data");
    try router.registerConversation("c-tty-ctrl");

    const tty_data = try allocEnvelope(
        std.testing.allocator,
        "c-tty-data",
        null,
        .tty_data,
        \\{"jsonrpc":"2.0","id":null,"result":{"ok":true,"kind":"data"}}
    );
    defer std.testing.allocator.free(tty_data);
    const tty_control = try muxly.protocol.allocConversationEnvelope(
        std.testing.allocator,
        "c-tty-ctrl",
        null,
        .{ .documentPath = "/", .nodeId = 7 },
        .tty_control,
        \\{"jsonrpc":"2.0","id":null,"result":{"ok":true,"kind":"control"}}
    ,
        true,
        .{
            .code = -32001,
            .message = "tail paused",
        },
    );
    defer std.testing.allocator.free(tty_control);

    try router.pushEnvelopeBytes(tty_control);
    try router.pushEnvelopeBytes(tty_data);

    var control_envelope = try router.takeEnvelope("c-tty-ctrl", null);
    defer control_envelope.deinit(std.testing.allocator);
    try std.testing.expectEqual(muxly.protocol.ConversationKind.tty_control, control_envelope.kind);
    try std.testing.expectEqual(@as(i64, -32001), control_envelope.conversation_error.?.code);

    const data_payload = try router.takePayloadForRequest("c-tty-data", null);
    defer std.testing.allocator.free(data_payload);
    try std.testing.expect(std.mem.indexOf(u8, data_payload, "\"kind\":\"data\"") != null);
}

const ChunkedReader = struct {
    bytes: []const u8,
    chunk_size: usize,
    offset: usize = 0,

    pub fn read(self: *ChunkedReader, buffer: []u8) !usize {
        if (self.offset >= self.bytes.len) return 0;
        const end = @min(self.offset + @min(self.chunk_size, buffer.len), self.bytes.len);
        const chunk = self.bytes[self.offset..end];
        std.mem.copyForwards(u8, buffer[0..chunk.len], chunk);
        self.offset = end;
        return chunk.len;
    }
};

test "message reader handles partial harness frame delivery" {
    const first = try allocEnvelope(
        std.testing.allocator,
        "c-1",
        1,
        .rpc,
        \\{"jsonrpc":"2.0","id":1,"result":{"pong":true}}
    );
    defer std.testing.allocator.free(first);
    const second = try allocEnvelope(
        std.testing.allocator,
        "c-2",
        null,
        .tty_data,
        \\{"chunk":"hello"}
    );
    defer std.testing.allocator.free(second);

    const combined = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}\n{s}\n",
        .{ first, second },
    );
    defer std.testing.allocator.free(combined);

    var reader = ChunkedReader{
        .bytes = combined,
        .chunk_size = 5,
    };
    var message_reader = muxly.transport.MessageReader.init(std.testing.allocator);
    defer message_reader.deinit();

    const first_line = (try message_reader.readMessageLine(&reader, muxly.transport.max_message_bytes)).?;
    defer std.testing.allocator.free(first_line);
    const first_parsed = try muxly.protocol.parseConversationEnvelope(std.testing.allocator, first_line);
    defer first_parsed.deinit();
    try std.testing.expectEqualStrings("c-1", first_parsed.value.conversationId);

    const second_line = (try message_reader.readMessageLine(&reader, muxly.transport.max_message_bytes)).?;
    defer std.testing.allocator.free(second_line);
    const second_parsed = try muxly.protocol.parseConversationEnvelope(std.testing.allocator, second_line);
    defer second_parsed.deinit();
    try std.testing.expectEqual(muxly.protocol.ConversationKind.tty_data, second_parsed.value.kind);
}

test "conversation broker preserves conversation identity for rpc envelopes" {
    var store = try daemon_router.Store.init(std.testing.allocator);
    defer store.deinit();
    var broker = muxly.conversation_broker.Broker.init();

    const request = try allocEnvelope(
        std.testing.allocator,
        "c-ping",
        1,
        .rpc,
        \\{"jsonrpc":"2.0","id":1,"target":{"documentPath":"/"},"method":"ping","params":{}}
    );
    defer std.testing.allocator.free(request);

    var batch = try broker.handleLine(std.testing.allocator, request, &store, routeDaemonRequest);
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 1), batch.frames.items.len);
    try std.testing.expectEqual(muxly.conversation_broker.WireKind.envelope, batch.frames.items[0].wire_kind);

    const response = try muxly.protocol.parseConversationEnvelope(std.testing.allocator, batch.frames.items[0].bytes);
    defer response.deinit();
    try std.testing.expectEqualStrings("c-ping", response.value.conversationId);
    try std.testing.expectEqual(@as(?u64, 1), response.value.requestId);
    try std.testing.expectEqual(muxly.protocol.ConversationKind.rpc, response.value.kind);
    try std.testing.expect(response.value.payload == .object);
    try std.testing.expect(response.value.payload.object.get("result").?.object.get("pong").?.bool);
}

test "conversation broker keeps plain json-rpc compatibility responses raw" {
    var store = try daemon_router.Store.init(std.testing.allocator);
    defer store.deinit();
    var broker = muxly.conversation_broker.Broker.init();

    var batch = try broker.handleLine(
        std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
    ,
        &store,
        routeDaemonRequest,
    );
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 1), batch.frames.items.len);
    try std.testing.expectEqual(muxly.conversation_broker.WireKind.json_rpc, batch.frames.items[0].wire_kind);
    try std.testing.expect(std.mem.indexOf(u8, batch.frames.items[0].bytes, "\"pong\":true") != null);
}

test "conversation broker rejects malformed envelopes with conversation-local errors" {
    var context = EchoContext{};
    var broker = muxly.conversation_broker.Broker.init();

    var batch = try broker.handleLine(
        std.testing.allocator,
        \\{"conversationId":"c-bad","kind":"rpc","fin":true}
    ,
        &context,
        echoRequest,
    );
    defer batch.deinit();

    try std.testing.expectEqual(@as(usize, 1), batch.frames.items.len);
    try std.testing.expectEqual(muxly.conversation_broker.WireKind.envelope, batch.frames.items[0].wire_kind);

    const response = try muxly.protocol.parseConversationEnvelope(std.testing.allocator, batch.frames.items[0].bytes);
    defer response.deinit();
    try std.testing.expectEqualStrings("c-bad", response.value.conversationId);
    try std.testing.expectEqual(@as(i64, -32600), response.value.conversationError.?.code);
}

test "conversation broker routes tty data and control envelopes through the same handler path" {
    var context = EchoContext{};
    var broker = muxly.conversation_broker.Broker.init();

    const tty_data = try allocEnvelope(
        std.testing.allocator,
        "c-tty-data",
        null,
        .tty_data,
        \\{"paneId":"%1","keys":"ls\\r"}
    );
    defer std.testing.allocator.free(tty_data);

    var data_batch = try broker.handleLine(std.testing.allocator, tty_data, &context, echoRequest);
    defer data_batch.deinit();
    const data_response = try muxly.protocol.parseConversationEnvelope(std.testing.allocator, data_batch.frames.items[0].bytes);
    defer data_response.deinit();
    try std.testing.expectEqual(muxly.protocol.ConversationKind.tty_data, data_response.value.kind);
    try std.testing.expect(std.mem.indexOf(u8, data_batch.frames.items[0].bytes, "\"pane.sendKeys\"") != null);

    const tty_control = try allocEnvelope(
        std.testing.allocator,
        "c-tty-ctrl",
        null,
        .tty_control,
        \\{"paneId":"%1","enabled":true}
    );
    defer std.testing.allocator.free(tty_control);

    var control_batch = try broker.handleLine(std.testing.allocator, tty_control, &context, echoRequest);
    defer control_batch.deinit();
    const control_response = try muxly.protocol.parseConversationEnvelope(std.testing.allocator, control_batch.frames.items[0].bytes);
    defer control_response.deinit();
    try std.testing.expectEqual(muxly.protocol.ConversationKind.tty_control, control_response.value.kind);
    try std.testing.expect(std.mem.indexOf(u8, control_batch.frames.items[0].bytes, "\"pane.followTail\"") != null);
}
