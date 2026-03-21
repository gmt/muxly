const std = @import("std");
const protocol = @import("../core/protocol.zig");

pub const OwnedConversationError = struct {
    code: i64,
    message: []u8,

    fn deinit(self: *OwnedConversationError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

pub const OwnedEnvelope = struct {
    conversation_id: []u8,
    request_id: ?u64,
    target: ?protocol.RequestTarget,
    kind: protocol.ConversationKind,
    payload_json: []u8,
    fin: bool,
    conversation_error: ?OwnedConversationError,

    pub fn deinit(self: *OwnedEnvelope, allocator: std.mem.Allocator) void {
        allocator.free(self.conversation_id);
        if (self.target) |target| {
            if (target.documentPath) |value| allocator.free(value);
            if (target.selector) |value| allocator.free(value);
        }
        allocator.free(self.payload_json);
        if (self.conversation_error) |*value| value.deinit(allocator);
    }
};

pub const ConversationRouter = struct {
    allocator: std.mem.Allocator,
    mailboxes: std.array_list.Managed(Mailbox),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    closed: bool = false,

    const Mailbox = struct {
        conversation_id: []u8,
        envelopes: std.array_list.Managed(OwnedEnvelope),

        fn init(allocator: std.mem.Allocator, conversation_id: []const u8) !Mailbox {
            return .{
                .conversation_id = try allocator.dupe(u8, conversation_id),
                .envelopes = std.array_list.Managed(OwnedEnvelope).init(allocator),
            };
        }

        fn deinit(self: *Mailbox, allocator: std.mem.Allocator) void {
            for (self.envelopes.items) |*envelope| envelope.deinit(allocator);
            self.envelopes.deinit();
            allocator.free(self.conversation_id);
        }
    };

    pub fn init(allocator: std.mem.Allocator) ConversationRouter {
        return .{
            .allocator = allocator,
            .mailboxes = std.array_list.Managed(Mailbox).init(allocator),
        };
    }

    pub fn deinit(self: *ConversationRouter) void {
        self.close();
        for (self.mailboxes.items) |*mailbox| mailbox.deinit(self.allocator);
        self.mailboxes.deinit();
    }

    pub fn registerConversation(self: *ConversationRouter, conversation_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.mailboxIndex(conversation_id) != null) return;
        try self.mailboxes.append(try Mailbox.init(self.allocator, conversation_id));
    }

    pub fn unregisterConversation(self: *ConversationRouter, conversation_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.mailboxIndex(conversation_id) orelse return;
        var mailbox = self.mailboxes.orderedRemove(index);
        mailbox.deinit(self.allocator);
    }

    pub fn pushEnvelopeBytes(self: *ConversationRouter, bytes: []const u8) !void {
        const parsed = try protocol.parseConversationEnvelope(self.allocator, bytes);
        defer parsed.deinit();
        try self.pushEnvelope(parsed.value);
    }

    pub fn pushEnvelope(self: *ConversationRouter, envelope: protocol.ConversationEnvelope) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.mailboxIndex(envelope.conversationId) orelse return error.UnknownConversation;
        try self.mailboxes.items[index].envelopes.append(try ownedEnvelopeFromBorrowed(self.allocator, envelope));
        self.condition.broadcast();
    }

    pub fn takeEnvelope(
        self: *ConversationRouter,
        conversation_id: []const u8,
        request_id: ?u64,
    ) !OwnedEnvelope {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.takeEnvelopeLocked(conversation_id, request_id);
    }

    pub fn waitForEnvelope(
        self: *ConversationRouter,
        conversation_id: []const u8,
        request_id: ?u64,
    ) !OwnedEnvelope {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.takeEnvelopeLocked(conversation_id, request_id)) |envelope| {
                return envelope;
            } else |err| switch (err) {
                error.ConversationResponseNotFound => {},
                else => return err,
            }

            if (self.closed) return error.EndOfStream;
            self.condition.wait(&self.mutex);
        }
    }

    pub fn close(self: *ConversationRouter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.condition.broadcast();
    }

    fn takeEnvelopeLocked(
        self: *ConversationRouter,
        conversation_id: []const u8,
        request_id: ?u64,
    ) !OwnedEnvelope {
        const index = self.mailboxIndex(conversation_id) orelse return error.UnknownConversation;
        var mailbox = &self.mailboxes.items[index];
        for (mailbox.envelopes.items, 0..) |envelope, envelope_index| {
            if (envelope.request_id == request_id) {
                return mailbox.envelopes.orderedRemove(envelope_index);
            }
        }
        return error.ConversationResponseNotFound;
    }

    pub fn takePayloadForRequest(
        self: *ConversationRouter,
        conversation_id: []const u8,
        request_id: ?u64,
    ) ![]u8 {
        var envelope = try self.takeEnvelope(conversation_id, request_id);
        defer envelope.deinit(self.allocator);

        const payload_json = envelope.payload_json;
        envelope.payload_json = try self.allocator.dupe(u8, "");
        return payload_json;
    }

    pub fn waitForPayloadForRequest(
        self: *ConversationRouter,
        conversation_id: []const u8,
        request_id: ?u64,
    ) ![]u8 {
        var envelope = try self.waitForEnvelope(conversation_id, request_id);
        defer envelope.deinit(self.allocator);

        const payload_json = envelope.payload_json;
        envelope.payload_json = try self.allocator.dupe(u8, "");
        return payload_json;
    }

    fn mailboxIndex(self: *ConversationRouter, conversation_id: []const u8) ?usize {
        for (self.mailboxes.items, 0..) |mailbox, index| {
            if (std.mem.eql(u8, mailbox.conversation_id, conversation_id)) return index;
        }
        return null;
    }
};

fn ownedEnvelopeFromBorrowed(
    allocator: std.mem.Allocator,
    envelope: protocol.ConversationEnvelope,
) !OwnedEnvelope {
    return .{
        .conversation_id = try allocator.dupe(u8, envelope.conversationId),
        .request_id = envelope.requestId,
        .target = if (envelope.target) |target| try duplicateTarget(allocator, target) else null,
        .kind = envelope.kind,
        .payload_json = try std.json.Stringify.valueAlloc(allocator, envelope.payload, .{}),
        .fin = envelope.fin,
        .conversation_error = if (envelope.conversationError) |value|
            .{
                .code = value.code,
                .message = try allocator.dupe(u8, value.message),
            }
        else
            null,
    };
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
