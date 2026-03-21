//! Thin Zig client for talking to an external `muxlyd` process.
//!
//! This layer owns the transport conversation with the daemon. Client handles
//! now keep one transport session open and reuse it across requests until
//! `deinit`, which is especially helpful for viewers and SSH relays.

const std = @import("std");
const protocol = @import("../core/protocol.zig");
const conversation_router = @import("conversation_router.zig");
const transport = @import("transport.zig");

pub const default_tty_rows: u16 = 24;
pub const default_tty_cols: u16 = 80;
pub const pooled_transport_connection_limit: usize = 4;

/// Handle-based client bound to one daemon transport address.
pub const Client = struct {
    allocator: std.mem.Allocator,
    address: transport.Address,
    document_path: []u8,
    connection: ?transport.Connection = null,
    response_reader: transport.MessageReader,
    next_request_id: u64 = 1,

    /// Initializes a client that will talk to the daemon at `transport_spec`.
    pub fn init(allocator: std.mem.Allocator, transport_spec: []const u8) !Client {
        return try initForDocument(allocator, transport_spec, protocol.default_document_path);
    }

    /// Initializes a client bound to one transport and one default document.
    pub fn initForDocument(
        allocator: std.mem.Allocator,
        transport_spec: []const u8,
        document_path: []const u8,
    ) !Client {
        return .{
            .allocator = allocator,
            .address = try transport.Address.parse(allocator, transport_spec),
            .document_path = try allocator.dupe(u8, document_path),
            .response_reader = transport.MessageReader.init(allocator),
        };
    }

    /// Releases memory and any live transport session owned by the client.
    pub fn deinit(self: *Client) void {
        if (self.connection) |*connection| connection.close();
        self.response_reader.deinit();
        self.allocator.free(self.document_path);
        self.address.deinit(self.allocator);
    }

    /// Sends one JSON-RPC request assembled from `method` and `params_json`.
    ///
    /// The returned slice is the raw UTF-8 response payload and is owned by the
    /// caller.
    pub fn request(self: *Client, method: []const u8, params_json: []const u8) ![]u8 {
        return try self.requestTarget(.{
            .documentPath = self.document_path,
        }, method, params_json);
    }

    /// Sends one JSON-RPC request against an explicit request target.
    pub fn requestTarget(
        self: *Client,
        target: protocol.RequestTarget,
        method: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        var request_json = std.array_list.Managed(u8).init(self.allocator);
        defer request_json.deinit();

        try protocol.writeClientRequestTarget(
            request_json.writer(),
            self.next_request_id,
            target,
            method,
            params_json,
        );

        self.next_request_id += 1;
        return try self.requestJson(request_json.items);
    }

    /// Sends a prebuilt JSON-RPC request payload to the daemon.
    ///
    /// This is the lowest-level Zig client entry point in the package. The
    /// returned slice is owned by the caller.
    pub fn requestJson(self: *Client, request_json: []const u8) ![]u8 {
        var connection = try self.ensureConnected();
        try connection.writeAll(request_json);
        try connection.writeAll("\n");

        return (try self.response_reader.readMessageLine(
            connection,
            transport.max_message_bytes,
        )) orelse error.EndOfStream;
    }

    fn ensureConnected(self: *Client) !*transport.Connection {
        if (self.connection == null) {
            self.connection = try transport.connect(self.allocator, &self.address);
        }
        return &self.connection.?;
    }
};

pub const TtyOpenOptions = struct {
    rows: ?u16 = null,
    cols: ?u16 = null,
};

pub const TtySize = struct {
    rows: u16,
    cols: u16,
};

pub const CompatibilityTransportMode = enum {
    shared_connection,
    pooled_connections,
};

pub const ClientLease = struct {
    pool: *CompatibilityClientPool,
    client: *Client,
    mode: CompatibilityTransportMode,
    released: bool = false,

    pub fn deinit(self: *ClientLease) void {
        if (self.released) return;
        self.released = true;
        self.pool.releaseLease(self);
    }
};

pub const CompatibilityClientPool = struct {
    allocator: std.mem.Allocator,
    transport_spec: []u8,
    document_path: []u8,
    mode: CompatibilityTransportMode,
    max_connections: usize,
    shared_client: ?Client = null,
    shared_in_use: bool = false,
    pooled_available: std.array_list.Managed(*Client),
    pooled_all: std.array_list.Managed(*Client),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        transport_spec: []const u8,
        document_path: []const u8,
    ) !CompatibilityClientPool {
        var address = try transport.Address.parse(allocator, transport_spec);
        defer address.deinit(allocator);

        const mode = transportModeForAddress(address);
        var pool = CompatibilityClientPool{
            .allocator = allocator,
            .transport_spec = try allocator.dupe(u8, transport_spec),
            .document_path = try allocator.dupe(u8, document_path),
            .mode = mode,
            .max_connections = switch (mode) {
                .shared_connection => 1,
                .pooled_connections => pooled_transport_connection_limit,
            },
            .pooled_available = std.array_list.Managed(*Client).init(allocator),
            .pooled_all = std.array_list.Managed(*Client).init(allocator),
        };
        errdefer allocator.free(pool.transport_spec);
        errdefer allocator.free(pool.document_path);
        errdefer pool.pooled_available.deinit();
        errdefer pool.pooled_all.deinit();

        try pool.pooled_available.ensureTotalCapacity(pool.max_connections);
        try pool.pooled_all.ensureTotalCapacity(pool.max_connections);

        if (mode == .shared_connection) {
            pool.shared_client = try Client.initForDocument(
                allocator,
                transport_spec,
                document_path,
            );
        }

        return pool;
    }

    pub fn deinit(self: *CompatibilityClientPool) void {
        if (self.shared_client) |*client| client.deinit();
        for (self.pooled_all.items) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        self.pooled_available.deinit();
        self.pooled_all.deinit();
        self.allocator.free(self.transport_spec);
        self.allocator.free(self.document_path);
    }

    pub fn documentPath(self: *const CompatibilityClientPool) []const u8 {
        return self.document_path;
    }

    pub fn checkout(self: *CompatibilityClientPool) !ClientLease {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            switch (self.mode) {
                .shared_connection => {
                    if (!self.shared_in_use) {
                        self.shared_in_use = true;
                        return .{
                            .pool = self,
                            .client = &self.shared_client.?,
                            .mode = .shared_connection,
                        };
                    }
                },
                .pooled_connections => {
                    if (self.pooled_available.items.len > 0) {
                        return .{
                            .pool = self,
                            .client = self.pooled_available.pop().?,
                            .mode = .pooled_connections,
                        };
                    }
                    if (self.pooled_all.items.len < self.max_connections) {
                        const client = try self.allocator.create(Client);
                        errdefer self.allocator.destroy(client);
                        client.* = try Client.initForDocument(
                            self.allocator,
                            self.transport_spec,
                            self.document_path,
                        );
                        self.pooled_all.appendAssumeCapacity(client);
                        return .{
                            .pool = self,
                            .client = client,
                            .mode = .pooled_connections,
                        };
                    }
                },
            }
            self.condition.wait(&self.mutex);
        }
    }

    fn releaseLease(self: *CompatibilityClientPool, lease: *const ClientLease) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        switch (lease.mode) {
            .shared_connection => self.shared_in_use = false,
            .pooled_connections => self.pooled_available.appendAssumeCapacity(lease.client),
        }
        self.condition.signal();
    }
};

fn transportModeForAddress(address: transport.Address) CompatibilityTransportMode {
    return switch (address.target) {
        .http, .ssh => .pooled_connections,
        .unix, .tcp, .h3wt => .shared_connection,
    };
}

pub const RpcConversation = struct {
    client: *ConversationClient,
    conversation_id: []u8,
    target: protocol.RequestTarget,

    pub fn deinit(self: *RpcConversation) void {
        self.client.frame_router.unregisterConversation(self.conversation_id);
        self.client.allocator.free(self.conversation_id);
        if (self.target.documentPath) |value| self.client.allocator.free(value);
        if (self.target.selector) |value| self.client.allocator.free(value);
    }

    pub fn request(self: *RpcConversation, method: []const u8, params_json: []const u8) ![]u8 {
        const request_id = self.client.nextRpcRequestId();

        var request_json = std.array_list.Managed(u8).init(self.client.allocator);
        defer request_json.deinit();
        try protocol.writeClientRequestTarget(
            request_json.writer(),
            request_id,
            self.target,
            method,
            params_json,
        );

        return try self.client.sendEnvelopeAndWait(
            self.conversation_id,
            request_id,
            self.target,
            .rpc,
            request_json.items,
            true,
        );
    }
};

pub const TtySessionInfo = struct {
    conversation_id: []u8,
    document_path: []u8,
    node_id: u64,
    requested_rows: ?u16,
    requested_cols: ?u16,
    size: TtySize,

    pub fn deinit(self: *TtySessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.conversation_id);
        allocator.free(self.document_path);
    }
};

pub const TtyConversation = struct {
    client: *ConversationClient,
    info: TtySessionInfo,
    session_name: []u8,
    pane_id: []u8,

    pub fn deinit(self: *TtyConversation) void {
        self.client.frame_router.unregisterConversation(self.info.conversation_id);
        self.info.deinit(self.client.allocator);
        self.client.allocator.free(self.session_name);
        self.client.allocator.free(self.pane_id);
    }

    pub fn sendInput(self: *TtyConversation, input: []const u8) !void {
        if (self.pane_id.len == 0) return error.UnsupportedTtyBackendHandle;

        const pane_id_json = try std.json.Stringify.valueAlloc(self.client.allocator, self.pane_id, .{});
        defer self.client.allocator.free(pane_id_json);
        const input_json = try std.json.Stringify.valueAlloc(self.client.allocator, input, .{});
        defer self.client.allocator.free(input_json);
        const params_json = try std.fmt.allocPrint(
            self.client.allocator,
            "{{\"paneId\":{s},\"keys\":{s}}}",
            .{ pane_id_json, input_json },
        );
        defer self.client.allocator.free(params_json);

        const envelope_json = try protocol.allocConversationEnvelope(
            self.client.allocator,
            self.info.conversation_id,
            null,
            .{
                .documentPath = self.info.document_path,
                .nodeId = self.info.node_id,
            },
            .tty_data,
            params_json,
            false,
            null,
        );
        defer self.client.allocator.free(envelope_json);

        const routed_response = try self.client.sendEnvelopeAndWait(
            self.info.conversation_id,
            null,
            .{
                .documentPath = self.info.document_path,
                .nodeId = self.info.node_id,
            },
            .tty_data,
            params_json,
            false,
        );
        defer self.client.allocator.free(routed_response);
    }

    pub fn setFollowTail(self: *TtyConversation, enabled: bool) !void {
        if (self.pane_id.len == 0) return error.UnsupportedTtyBackendHandle;

        const pane_id_json = try std.json.Stringify.valueAlloc(self.client.allocator, self.pane_id, .{});
        defer self.client.allocator.free(pane_id_json);
        const params_json = try std.fmt.allocPrint(
            self.client.allocator,
            "{{\"paneId\":{s},\"enabled\":{s}}}",
            .{ pane_id_json, if (enabled) "true" else "false" },
        );
        defer self.client.allocator.free(params_json);

        const envelope_json = try protocol.allocConversationEnvelope(
            self.client.allocator,
            self.info.conversation_id,
            null,
            .{
                .documentPath = self.info.document_path,
                .nodeId = self.info.node_id,
            },
            .tty_control,
            params_json,
            true,
            null,
        );
        defer self.client.allocator.free(envelope_json);

        const routed_response = try self.client.sendEnvelopeAndWait(
            self.info.conversation_id,
            null,
            .{
                .documentPath = self.info.document_path,
                .nodeId = self.info.node_id,
            },
            .tty_control,
            params_json,
            true,
        );
        defer self.client.allocator.free(routed_response);
    }

    pub fn requestSize(self: *TtyConversation, rows: u16, cols: u16) TtySize {
        self.info.requested_rows = rows;
        self.info.requested_cols = cols;
        self.info.size = .{
            .rows = rows,
            .cols = cols,
        };
        return self.info.size;
    }
};

pub const ConversationClient = struct {
    allocator: std.mem.Allocator,
    document_path: []u8,
    client_pool: ?CompatibilityClientPool = null,
    native_h3wt_session: ?*NativeH3wtSession = null,
    frame_router: conversation_router.ConversationRouter,
    next_conversation_id: u64 = 1,
    next_request_id: u64 = 1,
    request_id_mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, transport_spec: []const u8) !ConversationClient {
        return try initForDocument(allocator, transport_spec, protocol.default_document_path);
    }

    pub fn initForDocument(
        allocator: std.mem.Allocator,
        transport_spec: []const u8,
        document_path: []const u8,
    ) !ConversationClient {
        var client = ConversationClient{
            .allocator = allocator,
            .document_path = try allocator.dupe(u8, document_path),
            .frame_router = conversation_router.ConversationRouter.init(allocator),
        };
        errdefer allocator.free(client.document_path);
        errdefer client.frame_router.deinit();

        var address = try transport.Address.parse(allocator, transport_spec);
        defer address.deinit(allocator);

        switch (address.target) {
            .h3wt => |h3wt| {
                client.native_h3wt_session = try NativeH3wtSession.init(
                    allocator,
                    h3wt,
                    &client.frame_router,
                );
            },
            else => {
                client.client_pool = try CompatibilityClientPool.init(allocator, transport_spec, document_path);
            },
        }

        return client;
    }

    pub fn deinit(self: *ConversationClient) void {
        if (self.native_h3wt_session) |session| session.deinit();
        if (self.client_pool) |*pool| pool.deinit();
        self.frame_router.deinit();
        self.allocator.free(self.document_path);
    }

    pub fn documentPath(self: *const ConversationClient) []const u8 {
        return self.document_path;
    }

    pub fn request(self: *ConversationClient, method: []const u8, params_json: []const u8) ![]u8 {
        return try self.requestTarget(.{
            .documentPath = self.document_path,
        }, method, params_json);
    }

    pub fn requestTarget(
        self: *ConversationClient,
        target: protocol.RequestTarget,
        method: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        var conversation = try self.openRpc(target);
        defer conversation.deinit();
        return try conversation.request(method, params_json);
    }

    pub fn openRpc(self: *ConversationClient, target: protocol.RequestTarget) !RpcConversation {
        const conversation_id = try self.nextConversationId();
        errdefer self.allocator.free(conversation_id);
        try self.frame_router.registerConversation(conversation_id);
        errdefer self.frame_router.unregisterConversation(conversation_id);
        return .{
            .client = self,
            .conversation_id = conversation_id,
            .target = .{
                .documentPath = try self.allocator.dupe(u8, target.documentPath orelse self.document_path),
                .nodeId = target.nodeId,
                .selector = if (target.selector) |value| try self.allocator.dupe(u8, value) else null,
            },
        };
    }

    pub fn openTty(
        self: *ConversationClient,
        target: protocol.RequestTarget,
        options: TtyOpenOptions,
    ) !TtyConversation {
        var resolved = try resolveTtyTarget(self, .{
            .documentPath = target.documentPath orelse self.document_path,
            .nodeId = target.nodeId,
            .selector = target.selector,
        });
        errdefer resolved.deinit(self.allocator);
        const conversation_id = try self.nextConversationId();
        errdefer self.allocator.free(conversation_id);
        try self.frame_router.registerConversation(conversation_id);
        errdefer self.frame_router.unregisterConversation(conversation_id);

        return .{
            .client = self,
            .info = .{
                .conversation_id = conversation_id,
                .document_path = resolved.document_path,
                .node_id = resolved.node_id,
                .requested_rows = options.rows,
                .requested_cols = options.cols,
                .size = .{
                    .rows = options.rows orelse default_tty_rows,
                    .cols = options.cols orelse default_tty_cols,
                },
            },
            .session_name = resolved.session_name,
            .pane_id = resolved.pane_id,
        };
    }

    fn nextConversationId(self: *ConversationClient) ![]u8 {
        const id = try std.fmt.allocPrint(self.allocator, "c-{d}", .{self.next_conversation_id});
        self.next_conversation_id += 1;
        return id;
    }

    fn nextRpcRequestId(self: *ConversationClient) u64 {
        self.request_id_mutex.lock();
        defer self.request_id_mutex.unlock();
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn sendEnvelopeAndWait(
        self: *ConversationClient,
        conversation_id: []const u8,
        request_id: ?u64,
        target: protocol.RequestTarget,
        kind: protocol.ConversationKind,
        payload_json: []const u8,
        fin: bool,
    ) ![]u8 {
        const envelope_json = try protocol.allocConversationEnvelope(
            self.allocator,
            conversation_id,
            request_id,
            target,
            kind,
            payload_json,
            fin,
            null,
        );
        defer self.allocator.free(envelope_json);

        if (self.native_h3wt_session) |session| {
            try session.sendEnvelope(envelope_json);
        } else if (self.client_pool) |*pool| {
            var lease = try pool.checkout();
            defer lease.deinit();
            const response_envelope = try lease.client.requestJson(envelope_json);
            defer self.allocator.free(response_envelope);
            try self.frame_router.pushEnvelopeBytes(response_envelope);
        } else {
            return error.MissingConversationTransport;
        }

        return try self.frame_router.waitForPayloadForRequest(conversation_id, request_id);
    }
};

const ResolvedTtyTarget = struct {
    document_path: []u8,
    node_id: u64,
    session_name: []u8,
    pane_id: []u8,

    fn deinit(self: *ResolvedTtyTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.document_path);
        allocator.free(self.session_name);
        allocator.free(self.pane_id);
    }
};

const NativeH3wtSession = struct {
    allocator: std.mem.Allocator,
    router: *conversation_router.ConversationRouter,
    process: transport.ProcessSession,
    write_mutex: std.Thread.Mutex = .{},
    reader_thread: ?std.Thread = null,

    fn init(
        allocator: std.mem.Allocator,
        h3wt: transport.Address.H3wtAddress,
        router: *conversation_router.ConversationRouter,
    ) !*NativeH3wtSession {
        const session = try allocator.create(NativeH3wtSession);
        errdefer allocator.destroy(session);

        session.* = .{
            .allocator = allocator,
            .router = router,
            .process = try transport.ProcessSession.initH3wtConversation(allocator, h3wt),
        };
        errdefer {
            session.process.close();
        }

        session.reader_thread = try std.Thread.spawn(.{}, readerMain, .{session});
        return session;
    }

    fn deinit(self: *NativeH3wtSession) void {
        self.router.close();
        self.write_mutex.lock();
        self.process.stdin_file.close();
        self.write_mutex.unlock();
        _ = self.process.child.kill() catch {};
        if (self.reader_thread) |thread| thread.join();
        self.process.stdout_file.close();
        _ = self.process.child.wait() catch {};
        self.allocator.destroy(self);
    }

    fn sendEnvelope(self: *NativeH3wtSession, envelope_json: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.process.writeAll(envelope_json);
        try self.process.writeAll("\n");
    }

    fn readerMain(self: *NativeH3wtSession) void {
        self.readerLoop() catch {};
        self.router.close();
    }

    fn readerLoop(self: *NativeH3wtSession) !void {
        var reader = transport.MessageReader.init(self.allocator);
        defer reader.deinit();

        while (true) {
            const line = try reader.readMessageLine(&self.process, transport.max_message_bytes) orelse break;
            defer self.allocator.free(line);
            if (line.len == 0) continue;
            self.router.pushEnvelopeBytes(line) catch |err| switch (err) {
                error.UnknownConversation => {},
                else => return err,
            };
        }
    }
};

fn resolveTtyTarget(
    client: *ConversationClient,
    target: protocol.RequestTarget,
) !ResolvedTtyTarget {
    const response = try client.requestTarget(target, "node.get", "{}");
    defer client.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, client.allocator, response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;

    const node_id_value = result.object.get("id") orelse return error.InvalidResponse;
    if (node_id_value != .integer or node_id_value.integer < 0) return error.InvalidResponse;

    const source_value = result.object.get("source") orelse return error.InvalidResponse;
    if (source_value != .object) return error.InvalidResponse;

    const kind_value = source_value.object.get("kind") orelse return error.InvalidResponse;
    if (kind_value != .string) return error.InvalidResponse;
    if (!std.mem.eql(u8, kind_value.string, "tty")) return error.InvalidTtyTarget;

    const session_name_value = source_value.object.get("sessionName") orelse return error.InvalidResponse;
    if (session_name_value != .string) return error.InvalidResponse;

    const pane_id_value = source_value.object.get("paneId");

    return .{
        .document_path = try client.allocator.dupe(u8, target.documentPath orelse client.document_path),
        .node_id = @intCast(node_id_value.integer),
        .session_name = try client.allocator.dupe(u8, session_name_value.string),
        .pane_id = if (pane_id_value) |value|
            if (value == .string)
                try client.allocator.dupe(u8, value.string)
            else
                return error.InvalidResponse
        else
            try client.allocator.dupe(u8, ""),
    };
}
