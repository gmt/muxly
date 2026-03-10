const std = @import("std");

pub const CommandBoundary = struct {
    timestamp: u64,
    command_number: u64,
    flags: i64,
};

pub const Notification = struct {
    name: []const u8,
    payload: []const u8,
};

pub const PaneSnapshot = struct {
    session_name: []const u8,
    window_id: []const u8,
    pane_id: []const u8,
};

pub const Event = union(enum) {
    begin: CommandBoundary,
    end: CommandBoundary,
    command_error: CommandBoundary,
    notification: Notification,
    output: []const u8,
    exit,
};

pub const CommandBlock = struct {
    boundary: CommandBoundary,
    output_lines: std.array_list.Managed([]u8),
    completed: bool = false,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, boundary: CommandBoundary) CommandBlock {
        return .{
            .boundary = boundary,
            .output_lines = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *CommandBlock) void {
        for (self.output_lines.items) |line| self.output_lines.allocator.free(line);
        self.output_lines.deinit();
    }
};
