const std = @import("std");
const muxly = @import("muxly");

test "viewer renders boxed focused and nested regions" {
    const payload =
        \\{
        \\  "rows": 12,
        \\  "cols": 44,
        \\  "regions": [
        \\    {
        \\      "nodeId": 1,
        \\      "kind": "document",
        \\      "title": "muxly",
        \\      "x": 0,
        \\      "y": 0,
        \\      "width": 44,
        \\      "height": 12,
        \\      "focused": false,
        \\      "followTail": false,
        \\      "scrollable": false,
        \\      "scrollTop": 0,
        \\      "scrollMax": 0,
        \\      "elided": false,
        \\      "lines": []
        \\    },
        \\    {
        \\      "nodeId": 2,
        \\      "kind": "modeline_region",
        \\      "title": "status",
        \\      "x": 1,
        \\      "y": 1,
        \\      "width": 42,
        \\      "height": 3,
        \\      "focused": false,
        \\      "followTail": false,
        \\      "scrollable": false,
        \\      "scrollTop": 0,
        \\      "scrollMax": 0,
        \\      "elided": false,
        \\      "lines": ["muxview :: projection.get"]
        \\    },
        \\    {
        \\      "nodeId": 3,
        \\      "kind": "text_leaf",
        \\      "title": "thread",
        \\      "x": 1,
        \\      "y": 4,
        \\      "width": 24,
        \\      "height": 7,
        \\      "focused": true,
        \\      "followTail": true,
        \\      "scrollable": true,
        \\      "scrollTop": 1,
        \\      "scrollMax": 3,
        \\      "elided": false,
        \\      "lines": ["assistant: boxed stage", "tool: projection.get", "user: continue"]
        \\    },
        \\    {
        \\      "nodeId": 4,
        \\      "kind": "subdocument",
        \\      "title": "activity",
        \\      "x": 25,
        \\      "y": 4,
        \\      "width": 18,
        \\      "height": 7,
        \\      "focused": false,
        \\      "followTail": false,
        \\      "scrollable": false,
        \\      "scrollTop": 0,
        \\      "scrollMax": 0,
        \\      "elided": false,
        \\      "lines": []
        \\    },
        \\    {
        \\      "nodeId": 5,
        \\      "kind": "tty_leaf",
        \\      "title": "worker-1",
        \\      "x": 26,
        \\      "y": 5,
        \\      "width": 16,
        \\      "height": 5,
        \\      "focused": false,
        \\      "followTail": true,
        \\      "scrollable": false,
        \\      "scrollTop": 0,
        \\      "scrollMax": 0,
        \\      "elided": false,
        \\      "lines": ["zig build test", "ok"]
        \\    }
        \\  ]
        \\}
    ;

    const output = try renderPayload(payload);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "+muxly") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+status") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "*> thread [tail]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "assistant: boxed stage") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+activity") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "worker-1 [tai") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zig build test") != null);
}

test "viewer renders elided marker in header and body" {
    const payload =
        \\{
        \\  "rows": 6,
        \\  "cols": 40,
        \\  "regions": [
        \\    {
        \\      "nodeId": 9,
        \\      "kind": "scroll_region",
        \\      "title": "collapsed",
        \\      "x": 0,
        \\      "y": 0,
        \\      "width": 40,
        \\      "height": 6,
        \\      "focused": false,
        \\      "followTail": false,
        \\      "scrollable": false,
        \\      "scrollTop": 0,
        \\      "scrollMax": 0,
        \\      "elided": true,
        \\      "lines": ["... elided by shared view state ..."]
        \\    }
        \\  ]
        \\}
    ;

    const output = try renderPayload(payload);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "+collapsed [elided]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "... elided by shared view state ...") != null);
}

test "viewer rejects malformed projection payloads" {
    const payload =
        \\{
        \\  "rows": 4,
        \\  "cols": 10,
        \\  "regions": [
        \\    {"nodeId": 1, "kind": "document", "title": "broken"}
        \\  ]
        \\}
    ;

    try std.testing.expectError(error.InvalidProjection, renderPayload(payload));
}

fn renderPayload(payload: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    errdefer output.deinit();
    try muxly.viewer_render.renderProjectionValue(std.testing.allocator, parsed.value, output.writer());
    return output.toOwnedSlice();
}
