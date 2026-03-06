const std = @import("std");
const muxly = @import("muxly");

test "document tracks view root and elision" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "view");
    defer document.deinit();

    const child = try document.appendNode(document.root_node_id, .scroll_region, "child", .{ .none = {} });
    try document.setViewRoot(child);
    try document.toggleElided(child);

    try std.testing.expectEqual(child, document.view_root_node_id.?);
    try std.testing.expectEqual(@as(usize, 1), document.elided_node_ids.items.len);
}
