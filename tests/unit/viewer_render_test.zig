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

    const output = try renderPayload(payload);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "view-state :: shared-document") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "path :: muxly / scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "back-out :: muxly view clear-root | muxly view reset") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "- scope [id=2, kind=subdocument, lifecycle=live, source=synthetic, tail=follow]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "… elided by shared view state …") != null);
}

test "viewer renders live tty leaf content but not branch marker content" {
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

    const output = try renderPayload(payload);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "- shell [id=5, kind=tty_leaf, lifecycle=live, source=%1, tail=follow]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "theorem-demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "tmux-session:$0") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "tmux-window:@0") == null);
}

test "viewer renders detached tty state explicitly" {
    const payload =
        \\{
        \\  "title": "muxly",
        \\  "rootNodeId": 1,
        \\  "viewRootNodeId": null,
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
        \\      "kind": "tty_leaf",
        \\      "title": "detached-shell",
        \\      "content": "detached transcript",
        \\      "followTail": false,
        \\      "lifecycle": "detached",
        \\      "source": {"kind": "tty", "sessionName": "demo-detached", "paneId": "%9"},
        \\      "children": [],
        \\      "parentId": 1
        \\    }
        \\  ]
        \\}
    ;

    const output = try renderPayload(payload);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "- detached-shell [id=2, kind=tty_leaf, lifecycle=detached, source=%9, tail=manual]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "state :: detached tty source") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "detached transcript") != null);
}

test "viewer renders frozen text artifact provenance and content" {
    const payload =
        \\{
        \\  "title": "muxly",
        \\  "rootNodeId": 1,
        \\  "viewRootNodeId": null,
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
        \\      "kind": "tty_leaf",
        \\      "title": "frozen-shell",
        \\      "content": "hello\\nworld",
        \\      "followTail": true,
        \\      "lifecycle": "frozen",
        \\      "source": {
        \\        "kind": "terminal_artifact",
        \\        "artifactKind": "text",
        \\        "contentFormat": "plain_text",
        \\        "sections": [],
        \\        "origin": "tty",
        \\        "sessionName": "freeze-demo",
        \\        "windowId": "@1",
        \\        "paneId": "%3"
        \\      },
        \\      "children": [],
        \\      "parentId": 1
        \\    }
        \\  ]
        \\}
    ;

    const output = try renderPayload(payload);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "- frozen-shell [id=2, kind=tty_leaf, lifecycle=frozen, source=artifact:text, tail=follow]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "artifact :: origin=tty, session=freeze-demo, window=@1, pane=%3, format=plain_text, sections=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "world") != null);
}

test "viewer renders frozen surface artifact metadata with surface section" {
    const payload =
        \\{
        \\  "title": "muxly",
        \\  "rootNodeId": 1,
        \\  "viewRootNodeId": null,
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
        \\      "kind": "tty_leaf",
        \\      "title": "surface-pane",
        \\      "content": "[surface]\\nframe-1",
        \\      "followTail": false,
        \\      "lifecycle": "frozen",
        \\      "source": {
        \\        "kind": "terminal_artifact",
        \\        "artifactKind": "surface",
        \\        "contentFormat": "sectioned_text",
        \\        "sections": ["surface"],
        \\        "origin": "tty",
        \\        "sessionName": "freeze-surface",
        \\        "paneId": "%4"
        \\      },
        \\      "children": [],
        \\      "parentId": 1
        \\    }
        \\  ]
        \\}
    ;

    const output = try renderPayload(payload);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "- surface-pane [id=2, kind=tty_leaf, lifecycle=frozen, source=artifact:surface, tail=manual]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "artifact :: origin=tty, session=freeze-surface, pane=%4, format=sectioned_text, sections=surface") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[surface]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "frame-1") != null);
}

test "viewer renders frozen surface artifact metadata with alternate section" {
    const payload =
        \\{
        \\  "title": "muxly",
        \\  "rootNodeId": 1,
        \\  "viewRootNodeId": null,
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
        \\      "kind": "tty_leaf",
        \\      "title": "surface-pane",
        \\      "content": "[surface]\\nframe-1\\n[alternate]\\nframe-2",
        \\      "followTail": false,
        \\      "lifecycle": "frozen",
        \\      "source": {
        \\        "kind": "terminal_artifact",
        \\        "artifactKind": "surface",
        \\        "contentFormat": "sectioned_text",
        \\        "sections": ["surface", "alternate"],
        \\        "origin": "tty",
        \\        "sessionName": "freeze-surface",
        \\        "windowId": "@2",
        \\        "paneId": "%4"
        \\      },
        \\      "children": [],
        \\      "parentId": 1
        \\    }
        \\  ]
        \\}
    ;

    const output = try renderPayload(payload);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "artifact :: origin=tty, session=freeze-surface, window=@2, pane=%4, format=sectioned_text, sections=surface,alternate") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[alternate]") != null);
}

test "viewer rejects malformed artifact payloads" {
    const payload =
        \\{
        \\  "title": "muxly",
        \\  "rootNodeId": 1,
        \\  "viewRootNodeId": null,
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
        \\      "kind": "tty_leaf",
        \\      "title": "bad-artifact",
        \\      "content": "oops",
        \\      "followTail": false,
        \\      "lifecycle": "frozen",
        \\      "source": {
        \\        "kind": "terminal_artifact",
        \\        "artifactKind": "surface",
        \\        "contentFormat": "sectioned_text",
        \\        "sections": "surface",
        \\        "origin": "tty"
        \\      },
        \\      "children": [],
        \\      "parentId": 1
        \\    }
        \\  ]
        \\}
    ;

    try std.testing.expectError(error.InvalidDocument, tryRenderPayload(payload));
}

test "viewer rejects malformed lifecycle payloads" {
    const payload =
        \\{
        \\  "title": "muxly",
        \\  "rootNodeId": 1,
        \\  "viewRootNodeId": null,
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
        \\      "kind": "tty_leaf",
        \\      "title": "bad-lifecycle",
        \\      "content": "oops",
        \\      "followTail": false,
        \\      "lifecycle": "haunted",
        \\      "source": {"kind": "tty", "sessionName": "demo", "paneId": "%7"},
        \\      "children": [],
        \\      "parentId": 1
        \\    }
        \\  ]
        \\}
    ;

    try std.testing.expectError(error.InvalidDocument, tryRenderPayload(payload));
}

fn renderPayload(payload: []const u8) ![]u8 {
    return try tryRenderPayload(payload);
}

fn tryRenderPayload(payload: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    errdefer output.deinit();

    try muxly.viewer_render.renderDocumentValue(std.testing.allocator, parsed.value, output.writer());
    return try output.toOwnedSlice();
}
