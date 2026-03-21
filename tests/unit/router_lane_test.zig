const std = @import("std");
const router = @import("daemon_router");

test "execution lane classification keeps document-local requests on document lanes" {
    var doc_get = try router.classifyExecutionLane(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"target":{"documentPath":"/demo"},"method":"document.get","params":{}}
    );
    defer doc_get.deinit(std.testing.allocator);
    switch (doc_get) {
        .document => |path| try std.testing.expectEqualStrings("/demo", path),
        .root => return error.ExpectedDocumentLane,
    }

    var file_attach = try router.classifyExecutionLane(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":2,"target":{"documentPath":"/demo"},"method":"leaf.source.attach","params":{"kind":"static-file","path":"README.md"}}
    );
    defer file_attach.deinit(std.testing.allocator);
    switch (file_attach) {
        .document => |path| try std.testing.expectEqualStrings("/demo", path),
        .root => return error.ExpectedDocumentLane,
    }
}

test "execution lane classification keeps tmux and root-only work on the root lane" {
    var session_create = try router.classifyExecutionLane(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":1,"target":{"documentPath":"/demo"},"method":"session.create","params":{"sessionName":"demo"}}
    );
    defer session_create.deinit(std.testing.allocator);
    switch (session_create) {
        .root => {},
        .document => return error.ExpectedRootLane,
    }

    var tty_attach = try router.classifyExecutionLane(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":2,"target":{"documentPath":"/demo"},"method":"leaf.source.attach","params":{"kind":"tty","sessionName":"demo"}}
    );
    defer tty_attach.deinit(std.testing.allocator);
    switch (tty_attach) {
        .root => {},
        .document => return error.ExpectedRootLane,
    }

    var root_doc = try router.classifyExecutionLane(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":3,"target":{"documentPath":"/"},"method":"document.get","params":{}}
    );
    defer root_doc.deinit(std.testing.allocator);
    switch (root_doc) {
        .root => {},
        .document => return error.ExpectedRootLane,
    }
}
