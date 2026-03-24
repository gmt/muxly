const std = @import("std");
const router = @import("daemon_router");

test "execution lane classification keeps document-local requests on document lanes" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_id = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island");
    const leaf_id = try store.appendNode("/demo", document, island_id, .text_leaf, "leaf");

    var doc_get = try router.classifyExecutionLane(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":1,"target":{"documentPath":"/demo"},"method":"document.get","params":{}}
    );
    defer doc_get.deinit(std.testing.allocator);
    switch (doc_get) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    var file_attach = try router.classifyExecutionLane(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":2,"target":{"documentPath":"/demo"},"method":"leaf.source.attach","params":{"kind":"static-file","path":"README.md"}}
    );
    defer file_attach.deinit(std.testing.allocator);
    switch (file_attach) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    var debug_sleep = try router.classifyExecutionLane(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":3,"target":{"documentPath":"/demo"},"method":"debug.sleep","params":{"ms":50}}
    );
    defer debug_sleep.deinit(std.testing.allocator);
    switch (debug_sleep) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    const targeted_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{leaf_id},
    );
    defer std.testing.allocator.free(targeted_request);
    var targeted_debug_sleep = try router.classifyExecutionLane(
        std.testing.allocator,
        &store,
        targeted_request,
    );
    defer targeted_debug_sleep.deinit(std.testing.allocator);
    switch (targeted_debug_sleep) {
        .document_domain => |domain| {
            try std.testing.expectEqualStrings("/demo", domain.document_path);
            try std.testing.expectEqual(island_id, domain.root_node_id);
        },
        .document_coordinator => return error.ExpectedDomainLane,
        .root => return error.ExpectedDocumentLane,
    }

    const content_update_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":5,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"updated\"}}}}",
        .{leaf_id},
    );
    defer std.testing.allocator.free(content_update_request);
    var content_update = try router.classifyExecutionLane(
        std.testing.allocator,
        &store,
        content_update_request,
    );
    defer content_update.deinit(std.testing.allocator);
    switch (content_update) {
        .document_domain => |domain| {
            try std.testing.expectEqualStrings("/demo", domain.document_path);
            try std.testing.expectEqual(island_id, domain.root_node_id);
        },
        .document_coordinator => return error.ExpectedDomainLane,
        .root => return error.ExpectedDocumentLane,
    }

    const title_update_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":6,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"title\":\"renamed\"}}}}",
        .{leaf_id},
    );
    defer std.testing.allocator.free(title_update_request);
    var title_update = try router.classifyExecutionLane(
        std.testing.allocator,
        &store,
        title_update_request,
    );
    defer title_update.deinit(std.testing.allocator);
    switch (title_update) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    const mixed_update_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":7,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"title\":\"renamed\",\"content\":\"updated\"}}}}",
        .{leaf_id},
    );
    defer std.testing.allocator.free(mixed_update_request);
    var mixed_update = try router.classifyExecutionLane(
        std.testing.allocator,
        &store,
        mixed_update_request,
    );
    defer mixed_update.deinit(std.testing.allocator);
    switch (mixed_update) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    var root_content_update = try router.classifyExecutionLane(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":8,"target":{"documentPath":"/demo","nodeId":1},"method":"node.update","params":{"content":"updated"}}
    );
    defer root_content_update.deinit(std.testing.allocator);
    switch (root_content_update) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    const island_append_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":9,\"target\":{{\"documentPath\":\"/demo\"}},\"method\":\"node.append\",\"params\":{{\"parentId\":{d},\"kind\":\"text_leaf\",\"title\":\"child\"}}}}",
        .{island_id},
    );
    defer std.testing.allocator.free(island_append_request);
    var island_append = try router.classifyExecutionLane(
        std.testing.allocator,
        &store,
        island_append_request,
    );
    defer island_append.deinit(std.testing.allocator);
    switch (island_append) {
        .document_domain => |domain| {
            try std.testing.expectEqualStrings("/demo", domain.document_path);
            try std.testing.expectEqual(island_id, domain.root_node_id);
        },
        .document_coordinator => return error.ExpectedDomainLane,
        .root => return error.ExpectedDocumentLane,
    }

    var root_append = try router.classifyExecutionLane(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":10,"target":{"documentPath":"/demo"},"method":"node.append","params":{"parentId":1,"kind":"text_leaf","title":"root-child"}}
    );
    defer root_append.deinit(std.testing.allocator);
    switch (root_append) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    var root_remove = try router.classifyExecutionLane(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":10,"target":{"documentPath":"/demo","nodeId":1},"method":"node.remove","params":{}}
    );
    defer root_remove.deinit(std.testing.allocator);
    switch (root_remove) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    const leaf_remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":11,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
        .{leaf_id},
    );
    defer std.testing.allocator.free(leaf_remove_request);
    var leaf_remove = try router.classifyExecutionLane(
        std.testing.allocator,
        &store,
        leaf_remove_request,
    );
    defer leaf_remove.deinit(std.testing.allocator);
    switch (leaf_remove) {
        .document_domain => |domain| {
            try std.testing.expectEqualStrings("/demo", domain.document_path);
            try std.testing.expectEqual(island_id, domain.root_node_id);
        },
        .document_coordinator => return error.ExpectedDomainLane,
        .root => return error.ExpectedDocumentLane,
    }

    const subtree_parent = try store.appendNode("/demo", document, island_id, .container, "subtree-parent");
    const subtree_leaf = try store.appendNode("/demo", document, subtree_parent, .text_leaf, "subtree-leaf");
    _ = subtree_leaf;
    const subtree_remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":12,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
        .{subtree_parent},
    );
    defer std.testing.allocator.free(subtree_remove_request);
    var subtree_remove = try router.classifyExecutionLane(
        std.testing.allocator,
        &store,
        subtree_remove_request,
    );
    defer subtree_remove.deinit(std.testing.allocator);
    switch (subtree_remove) {
        .document_domain => |domain| {
            try std.testing.expectEqualStrings("/demo", domain.document_path);
            try std.testing.expectEqual(island_id, domain.root_node_id);
        },
        .document_coordinator => return error.ExpectedDomainLane,
        .root => return error.ExpectedDocumentLane,
    }

    const coordinator_parent = try store.appendNode("/demo", document, island_id, .container, "coordinator-parent");
    const nested_h = try store.appendNode("/demo", document, coordinator_parent, .h_container, "nested-h");
    const nested_child = try store.appendNode("/demo", document, nested_h, .scroll_region, "nested-child");
    _ = try store.appendNode("/demo", document, nested_child, .text_leaf, "nested-leaf");
    const coordinator_remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":13,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
        .{coordinator_parent},
    );
    defer std.testing.allocator.free(coordinator_remove_request);
    var coordinator_remove = try router.classifyExecutionLane(
        std.testing.allocator,
        &store,
        coordinator_remove_request,
    );
    defer coordinator_remove.deinit(std.testing.allocator);
    switch (coordinator_remove) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    const island_remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":14,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
        .{island_id},
    );
    defer std.testing.allocator.free(island_remove_request);
    var island_remove = try router.classifyExecutionLane(
        std.testing.allocator,
        &store,
        island_remove_request,
    );
    defer island_remove.deinit(std.testing.allocator);
    switch (island_remove) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }
}

test "horizontal and vertical split descendants classify below the first-layer island" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_id = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island");
    const h_id = try store.appendNode("/demo", document, island_id, .h_container, "h");
    const left_id = try store.appendNode("/demo", document, h_id, .scroll_region, "left");
    const right_id = try store.appendNode("/demo", document, h_id, .scroll_region, "right");
    const left_leaf = try store.appendNode("/demo", document, left_id, .text_leaf, "left-leaf");
    _ = try store.appendNode("/demo", document, right_id, .text_leaf, "right-leaf");

    const v_id = try store.appendNode("/demo", document, island_id, .v_container, "v");
    const top_id = try store.appendNode("/demo", document, v_id, .scroll_region, "top");
    const top_leaf = try store.appendNode("/demo", document, top_id, .text_leaf, "top-leaf");

    const left_update_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"updated\"}}}}",
        .{left_leaf},
    );
    defer std.testing.allocator.free(left_update_request);
    var left_update = try router.classifyExecutionLane(std.testing.allocator, &store, left_update_request);
    defer left_update.deinit(std.testing.allocator);
    switch (left_update) {
        .document_domain => |domain| {
            try std.testing.expectEqualStrings("/demo", domain.document_path);
            try std.testing.expectEqual(left_id, domain.root_node_id);
        },
        .document_coordinator => return error.ExpectedDomainLane,
        .root => return error.ExpectedDocumentLane,
    }

    const right_append_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\"}},\"method\":\"node.append\",\"params\":{{\"parentId\":{d},\"kind\":\"text_leaf\",\"title\":\"child\"}}}}",
        .{right_id},
    );
    defer std.testing.allocator.free(right_append_request);
    var right_append = try router.classifyExecutionLane(std.testing.allocator, &store, right_append_request);
    defer right_append.deinit(std.testing.allocator);
    switch (right_append) {
        .document_domain => |domain| {
            try std.testing.expectEqualStrings("/demo", domain.document_path);
            try std.testing.expectEqual(right_id, domain.root_node_id);
        },
        .document_coordinator => return error.ExpectedDomainLane,
        .root => return error.ExpectedDocumentLane,
    }

    const top_update_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"updated\"}}}}",
        .{top_leaf},
    );
    defer std.testing.allocator.free(top_update_request);
    var top_update = try router.classifyExecutionLane(std.testing.allocator, &store, top_update_request);
    defer top_update.deinit(std.testing.allocator);
    switch (top_update) {
        .document_domain => |domain| {
            try std.testing.expectEqualStrings("/demo", domain.document_path);
            try std.testing.expectEqual(top_id, domain.root_node_id);
        },
        .document_coordinator => return error.ExpectedDomainLane,
        .root => return error.ExpectedDocumentLane,
    }

    const direct_h_append_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"target\":{{\"documentPath\":\"/demo\"}},\"method\":\"node.append\",\"params\":{{\"parentId\":{d},\"kind\":\"text_leaf\",\"title\":\"child\"}}}}",
        .{h_id},
    );
    defer std.testing.allocator.free(direct_h_append_request);
    var direct_h_append = try router.classifyExecutionLane(std.testing.allocator, &store, direct_h_append_request);
    defer direct_h_append.deinit(std.testing.allocator);
    switch (direct_h_append) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    const direct_h_remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":5,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
        .{left_id},
    );
    defer std.testing.allocator.free(direct_h_remove_request);
    var direct_h_remove = try router.classifyExecutionLane(std.testing.allocator, &store, direct_h_remove_request);
    defer direct_h_remove.deinit(std.testing.allocator);
    switch (direct_h_remove) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    const direct_v_append_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":6,\"target\":{{\"documentPath\":\"/demo\"}},\"method\":\"node.append\",\"params\":{{\"parentId\":{d},\"kind\":\"text_leaf\",\"title\":\"child\"}}}}",
        .{v_id},
    );
    defer std.testing.allocator.free(direct_v_append_request);
    var direct_v_append = try router.classifyExecutionLane(std.testing.allocator, &store, direct_v_append_request);
    defer direct_v_append.deinit(std.testing.allocator);
    switch (direct_v_append) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }

    const direct_v_remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":7,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
        .{top_id},
    );
    defer std.testing.allocator.free(direct_v_remove_request);
    var direct_v_remove = try router.classifyExecutionLane(std.testing.allocator, &store, direct_v_remove_request);
    defer direct_v_remove.deinit(std.testing.allocator);
    switch (direct_v_remove) {
        .document_coordinator => |path| try std.testing.expectEqualStrings("/demo", path),
        .document_domain => return error.ExpectedCoordinatorLane,
        .root => return error.ExpectedDocumentLane,
    }
}

test "request guards keep same-island content-only node.update behind an active domain writer" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_id = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island");
    const first_leaf_id = try store.appendNode("/demo", document, island_id, .text_leaf, "first");
    const second_leaf_id = try store.appendNode("/demo", document, island_id, .text_leaf, "second");

    const slow_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{first_leaf_id},
    );
    defer std.testing.allocator.free(slow_request);

    const fast_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"updated\"}}}}",
        .{second_leaf_id},
    );
    defer std.testing.allocator.free(fast_request);

    var slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_request);
    errdefer slow_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};
    var thread_context = ThreadContext{
        .store = &store,
        .request = fast_request,
        .acquired = &acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };

    const worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&thread_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!acquired.load(.acquire));

    slow_guard.release();
    worker.join();

    if (failure) |err| return err;
    try std.testing.expect(acquired.load(.acquire));
}

test "request guards keep title and mixed node.update on the coordinator path" {
    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_a = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "a");
    const island_b = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "b");
    const leaf_a = try store.appendNode("/demo", document, island_a, .text_leaf, "leaf-a");
    const leaf_b = try store.appendNode("/demo", document, island_b, .text_leaf, "leaf-b");

    const slow_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{leaf_a},
    );
    defer std.testing.allocator.free(slow_request);
    const title_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"title\":\"renamed\"}}}}",
        .{leaf_b},
    );
    defer std.testing.allocator.free(title_request);
    var slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_request);
    errdefer slow_guard.release();

    var title_acquired = std.atomic.Value(bool).init(false);
    var title_failure: ?anyerror = null;
    var title_failure_mutex = std.Thread.Mutex{};
    var title_context = ThreadContext{
        .store = &store,
        .request = title_request,
        .acquired = &title_acquired,
        .mutex = &title_failure_mutex,
        .failure = &title_failure,
    };
    const title_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&title_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!title_acquired.load(.acquire));
    slow_guard.release();
    title_worker.join();
    if (title_failure) |err| return err;
    try std.testing.expect(title_acquired.load(.acquire));

    const mixed_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"title\":\"renamed\",\"content\":\"updated\"}}}}",
        .{leaf_b},
    );
    defer std.testing.allocator.free(mixed_request);
    slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_request);
    errdefer slow_guard.release();

    var mixed_acquired = std.atomic.Value(bool).init(false);
    var mixed_failure: ?anyerror = null;
    var mixed_failure_mutex = std.Thread.Mutex{};
    var mixed_context = ThreadContext{
        .store = &store,
        .request = mixed_request,
        .acquired = &mixed_acquired,
        .mutex = &mixed_failure_mutex,
        .failure = &mixed_failure,
    };
    const mixed_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&mixed_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!mixed_acquired.load(.acquire));
    slow_guard.release();
    mixed_worker.join();
    if (mixed_failure) |err| return err;
    try std.testing.expect(mixed_acquired.load(.acquire));
}

test "request guards keep same-island structural requests behind an active domain writer" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_id = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island");
    const parent_id = try store.appendNode("/demo", document, island_id, .container, "parent");
    const leaf_id = try store.appendNode("/demo", document, parent_id, .text_leaf, "leaf");

    const slow_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{leaf_id},
    );
    defer std.testing.allocator.free(slow_request);
    const append_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\"}},\"method\":\"node.append\",\"params\":{{\"parentId\":{d},\"kind\":\"text_leaf\",\"title\":\"child\"}}}}",
        .{parent_id},
    );
    defer std.testing.allocator.free(append_request);

    var slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_request);
    errdefer slow_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};
    var context = ThreadContext{
        .store = &store,
        .request = append_request,
        .acquired = &acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };

    const worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!acquired.load(.acquire));

    slow_guard.release();
    worker.join();
    if (failure) |err| return err;
    try std.testing.expect(acquired.load(.acquire));
}

test "request guards keep same-island subtree remove behind an active domain writer" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_id = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island");
    const parent_id = try store.appendNode("/demo", document, island_id, .container, "parent");
    const nested_id = try store.appendNode("/demo", document, parent_id, .container, "nested");
    const leaf_id = try store.appendNode("/demo", document, nested_id, .text_leaf, "leaf");

    const slow_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{leaf_id},
    );
    defer std.testing.allocator.free(slow_request);
    const remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
        .{parent_id},
    );
    defer std.testing.allocator.free(remove_request);

    var slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_request);
    errdefer slow_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};
    var context = ThreadContext{
        .store = &store,
        .request = remove_request,
        .acquired = &acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };

    const worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!acquired.load(.acquire));

    slow_guard.release();
    worker.join();
    if (failure) |err| return err;
    try std.testing.expect(acquired.load(.acquire));
}

test "request guards keep root parent churn on the coordinator path" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_id = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island");
    const leaf_id = try store.appendNode("/demo", document, island_id, .text_leaf, "leaf");

    const slow_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{leaf_id},
    );
    defer std.testing.allocator.free(slow_request);
    const root_append_request =
        \\{"jsonrpc":"2.0","id":2,"target":{"documentPath":"/demo"},"method":"node.append","params":{"parentId":1,"kind":"text_leaf","title":"root-child"}}
    ;

    var slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_request);
    errdefer slow_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};
    var context = ThreadContext{
        .store = &store,
        .request = root_append_request,
        .acquired = &acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };

    const worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!acquired.load(.acquire));

    slow_guard.release();
    worker.join();
    if (failure) |err| return err;
    try std.testing.expect(acquired.load(.acquire));
}

test "request guards keep current-domain-root subtree remove on the coordinator path" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_a = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-a");
    const island_b = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-b");
    const leaf_b = try store.appendNode("/demo", document, island_b, .text_leaf, "leaf-b");

    const h_id = try store.appendNode("/demo", document, island_a, .h_container, "h");
    const left_id = try store.appendNode("/demo", document, h_id, .scroll_region, "left");
    const nested_id = try store.appendNode("/demo", document, left_id, .container, "nested");
    _ = try store.appendNode("/demo", document, nested_id, .text_leaf, "leaf");

    const slow_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"title\":\"renamed\"}}}}",
        .{leaf_b},
    );
    defer std.testing.allocator.free(slow_request);
    const remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
        .{left_id},
    );
    defer std.testing.allocator.free(remove_request);

    var slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_request);
    errdefer slow_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};
    var context = ThreadContext{
        .store = &store,
        .request = remove_request,
        .acquired = &acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };

    const worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!acquired.load(.acquire));

    slow_guard.release();
    worker.join();
    if (failure) |err| return err;
    try std.testing.expect(acquired.load(.acquire));
}

test "request guards keep first-layer island-root subtree remove on the coordinator path" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_a = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-a");
    const island_b = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-b");
    _ = try store.appendNode("/demo", document, island_a, .container, "nested");
    const leaf_b = try store.appendNode("/demo", document, island_b, .text_leaf, "leaf-b");

    const slow_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"title\":\"renamed\"}}}}",
        .{leaf_b},
    );
    defer std.testing.allocator.free(slow_request);
    const remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
        .{island_a},
    );
    defer std.testing.allocator.free(remove_request);

    var slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_request);
    errdefer slow_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};
    var context = ThreadContext{
        .store = &store,
        .request = remove_request,
        .acquired = &acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };

    const worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!acquired.load(.acquire));

    slow_guard.release();
    worker.join();
    if (failure) |err| return err;
    try std.testing.expect(acquired.load(.acquire));
}

test "request guards keep document-root remove on the coordinator path" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_a = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-a");
    const island_b = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-b");
    _ = try store.appendNode("/demo", document, island_a, .container, "nested");
    const leaf_b = try store.appendNode("/demo", document, island_b, .text_leaf, "leaf-b");

    const slow_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"title\":\"renamed\"}}}}",
        .{leaf_b},
    );
    defer std.testing.allocator.free(slow_request);
    const remove_request =
        \\{"jsonrpc":"2.0","id":2,"target":{"documentPath":"/demo","nodeId":1},"method":"node.remove","params":{}}
    ;

    var slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_request);
    errdefer slow_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};
    var context = ThreadContext{
        .store = &store,
        .request = remove_request,
        .acquired = &acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };

    const worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!acquired.load(.acquire));

    slow_guard.release();
    worker.join();
    if (failure) |err| return err;
    try std.testing.expect(acquired.load(.acquire));
}

test "multi-domain recursive remove guards still allow unrelated island progress" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_a = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-a");
    const subtree = try store.appendNode("/demo", document, island_a, .container, "subtree");
    const nested_h = try store.appendNode("/demo", document, subtree, .h_container, "nested-h");
    const left_id = try store.appendNode("/demo", document, nested_h, .scroll_region, "left");
    const right_id = try store.appendNode("/demo", document, nested_h, .scroll_region, "right");
    _ = try store.appendNode("/demo", document, left_id, .text_leaf, "left-leaf");
    _ = try store.appendNode("/demo", document, right_id, .text_leaf, "right-leaf");

    const island_b = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-b");
    const unrelated_leaf = try store.appendNode("/demo", document, island_b, .text_leaf, "leaf-b");

    const remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.node.remove\",\"params\":{{\"pauseMs\":50}}}}",
        .{subtree},
    );
    defer std.testing.allocator.free(remove_request);
    const unrelated_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"updated\"}}}}",
        .{unrelated_leaf},
    );
    defer std.testing.allocator.free(unrelated_request);

    var remove_guard = try store.acquireRequestGuard(std.testing.allocator, remove_request);
    errdefer remove_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};
    var context = ThreadContext{
        .store = &store,
        .request = unrelated_request,
        .acquired = &acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };

    const worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(acquired.load(.acquire));

    remove_guard.release();
    worker.join();

    if (failure) |err| return err;
}

test "multi-domain recursive remove guards block participating domains" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_a = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-a");
    const subtree = try store.appendNode("/demo", document, island_a, .container, "subtree");
    const nested_h = try store.appendNode("/demo", document, subtree, .h_container, "nested-h");
    const left_id = try store.appendNode("/demo", document, nested_h, .scroll_region, "left");
    const right_id = try store.appendNode("/demo", document, nested_h, .scroll_region, "right");
    _ = try store.appendNode("/demo", document, left_id, .text_leaf, "left-leaf");
    const right_leaf = try store.appendNode("/demo", document, right_id, .text_leaf, "right-leaf");

    const remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.node.remove\",\"params\":{{\"pauseMs\":50}}}}",
        .{subtree},
    );
    defer std.testing.allocator.free(remove_request);
    const participating_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":5}}}}",
        .{right_leaf},
    );
    defer std.testing.allocator.free(participating_request);

    var remove_guard = try store.acquireRequestGuard(std.testing.allocator, remove_request);
    errdefer remove_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};
    var context = ThreadContext{
        .store = &store,
        .request = participating_request,
        .acquired = &acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };

    const worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!acquired.load(.acquire));

    remove_guard.release();
    worker.join();
    if (failure) |err| return err;
    try std.testing.expect(acquired.load(.acquire));
}

test "blocked same-domain content request does not hold coordinator over unrelated island work" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_a = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-a");
    const island_b = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-b");
    const leaf_a = try store.appendNode("/demo", document, island_a, .text_leaf, "leaf-a");
    const leaf_b = try store.appendNode("/demo", document, island_b, .text_leaf, "leaf-b");

    const held_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{leaf_a},
    );
    defer std.testing.allocator.free(held_request);
    const blocked_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"blocked\"}}}}",
        .{leaf_a},
    );
    defer std.testing.allocator.free(blocked_request);
    const unrelated_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"unrelated\"}}}}",
        .{leaf_b},
    );
    defer std.testing.allocator.free(unrelated_request);

    var held_guard = try store.acquireRequestGuard(std.testing.allocator, held_request);
    errdefer held_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var blocked_acquired = std.atomic.Value(bool).init(false);
    var unrelated_acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};

    var blocked_context = ThreadContext{
        .store = &store,
        .request = blocked_request,
        .acquired = &blocked_acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };
    const blocked_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&blocked_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!blocked_acquired.load(.acquire));

    var unrelated_context = ThreadContext{
        .store = &store,
        .request = unrelated_request,
        .acquired = &unrelated_acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };
    const unrelated_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&unrelated_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(unrelated_acquired.load(.acquire));

    held_guard.release();
    blocked_worker.join();
    unrelated_worker.join();
    if (failure) |err| return err;
    try std.testing.expect(blocked_acquired.load(.acquire));
}

test "blocked same-parent structural request does not hold coordinator over unrelated structural work" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_a = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-a");
    const island_b = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-b");
    const parent_a = try store.appendNode("/demo", document, island_a, .container, "parent-a");
    const parent_b = try store.appendNode("/demo", document, island_b, .container, "parent-b");

    const held_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\"}},\"method\":\"debug.node.append\",\"params\":{{\"parentId\":{d},\"kind\":\"text_leaf\",\"title\":\"held\",\"pauseMs\":50}}}}",
        .{parent_a},
    );
    defer std.testing.allocator.free(held_request);
    const blocked_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\"}},\"method\":\"debug.node.append\",\"params\":{{\"parentId\":{d},\"kind\":\"text_leaf\",\"title\":\"blocked\",\"pauseMs\":0}}}}",
        .{parent_a},
    );
    defer std.testing.allocator.free(blocked_request);
    const unrelated_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"target\":{{\"documentPath\":\"/demo\"}},\"method\":\"debug.node.append\",\"params\":{{\"parentId\":{d},\"kind\":\"text_leaf\",\"title\":\"unrelated\",\"pauseMs\":0}}}}",
        .{parent_b},
    );
    defer std.testing.allocator.free(unrelated_request);

    var held_guard = try store.acquireRequestGuard(std.testing.allocator, held_request);
    errdefer held_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var blocked_acquired = std.atomic.Value(bool).init(false);
    var unrelated_acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};

    var blocked_context = ThreadContext{
        .store = &store,
        .request = blocked_request,
        .acquired = &blocked_acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };
    const blocked_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&blocked_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!blocked_acquired.load(.acquire));

    var unrelated_context = ThreadContext{
        .store = &store,
        .request = unrelated_request,
        .acquired = &unrelated_acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };
    const unrelated_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&unrelated_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(unrelated_acquired.load(.acquire));

    held_guard.release();
    blocked_worker.join();
    unrelated_worker.join();
    if (failure) |err| return err;
    try std.testing.expect(blocked_acquired.load(.acquire));
}

test "blocked participating-domain delete request does not hold coordinator over unrelated island work" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_a = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-a");
    const subtree = try store.appendNode("/demo", document, island_a, .container, "subtree");
    const nested_h = try store.appendNode("/demo", document, subtree, .h_container, "nested-h");
    const left_id = try store.appendNode("/demo", document, nested_h, .scroll_region, "left");
    const right_id = try store.appendNode("/demo", document, nested_h, .scroll_region, "right");
    _ = try store.appendNode("/demo", document, left_id, .text_leaf, "left-leaf");
    const right_leaf = try store.appendNode("/demo", document, right_id, .text_leaf, "right-leaf");

    const island_b = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island-b");
    const unrelated_leaf = try store.appendNode("/demo", document, island_b, .text_leaf, "leaf-b");

    const held_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{right_leaf},
    );
    defer std.testing.allocator.free(held_request);
    const blocked_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.node.remove\",\"params\":{{\"pauseMs\":50}}}}",
        .{subtree},
    );
    defer std.testing.allocator.free(blocked_request);
    const unrelated_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"unrelated\"}}}}",
        .{unrelated_leaf},
    );
    defer std.testing.allocator.free(unrelated_request);

    var held_guard = try store.acquireRequestGuard(std.testing.allocator, held_request);
    errdefer held_guard.release();

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var blocked_acquired = std.atomic.Value(bool).init(false);
    var unrelated_acquired = std.atomic.Value(bool).init(false);
    var failure: ?anyerror = null;
    var failure_mutex = std.Thread.Mutex{};

    var blocked_context = ThreadContext{
        .store = &store,
        .request = blocked_request,
        .acquired = &blocked_acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };
    const blocked_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&blocked_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!blocked_acquired.load(.acquire));

    var unrelated_context = ThreadContext{
        .store = &store,
        .request = unrelated_request,
        .acquired = &unrelated_acquired,
        .mutex = &failure_mutex,
        .failure = &failure,
    };
    const unrelated_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&unrelated_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(unrelated_acquired.load(.acquire));

    held_guard.release();
    blocked_worker.join();
    unrelated_worker.join();
    if (failure) |err| return err;
    try std.testing.expect(blocked_acquired.load(.acquire));
}

test "request guards let horizontal and vertical split siblings acquire separate domains while same-child work stays serialized" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    const document = try store.createDocument("/demo", null);
    const island_id = try store.appendNode("/demo", document, document.root_node_id, .subdocument, "island");
    const h_id = try store.appendNode("/demo", document, island_id, .h_container, "h");
    const left_id = try store.appendNode("/demo", document, h_id, .scroll_region, "left");
    const right_id = try store.appendNode("/demo", document, h_id, .scroll_region, "right");
    const left_leaf = try store.appendNode("/demo", document, left_id, .text_leaf, "left-leaf");
    const right_leaf = try store.appendNode("/demo", document, right_id, .text_leaf, "right-leaf");

    const v_id = try store.appendNode("/demo", document, island_id, .v_container, "v");
    const top_id = try store.appendNode("/demo", document, v_id, .scroll_region, "top");
    const bottom_id = try store.appendNode("/demo", document, v_id, .scroll_region, "bottom");
    const top_leaf = try store.appendNode("/demo", document, top_id, .text_leaf, "top-leaf");
    const bottom_leaf = try store.appendNode("/demo", document, bottom_id, .text_leaf, "bottom-leaf");

    const slow_horizontal_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":1,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{left_leaf},
    );
    defer std.testing.allocator.free(slow_horizontal_request);
    const fast_horizontal_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":2,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"updated\"}}}}",
        .{right_leaf},
    );
    defer std.testing.allocator.free(fast_horizontal_request);

    const ThreadContext = struct {
        store: *router.Store,
        request: []const u8,
        acquired: *std.atomic.Value(bool),
        mutex: *std.Thread.Mutex,
        failure: *?anyerror,

        fn run(context: *@This()) void {
            var guard = context.store.acquireRequestGuard(std.heap.page_allocator, context.request) catch |err| {
                context.mutex.lock();
                context.failure.* = err;
                context.mutex.unlock();
                return;
            };
            defer guard.release();
            context.acquired.store(true, .release);
        }
    };

    var slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_horizontal_request);
    errdefer slow_guard.release();

    var horizontal_acquired = std.atomic.Value(bool).init(false);
    var horizontal_failure: ?anyerror = null;
    var horizontal_failure_mutex = std.Thread.Mutex{};
    var horizontal_context = ThreadContext{
        .store = &store,
        .request = fast_horizontal_request,
        .acquired = &horizontal_acquired,
        .mutex = &horizontal_failure_mutex,
        .failure = &horizontal_failure,
    };

    const horizontal_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&horizontal_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(horizontal_acquired.load(.acquire));
    slow_guard.release();
    horizontal_worker.join();
    if (horizontal_failure) |err| return err;

    const slow_same_horizontal_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":5,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{left_leaf},
    );
    defer std.testing.allocator.free(slow_same_horizontal_request);
    const fast_same_horizontal_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":6,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"updated\"}}}}",
        .{left_leaf},
    );
    defer std.testing.allocator.free(fast_same_horizontal_request);

    slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_same_horizontal_request);
    errdefer slow_guard.release();

    var same_horizontal_acquired = std.atomic.Value(bool).init(false);
    var same_horizontal_failure: ?anyerror = null;
    var same_horizontal_failure_mutex = std.Thread.Mutex{};
    var same_horizontal_context = ThreadContext{
        .store = &store,
        .request = fast_same_horizontal_request,
        .acquired = &same_horizontal_acquired,
        .mutex = &same_horizontal_failure_mutex,
        .failure = &same_horizontal_failure,
    };

    const same_horizontal_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&same_horizontal_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!same_horizontal_acquired.load(.acquire));
    slow_guard.release();
    same_horizontal_worker.join();
    if (same_horizontal_failure) |err| return err;
    try std.testing.expect(same_horizontal_acquired.load(.acquire));

    const slow_vertical_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":3,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{top_leaf},
    );
    defer std.testing.allocator.free(slow_vertical_request);
    const fast_vertical_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":4,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"updated\"}}}}",
        .{bottom_leaf},
    );
    defer std.testing.allocator.free(fast_vertical_request);

    slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_vertical_request);
    errdefer slow_guard.release();

    var vertical_acquired = std.atomic.Value(bool).init(false);
    var vertical_failure: ?anyerror = null;
    var vertical_failure_mutex = std.Thread.Mutex{};
    var vertical_context = ThreadContext{
        .store = &store,
        .request = fast_vertical_request,
        .acquired = &vertical_acquired,
        .mutex = &vertical_failure_mutex,
        .failure = &vertical_failure,
    };

    const vertical_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&vertical_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(vertical_acquired.load(.acquire));
    slow_guard.release();
    vertical_worker.join();
    if (vertical_failure) |err| return err;

    const slow_same_vertical_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":7,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"debug.sleep\",\"params\":{{\"ms\":50}}}}",
        .{top_leaf},
    );
    defer std.testing.allocator.free(slow_same_vertical_request);
    const fast_same_vertical_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":8,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.update\",\"params\":{{\"content\":\"updated\"}}}}",
        .{top_leaf},
    );
    defer std.testing.allocator.free(fast_same_vertical_request);

    slow_guard = try store.acquireRequestGuard(std.testing.allocator, slow_same_vertical_request);
    errdefer slow_guard.release();

    var same_vertical_acquired = std.atomic.Value(bool).init(false);
    var same_vertical_failure: ?anyerror = null;
    var same_vertical_failure_mutex = std.Thread.Mutex{};
    var same_vertical_context = ThreadContext{
        .store = &store,
        .request = fast_same_vertical_request,
        .acquired = &same_vertical_acquired,
        .mutex = &same_vertical_failure_mutex,
        .failure = &same_vertical_failure,
    };

    const same_vertical_worker = try std.Thread.spawn(.{}, ThreadContext.run, .{&same_vertical_context});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!same_vertical_acquired.load(.acquire));
    slow_guard.release();
    same_vertical_worker.join();
    if (same_vertical_failure) |err| return err;
    try std.testing.expect(same_vertical_acquired.load(.acquire));
}

test "execution lane classification keeps tmux and root-only work on the root lane" {
    var store = try router.Store.init(std.testing.allocator);
    defer store.deinit();

    var session_create = try router.classifyExecutionLane(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":1,"target":{"documentPath":"/demo"},"method":"session.create","params":{"sessionName":"demo"}}
    );
    defer session_create.deinit(std.testing.allocator);
    switch (session_create) {
        .root => {},
        .document_coordinator, .document_domain => return error.ExpectedRootLane,
    }

    var tty_attach = try router.classifyExecutionLane(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":2,"target":{"documentPath":"/demo"},"method":"leaf.source.attach","params":{"kind":"tty","sessionName":"demo"}}
    );
    defer tty_attach.deinit(std.testing.allocator);
    switch (tty_attach) {
        .root => {},
        .document_coordinator, .document_domain => return error.ExpectedRootLane,
    }

    var root_doc = try router.classifyExecutionLane(std.testing.allocator, &store,
        \\{"jsonrpc":"2.0","id":3,"target":{"documentPath":"/"},"method":"document.get","params":{}}
    );
    defer root_doc.deinit(std.testing.allocator);
    switch (root_doc) {
        .root => {},
        .document_coordinator, .document_domain => return error.ExpectedRootLane,
    }
}
