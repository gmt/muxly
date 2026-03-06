const std = @import("std");
const muxly = @import("muxly");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    var socket_path = muxly.api.defaultSocketPath();
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--socket")) socket_path = args[2];

    const response = try muxly.api.documentGet(allocator, socket_path);
    defer allocator.free(response);

    const parsed_response = try std.json.parseFromSlice(std.json.Value, allocator, response, .{
        .allocate = .alloc_always,
    });
    defer parsed_response.deinit();

    const result = parsed_response.value.object.get("result") orelse {
        try std.io.getStdOut().writer().writeAll(response);
        return;
    };

    try renderDocument(result, std.io.getStdOut().writer());
}

fn renderDocument(document_value: std.json.Value, writer: anytype) !void {
    if (document_value != .object) return error.InvalidDocument;

    const title = document_value.object.get("title") orelse return error.InvalidDocument;
    const root_node_id = document_value.object.get("rootNodeId") orelse return error.InvalidDocument;
    const nodes = document_value.object.get("nodes") orelse return error.InvalidDocument;

    if (title != .string or root_node_id != .integer or nodes != .array) return error.InvalidDocument;

    try writer.print("muxview :: {s}\n", .{title.string});
    try renderNodeTree(nodes.array.items, @intCast(root_node_id.integer), 0, writer);
}

fn renderNodeTree(nodes: []const std.json.Value, node_id: u64, depth: usize, writer: anytype) !void {
    const node = findNode(nodes, node_id) orelse return error.InvalidDocument;
    const title = node.object.get("title") orelse return error.InvalidDocument;
    const kind = node.object.get("kind") orelse return error.InvalidDocument;
    const content = node.object.get("content") orelse return error.InvalidDocument;
    const children = node.object.get("children") orelse return error.InvalidDocument;

    if (title != .string or kind != .string or content != .string or children != .array) return error.InvalidDocument;

    for (0..depth) |_| try writer.writeAll("  ");
    try writer.print("- {s} [{s}]\n", .{ title.string, kind.string });

    if (content.string.len != 0 and depth <= 1) {
        var line_it = std.mem.splitScalar(u8, content.string, '\n');
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            for (0..depth + 1) |_| try writer.writeAll("  ");
            try writer.print("> {s}\n", .{line});
        }
    }

    for (children.array.items) |child| {
        if (child != .integer) return error.InvalidDocument;
        try renderNodeTree(nodes, @intCast(child.integer), depth + 1, writer);
    }
}

fn findNode(nodes: []const std.json.Value, node_id: u64) ?std.json.Value {
    for (nodes) |node| {
        if (node != .object) continue;
        const id_value = node.object.get("id") orelse continue;
        if (id_value != .integer) continue;
        if (@as(u64, @intCast(id_value.integer)) == node_id) return node;
    }
    return null;
}
