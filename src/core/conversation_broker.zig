const std = @import("std");
const errors = @import("errors.zig");
const protocol = @import("protocol.zig");

pub const WireKind = enum {
    json_rpc,
    envelope,
};

pub const OutboundFrame = struct {
    wire_kind: WireKind,
    bytes: []u8,

    fn deinit(self: *OutboundFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const ResponseBatch = struct {
    allocator: std.mem.Allocator,
    frames: std.array_list.Managed(OutboundFrame),

    pub fn init(allocator: std.mem.Allocator) ResponseBatch {
        return .{
            .allocator = allocator,
            .frames = std.array_list.Managed(OutboundFrame).init(allocator),
        };
    }

    pub fn deinit(self: *ResponseBatch) void {
        for (self.frames.items) |*frame| frame.deinit(self.allocator);
        self.frames.deinit();
    }

    pub fn append(self: *ResponseBatch, wire_kind: WireKind, bytes: []u8) !void {
        try self.frames.append(.{
            .wire_kind = wire_kind,
            .bytes = bytes,
        });
    }
};

pub const Broker = struct {
    next_compat_conversation_id: u64 = 1,
    next_generated_request_id: u64 = 1,

    pub fn init() Broker {
        return .{};
    }

    pub fn handleLine(
        self: *Broker,
        allocator: std.mem.Allocator,
        line: []const u8,
        context: anytype,
        handler: anytype,
    ) !ResponseBatch {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
            .allocate = .alloc_always,
        }) catch {
            var batch = ResponseBatch.init(allocator);
            try batch.append(
                .json_rpc,
                try buildJsonRpcError(
                    allocator,
                    null,
                    .parse_error,
                    "invalid JSON payload",
                ),
            );
            return batch;
        };
        defer parsed.deinit();

        if (parsed.value != .object or parsed.value.object.get("conversationId") == null) {
            return try self.handleCompatibilityLine(allocator, line, context, handler);
        }

        return try self.handleEnvelopeLine(allocator, line, parsed.value, context, handler);
    }

    fn handleCompatibilityLine(
        self: *Broker,
        allocator: std.mem.Allocator,
        line: []const u8,
        context: anytype,
        handler: anytype,
    ) !ResponseBatch {
        _ = self.nextCompatConversationId();
        var batch = ResponseBatch.init(allocator);
        try batch.append(.json_rpc, try callHandler(allocator, line, context, handler));
        return batch;
    }

    fn handleEnvelopeLine(
        self: *Broker,
        allocator: std.mem.Allocator,
        line: []const u8,
        parsed_json: std.json.Value,
        context: anytype,
        handler: anytype,
    ) !ResponseBatch {
        const conversation_id = extractConversationId(parsed_json) orelse "invalid-conversation";
        const conversation_kind = extractConversationKind(parsed_json) orelse .rpc;

        const envelope = protocol.parseConversationEnvelope(allocator, line) catch {
            var batch = ResponseBatch.init(allocator);
            try batch.append(
                .envelope,
                try protocol.allocConversationEnvelope(
                    allocator,
                    conversation_id,
                    null,
                    null,
                    conversation_kind,
                    "null",
                    true,
                    .{
                        .code = @intFromEnum(errors.RpcErrorCode.invalid_request),
                        .message = "invalid conversation envelope",
                    },
                ),
            );
            return batch;
        };
        defer envelope.deinit();

        const request_json = requestJsonForEnvelope(self, allocator, envelope.value) catch {
            var batch = ResponseBatch.init(allocator);
            try batch.append(
                .envelope,
                try protocol.allocConversationEnvelope(
                    allocator,
                    envelope.value.conversationId,
                    envelope.value.requestId,
                    envelope.value.target,
                    envelope.value.kind,
                    "null",
                    true,
                    .{
                        .code = @intFromEnum(errors.RpcErrorCode.invalid_params),
                        .message = "unsupported conversation payload",
                    },
                ),
            );
            return batch;
        };
        defer allocator.free(request_json);

        const response_json = callHandler(allocator, request_json, context, handler) catch |err| {
            var batch = ResponseBatch.init(allocator);
            const message = try std.fmt.allocPrint(allocator, "conversation handler failed: {s}", .{@errorName(err)});
            defer allocator.free(message);
            try batch.append(
                .envelope,
                try protocol.allocConversationEnvelope(
                    allocator,
                    envelope.value.conversationId,
                    envelope.value.requestId,
                    envelope.value.target,
                    envelope.value.kind,
                    "null",
                    true,
                    .{
                        .code = @intFromEnum(errors.RpcErrorCode.internal_error),
                        .message = message,
                    },
                ),
            );
            return batch;
        };

        var batch = ResponseBatch.init(allocator);
        try batch.append(
            .envelope,
            try protocol.allocConversationEnvelope(
                allocator,
                envelope.value.conversationId,
                envelope.value.requestId,
                envelope.value.target,
                envelope.value.kind,
                response_json,
                true,
                null,
            ),
        );
        allocator.free(response_json);
        return batch;
    }

    fn nextCompatConversationId(self: *Broker) u64 {
        const id = self.next_compat_conversation_id;
        self.next_compat_conversation_id += 1;
        return id;
    }

    fn nextGeneratedRequestId(self: *Broker) u64 {
        const id = self.next_generated_request_id;
        self.next_generated_request_id += 1;
        return id;
    }
};

fn callHandler(
    allocator: std.mem.Allocator,
    request_json: []const u8,
    context: anytype,
    handler: anytype,
) ![]u8 {
    return try @call(.auto, handler, .{ allocator, context, request_json });
}

fn requestJsonForEnvelope(
    broker: *Broker,
    allocator: std.mem.Allocator,
    envelope: protocol.ConversationEnvelope,
) ![]u8 {
    return switch (envelope.kind) {
        .rpc => try std.json.Stringify.valueAlloc(allocator, envelope.payload, .{}),
        .tty_data => try buildLegacyTtyRequest(
            broker,
            allocator,
            envelope,
            "pane.sendKeys",
        ),
        .tty_control => try buildLegacyTtyControlRequest(
            broker,
            allocator,
            envelope,
        ),
    };
}

fn buildLegacyTtyControlRequest(
    broker: *Broker,
    allocator: std.mem.Allocator,
    envelope: protocol.ConversationEnvelope,
) ![]u8 {
    if (envelope.payload != .object) return error.UnsupportedConversationPayload;
    const enabled = envelope.payload.object.get("enabled") orelse return error.UnsupportedConversationPayload;
    if (enabled != .bool) return error.UnsupportedConversationPayload;
    return try buildLegacyTtyRequest(
        broker,
        allocator,
        envelope,
        "pane.followTail",
    );
}

fn buildLegacyTtyRequest(
    broker: *Broker,
    allocator: std.mem.Allocator,
    envelope: protocol.ConversationEnvelope,
    method: []const u8,
) ![]u8 {
    const params_json = try std.json.Stringify.valueAlloc(allocator, envelope.payload, .{});
    defer allocator.free(params_json);

    var request_json = std.array_list.Managed(u8).init(allocator);
    errdefer request_json.deinit();
    try protocol.writeClientRequestTarget(
        request_json.writer(),
        envelope.requestId orelse broker.nextGeneratedRequestId(),
        envelope.target orelse .{},
        method,
        params_json,
    );
    return try request_json.toOwnedSlice();
}

fn buildJsonRpcError(
    allocator: std.mem.Allocator,
    id: ?std.json.Value,
    code: errors.RpcErrorCode,
    message: []const u8,
) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();
    try protocol.writeError(buffer.writer(), id, code, message);
    return try buffer.toOwnedSlice();
}

fn extractConversationId(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const conversation_id = value.object.get("conversationId") orelse return null;
    if (conversation_id != .string) return null;
    return conversation_id.string;
}

fn extractConversationKind(value: std.json.Value) ?protocol.ConversationKind {
    if (value != .object) return null;
    const kind = value.object.get("kind") orelse return null;
    if (kind != .string) return null;
    if (std.mem.eql(u8, kind.string, "rpc")) return .rpc;
    if (std.mem.eql(u8, kind.string, "tty_control")) return .tty_control;
    if (std.mem.eql(u8, kind.string, "tty_data")) return .tty_data;
    return null;
}
