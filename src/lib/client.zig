const std = @import("std");
const builtin = @import("builtin");
const unix_socket = @import("../platform/unix_socket.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !Client {
        return .{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.socket_path);
    }

    pub fn request(self: *Client, method: []const u8, params_json: []const u8) ![]u8 {
        const request_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        );
        defer self.allocator.free(request_json);
        return try self.requestJson(request_json);
    }

    pub fn requestJson(self: *Client, request_json: []const u8) ![]u8 {
        if (builtin.os.tag == .windows) return error.UnsupportedPlatform;

        var stream = try unix_socket.connect(self.socket_path);
        defer stream.close();

        try stream.writer().writeAll(request_json);
        try stream.writer().writeByte('\n');

        return try stream.reader().readAllAlloc(self.allocator, 1 << 20);
    }
};
