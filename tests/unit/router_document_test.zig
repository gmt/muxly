const std = @import("std");
const router = @import("daemon_router");

fn call(
    allocator: std.mem.Allocator,
    store: *router.Store,
    payload: []const u8,
) !std.json.Parsed(std.json.Value) {
    const response = try router.handleRequest(allocator, store, payload);
    defer allocator.free(response);
    return try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
}

fn resultValue(parsed: std.json.Parsed(std.json.Value)) !std.json.Value {
    if (parsed.value != .object) return error.InvalidJson;
    return parsed.value.object.get("result") orelse return error.MissingResult;
}

fn resultObject(parsed: std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    const result = try resultValue(parsed);
    if (result != .object) return error.InvalidJson;
    return result.object;
}

fn errorObject(parsed: std.json.Parsed(std.json.Value)) !std.json.ObjectMap {
    if (parsed.value != .object) return error.InvalidJson;
    const result = parsed.value.object.get("error") orelse return error.MissingError;
    if (result != .object) return error.InvalidJson;
    return result.object;
}

test "document lifecycle methods create and list registered documents" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    var created = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":1,"method":"document.create","params":{"path":"/docs/demo"}}
    );
    defer created.deinit();

    const created_result = try resultObject(created);
    try std.testing.expectEqualStrings("/docs/demo", created_result.get("path").?.string);
    try std.testing.expectEqualStrings("demo", created_result.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 1), created_result.get("rootNodeId").?.integer);
    try std.testing.expectEqual(@as(i64, 1), created_result.get("nodeCount").?.integer);

    var listed = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":2,"method":"document.list","params":{}}
    );
    defer listed.deinit();

    const list_result = try resultValue(listed);
    try std.testing.expect(list_result == .array);
    try std.testing.expectEqual(@as(usize, 2), list_result.array.items.len);
    try std.testing.expectEqualStrings("/", list_result.array.items[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("/docs/demo", list_result.array.items[1].object.get("path").?.string);
}

test "document lifecycle rejects duplicate and non-canonical paths" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    var created = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":1,"method":"document.create","params":{"path":"/docs/demo"}}
    );
    created.deinit();

    var duplicate = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":2,"method":"document.create","params":{"path":"/docs/demo"}}
    );
    defer duplicate.deinit();
    const duplicate_err = try errorObject(duplicate);
    try std.testing.expectEqual(@as(i64, -32602), duplicate_err.get("code").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_err.get("message").?.string, "already exists") != null);

    const invalid_paths = [_][]const u8{
        "/",
        "/docs/demo/",
        "/docs//demo",
        "/docs/./demo",
        "/docs/../demo",
    };

    for (invalid_paths, 3..) |path, id| {
        const payload = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"document.create\",\"params\":{{\"path\":{f}}}}}",
            .{ id, std.json.fmt(path, .{}) },
        );
        defer std.testing.allocator.free(payload);

        var invalid = try call(std.testing.allocator, &store, payload);
        defer invalid.deinit();
        const err = try errorObject(invalid);
        try std.testing.expectEqual(@as(i64, -32602), err.get("code").?.integer);
    }
}

test "document-targeted node and view mutations stay scoped" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    var created = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":1,"method":"document.create","params":{"path":"/demo","title":"Demo Doc"}}
    );
    created.deinit();

    var appended = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":2,"target":{"documentPath":"/demo"},"method":"node.append","params":{"parentId":1,"kind":"scroll_region","title":"alpha"}}
    );
    defer appended.deinit();
    const append_result = try resultObject(appended);
    try std.testing.expectEqual(@as(i64, 2), append_result.get("nodeId").?.integer);

    var set_root = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":3,"target":{"documentPath":"/demo"},"method":"view.setRoot","params":{"nodeId":2}}
    );
    set_root.deinit();

    var demo_doc = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":4,"target":{"documentPath":"/demo"},"method":"document.get","params":{}}
    );
    defer demo_doc.deinit();

    const demo = try resultObject(demo_doc);
    try std.testing.expectEqual(@as(i64, 2), demo.get("viewRootNodeId").?.integer);
    const demo_nodes = demo.get("nodes").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), demo_nodes.len);
    try std.testing.expectEqualStrings("alpha", demo_nodes[1].object.get("title").?.string);

    var root_doc = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":5,"target":{"documentPath":"/"},"method":"document.get","params":{}}
    );
    defer root_doc.deinit();

    const root = try resultObject(root_doc);
    try std.testing.expect((root.get("viewRootNodeId").?) == .null);
    const root_nodes = root.get("nodes").?.array.items;
    try std.testing.expect(root_nodes.len >= 2);
    for (root_nodes) |node| {
        try std.testing.expect(!std.mem.eql(u8, node.object.get("title").?.string, "alpha"));
    }
}

test "tmux methods reject non-root document targets until projections are generalized" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    var created = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":1,"method":"document.create","params":{"path":"/demo"}}
    );
    created.deinit();

    var rejected = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":2,"target":{"documentPath":"/demo"},"method":"session.create","params":{"sessionName":"demo"}}
    );
    defer rejected.deinit();

    const err = try errorObject(rejected);
    try std.testing.expectEqual(@as(i64, -32001), err.get("code").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, err.get("message").?.string, "root document target /") != null);
}

test "document-targeted methods reject non-canonical target paths" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    var invalid = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":1,"target":{"documentPath":"/demo/"},"method":"document.get","params":{}}
    );
    defer invalid.deinit();

    const err = try errorObject(invalid);
    try std.testing.expectEqual(@as(i64, -32602), err.get("code").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, err.get("message").?.string, "canonical absolute path") != null);
}

test "node-targeted methods accept target.nodeId and resolve target.selector server-side" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    var appended = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":1,"method":"node.append","params":{"parentId":1,"kind":"scroll_region","title":"alpha"}}
    );
    defer appended.deinit();
    const append_result = try resultObject(appended);
    const node_id = append_result.get("nodeId").?.integer;

    const via_target_payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/\",\"nodeId\":{d}}},\"method\":\"node.get\",\"params\":{{}}}}",
        .{node_id},
    );
    defer std.testing.allocator.free(via_target_payload);
    var via_target = try call(
        std.testing.allocator,
        &store,
        via_target_payload,
    );
    defer via_target.deinit();
    const target_result = try resultObject(via_target);
    try std.testing.expectEqualStrings("alpha", target_result.get("title").?.string);

    var selector_target = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":3,"target":{"documentPath":"/","selector":"alpha"},"method":"node.get","params":{}}
    );
    defer selector_target.deinit();
    const selector_result = try resultObject(selector_target);
    try std.testing.expectEqualStrings("alpha", selector_result.get("title").?.string);

    var selector_miss = try call(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":4,"target":{"documentPath":"/","selector":"does-not-exist"},"method":"node.get","params":{}}
    );
    defer selector_miss.deinit();
    const err = try errorObject(selector_miss);
    try std.testing.expectEqual(@as(i64, -32602), err.get("code").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, err.get("message").?.string, "does not match any node") != null);
}
