const std = @import("std");

pub const FileMode = enum {
    monitored,
    static,
};

pub const TtySource = struct {
    session_name: []u8,
    window_id: ?[]u8 = null,
    pane_id: ?[]u8 = null,

    pub fn clone(self: TtySource, allocator: std.mem.Allocator) !TtySource {
        return .{
            .session_name = try allocator.dupe(u8, self.session_name),
            .window_id = if (self.window_id) |value| try allocator.dupe(u8, value) else null,
            .pane_id = if (self.pane_id) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *TtySource, allocator: std.mem.Allocator) void {
        allocator.free(self.session_name);
        if (self.window_id) |value| allocator.free(value);
        if (self.pane_id) |value| allocator.free(value);
    }
};

pub const FileSource = struct {
    path: []u8,
    mode: FileMode,

    pub fn clone(self: FileSource, allocator: std.mem.Allocator) !FileSource {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .mode = self.mode,
        };
    }

    pub fn deinit(self: *FileSource, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const SourceKind = enum {
    none,
    tty,
    file,
};

pub const Source = union(SourceKind) {
    none: void,
    tty: TtySource,
    file: FileSource,

    pub fn clone(self: Source, allocator: std.mem.Allocator) !Source {
        return switch (self) {
            .none => .{ .none = {} },
            .tty => |tty| .{ .tty = try tty.clone(allocator) },
            .file => |file| .{ .file = try file.clone(allocator) },
        };
    }

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .tty => |*tty| tty.deinit(allocator),
            .file => |*file| file.deinit(allocator),
        }
        self.* = .{ .none = {} };
    }
};
