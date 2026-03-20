//! Serialization helpers for muxml, the durable representation of TOM state.
//!
//! This module defines how nodes and sources are written into JSON and XML
//! forms. It does not own the live graph; `document.zig` does.

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
    name: ?[]u8 = null,
    content: []u8,
    parent_id: ?ids.NodeId,
    children: std.ArrayListUnmanaged(ids.NodeId) = .{},
    source: source_mod.Source = .{ .none = {} },
    lifecycle: types.LifecycleState = .live,
    follow_tail: bool = true,
    backend_id: ?[]u8 = null,

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
        if (self.name) |name| allocator.free(name);
        allocator.free(self.content);
        self.children.deinit(allocator);
        self.source.deinit(allocator);
        if (self.backend_id) |bid| allocator.free(bid);
    }

    pub fn setBackendId(self: *Node, allocator: std.mem.Allocator, value: []const u8) !void {
        if (self.backend_id) |bid| allocator.free(bid);
        self.backend_id = try allocator.dupe(u8, value);
    }

    pub fn setName(self: *Node, allocator: std.mem.Allocator, value: ?[]const u8) !void {
        if (value) |name| {
            if (!isValidNodeName(name)) return error.InvalidNodeName;
            const owned = try allocator.dupe(u8, name);
            if (self.name) |existing| allocator.free(existing);
            self.name = owned;
            return;
        }

        if (self.name) |existing| allocator.free(existing);
        self.name = null;
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
        if (self.name) |name| {
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, name);
        }
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
        try writer.print("<node id=\"{d}\" kind=\"{s}\" lifecycle=\"{s}\" followTail=\"{s}\"", .{
            self.id,
            @tagName(self.kind),
            @tagName(self.lifecycle),
            if (self.follow_tail) "true" else "false",
        });
        if (self.name) |name| {
            try writer.writeAll(" name=\"");
            try escapeXml(name, writer);
            try writer.writeAll("\"");
        }
        try writer.writeAll(">");
        try writer.writeAll("<title>");
        try escapeXml(self.title, writer);
        try writer.writeAll("</title>");
        try writeSourceXml(self.source, writer);
        try writer.writeAll("<content>");
        try escapeXml(self.content, writer);
        try writer.writeAll("</content></node>");
    }
};

pub fn isValidNodeName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (looksLikeDirectNodeReference(name)) return false;
    for (name) |char| {
        if (!isValidNodeNameByte(char)) return false;
    }
    return true;
}

pub fn defaultNodeName(allocator: std.mem.Allocator, title: []const u8) !?[]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();

    var needs_separator = false;
    for (title) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            if (needs_separator and buffer.items.len != 0 and buffer.items[buffer.items.len - 1] != '-') {
                try buffer.append('-');
            }
            try buffer.append(std.ascii.toLower(char));
            needs_separator = false;
            continue;
        }

        switch (char) {
            '.', '_', '~' => {
                if (needs_separator and buffer.items.len != 0 and buffer.items[buffer.items.len - 1] != '-') {
                    try buffer.append('-');
                }
                try buffer.append(char);
                needs_separator = false;
            },
            '-' => {
                if (buffer.items.len == 0 or buffer.items[buffer.items.len - 1] == '-') continue;
                try buffer.append('-');
                needs_separator = false;
            },
            else => {
                if (buffer.items.len != 0) needs_separator = true;
            },
        }
    }

    while (buffer.items.len != 0 and buffer.items[buffer.items.len - 1] == '-') {
        _ = buffer.pop();
    }

    if (buffer.items.len == 0) return null;
    if (isValidNodeName(buffer.items)) return try buffer.toOwnedSlice();
    return try std.fmt.allocPrint(allocator, "n-{s}", .{buffer.items});
}

fn isValidNodeNameByte(char: u8) bool {
    if (std.ascii.isAlphanumeric(char)) return true;
    return switch (char) {
        '-', '.', '_', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '@' => true,
        else => false,
    };
}

fn looksLikeDirectNodeReference(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isDigit(name[0])) {
        _ = std.fmt.parseInt(u64, name, 10) catch return false;
        return true;
    }
    if (name[0] == '@' and name.len > 1) {
        _ = std.fmt.parseInt(u64, name[1..], 10) catch return false;
        return true;
    }
    if (std.mem.startsWith(u8, name, "node-") and name.len > "node-".len) {
        _ = std.fmt.parseInt(u64, name["node-".len..], 10) catch return false;
        return true;
    }
    return false;
}

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
        .terminal_artifact => |artifact| {
            try writer.writeAll("{\"kind\":\"terminal_artifact\",\"artifactKind\":\"");
            try writer.writeAll(@tagName(artifact.artifact_kind));
            try writer.writeAll("\",\"contentFormat\":\"");
            try writer.writeAll(@tagName(artifact.content_format));
            try writer.writeAll("\",\"sections\":[");
            try writeArtifactSectionsJson(artifact.sections, writer);
            try writer.writeAll("],\"origin\":\"");
            try writer.writeAll(@tagName(artifact.origin));
            try writer.writeAll("\"");
            if (artifact.session_name) |session_name| {
                try writer.writeAll(",\"sessionName\":");
                try writeJsonString(writer, session_name);
            }
            if (artifact.window_id) |window_id| {
                try writer.writeAll(",\"windowId\":");
                try writeJsonString(writer, window_id);
            }
            if (artifact.pane_id) |pane_id| {
                try writer.writeAll(",\"paneId\":");
                try writeJsonString(writer, pane_id);
            }
            try writer.writeAll("}");
        },
    }
}

fn writeSourceXml(source: source_mod.Source, writer: anytype) !void {
    switch (source) {
        .none => try writer.writeAll("<source kind=\"none\"/>"),
        .tty => |tty| {
            try writer.writeAll("<source kind=\"tty\"");
            try writer.writeAll(" sessionName=\"");
            try escapeXml(tty.session_name, writer);
            try writer.writeAll("\"");
            if (tty.window_id) |window_id| {
                try writer.writeAll(" windowId=\"");
                try escapeXml(window_id, writer);
                try writer.writeAll("\"");
            }
            if (tty.pane_id) |pane_id| {
                try writer.writeAll(" paneId=\"");
                try escapeXml(pane_id, writer);
                try writer.writeAll("\"");
            }
            try writer.writeAll("/>");
        },
        .file => |file| {
            try writer.writeAll("<source kind=\"file\" path=\"");
            try escapeXml(file.path, writer);
            try writer.writeAll("\" mode=\"");
            try writer.writeAll(@tagName(file.mode));
            try writer.writeAll("\"/>");
        },
        .terminal_artifact => |artifact| {
            try writer.writeAll("<source kind=\"terminal_artifact\" artifactKind=\"");
            try writer.writeAll(@tagName(artifact.artifact_kind));
            try writer.writeAll("\" contentFormat=\"");
            try writer.writeAll(@tagName(artifact.content_format));
            if (!artifact.sections.isEmpty()) {
                try writer.writeAll("\" sections=\"");
                try writeArtifactSectionsXml(artifact.sections, writer);
            }
            try writer.writeAll("\" origin=\"");
            try writer.writeAll(@tagName(artifact.origin));
            try writer.writeAll("\"");
            if (artifact.session_name) |session_name| {
                try writer.writeAll(" sessionName=\"");
                try escapeXml(session_name, writer);
                try writer.writeAll("\"");
            }
            if (artifact.window_id) |window_id| {
                try writer.writeAll(" windowId=\"");
                try escapeXml(window_id, writer);
                try writer.writeAll("\"");
            }
            if (artifact.pane_id) |pane_id| {
                try writer.writeAll(" paneId=\"");
                try escapeXml(pane_id, writer);
                try writer.writeAll("\"");
            }
            try writer.writeAll("/>");
        },
    }
}

fn writeArtifactSectionsJson(sections: source_mod.TerminalArtifactSections, writer: anytype) !void {
    var wrote_one = false;
    if (sections.surface) {
        try writer.writeAll("\"surface\"");
        wrote_one = true;
    }
    if (sections.alternate) {
        if (wrote_one) try writer.writeAll(",");
        try writer.writeAll("\"alternate\"");
    }
}

fn writeArtifactSectionsXml(sections: source_mod.TerminalArtifactSections, writer: anytype) !void {
    var wrote_one = false;
    if (sections.surface) {
        try writer.writeAll("surface");
        wrote_one = true;
    }
    if (sections.alternate) {
        if (wrote_one) try writer.writeAll(",");
        try writer.writeAll("alternate");
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
