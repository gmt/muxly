const std = @import("std");
const muxly = @import("muxly");
const daemon_router = @import("daemon_router");

test "store refresh keeps file-source content accounting in sync" {
    var store = try daemon_router.Store.init(std.testing.allocator);
    defer store.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "fixture.txt",
        .data = "hello from fixture\n",
    });

    const fixture_path = try tmp.dir.realpathAlloc(std.testing.allocator, "fixture.txt");
    defer std.testing.allocator.free(fixture_path);

    const document = store.rootDocument();
    const baseline_bytes = document.content_bytes;
    const node_id = try document.appendNode(
        document.root_node_id,
        .static_file_leaf,
        "fixture",
        .{ .file = .{
            .path = fixture_path,
            .mode = .static,
        } },
    );

    try store.refreshSourcesForDocument(document);

    const node = document.findNode(node_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("hello from fixture\n", node.content);
    try std.testing.expectEqual(baseline_bytes + node.content.len, document.content_bytes);

    try document.removeNode(node_id);
    try std.testing.expectEqual(baseline_bytes, document.content_bytes);
}
