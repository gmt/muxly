const std = @import("std");
const muxly = @import("muxly");

test "viewer renders shared scope breadcrumbs and elision cues" {
    const payload =
        \\{
        \\  "title": "muxly",
        \\  "rootNodeId": 1,
        \\  "viewRootNodeId": 2,
        \\  "elidedNodeIds": [3],
        \\  "nodes": [
        \\    {
        \\      "id": 1,
        \\      "kind": "document",
        \\      "title": "muxly",
        \\      "content": "",
        \\      "followTail": false,
        \\      "lifecycle": "live",
        \\      "source": {"kind": "none"},
        \\      "children": [2]
        \\    },
        \\    {
        \\      "id": 2,
        \\      "kind": "subdocument",
        \\      "title": "scope",
        \\      "content": "scope line",
        \\      "followTail": true,
        \\      "lifecycle": "live",
        \\      "source": {"kind": "none"},
        \\      "children": [3],
        \\      "parentId": 1
        \\    },
        \\    {
        \\      "id": 3,
        \\      "kind": "monitored_file_leaf",
        \\      "title": "logs",
        \\      "content": "line-1\\nline-2",
        \\      "followTail": false,
        \\      "lifecycle": "live",
        \\      "source": {"kind": "file", "path": "/tmp/log.txt", "mode": "monitored"},
        \\      "children": [],
        \\      "parentId": 2
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();

    try muxly.viewer_render.renderDocumentValue(std.testing.allocator, parsed.value, output.writer());

    try std.testing.expect(std.mem.indexOf(u8, output.items, "view-state :: shared-document") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "path :: muxly / scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "back-out :: muxly view clear-root | muxly view reset") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "… elided by shared view state …") != null);
}
