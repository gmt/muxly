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

    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();

    try muxly.viewer_render.renderDocumentValue(std.testing.allocator, parsed.value, output.writer());

    try std.testing.expect(std.mem.indexOf(u8, output.items, "view-state :: shared-document") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "path :: muxly / scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "back-out :: muxly view clear-root | muxly view reset") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "… elided by shared view state …") != null);
}

test "viewer renders deep leaf content but not branch marker content" {
    const payload =
        \\{
        \\  "title": "muxly",
        \\  "rootNodeId": 1,
        \\  "viewRootNodeId": 2,
        \\  "elidedNodeIds": [],
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
        \\      "content": "",
        \\      "followTail": true,
        \\      "lifecycle": "live",
        \\      "source": {"kind": "none"},
        \\      "children": [3],
        \\      "parentId": 1
        \\    },
        \\    {
        \\      "id": 3,
        \\      "kind": "subdocument",
        \\      "title": "session",
        \\      "content": "tmux-session:$0",
        \\      "followTail": true,
        \\      "lifecycle": "live",
        \\      "source": {"kind": "none"},
        \\      "children": [4],
        \\      "parentId": 2
        \\    },
        \\    {
        \\      "id": 4,
        \\      "kind": "subdocument",
        \\      "title": "tmux",
        \\      "content": "tmux-window:@0",
        \\      "followTail": true,
        \\      "lifecycle": "live",
        \\      "source": {"kind": "none"},
        \\      "children": [5],
        \\      "parentId": 3
        \\    },
        \\    {
        \\      "id": 5,
        \\      "kind": "tty_leaf",
        \\      "title": "shell",
        \\      "content": "theorem-demo",
        \\      "followTail": true,
        \\      "lifecycle": "live",
        \\      "source": {"kind": "tty", "sessionName": "demo", "windowId": "@0", "paneId": "%1"},
        \\      "children": [],
        \\      "parentId": 4
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();

    try muxly.viewer_render.renderDocumentValue(std.testing.allocator, parsed.value, output.writer());

    try std.testing.expect(std.mem.indexOf(u8, output.items, "theorem-demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "tmux-session:$0") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "tmux-window:@0") == null);
}
