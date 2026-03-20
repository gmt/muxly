const std = @import("std");
const muxly = @import("muxly");

test "document derives url-safe node names and keeps backend ids internal" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "Demo Root");
    defer document.deinit();

    const first_id = try document.appendNode(document.root_node_id, .text_leaf, "Build Log", .{ .none = {} });
    const second_id = try document.appendNode(document.root_node_id, .text_leaf, "Build Log", .{ .none = {} });
    const third_id = try document.appendNode(document.root_node_id, .text_leaf, "qa/dev shell", .{ .none = {} });
    const fourth_id = try document.appendNode(document.root_node_id, .text_leaf, "123", .{ .none = {} });

    try document.setNodeBackendId(first_id, "tmux-window:@1");

    const root = document.findNode(document.root_node_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("demo-root", root.name.?);

    const first = document.findNode(first_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("build-log", first.name.?);

    const second = document.findNode(second_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("build-log-2", second.name.?);

    const third = document.findNode(third_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("qa-dev-shell", third.name.?);

    const fourth = document.findNode(fourth_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("n-123", fourth.name.?);

    var json = std.array_list.Managed(u8).init(std.testing.allocator);
    defer json.deinit();
    try document.writeJson(json.writer());
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"name\":\"demo-root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"name\":\"build-log\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"name\":\"build-log-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"backendId\"") == null);

    var xml = std.array_list.Managed(u8).init(std.testing.allocator);
    defer xml.deinit();
    try document.writeXml(xml.writer());
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "name=\"demo-root\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "name=\"build-log\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "backendId=") == null);
}

test "explicit node names validate and stay stable across title updates" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const first_id = try document.appendNode(document.root_node_id, .text_leaf, "Worker Log", .{ .none = {} });
    const second_id = try document.appendNode(document.root_node_id, .text_leaf, "Side Pane", .{ .none = {} });

    try document.setNodeName(first_id, "worker.main");
    try document.setNodeTitle(first_id, "Renamed Worker Log");

    const first = document.findNode(first_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Renamed Worker Log", first.title);
    try std.testing.expectEqualStrings("worker.main", first.name.?);

    try std.testing.expectError(error.InvalidNodeName, document.setNodeName(first_id, "worker/main"));
    try std.testing.expectError(error.InvalidNodeName, document.setNodeName(first_id, "."));
    try std.testing.expectError(error.InvalidNodeName, document.setNodeName(first_id, ".."));
    try std.testing.expectError(error.InvalidNodeName, document.setNodeName(first_id, "123"));
    try std.testing.expectError(error.InvalidNodeName, document.setNodeName(first_id, "@123"));
    try std.testing.expectError(error.InvalidNodeName, document.setNodeName(first_id, "node-123"));
    try std.testing.expectError(error.DuplicateNodeName, document.setNodeName(second_id, "worker.main"));
}
