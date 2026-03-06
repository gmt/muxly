const std = @import("std");

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
        _ = method;
        _ = params_json;
        return std.fmt.allocPrint(self.allocator, "{{\"status\":\"bootstrap\",\"socketPath\":\"{s}\"}}", .{
            self.socket_path,
        });
    }
};
