//! Thin Zig client for talking to an external `muxlyd` process.
//!
//! This layer owns the transport conversation with the daemon. Client handles
//! now keep one transport session open and reuse it across requests until
//! `deinit`, which is especially helpful for viewers and SSH relays.

const std = @import("std");
const transport = @import("transport.zig");

/// Handle-based client bound to one daemon transport address.
pub const Client = struct {
    allocator: std.mem.Allocator,
    address: transport.Address,
    connection: ?transport.Connection = null,
    next_request_id: u64 = 1,

    /// Initializes a client that will talk to the daemon at `transport_spec`.
    pub fn init(allocator: std.mem.Allocator, transport_spec: []const u8) !Client {
        return .{
            .allocator = allocator,
            .address = try transport.Address.parse(allocator, transport_spec),
        };
    }

    /// Releases memory and any live transport session owned by the client.
    pub fn deinit(self: *Client) void {
        if (self.connection) |*connection| connection.close();
        self.address.deinit(self.allocator);
    }

    /// Sends one JSON-RPC request assembled from `method` and `params_json`.
    ///
    /// The returned slice is the raw UTF-8 response payload and is owned by the
    /// caller.
    pub fn request(self: *Client, method: []const u8, params_json: []const u8) ![]u8 {
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ self.next_request_id, method, params_json },
        );
        defer self.allocator.free(request_json);

        self.next_request_id += 1;
        return try self.requestJson(request_json);
    }

    /// Sends a prebuilt JSON-RPC request payload to the daemon.
    ///
    /// This is the lowest-level Zig client entry point in the package. The
    /// returned slice is owned by the caller.
    pub fn requestJson(self: *Client, request_json: []const u8) ![]u8 {
        var connection = try self.ensureConnected();
        try connection.writeAll(request_json);
        try connection.writeAll("\n");

        return (try transport.readMessageLine(
            self.allocator,
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
