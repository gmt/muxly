//! Thin Zig client for talking to an external `muxlyd` process.
//!
//! This layer owns the transport conversation with the daemon. Client handles
//! now keep one transport session open and reuse it across requests until
//! `deinit`, which is especially helpful for viewers and SSH relays.

const std = @import("std");
const protocol = @import("../core/protocol.zig");
const runtime_config = @import("../core/runtime_config.zig");
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
    runtime_limits: runtime_config.RuntimeLimits,
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
        return try initForDocumentWithRuntimeLimits(
            allocator,
            transport_spec,
            document_path,
            try runtime_config.loadClientLimits(allocator),
        );
    }

    pub fn initForDocumentWithRuntimeLimits(
        allocator: std.mem.Allocator,
        transport_spec: []const u8,
        document_path: []const u8,
        resolved_runtime_limits: runtime_config.RuntimeLimits,
    ) !Client {
        return .{
            .allocator = allocator,
            .address = try transport.Address.parse(allocator, transport_spec),
            .document_path = try allocator.dupe(u8, document_path),
            .runtime_limits = resolved_runtime_limits,
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
            self.runtime_limits.max_message_bytes,
        )) orelse error.EndOfStream;
    }

    fn ensureConnected(self: *Client) !*transport.Connection {
        if (self.connection == null) {
            self.connection = try transport.connectWithMaxMessageBytes(
                self.allocator,
                &self.address,
                self.runtime_limits.max_message_bytes,
            );
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

pub const TtyOutputChunk = union(enum) {
    data: []u8,
    overflow,
    closed,
};

pub const TtyOutputPoll = union(enum) {
    pending,
    data: []u8,
    overflow,
    closed,
};

pub const PaneCaptureChunk = union(enum) {
    data: []u8,
    closed,
};

pub const PaneCapturePoll = union(enum) {
    pending,
    data: []u8,
    closed,
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
    runtime_limits: runtime_config.RuntimeLimits,
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
        return try initWithRuntimeLimits(
            allocator,
            transport_spec,
            document_path,
            try runtime_config.loadClientLimits(allocator),
        );
    }

    pub fn initWithRuntimeLimits(
        allocator: std.mem.Allocator,
        transport_spec: []const u8,
        document_path: []const u8,
        resolved_runtime_limits: runtime_config.RuntimeLimits,
    ) !CompatibilityClientPool {
        var address = try transport.Address.parse(allocator, transport_spec);
        defer address.deinit(allocator);

        const mode = transportModeForAddress(address);
        var pool = CompatibilityClientPool{
            .allocator = allocator,
            .transport_spec = try allocator.dupe(u8, transport_spec),
            .document_path = try allocator.dupe(u8, document_path),
            .runtime_limits = resolved_runtime_limits,
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
            pool.shared_client = try Client.initForDocumentWithRuntimeLimits(
                allocator,
                transport_spec,
                document_path,
                resolved_runtime_limits,
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
                        client.* = try Client.initForDocumentWithRuntimeLimits(
                            self.allocator,
                            self.transport_spec,
                            self.document_path,
                            self.runtime_limits,
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

pub const RpcRequestPoll = union(enum) {
    pending,
    ready: []u8,
    canceled,
};

const PendingHandleStatus = enum {
    active,
    canceled,
    consumed,
    released,
};

pub const PendingRpcRequest = struct {
    state_owner: *ConversationClientState,
    conversation_id: []u8,
    request_id: u64,
    mutex: std.Thread.Mutex = .{},
    status: PendingHandleStatus = .active,
    released: bool = false,

    pub fn poll(self: *PendingRpcRequest) !RpcRequestPoll {
        switch (self.currentStatus()) {
            .active => {},
            .canceled => return .canceled,
            .consumed => return error.RequestResultConsumed,
            .released => return error.InvalidPendingRequest,
        }

        var envelope = self.state_owner.frame_router.takeEnvelope(
            self.conversation_id,
            self.request_id,
        ) catch |err| switch (err) {
            error.ConversationResponseNotFound => return .pending,
            error.UnknownConversation => return switch (self.currentStatus()) {
                .canceled => .canceled,
                .consumed => error.RequestResultConsumed,
                .released => error.InvalidPendingRequest,
                .active => .pending,
            },
            else => return err,
        };
        return .{
            .ready = try self.consumeEnvelope(&envelope),
        };
    }

    pub fn wait(self: *PendingRpcRequest) ![]u8 {
        switch (self.currentStatus()) {
            .active => {},
            .canceled => return error.RequestCanceled,
            .consumed => return error.RequestResultConsumed,
            .released => return error.InvalidPendingRequest,
        }

        var envelope = self.state_owner.frame_router.waitForEnvelope(
            self.conversation_id,
            self.request_id,
        ) catch |err| switch (err) {
            error.UnknownConversation, error.EndOfStream => return switch (self.currentStatus()) {
                .canceled => error.RequestCanceled,
                .consumed => error.RequestResultConsumed,
                .released => error.InvalidPendingRequest,
                .active => err,
            },
            else => return err,
        };
        return try self.consumeEnvelope(&envelope);
    }

    pub fn cancel(self: *PendingRpcRequest) void {
        if (!self.setCanceled()) return;
        self.state_owner.frame_router.unregisterConversation(self.conversation_id);
    }

    pub fn deinit(self: *PendingRpcRequest) void {
        self.mutex.lock();
        if (self.released) {
            self.mutex.unlock();
            return;
        }
        self.released = true;
        if (self.status == .active) self.status = .canceled;
        self.mutex.unlock();

        self.state_owner.frame_router.unregisterConversation(self.conversation_id);
        self.state_owner.allocator.free(self.conversation_id);
    }

    fn consumeEnvelope(
        self: *PendingRpcRequest,
        envelope: *conversation_router.OwnedEnvelope,
    ) ![]u8 {
        defer envelope.deinit(self.state_owner.allocator);
        self.state_owner.frame_router.unregisterConversation(self.conversation_id);

        switch (self.tryMarkConsumed()) {
            .active => {},
            .canceled => return error.RequestCanceled,
            .consumed => return error.RequestResultConsumed,
            .released => return error.InvalidPendingRequest,
        }

        if (envelope.conversation_error != null) {
            return error.RequestFailed;
        }

        return try self.state_owner.allocator.dupe(u8, envelope.payload_json);
    }

    fn currentStatus(self: *PendingRpcRequest) PendingHandleStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.released) .released else self.status;
    }

    fn setCanceled(self: *PendingRpcRequest) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.released or self.status != .active) return false;
        self.status = .canceled;
        return true;
    }

    fn tryMarkConsumed(self: *PendingRpcRequest) PendingHandleStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.released) return .released;
        switch (self.status) {
            .active => {
                self.status = .consumed;
                return .active;
            },
            .canceled => return .canceled,
            .consumed => return .consumed,
            .released => unreachable,
        }
    }
};

pub const RpcConversation = struct {
    state_owner: *ConversationClientState,
    target: protocol.RequestTarget,

    pub fn deinit(self: *RpcConversation) void {
        if (self.target.documentPath) |value| self.state_owner.allocator.free(value);
        if (self.target.selector) |value| self.state_owner.allocator.free(value);
    }

    pub fn startRequest(
        self: *RpcConversation,
        method: []const u8,
        params_json: []const u8,
    ) !PendingRpcRequest {
        return try self.state_owner.startRpcRequest(self.target, method, params_json);
    }

    pub fn request(self: *RpcConversation, method: []const u8, params_json: []const u8) ![]u8 {
        var pending = try self.startRequest(method, params_json);
        defer pending.deinit();
        return try pending.wait();
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

const TtyOutputStreamStatus = enum {
    active,
    closed,
    released,
};

const PaneCaptureStreamStatus = enum {
    active,
    closed,
    released,
};

pub const TtyOutputStream = struct {
    state_owner: *ConversationClientState,
    conversation_id: []u8,
    document_path: []u8,
    node_id: u64,
    mutex: std.Thread.Mutex = .{},
    status: TtyOutputStreamStatus = .active,
    released: bool = false,

    pub fn waitChunk(self: *TtyOutputStream) !TtyOutputChunk {
        switch (self.currentStatus()) {
            .active => {},
            .closed => return .closed,
            .released => return error.InvalidTtyOutputStream,
        }

        var envelope = self.state_owner.frame_router.waitForEnvelope(
            self.conversation_id,
            null,
        ) catch |err| switch (err) {
            error.UnknownConversation, error.EndOfStream => return .closed,
            else => return err,
        };
        return try self.consumeEnvelope(&envelope);
    }

    pub fn pollChunk(self: *TtyOutputStream) !TtyOutputPoll {
        switch (self.currentStatus()) {
            .active => {},
            .closed => return .closed,
            .released => return error.InvalidTtyOutputStream,
        }

        var envelope = self.state_owner.frame_router.takeEnvelope(
            self.conversation_id,
            null,
        ) catch |err| switch (err) {
            error.ConversationResponseNotFound => return .pending,
            error.UnknownConversation => return .closed,
            else => return err,
        };
        return switch (try self.consumeEnvelope(&envelope)) {
            .data => |bytes| .{ .data = bytes },
            .overflow => .overflow,
            .closed => .closed,
        };
    }

    pub fn close(self: *TtyOutputStream) void {
        if (!self.markClosed()) return;
        self.state_owner.closeTtyOutputStream(
            self.document_path,
            self.node_id,
            self.conversation_id,
        ) catch {};
        self.state_owner.frame_router.unregisterConversation(self.conversation_id);
    }

    pub fn deinit(self: *TtyOutputStream) void {
        self.close();

        self.mutex.lock();
        if (self.released) {
            self.mutex.unlock();
            return;
        }
        self.released = true;
        self.mutex.unlock();

        self.state_owner.allocator.free(self.conversation_id);
        self.state_owner.allocator.free(self.document_path);
    }

    fn consumeEnvelope(
        self: *TtyOutputStream,
        envelope: *conversation_router.OwnedEnvelope,
    ) !TtyOutputChunk {
        defer envelope.deinit(self.state_owner.allocator);

        if (envelope.conversation_error != null) {
            _ = self.markClosed();
            return .closed;
        }
        if (envelope.kind != .tty_data) return error.InvalidResponse;
        if (envelope.fin and std.mem.eql(u8, envelope.payload_json, "null")) {
            _ = self.markClosed();
            self.state_owner.frame_router.unregisterConversation(self.conversation_id);
            return .closed;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.state_owner.allocator, envelope.payload_json, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;

        if (parsed.value.object.get("overflow")) |overflow_value| {
            if (overflow_value == .bool and overflow_value.bool) return .overflow;
        }

        const chunk_value = parsed.value.object.get("chunk") orelse return error.InvalidResponse;
        if (chunk_value != .string) return error.InvalidResponse;
        return .{
            .data = try self.state_owner.allocator.dupe(u8, chunk_value.string),
        };
    }

    fn currentStatus(self: *TtyOutputStream) TtyOutputStreamStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.released) .released else self.status;
    }

    fn markClosed(self: *TtyOutputStream) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.released or self.status == .closed) return false;
        self.status = .closed;
        return true;
    }
};

pub const PaneCaptureStream = struct {
    state_owner: *ConversationClientState,
    conversation_id: []u8,
    pane_id: []u8,
    mutex: std.Thread.Mutex = .{},
    status: PaneCaptureStreamStatus = .active,
    released: bool = false,

    pub fn waitChunk(self: *PaneCaptureStream) !PaneCaptureChunk {
        switch (self.currentStatus()) {
            .active => {},
            .closed => return .closed,
            .released => return error.InvalidPaneCaptureStream,
        }

        var envelope = self.state_owner.frame_router.waitForEnvelope(
            self.conversation_id,
            null,
        ) catch |err| switch (err) {
            error.UnknownConversation, error.EndOfStream => return .closed,
            else => return err,
        };
        return try self.consumeEnvelope(&envelope);
    }

    pub fn pollChunk(self: *PaneCaptureStream) !PaneCapturePoll {
        switch (self.currentStatus()) {
            .active => {},
            .closed => return .closed,
            .released => return error.InvalidPaneCaptureStream,
        }

        var envelope = self.state_owner.frame_router.takeEnvelope(
            self.conversation_id,
            null,
        ) catch |err| switch (err) {
            error.ConversationResponseNotFound => return .pending,
            error.UnknownConversation => return .closed,
            else => return err,
        };

        return switch (try self.consumeEnvelope(&envelope)) {
            .data => |bytes| .{ .data = bytes },
            .closed => .closed,
        };
    }

    pub fn close(self: *PaneCaptureStream) void {
        if (!self.markClosed()) return;
        self.state_owner.frame_router.unregisterConversation(self.conversation_id);
    }

    pub fn deinit(self: *PaneCaptureStream) void {
        self.close();

        self.mutex.lock();
        if (self.released) {
            self.mutex.unlock();
            return;
        }
        self.released = true;
        self.mutex.unlock();

        self.state_owner.allocator.free(self.conversation_id);
        self.state_owner.allocator.free(self.pane_id);
    }

    fn consumeEnvelope(
        self: *PaneCaptureStream,
        envelope: *conversation_router.OwnedEnvelope,
    ) !PaneCaptureChunk {
        defer envelope.deinit(self.state_owner.allocator);

        if (envelope.conversation_error != null) {
            _ = self.markClosed();
            self.state_owner.frame_router.unregisterConversation(self.conversation_id);
            return .closed;
        }
        if (envelope.kind != .capture_data) return error.InvalidResponse;
        if (envelope.fin and std.mem.eql(u8, envelope.payload_json, "null")) {
            _ = self.markClosed();
            self.state_owner.frame_router.unregisterConversation(self.conversation_id);
            return .closed;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, self.state_owner.allocator, envelope.payload_json, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidResponse;

        const chunk_value = parsed.value.object.get("chunk") orelse return error.InvalidResponse;
        if (chunk_value != .string) return error.InvalidResponse;
        return .{
            .data = try self.state_owner.allocator.dupe(u8, chunk_value.string),
        };
    }

    fn currentStatus(self: *PaneCaptureStream) PaneCaptureStreamStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.released) .released else self.status;
    }

    fn markClosed(self: *PaneCaptureStream) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.released or self.status == .closed) return false;
        self.status = .closed;
        return true;
    }
};

pub const TtyConversation = struct {
    state_owner: *ConversationClientState,
    info: TtySessionInfo,
    session_name: []u8,
    pane_id: []u8,

    pub fn deinit(self: *TtyConversation) void {
        self.state_owner.frame_router.unregisterConversation(self.info.conversation_id);
        self.info.deinit(self.state_owner.allocator);
        self.state_owner.allocator.free(self.session_name);
        self.state_owner.allocator.free(self.pane_id);
    }

    pub fn sendInput(self: *TtyConversation, input: []const u8) !void {
        if (self.pane_id.len == 0) return error.UnsupportedTtyBackendHandle;

        const pane_id_json = try std.json.Stringify.valueAlloc(self.state_owner.allocator, self.pane_id, .{});
        defer self.state_owner.allocator.free(pane_id_json);
        const input_json = try std.json.Stringify.valueAlloc(self.state_owner.allocator, input, .{});
        defer self.state_owner.allocator.free(input_json);
        const params_json = try std.fmt.allocPrint(
            self.state_owner.allocator,
            "{{\"paneId\":{s},\"keys\":{s}}}",
            .{ pane_id_json, input_json },
        );
        defer self.state_owner.allocator.free(params_json);

        const response = try self.state_owner.sendEnvelopeAndWait(
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
        defer self.state_owner.allocator.free(response);
    }

    pub fn setFollowTail(self: *TtyConversation, enabled: bool) !void {
        if (self.pane_id.len == 0) return error.UnsupportedTtyBackendHandle;

        const pane_id_json = try std.json.Stringify.valueAlloc(self.state_owner.allocator, self.pane_id, .{});
        defer self.state_owner.allocator.free(pane_id_json);
        const params_json = try std.fmt.allocPrint(
            self.state_owner.allocator,
            "{{\"paneId\":{s},\"enabled\":{s}}}",
            .{ pane_id_json, if (enabled) "true" else "false" },
        );
        defer self.state_owner.allocator.free(params_json);

        const response = try self.state_owner.sendEnvelopeAndWait(
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
        defer self.state_owner.allocator.free(response);
    }

    /// Records the caller's preferred tty size locally. The daemon/backend
    /// resize contract is still provisional, so this does not resize the
    /// server-side tty yet.
    pub fn requestSize(self: *TtyConversation, rows: u16, cols: u16) TtySize {
        self.info.requested_rows = rows;
        self.info.requested_cols = cols;
        self.info.size = .{
            .rows = rows,
            .cols = cols,
        };
        return self.info.size;
    }

    pub fn openOutputStream(self: *TtyConversation) !TtyOutputStream {
        if (self.pane_id.len == 0) return error.UnsupportedTtyBackendHandle;
        return try self.state_owner.openTtyOutputStream(
            self.info.document_path,
            self.info.node_id,
        );
    }
};

pub const ConversationClient = struct {
    state: *ConversationClientState,

    pub fn init(allocator: std.mem.Allocator, transport_spec: []const u8) !ConversationClient {
        return try initForDocument(allocator, transport_spec, protocol.default_document_path);
    }

    pub fn initForDocument(
        allocator: std.mem.Allocator,
        transport_spec: []const u8,
        document_path: []const u8,
    ) !ConversationClient {
        return .{
            .state = try ConversationClientState.init(allocator, transport_spec, document_path),
        };
    }

    pub fn deinit(self: *ConversationClient) void {
        self.state.deinit();
    }

    pub fn documentPath(self: *const ConversationClient) []const u8 {
        return self.state.document_path;
    }

    pub fn startRequest(
        self: *ConversationClient,
        target: protocol.RequestTarget,
        method: []const u8,
        params_json: []const u8,
    ) !PendingRpcRequest {
        return try self.state.startRpcRequest(target, method, params_json);
    }

    pub fn request(self: *ConversationClient, method: []const u8, params_json: []const u8) ![]u8 {
        return try self.requestTarget(.{
            .documentPath = self.state.document_path,
        }, method, params_json);
    }

    pub fn requestTarget(
        self: *ConversationClient,
        target: protocol.RequestTarget,
        method: []const u8,
        params_json: []const u8,
    ) ![]u8 {
        var pending = try self.startRequest(target, method, params_json);
        defer pending.deinit();
        return try pending.wait();
    }

    pub fn openRpc(self: *ConversationClient, target: protocol.RequestTarget) !RpcConversation {
        return .{
            .state_owner = self.state,
            .target = .{
                .documentPath = try self.state.allocator.dupe(u8, target.documentPath orelse self.state.document_path),
                .nodeId = target.nodeId,
                .selector = if (target.selector) |value| try self.state.allocator.dupe(u8, value) else null,
            },
        };
    }

    pub fn openTty(
        self: *ConversationClient,
        target: protocol.RequestTarget,
        options: TtyOpenOptions,
    ) !TtyConversation {
        return try self.state.openTty(target, options);
    }

    pub fn openPaneCaptureStream(
        self: *ConversationClient,
        pane_id: []const u8,
    ) !PaneCaptureStream {
        return try self.state.openPaneCaptureStream(pane_id);
    }

    pub fn openPaneScrollStream(
        self: *ConversationClient,
        pane_id: []const u8,
        start_line: i64,
        end_line: i64,
    ) !PaneCaptureStream {
        return try self.state.openPaneScrollStream(pane_id, start_line, end_line);
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

const CompatibilityWorkerJob = struct {
    envelope_json: []u8,
};

const CompatibilityAsyncDispatcher = struct {
    state_owner: *ConversationClientState,
    allocator: std.mem.Allocator,
    pool: CompatibilityClientPool,
    jobs: std.array_list.Managed(CompatibilityWorkerJob),
    worker_threads: std.array_list.Managed(std.Thread),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    closing: bool = false,

    fn init(
        state_owner: *ConversationClientState,
        allocator: std.mem.Allocator,
        transport_spec: []const u8,
        document_path: []const u8,
        runtime_limits: runtime_config.RuntimeLimits,
    ) !*CompatibilityAsyncDispatcher {
        const dispatcher = try allocator.create(CompatibilityAsyncDispatcher);
        errdefer allocator.destroy(dispatcher);

        dispatcher.* = .{
            .state_owner = state_owner,
            .allocator = allocator,
            .pool = try CompatibilityClientPool.initWithRuntimeLimits(allocator, transport_spec, document_path, runtime_limits),
            .jobs = std.array_list.Managed(CompatibilityWorkerJob).init(allocator),
            .worker_threads = std.array_list.Managed(std.Thread).init(allocator),
        };
        errdefer dispatcher.pool.deinit();
        errdefer dispatcher.jobs.deinit();
        errdefer dispatcher.worker_threads.deinit();

        try dispatcher.jobs.ensureTotalCapacity(dispatcher.pool.max_connections * 4);
        try dispatcher.worker_threads.ensureTotalCapacity(dispatcher.pool.max_connections);
        try dispatcher.startWorkers();
        return dispatcher;
    }

    fn deinit(self: *CompatibilityAsyncDispatcher) void {
        self.mutex.lock();
        self.closing = true;
        for (self.jobs.items) |job| {
            self.state_owner.completeFailedCompatibilityRequest(
                job.envelope_json,
                error.ClientShuttingDown,
            );
            self.allocator.free(job.envelope_json);
        }
        self.jobs.clearRetainingCapacity();
        self.condition.broadcast();
        self.mutex.unlock();

        for (self.worker_threads.items) |thread| thread.join();
        self.pool.deinit();
        self.jobs.deinit();
        self.worker_threads.deinit();
        self.allocator.destroy(self);
    }

    fn submit(self: *CompatibilityAsyncDispatcher, envelope_json: []u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing) return error.ClientShuttingDown;
        try self.jobs.append(.{
            .envelope_json = envelope_json,
        });
        self.condition.signal();
    }

    fn startWorkers(self: *CompatibilityAsyncDispatcher) !void {
        var count: usize = 0;
        while (count < self.pool.max_connections) : (count += 1) {
            const thread = try std.Thread.spawn(.{}, workerMain, .{self});
            self.worker_threads.appendAssumeCapacity(thread);
        }
    }

    fn workerMain(self: *CompatibilityAsyncDispatcher) void {
        self.workerLoop() catch {};
    }

    fn workerLoop(self: *CompatibilityAsyncDispatcher) !void {
        while (true) {
            self.mutex.lock();
            while (self.jobs.items.len == 0 and !self.closing) {
                self.condition.wait(&self.mutex);
            }
            if (self.jobs.items.len == 0 and self.closing) {
                self.mutex.unlock();
                return;
            }
            const job = self.jobs.orderedRemove(0);
            self.mutex.unlock();

            var lease = self.pool.checkout() catch |err| {
                self.state_owner.completeFailedCompatibilityRequest(job.envelope_json, err);
                self.allocator.free(job.envelope_json);
                continue;
            };
            defer lease.deinit();

            const response_envelope = lease.client.requestJson(job.envelope_json) catch |err| {
                self.state_owner.completeFailedCompatibilityRequest(job.envelope_json, err);
                self.allocator.free(job.envelope_json);
                continue;
            };
            defer self.allocator.free(response_envelope);
            self.allocator.free(job.envelope_json);

            self.state_owner.pushEnvelopeBytes(response_envelope) catch |err| switch (err) {
                error.UnknownConversation => {},
                else => return err,
            };
        }
    }
};

const ConversationClientState = struct {
    allocator: std.mem.Allocator,
    document_path: []u8,
    runtime_limits: runtime_config.RuntimeLimits,
    compatibility_dispatcher: ?*CompatibilityAsyncDispatcher = null,
    native_h3wt_session: ?*NativeH3wtSession = null,
    frame_router: conversation_router.ConversationRouter,
    next_conversation_id: u64 = 1,
    next_request_id: u64 = 1,
    conversation_id_mutex: std.Thread.Mutex = .{},
    request_id_mutex: std.Thread.Mutex = .{},

    fn init(
        allocator: std.mem.Allocator,
        transport_spec: []const u8,
        document_path: []const u8,
    ) !*ConversationClientState {
        const resolved_runtime_limits = try runtime_config.loadClientLimits(allocator);
        const state = try allocator.create(ConversationClientState);
        errdefer allocator.destroy(state);

        state.* = .{
            .allocator = allocator,
            .document_path = try allocator.dupe(u8, document_path),
            .runtime_limits = resolved_runtime_limits,
            .frame_router = conversation_router.ConversationRouter.init(allocator),
        };
        errdefer allocator.free(state.document_path);
        errdefer state.frame_router.deinit();

        var address = try transport.Address.parse(allocator, transport_spec);
        defer address.deinit(allocator);

        switch (address.target) {
            .h3wt => |h3wt| {
                state.native_h3wt_session = try NativeH3wtSession.init(state, h3wt);
            },
            else => {
                state.compatibility_dispatcher = try CompatibilityAsyncDispatcher.init(
                    state,
                    allocator,
                    transport_spec,
                    document_path,
                    resolved_runtime_limits,
                );
            },
        }

        return state;
    }

    fn deinit(self: *ConversationClientState) void {
        if (self.native_h3wt_session) |session| session.deinit();
        if (self.compatibility_dispatcher) |dispatcher| dispatcher.deinit();
        self.frame_router.deinit();
        self.allocator.free(self.document_path);
        self.allocator.destroy(self);
    }

    fn nextConversationId(self: *ConversationClientState) ![]u8 {
        self.conversation_id_mutex.lock();
        defer self.conversation_id_mutex.unlock();
        const id = try std.fmt.allocPrint(self.allocator, "c-{d}", .{self.next_conversation_id});
        self.next_conversation_id += 1;
        return id;
    }

    fn nextRpcRequestId(self: *ConversationClientState) u64 {
        self.request_id_mutex.lock();
        defer self.request_id_mutex.unlock();
        const id = self.next_request_id;
        self.next_request_id += 1;
        return id;
    }

    fn startRpcRequest(
        self: *ConversationClientState,
        target: protocol.RequestTarget,
        method: []const u8,
        params_json: []const u8,
    ) !PendingRpcRequest {
        const conversation_id = try self.nextConversationId();
        errdefer self.allocator.free(conversation_id);
        try self.frame_router.registerConversation(conversation_id);
        errdefer self.frame_router.unregisterConversation(conversation_id);
        const request_id = self.nextRpcRequestId();

        var request_json = std.array_list.Managed(u8).init(self.allocator);
        defer request_json.deinit();
        try protocol.writeClientRequestTarget(
            request_json.writer(),
            request_id,
            target,
            method,
            params_json,
        );

        const envelope_json = try protocol.allocConversationEnvelope(
            self.allocator,
            conversation_id,
            request_id,
            target,
            .rpc,
            request_json.items,
            true,
            null,
        );

        try self.submitEnvelopeOwned(envelope_json);
        return .{ .state_owner = self, .conversation_id = conversation_id, .request_id = request_id };
    }

    fn sendEnvelopeAndWait(
        self: *ConversationClientState,
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

        try self.submitEnvelopeOwned(envelope_json);

        var envelope = try self.frame_router.waitForEnvelope(conversation_id, request_id);
        defer envelope.deinit(self.allocator);

        if (envelope.conversation_error != null) return error.RequestFailed;
        return try self.allocator.dupe(u8, envelope.payload_json);
    }

    fn completeFailedCompatibilityRequest(
        self: *ConversationClientState,
        request_envelope: []const u8,
        err: anyerror,
    ) void {
        const parsed = protocol.parseConversationEnvelope(self.allocator, request_envelope) catch return;
        defer parsed.deinit();

        const message = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch return;
        defer self.allocator.free(message);

        const failure = protocol.allocConversationEnvelope(
            self.allocator,
            parsed.value.conversationId,
            parsed.value.requestId,
            parsed.value.target,
            parsed.value.kind,
            "null",
            true,
            .{
                .code = -32603,
                .message = message,
            },
        ) catch return;
        defer self.allocator.free(failure);

        self.frame_router.pushEnvelopeBytes(failure) catch |push_err| switch (push_err) {
            error.UnknownConversation => {},
            else => {},
        };
    }

    fn pushEnvelopeBytes(self: *ConversationClientState, response_envelope: []const u8) !void {
        try self.frame_router.pushEnvelopeBytes(response_envelope);
    }

    fn submitEnvelopeOwned(self: *ConversationClientState, envelope_json: []u8) !void {
        if (self.native_h3wt_session) |session| {
            defer self.allocator.free(envelope_json);
            try session.sendEnvelope(envelope_json);
            return;
        }
        if (self.compatibility_dispatcher) |dispatcher| {
            errdefer self.allocator.free(envelope_json);
            try dispatcher.submit(envelope_json);
            return;
        }
        self.allocator.free(envelope_json);
        return error.MissingConversationTransport;
    }

    fn openTty(
        self: *ConversationClientState,
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
            .state_owner = self,
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

    fn openTtyOutputStream(
        self: *ConversationClientState,
        document_path: []const u8,
        node_id: u64,
    ) !TtyOutputStream {
        if (self.native_h3wt_session == null) return error.UnsupportedTtyOutputStreamTransport;

        const conversation_id = try self.nextConversationId();
        errdefer self.allocator.free(conversation_id);
        try self.frame_router.registerConversation(conversation_id);
        errdefer self.frame_router.unregisterConversation(conversation_id);

        const request_id = self.nextRpcRequestId();
        var request_json = std.array_list.Managed(u8).init(self.allocator);
        defer request_json.deinit();
        try protocol.writeClientRequestTarget(
            request_json.writer(),
            request_id,
            .{
                .documentPath = document_path,
                .nodeId = node_id,
            },
            "tty.stream.open",
            "{}",
        );

        const envelope_json = try protocol.allocConversationEnvelope(
            self.allocator,
            conversation_id,
            request_id,
            .{
                .documentPath = document_path,
                .nodeId = node_id,
            },
            .rpc,
            request_json.items,
            false,
            null,
        );
        try self.submitEnvelopeOwned(envelope_json);

        var ack = try self.frame_router.waitForEnvelope(conversation_id, request_id);
        defer ack.deinit(self.allocator);
        if (ack.conversation_error != null) {
            self.frame_router.unregisterConversation(conversation_id);
            return error.RequestFailed;
        }

        return .{
            .state_owner = self,
            .conversation_id = conversation_id,
            .document_path = try self.allocator.dupe(u8, document_path),
            .node_id = node_id,
        };
    }

    fn closeTtyOutputStream(
        self: *ConversationClientState,
        document_path: []const u8,
        node_id: u64,
        stream_conversation_id: []const u8,
    ) !void {
        const stream_conversation_json = try std.json.Stringify.valueAlloc(self.allocator, stream_conversation_id, .{});
        defer self.allocator.free(stream_conversation_json);
        const params_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"streamConversationId\":{s}}}",
            .{stream_conversation_json},
        );
        defer self.allocator.free(params_json);

        var pending = try self.startRpcRequest(
            .{
                .documentPath = document_path,
                .nodeId = node_id,
            },
            "tty.stream.close",
            params_json,
        );
        defer pending.deinit();

        const response = pending.wait() catch return;
        defer self.allocator.free(response);
    }

    fn openPaneCaptureStream(
        self: *ConversationClientState,
        pane_id: []const u8,
    ) !PaneCaptureStream {
        const pane_id_json = try std.json.Stringify.valueAlloc(self.allocator, pane_id, .{});
        defer self.allocator.free(pane_id_json);
        const params_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"paneId\":{s}}}",
            .{pane_id_json},
        );
        defer self.allocator.free(params_json);
        return try self.openPaneCaptureStreamInternal(
            "pane.capture.stream.open",
            params_json,
            pane_id,
        );
    }

    fn openPaneScrollStream(
        self: *ConversationClientState,
        pane_id: []const u8,
        start_line: i64,
        end_line: i64,
    ) !PaneCaptureStream {
        const pane_id_json = try std.json.Stringify.valueAlloc(self.allocator, pane_id, .{});
        defer self.allocator.free(pane_id_json);
        const params_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"paneId\":{s},\"startLine\":{d},\"endLine\":{d}}}",
            .{ pane_id_json, start_line, end_line },
        );
        defer self.allocator.free(params_json);
        return try self.openPaneCaptureStreamInternal(
            "pane.scroll.stream.open",
            params_json,
            pane_id,
        );
    }

    fn openPaneCaptureStreamInternal(
        self: *ConversationClientState,
        method: []const u8,
        params_json: []const u8,
        pane_id: []const u8,
    ) !PaneCaptureStream {
        if (self.native_h3wt_session == null) return error.UnsupportedPaneCaptureStreamTransport;

        const conversation_id = try self.nextConversationId();
        errdefer self.allocator.free(conversation_id);
        try self.frame_router.registerConversation(conversation_id);
        errdefer self.frame_router.unregisterConversation(conversation_id);

        const request_id = self.nextRpcRequestId();
        var request_json = std.array_list.Managed(u8).init(self.allocator);
        defer request_json.deinit();
        try protocol.writeClientRequestTarget(
            request_json.writer(),
            request_id,
            .{ .documentPath = protocol.default_document_path },
            method,
            params_json,
        );

        const envelope_json = try protocol.allocConversationEnvelope(
            self.allocator,
            conversation_id,
            request_id,
            .{ .documentPath = protocol.default_document_path },
            .rpc,
            request_json.items,
            false,
            null,
        );
        try self.submitEnvelopeOwned(envelope_json);

        var ack = try self.frame_router.waitForEnvelope(conversation_id, request_id);
        defer ack.deinit(self.allocator);
        if (ack.conversation_error != null) {
            self.frame_router.unregisterConversation(conversation_id);
            return error.RequestFailed;
        }

        return .{
            .state_owner = self,
            .conversation_id = conversation_id,
            .pane_id = try self.allocator.dupe(u8, pane_id),
        };
    }
};

const NativeH3wtSession = struct {
    state_owner: *ConversationClientState,
    process: transport.ProcessSession,
    write_mutex: std.Thread.Mutex = .{},
    reader_thread: ?std.Thread = null,

    fn init(
        state_owner: *ConversationClientState,
        h3wt: transport.Address.H3wtAddress,
    ) !*NativeH3wtSession {
        const session = try state_owner.allocator.create(NativeH3wtSession);
        errdefer state_owner.allocator.destroy(session);

        session.* = .{
            .state_owner = state_owner,
            .process = try transport.ProcessSession.initH3wtConversationWithMaxMessageBytes(
                state_owner.allocator,
                h3wt,
                state_owner.runtime_limits.max_message_bytes,
            ),
        };
        errdefer session.process.close();

        session.reader_thread = try std.Thread.spawn(.{}, readerMain, .{session});
        return session;
    }

    fn deinit(self: *NativeH3wtSession) void {
        self.state_owner.frame_router.close();
        self.write_mutex.lock();
        self.process.stdin_file.close();
        self.write_mutex.unlock();
        _ = self.process.child.kill() catch {};
        if (self.reader_thread) |thread| thread.join();
        self.process.stdout_file.close();
        _ = self.process.child.wait() catch {};
        self.state_owner.allocator.destroy(self);
    }

    fn sendEnvelope(self: *NativeH3wtSession, envelope_json: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try self.process.writeAll(envelope_json);
        try self.process.writeAll("\n");
    }

    fn readerMain(self: *NativeH3wtSession) void {
        self.readerLoop() catch {};
        self.state_owner.frame_router.close();
    }

    fn readerLoop(self: *NativeH3wtSession) !void {
        var reader = transport.MessageReader.init(self.state_owner.allocator);
        defer reader.deinit();

        while (true) {
            const line = try reader.readMessageLine(&self.process, self.state_owner.runtime_limits.max_message_bytes) orelse break;
            defer self.state_owner.allocator.free(line);
            if (line.len == 0) continue;
            self.state_owner.frame_router.pushEnvelopeBytes(line) catch |err| switch (err) {
                error.UnknownConversation => {},
                else => return err,
            };
        }
    }
};

fn resolveTtyTarget(
    state_owner: *ConversationClientState,
    target: protocol.RequestTarget,
) !ResolvedTtyTarget {
    var pending = try state_owner.startRpcRequest(target, "node.get", "{}");
    defer pending.deinit();
    const response = try pending.wait();
    defer state_owner.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, state_owner.allocator, response, .{
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
        .document_path = try state_owner.allocator.dupe(u8, target.documentPath orelse state_owner.document_path),
        .node_id = @intCast(node_id_value.integer),
        .session_name = try state_owner.allocator.dupe(u8, session_name_value.string),
        .pane_id = if (pane_id_value) |value|
            if (value == .string)
                try state_owner.allocator.dupe(u8, value.string)
            else
                return error.InvalidResponse
        else
            try state_owner.allocator.dupe(u8, ""),
    };
}

test "tty output stream consumes data overflow and close envelopes" {
    var state = ConversationClientState{
        .allocator = std.testing.allocator,
        .document_path = try std.testing.allocator.dupe(u8, "/"),
        .runtime_limits = .{},
        .frame_router = conversation_router.ConversationRouter.init(std.testing.allocator),
    };
    defer {
        state.frame_router.deinit();
        std.testing.allocator.free(state.document_path);
    }

    const conversation_id = try std.testing.allocator.dupe(u8, "c-tty-stream");
    try state.frame_router.registerConversation(conversation_id);

    var stream = TtyOutputStream{
        .state_owner = &state,
        .conversation_id = conversation_id,
        .document_path = try std.testing.allocator.dupe(u8, "/"),
        .node_id = 7,
    };
    defer stream.deinit();

    const data_frame = try protocol.allocConversationEnvelope(
        std.testing.allocator,
        conversation_id,
        null,
        .{
            .documentPath = "/",
            .nodeId = 7,
        },
        .tty_data,
        "{\"chunk\":\"hello\"}",
        false,
        null,
    );
    defer std.testing.allocator.free(data_frame);
    try state.frame_router.pushEnvelopeBytes(data_frame);

    const first = try stream.pollChunk();
    switch (first) {
        .data => |bytes| {
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqualStrings("hello", bytes);
        },
        else => return error.UnexpectedTestResult,
    }

    const overflow_frame = try protocol.allocConversationEnvelope(
        std.testing.allocator,
        conversation_id,
        null,
        .{
            .documentPath = "/",
            .nodeId = 7,
        },
        .tty_data,
        "{\"overflow\":true}",
        false,
        null,
    );
    defer std.testing.allocator.free(overflow_frame);
    try state.frame_router.pushEnvelopeBytes(overflow_frame);

    try std.testing.expect((try stream.pollChunk()) == .overflow);

    const closed_frame = try protocol.allocConversationEnvelope(
        std.testing.allocator,
        conversation_id,
        null,
        .{
            .documentPath = "/",
            .nodeId = 7,
        },
        .tty_data,
        "null",
        true,
        null,
    );
    defer std.testing.allocator.free(closed_frame);
    try state.frame_router.pushEnvelopeBytes(closed_frame);

    try std.testing.expect((try stream.waitChunk()) == .closed);
    try std.testing.expect((try stream.pollChunk()) == .closed);
}

test "pane capture stream consumes chunk and close envelopes" {
    var state = ConversationClientState{
        .allocator = std.testing.allocator,
        .document_path = try std.testing.allocator.dupe(u8, "/"),
        .runtime_limits = .{},
        .frame_router = conversation_router.ConversationRouter.init(std.testing.allocator),
    };
    defer {
        state.frame_router.deinit();
        std.testing.allocator.free(state.document_path);
    }

    const conversation_id = try std.testing.allocator.dupe(u8, "c-pane-stream");
    try state.frame_router.registerConversation(conversation_id);

    var stream = PaneCaptureStream{
        .state_owner = &state,
        .conversation_id = conversation_id,
        .pane_id = try std.testing.allocator.dupe(u8, "%1"),
    };
    defer stream.deinit();

    const data_frame = try protocol.allocConversationEnvelope(
        std.testing.allocator,
        conversation_id,
        null,
        .{ .documentPath = "/" },
        .capture_data,
        "{\"paneId\":\"%1\",\"chunk\":\"hello\"}",
        false,
        null,
    );
    defer std.testing.allocator.free(data_frame);
    try state.frame_router.pushEnvelopeBytes(data_frame);

    const first = try stream.pollChunk();
    switch (first) {
        .data => |bytes| {
            defer std.testing.allocator.free(bytes);
            try std.testing.expectEqualStrings("hello", bytes);
        },
        else => return error.UnexpectedTestResult,
    }

    const closed_frame = try protocol.allocConversationEnvelope(
        std.testing.allocator,
        conversation_id,
        null,
        .{ .documentPath = "/" },
        .capture_data,
        "null",
        true,
        null,
    );
    defer std.testing.allocator.free(closed_frame);
    try state.frame_router.pushEnvelopeBytes(closed_frame);

    try std.testing.expect((try stream.waitChunk()) == .closed);
    try std.testing.expect((try stream.pollChunk()) == .closed);
}
