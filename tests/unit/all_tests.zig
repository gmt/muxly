const std = @import("std");
const muxly = @import("muxly");

test "document bootstrap model supports append and xml serialization" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "demo");
    defer document.deinit();

    const node_id = try document.appendNode(
        document.root_node_id,
        .scroll_region,
        "tail",
        .{ .none = {} },
    );
    try document.appendTextToNode(node_id, "hello");
    try document.appendTextToNode(node_id, "\nworld");
    try document.setViewRoot(node_id);
    try document.toggleElided(node_id);

    var json = std.ArrayList(u8).init(std.testing.allocator);
    defer json.deinit();
    try document.writeJson(json.writer());
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"viewRootNodeId\":2") != null);

    var xml = std.ArrayList(u8).init(std.testing.allocator);
    defer xml.deinit();
    try document.writeXml(xml.writer());
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<muxml") != null);
}

test "protocol request parsing keeps JSON-RPC fields" {
    const payload =
        \\{"jsonrpc":"2.0","id":7,"method":"document.get","params":{}}
    ;
    const parsed = try muxly.protocol.parseRequest(std.testing.allocator, payload);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("2.0", parsed.value.jsonrpc);
    try std.testing.expectEqualStrings("document.get", parsed.value.method);
    try std.testing.expect(parsed.value.id != null);
}
