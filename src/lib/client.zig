//! Thin Zig client for talking to an external `muxlyd` process.
//!
//! This layer owns the transport conversation with the daemon. Client handles
//! now keep one transport session open and reuse it across requests until
//! `deinit`, which is especially helpful for viewers and SSH relays.

const std = @import("std");
const protocol = @import("../core/protocol.zig");
const transport = @import("transport.zig");

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
        var request_json = std.array_list.Managed(u8).init(self.allocator);
        defer request_json.deinit();

        try protocol.writeClientRequest(
            request_json.writer(),
            self.next_request_id,
            self.document_path,
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
