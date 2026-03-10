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

pub const PaneOutput = struct {
    pane_id: []const u8,
    payload: []const u8,
};

pub const PaneSnapshot = struct {
    session_name: []const u8,
    session_id: []const u8,
    window_id: []const u8,
    window_name: []const u8,
    pane_id: []const u8,
    pane_title: []const u8,
    pane_active: bool,

    pub fn clone(self: PaneSnapshot, allocator: std.mem.Allocator) !PaneSnapshot {
        return .{
            .session_name = try allocator.dupe(u8, self.session_name),
            .session_id = try allocator.dupe(u8, self.session_id),
            .window_id = try allocator.dupe(u8, self.window_id),
            .window_name = try allocator.dupe(u8, self.window_name),
            .pane_id = try allocator.dupe(u8, self.pane_id),
            .pane_title = try allocator.dupe(u8, self.pane_title),
            .pane_active = self.pane_active,
        };
    }

    pub fn deinit(self: *PaneSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.session_name);
        allocator.free(self.session_id);
        allocator.free(self.window_id);
        allocator.free(self.window_name);
        allocator.free(self.pane_id);
        allocator.free(self.pane_title);
    }
};

pub const Event = union(enum) {
    begin: CommandBoundary,
    end: CommandBoundary,
    command_error: CommandBoundary,
    notification: Notification,
    pane_output: PaneOutput,
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
