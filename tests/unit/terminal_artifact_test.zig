const std = @import("std");
const muxly = @import("muxly");

test "tty leaf can freeze into captured text artifact while preserving provenance" {
    var document = try muxly.document.Document.init(std.testing.allocator, 1, "artifact-demo");
    defer document.deinit();

    const node_id = try document.appendNode(
        document.root_node_id,
        .tty_leaf,
        "shell",
        .{ .tty = .{
            .session_name = @constCast("demo"),
            .window_id = @constCast("@1"),
            .pane_id = @constCast("%3"),
        } },
    );
    try document.setNodeContent(node_id, "hello\nworld\n");

    try document.freezeTtyNodeAsArtifact(node_id, .text);

    const node = document.findNode(node_id).?;
    try std.testing.expectEqual(muxly.types.LifecycleState.frozen, node.lifecycle);
    switch (node.source) {
        .terminal_artifact => |artifact| {
            try std.testing.expectEqual(muxly.source.TerminalArtifactKind.text, artifact.artifact_kind);
            try std.testing.expectEqual(muxly.source.TerminalArtifactOriginKind.tty, artifact.origin);
            try std.testing.expectEqualStrings("demo", artifact.session_name.?);
            try std.testing.expectEqualStrings("@1", artifact.window_id.?);
            try std.testing.expectEqualStrings("%3", artifact.pane_id.?);
        },
        else => return error.UnexpectedSourceKind,
    }

    var json = std.array_list.Managed(u8).init(std.testing.allocator);
    defer json.deinit();
    try document.writeJson(json.writer());
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"kind\":\"terminal_artifact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.items, "\"artifactKind\":\"text\"") != null);

    var xml = std.array_list.Managed(u8).init(std.testing.allocator);
    defer xml.deinit();
    try document.writeXml(xml.writer());
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "<source kind=\"terminal_artifact\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml.items, "artifactKind=\"text\"") != null);
}
