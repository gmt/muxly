const std = @import("std");
const muxly = @import("muxly");

test "protocol parse request smoke" {
    const payload =
        \\{"jsonrpc":"2.0","id":7,"method":"document.get","params":{}}
    ;
    const parsed = try muxly.protocol.parseRequest(std.testing.allocator, payload);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("2.0", parsed.value.jsonrpc);
    try std.testing.expectEqualStrings("document.get", parsed.value.method);
}

test "protocol request parsing keeps optional document target" {
    const payload =
        \\{"jsonrpc":"2.0","id":7,"target":{"documentPath":"/docs/demo"},"method":"document.get","params":{}}
    ;
    const parsed = try muxly.protocol.parseRequest(std.testing.allocator, payload);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("/docs/demo", try muxly.protocol.requestDocumentPath(parsed.value));
}

test "protocol request parsing keeps optional node target fields" {
    const payload =
        \\{"jsonrpc":"2.0","id":7,"target":{"documentPath":"/docs/demo","nodeId":12,"selector":"left/pane"},"method":"node.get","params":{}}
    ;
    const parsed = try muxly.protocol.parseRequest(std.testing.allocator, payload);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("/docs/demo", try muxly.protocol.requestDocumentPath(parsed.value));
    try std.testing.expectEqual(@as(i64, 12), try muxly.protocol.requestTargetNodeId(parsed.value, "nodeId"));
    try std.testing.expectEqualStrings("left/pane", parsed.value.target.?.selector.?);
}

test "protocol document targets must be canonical absolute paths" {
    const trailing_payload =
        \\{"jsonrpc":"2.0","id":7,"target":{"documentPath":"/docs/demo/"},"method":"document.get","params":{}}
    ;
    const trailing = try muxly.protocol.parseRequest(std.testing.allocator, trailing_payload);
    defer trailing.deinit();
    try std.testing.expectError(error.InvalidDocumentPath, muxly.protocol.requestDocumentPath(trailing.value));

    const dotted_payload =
        \\{"jsonrpc":"2.0","id":8,"target":{"documentPath":"/docs/./demo"},"method":"document.get","params":{}}
    ;
    const dotted = try muxly.protocol.parseRequest(std.testing.allocator, dotted_payload);
    defer dotted.deinit();
    try std.testing.expectError(error.InvalidDocumentPath, muxly.protocol.requestDocumentPath(dotted.value));

    try std.testing.expect(muxly.protocol.isCanonicalDocumentPath("/"));
    try std.testing.expect(muxly.protocol.isCanonicalDocumentPath("/docs/demo"));
    try std.testing.expect(!muxly.protocol.isCanonicalDocumentPath("/docs//demo"));
    try std.testing.expect(!muxly.protocol.isCanonicalDocumentPath("/docs/../demo"));

    try muxly.protocol.validateRootDocumentOnlyTarget("/");
    try std.testing.expectError(
        error.RootDocumentOnlyTarget,
        muxly.protocol.validateRootDocumentOnlyTarget("/docs/demo"),
    );
    try std.testing.expectError(
        error.InvalidDocumentPath,
        muxly.protocol.validateRootDocumentOnlyTarget("/docs/demo/"),
    );
}

test "protocol client request writer emits document target" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try muxly.protocol.writeClientRequest(
        buffer.writer(),
        42,
        "/docs/demo",
        "document.status",
        "{}",
    );

    const parsed = try muxly.protocol.parseRequest(std.testing.allocator, buffer.items);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("document.status", parsed.value.method);
    try std.testing.expectEqualStrings("/docs/demo", try muxly.protocol.requestDocumentPath(parsed.value));
}

test "protocol client request writer emits node target fields" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try muxly.protocol.writeClientRequestTarget(
        buffer.writer(),
        43,
        .{
            .documentPath = "/docs/demo",
            .nodeId = 12,
            .selector = "left/pane",
        },
        "node.get",
        "{}",
    );

    const parsed = try muxly.protocol.parseRequest(std.testing.allocator, buffer.items);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("node.get", parsed.value.method);
    try std.testing.expectEqualStrings("/docs/demo", try muxly.protocol.requestDocumentPath(parsed.value));
    try std.testing.expectEqual(@as(i64, 12), try muxly.protocol.requestTargetNodeId(parsed.value, "nodeId"));
    try std.testing.expectEqualStrings("left/pane", parsed.value.target.?.selector.?);
}

test "protocol client request writer rejects non-canonical document paths" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try std.testing.expectError(
        error.InvalidDocumentPath,
        muxly.protocol.writeClientRequestTarget(
            buffer.writer(),
            44,
            .{ .documentPath = "/docs/demo/" },
            "document.get",
            "{}",
        ),
    );
}

test "conversation envelope round-trips rpc kind and target metadata" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try muxly.protocol.writeConversationEnvelope(
        buffer.writer(),
        "c-1",
        42,
        .{
            .documentPath = "/docs/demo",
            .nodeId = 12,
            .selector = "left/pane",
        },
        .rpc,
        \\{"jsonrpc":"2.0","id":42,"method":"document.get","params":{}}
    ,
        true,
        null,
    );

    const parsed = try muxly.protocol.parseConversationEnvelope(std.testing.allocator, buffer.items);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("c-1", parsed.value.conversationId);
    try std.testing.expectEqual(@as(?u64, 42), parsed.value.requestId);
    try std.testing.expectEqual(muxly.protocol.ConversationKind.rpc, parsed.value.kind);
    try std.testing.expect(parsed.value.fin);
    try std.testing.expectEqualStrings("/docs/demo", parsed.value.target.?.documentPath.?);
    try std.testing.expectEqual(@as(u64, 12), parsed.value.target.?.nodeId.?);
    try std.testing.expectEqualStrings("left/pane", parsed.value.target.?.selector.?);
    try std.testing.expect(parsed.value.payload == .object);
}

test "conversation envelope parses tty conversation kinds and conversation-local errors" {
    const payload =
        \\{"conversationId":"c-tty","requestId":null,"kind":"tty_data","payload":{"chunk":"hello"},"fin":false}
    ;
    const parsed = try muxly.protocol.parseConversationEnvelope(std.testing.allocator, payload);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("c-tty", parsed.value.conversationId);
    try std.testing.expectEqual(@as(?u64, null), parsed.value.requestId);
    try std.testing.expectEqual(muxly.protocol.ConversationKind.tty_data, parsed.value.kind);
    try std.testing.expect(!parsed.value.fin);

    var error_buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer error_buffer.deinit();
    try muxly.protocol.writeConversationEnvelope(
        error_buffer.writer(),
        "c-ctrl",
        null,
        null,
        .tty_control,
        \\{"enabled":true}
    ,
        true,
        .{
            .code = -32001,
            .message = "tty focus unavailable",
        },
    );

    const parsed_error = try muxly.protocol.parseConversationEnvelope(std.testing.allocator, error_buffer.items);
    defer parsed_error.deinit();

    try std.testing.expectEqual(muxly.protocol.ConversationKind.tty_control, parsed_error.value.kind);
    try std.testing.expectEqual(@as(i64, -32001), parsed_error.value.conversationError.?.code);
    try std.testing.expectEqualStrings("tty focus unavailable", parsed_error.value.conversationError.?.message);
}
