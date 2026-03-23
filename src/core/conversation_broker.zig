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

pub const DispatchRequest = struct {
    allocator: std.mem.Allocator,
    request_json: []u8,
    response_mode: ResponseMode,

    pub const ResponseMode = union(enum) {
        json_rpc,
        envelope: EnvelopeResponse,
    };

    pub const EnvelopeResponse = struct {
        conversation_id: []u8,
        request_id: ?u64,
        target: ?protocol.RequestTarget,
        kind: protocol.ConversationKind,

        fn deinit(self: *EnvelopeResponse, allocator: std.mem.Allocator) void {
            allocator.free(self.conversation_id);
            if (self.target) |target| {
                if (target.documentPath) |value| allocator.free(value);
                if (target.selector) |value| allocator.free(value);
            }
        }
    };

    pub fn deinit(self: *DispatchRequest) void {
        self.allocator.free(self.request_json);
        switch (self.response_mode) {
            .json_rpc => {},
            .envelope => |*value| value.deinit(self.allocator),
        }
    }

    pub fn buildSuccessFrameOwned(
        self: *const DispatchRequest,
        allocator: std.mem.Allocator,
        response_json: []u8,
    ) !OutboundFrame {
        return switch (self.response_mode) {
            .json_rpc => .{
                .wire_kind = .json_rpc,
                .bytes = response_json,
            },
            .envelope => |response| blk: {
                const envelope = try protocol.allocConversationEnvelope(
                    allocator,
                    response.conversation_id,
                    response.request_id,
                    response.target,
                    response.kind,
                    response_json,
                    true,
                    null,
                );
                allocator.free(response_json);
                break :blk .{
                    .wire_kind = .envelope,
                    .bytes = envelope,
                };
            },
        };
    }

    pub fn buildFailureFrame(
        self: *const DispatchRequest,
        allocator: std.mem.Allocator,
        message: []const u8,
    ) !OutboundFrame {
        return switch (self.response_mode) {
            .json_rpc => .{
                .wire_kind = .json_rpc,
                .bytes = try buildJsonRpcErrorForRequest(
                    allocator,
                    self.request_json,
                    .internal_error,
                    message,
                ),
            },
            .envelope => |response| .{
                .wire_kind = .envelope,
                .bytes = try protocol.allocConversationEnvelope(
                    allocator,
                    response.conversation_id,
                    response.request_id,
                    response.target,
                    response.kind,
                    "null",
                    true,
                    .{
                        .code = @intFromEnum(errors.RpcErrorCode.internal_error),
                        .message = message,
                    },
                ),
            },
        };
    }
};

pub const HandleLineResult = union(enum) {
    immediate: ResponseBatch,
    dispatch: DispatchRequest,
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
        var handled = try self.acceptLine(allocator, line);
        switch (handled) {
            .immediate => |batch| return batch,
            .dispatch => |*request| {
                defer request.deinit();
                const response_json = callHandler(allocator, request.request_json, context, handler) catch |err| {
                    const message = try std.fmt.allocPrint(allocator, "conversation handler failed: {s}", .{@errorName(err)});
                    defer allocator.free(message);
                    var batch = ResponseBatch.init(allocator);
                    const frame = try request.buildFailureFrame(allocator, message);
                    try batch.append(frame.wire_kind, frame.bytes);
                    return batch;
                };
                const frame = try request.buildSuccessFrameOwned(allocator, response_json);
                var batch = ResponseBatch.init(allocator);
                try batch.append(frame.wire_kind, frame.bytes);
                return batch;
            },
        }
    }

    pub fn acceptLine(
        self: *Broker,
        allocator: std.mem.Allocator,
        line: []const u8,
    ) !HandleLineResult {
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
            return .{ .immediate = batch };
        };
        defer parsed.deinit();

        if (parsed.value != .object or parsed.value.object.get("conversationId") == null) {
            return .{ .dispatch = try self.acceptCompatibilityLine(allocator, line) };
        }

        return try self.acceptEnvelopeLine(allocator, line, parsed.value);
    }

    fn acceptCompatibilityLine(
        self: *Broker,
        allocator: std.mem.Allocator,
        line: []const u8,
    ) !DispatchRequest {
        _ = self.nextCompatConversationId();
        return .{
            .allocator = allocator,
            .request_json = try allocator.dupe(u8, line),
            .response_mode = .json_rpc,
        };
    }

    fn acceptEnvelopeLine(
        self: *Broker,
        allocator: std.mem.Allocator,
        line: []const u8,
        parsed_json: std.json.Value,
    ) !HandleLineResult {
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
            return .{ .immediate = batch };
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
            return .{ .immediate = batch };
        };
        return .{ .dispatch = .{
            .allocator = allocator,
            .request_json = request_json,
            .response_mode = .{ .envelope = .{
                .conversation_id = try allocator.dupe(u8, envelope.value.conversationId),
                .request_id = envelope.value.requestId,
                .target = if (envelope.value.target) |target| try duplicateTarget(allocator, target) else null,
                .kind = envelope.value.kind,
            } },
        } };
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
        .capture_data => error.UnsupportedConversationKind,
        .projection_event => error.UnsupportedConversationKind,
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

fn buildJsonRpcErrorForRequest(
    allocator: std.mem.Allocator,
    request_json: []const u8,
    code: errors.RpcErrorCode,
    message: []const u8,
) ![]u8 {
    const parsed = protocol.parseRequest(allocator, request_json) catch {
        return try buildJsonRpcError(allocator, null, code, message);
    };
    defer parsed.deinit();
    return try buildJsonRpcError(allocator, parsed.value.id, code, message);
}

fn duplicateTarget(
    allocator: std.mem.Allocator,
    target: protocol.RequestTarget,
) !protocol.RequestTarget {
    return .{
        .documentPath = if (target.documentPath) |value| try allocator.dupe(u8, value) else null,
        .nodeId = target.nodeId,
        .selector = if (target.selector) |value| try allocator.dupe(u8, value) else null,
    };
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
    if (std.mem.eql(u8, kind.string, "capture_data")) return .capture_data;
    if (std.mem.eql(u8, kind.string, "projection_event")) return .projection_event;
    return null;
}
