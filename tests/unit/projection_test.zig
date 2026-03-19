const std = @import("std");
const muxly = @import("muxly");

test "document serializes new node kinds" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "muxly");
    defer document.deinit();

    const split = try document.appendNode(document.root_node_id, .h_container, "body", .{ .none = {} });
    _ = try document.appendNode(split, .v_container, "column", .{ .none = {} });
    _ = try document.appendNode(split, .text_leaf, "thread", .{ .none = {} });

    var json = std.array_list.Managed(u8).init(std.testing.allocator);
    defer json.deinit();
    try document.writeJson(json.writer());

    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"kind\":\"h_container\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"kind\":\"v_container\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"kind\":\"text_leaf\"") != null);
}

test "projection lays out chrome and split regions with local focus" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "muxly");
    defer document.deinit();

    const modeline = try document.appendNode(document.root_node_id, .modeline_region, "status", .{ .none = {} });
    try document.setNodeContent(modeline, "viewer :: projection.get");
    const body = try document.appendNode(document.root_node_id, .h_container, "body", .{ .none = {} });
    const thread = try document.appendNode(body, .text_leaf, "thread", .{ .none = {} });
    try document.setNodeContent(thread, "line-1\nline-2\nline-3");
    const activity = try document.appendNode(body, .tty_leaf, "worker", .{ .none = {} });
    try document.setNodeContent(activity, "zig build test\nok");

    const projection = try projectDocument(&document, .{
        .rows = 20,
        .cols = 60,
        .local_state = .{ .focused_node_id = thread },
    });
    defer std.testing.allocator.free(projection);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, projection, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const regions = parsed.value.object.get("regions").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), regions.len);

    const modeline_region = findRegion(regions, modeline).?;
    try std.testing.expectEqual(@as(i64, 1), modeline_region.object.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 1), modeline_region.object.get("y").?.integer);
    try std.testing.expectEqual(@as(i64, 58), modeline_region.object.get("width").?.integer);
    try std.testing.expectEqual(@as(i64, 3), modeline_region.object.get("height").?.integer);

    const thread_region = findRegion(regions, thread).?;
    try std.testing.expectEqual(true, thread_region.object.get("focused").?.bool);

    const activity_region = findRegion(regions, activity).?;
    try std.testing.expectEqual(@as(i64, 30), activity_region.object.get("x").?.integer);
}

test "projection applies local scroll offsets without mutating document state" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "muxly");
    defer document.deinit();

    const node_id = try document.appendNode(document.root_node_id, .text_leaf, "thread", .{ .none = {} });
    try document.setNodeContent(node_id, "zero\none\ntwo\nthree\nfour\nfive");
    try document.setFollowTail(node_id, false);

    const projection = try projectDocument(&document, .{
        .rows = 8,
        .cols = 24,
        .local_state = .{ .scroll_offsets = &.{.{ .node_id = node_id, .top_line = 2 }} },
    });
    defer std.testing.allocator.free(projection);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, projection, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const region = findRegion(parsed.value.object.get("regions").?.array.items, node_id).?;
    try std.testing.expectEqual(@as(i64, 2), region.object.get("scrollTop").?.integer);
    const lines = region.object.get("lines").?.array.items;
    try std.testing.expectEqualStrings("two", lines[0].string);
    try std.testing.expectEqualStrings("three", lines[1].string);
    try std.testing.expect(document.view_root_node_id == null);
    try std.testing.expectEqual(false, document.findNode(node_id).?.follow_tail);
}

fn projectDocument(document: *const muxly.document.Document, request: muxly.projection.Request) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    errdefer buffer.deinit();
    try muxly.projection.writeProjectionJson(std.testing.allocator, document, request, buffer.writer());
    return buffer.toOwnedSlice();
}

fn findRegion(regions: []const std.json.Value, node_id: u64) ?std.json.Value {
    for (regions) |region| {
        if (region != .object) continue;
        const value = region.object.get("nodeId") orelse continue;
        if (value != .integer) continue;
        if (@as(u64, @intCast(value.integer)) == node_id) return region;
    }
    return null;
}
