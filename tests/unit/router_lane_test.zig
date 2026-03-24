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

    const island_remove_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":12,\"target\":{{\"documentPath\":\"/demo\",\"nodeId\":{d}}},\"method\":\"node.remove\",\"params\":{{}}}}",
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
