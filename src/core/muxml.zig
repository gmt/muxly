const std = @import("std");
const ids = @import("ids.zig");
const source_mod = @import("source.zig");
const types = @import("types.zig");

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

pub const Node = struct {
    id: ids.NodeId,
    kind: types.NodeKind,
    title: []u8,
    content: []u8,
    parent_id: ?ids.NodeId,
    children: std.ArrayListUnmanaged(ids.NodeId) = .{},
    source: source_mod.Source = .{ .none = {} },
    lifecycle: types.LifecycleState = .live,
    follow_tail: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        id: ids.NodeId,
        kind: types.NodeKind,
        title: []const u8,
        parent_id: ?ids.NodeId,
        source: source_mod.Source,
    ) !Node {
        return .{
            .id = id,
            .kind = kind,
            .title = try allocator.dupe(u8, title),
            .content = try allocator.dupe(u8, ""),
            .parent_id = parent_id,
            .source = try source.clone(allocator),
        };
    }

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.content);
        self.children.deinit(allocator);
        self.source.deinit(allocator);
    }

    pub fn setContent(self: *Node, allocator: std.mem.Allocator, content: []const u8) !void {
        allocator.free(self.content);
        self.content = try allocator.dupe(u8, content);
    }

    pub fn setTitle(self: *Node, allocator: std.mem.Allocator, title: []const u8) !void {
        allocator.free(self.title);
        self.title = try allocator.dupe(u8, title);
    }

    pub fn appendContent(self: *Node, allocator: std.mem.Allocator, chunk: []const u8) !void {
        var buffer = std.array_list.Managed(u8).init(allocator);
        defer buffer.deinit();
        try buffer.appendSlice(self.content);
        try buffer.appendSlice(chunk);
        allocator.free(self.content);
        self.content = try buffer.toOwnedSlice();
    }

    pub fn writeJson(self: Node, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"id\":{d},", .{self.id});
        try writer.print("\"kind\":\"{s}\",", .{@tagName(self.kind)});
        try writer.writeAll("\"title\":");
        try writeJsonString(writer, self.title);
        try writer.writeAll(",\"content\":");
        try writeJsonString(writer, self.content);
        try writer.print(",\"followTail\":{},", .{self.follow_tail});
        try writer.print("\"lifecycle\":\"{s}\",", .{@tagName(self.lifecycle)});
        try writer.writeAll("\"source\":");
        try writeSourceJson(self.source, writer);
        try writer.writeAll(",\"children\":[");
        for (self.children.items, 0..) |child_id, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.print("{d}", .{child_id});
        }
        try writer.writeAll("]");
        if (self.parent_id) |parent_id| {
            try writer.print(",\"parentId\":{d}", .{parent_id});
        }
        try writer.writeAll("}");
    }

    pub fn writeXml(self: Node, writer: anytype) !void {
        try writer.print("<node id=\"{d}\" kind=\"{s}\" lifecycle=\"{s}\" followTail=\"{s}\">", .{
            self.id,
            @tagName(self.kind),
            @tagName(self.lifecycle),
            if (self.follow_tail) "true" else "false",
        });
        try writer.writeAll("<title>");
        try escapeXml(self.title, writer);
        try writer.writeAll("</title><content>");
        try escapeXml(self.content, writer);
        try writer.writeAll("</content></node>");
    }
};

pub fn writeSourceJson(source: source_mod.Source, writer: anytype) !void {
    switch (source) {
        .none => try writer.writeAll("{\"kind\":\"none\"}"),
        .tty => |tty| {
            try writer.writeAll("{\"kind\":\"tty\",\"sessionName\":");
            try writeJsonString(writer, tty.session_name);
            if (tty.window_id) |window_id| {
                try writer.writeAll(",\"windowId\":");
                try writeJsonString(writer, window_id);
            }
            if (tty.pane_id) |pane_id| {
                try writer.writeAll(",\"paneId\":");
                try writeJsonString(writer, pane_id);
            }
            try writer.writeAll("}");
        },
        .file => |file| {
            try writer.writeAll("{\"kind\":\"file\",\"path\":");
            try writeJsonString(writer, file.path);
            try writer.print(",\"mode\":\"{s}\"}}", .{@tagName(file.mode)});
        },
    }
}

fn escapeXml(value: []const u8, writer: anytype) !void {
    for (value) |char| switch (char) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&apos;"),
        else => try writer.writeByte(char),
    };
}
