//! Thin Zig client for talking to an external `muxlyd` process.
//!
//! This layer owns the transport conversation with the daemon. It currently
//! uses Unix-domain sockets on Unix-like hosts and returns
//! `error.UnsupportedPlatform` on Windows until the named-pipe transport is
//! implemented.

const std = @import("std");
const builtin = @import("builtin");
const unix_socket = @import("../platform/unix_socket.zig");

/// Handle-based client bound to one daemon socket path.
pub const Client = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,

    /// Initializes a client that will talk to the daemon at `socket_path`.
    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !Client {
        return .{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
        };
    }

    /// Releases memory owned by the client handle.
    pub fn deinit(self: *Client) void {
        self.allocator.free(self.socket_path);
    }

    /// Sends one JSON-RPC request assembled from `method` and `params_json`.
    ///
    /// The returned slice is the raw UTF-8 response payload and is owned by the
    /// caller.
    pub fn request(self: *Client, method: []const u8, params_json: []const u8) ![]u8 {
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        );
        defer self.allocator.free(request_json);
        return try self.requestJson(request_json);
    }

    /// Sends a prebuilt JSON-RPC request payload to the daemon.
    ///
    /// This is the lowest-level Zig client entry point in the package. The
    /// returned slice is owned by the caller.
    pub fn requestJson(self: *Client, request_json: []const u8) ![]u8 {
        if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

        var stream = try unix_socket.connect(self.socket_path);
        defer stream.close();

        try stream.writeAll(request_json);
        try stream.writeAll("\n");

        var response = std.array_list.Managed(u8).init(self.allocator);
        errdefer response.deinit();

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try stream.read(&buffer);
            if (bytes_read == 0) break;
            try response.appendSlice(buffer[0..bytes_read]);
        }

        return try response.toOwnedSlice();
    }
};
