const std = @import("std");
const muxly = @import("muxly");

const ClientHandle = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,
};

export fn muxly_version() [*:0]const u8 {
    return "0.1.0";
}

export fn muxly_ping(socket_path: [*:0]const u8) ?[*:0]u8 {
    return callStringApi(socket_path, muxly.api.ping);
}

export fn muxly_document_get(socket_path: [*:0]const u8) ?[*:0]u8 {
    return callStringApi(socket_path, muxly.api.documentGet);
}

export fn muxly_graph_get(socket_path: [*:0]const u8) ?[*:0]u8 {
    return callStringApi(socket_path, muxly.api.graphGet);
}

export fn muxly_client_create(socket_path: [*:0]const u8) ?*ClientHandle {
    const allocator = std.heap.c_allocator;
    const handle = allocator.create(ClientHandle) catch return null;
    handle.* = .{
        .allocator = allocator,
        .socket_path = allocator.dupe(u8, std.mem.span(socket_path)) catch {
            allocator.destroy(handle);
            return null;
        },
    };
    return handle;
}

export fn muxly_client_destroy(handle: ?*ClientHandle) void {
    if (handle) |client| {
        client.allocator.free(client.socket_path);
        client.allocator.destroy(client);
    }
}

export fn muxly_client_ping(handle: ?*ClientHandle) ?[*:0]u8 {
    return callHandleStringApi(handle, muxly.api.ping);
}

export fn muxly_client_document_get(handle: ?*ClientHandle) ?[*:0]u8 {
    return callHandleStringApi(handle, muxly.api.documentGet);
}

export fn muxly_client_graph_get(handle: ?*ClientHandle) ?[*:0]u8 {
    return callHandleStringApi(handle, muxly.api.graphGet);
}

export fn muxly_client_document_status(handle: ?*ClientHandle) ?[*:0]u8 {
    return callHandleStringApi(handle, muxly.api.documentStatus);
}

export fn muxly_client_node_get(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    const client = handle orelse return null;
    return ownedStringResult(client.allocator, muxly.api.nodeGet(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_node_append(
    handle: ?*ClientHandle,
    parent_id: u64,
    kind: [*:0]const u8,
    title: [*:0]const u8,
) ?[*:0]u8 {
    const client = handle orelse return null;
    return ownedStringResult(
        client.allocator,
        muxly.api.nodeAppend(
            client.allocator,
            client.socket_path,
            parent_id,
            std.mem.span(kind),
            std.mem.span(title),
        ),
    );
}

export fn muxly_client_node_update(
    handle: ?*ClientHandle,
    node_id: u64,
    title: ?[*:0]const u8,
    content: ?[*:0]const u8,
) ?[*:0]u8 {
    const client = handle orelse return null;
    const title_slice = if (title) |value| std.mem.span(value) else null;
    const content_slice = if (content) |value| std.mem.span(value) else null;
    return ownedStringResult(
        client.allocator,
        muxly.api.nodeUpdate(client.allocator, client.socket_path, node_id, title_slice, content_slice),
    );
}

export fn muxly_client_node_remove(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    const client = handle orelse return null;
    return ownedStringResult(client.allocator, muxly.api.nodeRemove(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_leaf_source_get(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    const client = handle orelse return null;
    return ownedStringResult(client.allocator, muxly.api.leafSourceGet(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_view_clear_root(handle: ?*ClientHandle) ?[*:0]u8 {
    return callHandleStringApi(handle, muxly.api.viewClearRoot);
}

export fn muxly_client_view_set_root(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    const client = handle orelse return null;
    return ownedStringResult(client.allocator, muxly.api.viewSetRoot(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_view_elide(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    const client = handle orelse return null;
    return ownedStringResult(client.allocator, muxly.api.viewElide(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_view_expand(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    const client = handle orelse return null;
    return ownedStringResult(client.allocator, muxly.api.viewExpand(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_view_reset(handle: ?*ClientHandle) ?[*:0]u8 {
    return callHandleStringApi(handle, muxly.api.viewReset);
}

export fn muxly_client_pane_capture(handle: ?*ClientHandle, pane_id: [*:0]const u8) ?[*:0]u8 {
    const client = handle orelse return null;
    return ownedStringResult(client.allocator, muxly.api.paneCapture(client.allocator, client.socket_path, std.mem.span(pane_id)));
}

export fn muxly_client_pane_split(
    handle: ?*ClientHandle,
    target: [*:0]const u8,
    direction: [*:0]const u8,
    command: ?[*:0]const u8,
) ?[*:0]u8 {
    const client = handle orelse return null;
    const command_slice = if (command) |value| std.mem.span(value) else null;
    return ownedStringResult(
        client.allocator,
        muxly.api.paneSplit(
            client.allocator,
            client.socket_path,
            std.mem.span(target),
            std.mem.span(direction),
            command_slice,
        ),
    );
}

export fn muxly_client_session_create(
    handle: ?*ClientHandle,
    session_name: [*:0]const u8,
    command: ?[*:0]const u8,
) ?[*:0]u8 {
    const client = handle orelse return null;
    const command_slice = if (command) |value| std.mem.span(value) else null;
    return ownedStringResult(
        client.allocator,
        muxly.api.sessionCreate(
            client.allocator,
            client.socket_path,
            std.mem.span(session_name),
            command_slice,
        ),
    );
}

export fn muxly_string_free(value: ?[*:0]u8) void {
    if (value) |ptr| {
        const allocator = std.heap.c_allocator;
        allocator.free(std.mem.span(ptr));
    }
}

fn callStringApi(
    socket_path: [*:0]const u8,
    comptime api_fn: fn (std.mem.Allocator, []const u8) anyerror![]u8,
) ?[*:0]u8 {
    const allocator = std.heap.c_allocator;
    const path = std.mem.span(socket_path);
    return ownedStringResult(allocator, api_fn(allocator, path));
}

fn callHandleStringApi(
    handle: ?*ClientHandle,
    comptime api_fn: fn (std.mem.Allocator, []const u8) anyerror![]u8,
) ?[*:0]u8 {
    const client = handle orelse return null;
    return ownedStringResult(client.allocator, api_fn(client.allocator, client.socket_path));
}

fn ownedStringResult(
    allocator: std.mem.Allocator,
    result: anyerror![]u8,
) ?[*:0]u8 {
    const response = result catch return null;
    const owned = allocator.allocSentinel(u8, response.len, 0) catch {
        allocator.free(response);
        return null;
    };
    @memcpy(owned[0..response.len], response);
    allocator.free(response);
    return owned.ptr;
}
