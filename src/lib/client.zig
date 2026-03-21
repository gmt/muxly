//! Thin Zig client for talking to an external `muxlyd` process.
//!
//! This layer owns the transport conversation with the daemon. Client handles
//! now keep one transport session open and reuse it across requests until
//! `deinit`, which is especially helpful for viewers and SSH relays.

const std = @import("std");
const protocol = @import("../core/protocol.zig");
const transport = @import("transport.zig");

pub const default_tty_rows: u16 = 24;
pub const default_tty_cols: u16 = 80;

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

pub const RpcConversation = struct {
    client: *ConversationClient,
    conversation_id: []u8,
    target: protocol.RequestTarget,

    pub fn deinit(self: *RpcConversation) void {
        self.client.allocator.free(self.conversation_id);
        if (self.target.documentPath) |value| self.client.allocator.free(value);
        if (self.target.selector) |value| self.client.allocator.free(value);
    }

    pub fn request(self: *RpcConversation, method: []const u8, params_json: []const u8) ![]u8 {
        const request_id = self.client.rpc_client.next_request_id;

        var request_json = std.array_list.Managed(u8).init(self.client.allocator);
        defer request_json.deinit();
        try protocol.writeClientRequestTarget(
            request_json.writer(),
            request_id,
            self.target,
            method,
            params_json,
        );

        // The logical envelope exists now even though the current transport
        // compatibility path still emits plain JSON-RPC over the wire.
        var envelope_json = std.array_list.Managed(u8).init(self.client.allocator);
        defer envelope_json.deinit();
        try protocol.writeConversationEnvelope(
            envelope_json.writer(),
            self.conversation_id,
            request_id,
            self.target,
            .rpc,
            request_json.items,
            true,
            null,
        );

        self.client.rpc_client.next_request_id += 1;
        return try self.client.rpc_client.requestJson(request_json.items);
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

        var envelope_json = std.array_list.Managed(u8).init(self.client.allocator);
        defer envelope_json.deinit();
        try protocol.writeConversationEnvelope(
            envelope_json.writer(),
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

        const response = try self.client.rpc_client.request("pane.sendKeys", params_json);
        defer self.client.allocator.free(response);
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

        var envelope_json = std.array_list.Managed(u8).init(self.client.allocator);
        defer envelope_json.deinit();
        try protocol.writeConversationEnvelope(
            envelope_json.writer(),
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

        const response = try self.client.rpc_client.request("pane.followTail", params_json);
        defer self.client.allocator.free(response);
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
    rpc_client: Client,
    next_conversation_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, transport_spec: []const u8) !ConversationClient {
        return try initForDocument(allocator, transport_spec, protocol.default_document_path);
    }

    pub fn initForDocument(
        allocator: std.mem.Allocator,
        transport_spec: []const u8,
        document_path: []const u8,
    ) !ConversationClient {
        return .{
            .allocator = allocator,
            .rpc_client = try Client.initForDocument(allocator, transport_spec, document_path),
        };
    }

    pub fn deinit(self: *ConversationClient) void {
        self.rpc_client.deinit();
    }

    pub fn documentPath(self: *const ConversationClient) []const u8 {
        return self.rpc_client.document_path;
    }

    pub fn request(self: *ConversationClient, method: []const u8, params_json: []const u8) ![]u8 {
        return try self.requestTarget(.{
            .documentPath = self.rpc_client.document_path,
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
        return .{
            .client = self,
            .conversation_id = try self.nextConversationId(),
            .target = .{
                .documentPath = try self.allocator.dupe(u8, target.documentPath orelse self.rpc_client.document_path),
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
        var resolved = try resolveTtyTarget(self.allocator, &self.rpc_client, .{
            .documentPath = target.documentPath orelse self.rpc_client.document_path,
            .nodeId = target.nodeId,
            .selector = target.selector,
        });
        errdefer resolved.deinit(self.allocator);

        return .{
            .client = self,
            .info = .{
                .conversation_id = try self.nextConversationId(),
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

fn resolveTtyTarget(
    allocator: std.mem.Allocator,
    rpc_client: *Client,
    target: protocol.RequestTarget,
) !ResolvedTtyTarget {
    const response = try rpc_client.requestTarget(target, "node.get", "{}");
    defer allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{
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
        .document_path = try allocator.dupe(u8, target.documentPath orelse rpc_client.document_path),
        .node_id = @intCast(node_id_value.integer),
        .session_name = try allocator.dupe(u8, session_name_value.string),
        .pane_id = if (pane_id_value) |value|
            if (value == .string)
                try allocator.dupe(u8, value.string)
            else
                return error.InvalidResponse
        else
            try allocator.dupe(u8, ""),
    };
}
