const std = @import("std");
const muxly = @import("muxly");

const ClientHandle = struct {
    allocator: std.mem.Allocator,
    socket_path: []u8,
};

const MuxlyStatus = enum(c_int) {
    ok = 0,
    null_argument = 1,
    invalid_argument = 2,
    unsupported_platform = 3,
    allocation_failure = 4,
    transport_failure = 5,
};

export fn muxly_version() [*:0]const u8 {
    return "0.1.0";
}

export fn muxly_status_string(status: MuxlyStatus) [*:0]const u8 {
    return switch (status) {
        .ok => "ok",
        .null_argument => "null_argument",
        .invalid_argument => "invalid_argument",
        .unsupported_platform => "unsupported_platform",
        .allocation_failure => "allocation_failure",
        .transport_failure => "transport_failure",
    };
}

export fn muxly_ping(socket_path: [*:0]const u8) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_ping_ex(socket_path, &out), out);
}

export fn muxly_ping_ex(socket_path: ?[*:0]const u8, out_response: ?*?[*:0]u8) MuxlyStatus {
    return callStringApiEx(socket_path, out_response, muxly.api.ping);
}

export fn muxly_document_get(socket_path: [*:0]const u8) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_document_get_ex(socket_path, &out), out);
}

export fn muxly_document_get_ex(socket_path: ?[*:0]const u8, out_response: ?*?[*:0]u8) MuxlyStatus {
    return callStringApiEx(socket_path, out_response, muxly.api.documentGet);
}

export fn muxly_graph_get(socket_path: [*:0]const u8) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_graph_get_ex(socket_path, &out), out);
}

export fn muxly_graph_get_ex(socket_path: ?[*:0]const u8, out_response: ?*?[*:0]u8) MuxlyStatus {
    return callStringApiEx(socket_path, out_response, muxly.api.graphGet);
}

export fn muxly_client_create(socket_path: [*:0]const u8) ?*ClientHandle {
    var out: ?*ClientHandle = null;
    return legacyHandleFromStatus(muxly_client_create_ex(socket_path, &out), out);
}

export fn muxly_client_create_ex(socket_path: ?[*:0]const u8, out_client: ?*?*ClientHandle) MuxlyStatus {
    const out = initHandleOut(out_client) orelse return .null_argument;
    const path = socket_path orelse return .null_argument;
    const allocator = std.heap.c_allocator;
    const handle = allocator.create(ClientHandle) catch return .allocation_failure;
    const copied_path = allocator.dupe(u8, std.mem.span(path)) catch {
        allocator.destroy(handle);
        return .allocation_failure;
    };
    handle.* = .{
        .allocator = allocator,
        .socket_path = copied_path,
    };
    out.* = handle;
    return .ok;
}

export fn muxly_client_destroy(handle: ?*ClientHandle) void {
    if (handle) |client| {
        client.allocator.free(client.socket_path);
        client.allocator.destroy(client);
    }
}

export fn muxly_client_ping(handle: ?*ClientHandle) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_ping_ex(handle, &out), out);
}

export fn muxly_client_ping_ex(handle: ?*ClientHandle, out_response: ?*?[*:0]u8) MuxlyStatus {
    return callHandleStringApiEx(handle, out_response, muxly.api.ping);
}

export fn muxly_client_document_get(handle: ?*ClientHandle) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_document_get_ex(handle, &out), out);
}

export fn muxly_client_document_get_ex(handle: ?*ClientHandle, out_response: ?*?[*:0]u8) MuxlyStatus {
    return callHandleStringApiEx(handle, out_response, muxly.api.documentGet);
}

export fn muxly_client_graph_get(handle: ?*ClientHandle) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_graph_get_ex(handle, &out), out);
}

export fn muxly_client_graph_get_ex(handle: ?*ClientHandle, out_response: ?*?[*:0]u8) MuxlyStatus {
    return callHandleStringApiEx(handle, out_response, muxly.api.graphGet);
}

export fn muxly_client_document_status(handle: ?*ClientHandle) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_document_status_ex(handle, &out), out);
}

export fn muxly_client_document_status_ex(handle: ?*ClientHandle, out_response: ?*?[*:0]u8) MuxlyStatus {
    return callHandleStringApiEx(handle, out_response, muxly.api.documentStatus);
}

export fn muxly_client_node_get(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_node_get_ex(handle, node_id, &out), out);
}

export fn muxly_client_node_get_ex(handle: ?*ClientHandle, node_id: u64, out_response: ?*?[*:0]u8) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    return writeOwnedStringResult(client.allocator, out, muxly.api.nodeGet(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_node_append(
    handle: ?*ClientHandle,
    parent_id: u64,
    kind: [*:0]const u8,
    title: [*:0]const u8,
) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_node_append_ex(handle, parent_id, kind, title, &out), out);
}

export fn muxly_client_node_append_ex(
    handle: ?*ClientHandle,
    parent_id: u64,
    kind: ?[*:0]const u8,
    title: ?[*:0]const u8,
    out_response: ?*?[*:0]u8,
) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    const kind_slice = cStringSlice(kind) orelse return .null_argument;
    const title_slice = cStringSlice(title) orelse return .null_argument;
    return writeOwnedStringResult(
        client.allocator,
        out,
        muxly.api.nodeAppend(
            client.allocator,
            client.socket_path,
            parent_id,
            kind_slice,
            title_slice,
        ),
    );
}

export fn muxly_client_node_update(
    handle: ?*ClientHandle,
    node_id: u64,
    title: ?[*:0]const u8,
    content: ?[*:0]const u8,
) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_node_update_ex(handle, node_id, title, content, &out), out);
}

export fn muxly_client_node_update_ex(
    handle: ?*ClientHandle,
    node_id: u64,
    title: ?[*:0]const u8,
    content: ?[*:0]const u8,
    out_response: ?*?[*:0]u8,
) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    const title_slice = if (title) |value| std.mem.span(value) else null;
    const content_slice = if (content) |value| std.mem.span(value) else null;
    return writeOwnedStringResult(
        client.allocator,
        out,
        muxly.api.nodeUpdate(client.allocator, client.socket_path, node_id, title_slice, content_slice),
    );
}

export fn muxly_client_node_freeze(
    handle: ?*ClientHandle,
    node_id: u64,
    artifact_kind: [*:0]const u8,
) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_node_freeze_ex(handle, node_id, artifact_kind, &out), out);
}

export fn muxly_client_node_freeze_ex(
    handle: ?*ClientHandle,
    node_id: u64,
    artifact_kind: ?[*:0]const u8,
    out_response: ?*?[*:0]u8,
) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    const artifact_kind_slice = cStringSlice(artifact_kind) orelse return .null_argument;
    return writeOwnedStringResult(
        client.allocator,
        out,
        muxly.api.nodeFreeze(client.allocator, client.socket_path, node_id, artifact_kind_slice),
    );
}

export fn muxly_client_node_remove(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_node_remove_ex(handle, node_id, &out), out);
}

export fn muxly_client_node_remove_ex(handle: ?*ClientHandle, node_id: u64, out_response: ?*?[*:0]u8) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    return writeOwnedStringResult(client.allocator, out, muxly.api.nodeRemove(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_leaf_source_get(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_leaf_source_get_ex(handle, node_id, &out), out);
}

export fn muxly_client_leaf_source_get_ex(handle: ?*ClientHandle, node_id: u64, out_response: ?*?[*:0]u8) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    return writeOwnedStringResult(client.allocator, out, muxly.api.leafSourceGet(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_view_clear_root(handle: ?*ClientHandle) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_view_clear_root_ex(handle, &out), out);
}

export fn muxly_client_view_clear_root_ex(handle: ?*ClientHandle, out_response: ?*?[*:0]u8) MuxlyStatus {
    return callHandleStringApiEx(handle, out_response, muxly.api.viewClearRoot);
}

export fn muxly_client_view_set_root(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_view_set_root_ex(handle, node_id, &out), out);
}

export fn muxly_client_view_set_root_ex(handle: ?*ClientHandle, node_id: u64, out_response: ?*?[*:0]u8) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    return writeOwnedStringResult(client.allocator, out, muxly.api.viewSetRoot(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_view_elide(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_view_elide_ex(handle, node_id, &out), out);
}

export fn muxly_client_view_elide_ex(handle: ?*ClientHandle, node_id: u64, out_response: ?*?[*:0]u8) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    return writeOwnedStringResult(client.allocator, out, muxly.api.viewElide(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_view_expand(handle: ?*ClientHandle, node_id: u64) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_view_expand_ex(handle, node_id, &out), out);
}

export fn muxly_client_view_expand_ex(handle: ?*ClientHandle, node_id: u64, out_response: ?*?[*:0]u8) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    return writeOwnedStringResult(client.allocator, out, muxly.api.viewExpand(client.allocator, client.socket_path, node_id));
}

export fn muxly_client_view_reset(handle: ?*ClientHandle) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_view_reset_ex(handle, &out), out);
}

export fn muxly_client_view_reset_ex(handle: ?*ClientHandle, out_response: ?*?[*:0]u8) MuxlyStatus {
    return callHandleStringApiEx(handle, out_response, muxly.api.viewReset);
}

export fn muxly_client_pane_capture(handle: ?*ClientHandle, pane_id: [*:0]const u8) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_pane_capture_ex(handle, pane_id, &out), out);
}

export fn muxly_client_pane_capture_ex(
    handle: ?*ClientHandle,
    pane_id: ?[*:0]const u8,
    out_response: ?*?[*:0]u8,
) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    const pane_id_slice = cStringSlice(pane_id) orelse return .null_argument;
    return writeOwnedStringResult(client.allocator, out, muxly.api.paneCapture(client.allocator, client.socket_path, pane_id_slice));
}

export fn muxly_client_pane_split(
    handle: ?*ClientHandle,
    target: [*:0]const u8,
    direction: [*:0]const u8,
    command: ?[*:0]const u8,
) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_pane_split_ex(handle, target, direction, command, &out), out);
}

export fn muxly_client_pane_split_ex(
    handle: ?*ClientHandle,
    target: ?[*:0]const u8,
    direction: ?[*:0]const u8,
    command: ?[*:0]const u8,
    out_response: ?*?[*:0]u8,
) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    const target_slice = cStringSlice(target) orelse return .null_argument;
    const direction_slice = cStringSlice(direction) orelse return .null_argument;
    const command_slice = if (command) |value| std.mem.span(value) else null;
    return writeOwnedStringResult(
        client.allocator,
        out,
        muxly.api.paneSplit(
            client.allocator,
            client.socket_path,
            target_slice,
            direction_slice,
            command_slice,
        ),
    );
}

export fn muxly_client_session_create(
    handle: ?*ClientHandle,
    session_name: [*:0]const u8,
    command: ?[*:0]const u8,
) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(muxly_client_session_create_ex(handle, session_name, command, &out), out);
}

export fn muxly_client_session_create_ex(
    handle: ?*ClientHandle,
    session_name: ?[*:0]const u8,
    command: ?[*:0]const u8,
    out_response: ?*?[*:0]u8,
) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    const session_name_slice = cStringSlice(session_name) orelse return .null_argument;
    const command_slice = if (command) |value| std.mem.span(value) else null;
    return writeOwnedStringResult(
        client.allocator,
        out,
        muxly.api.sessionCreate(
            client.allocator,
            client.socket_path,
            session_name_slice,
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
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(callStringApiEx(socket_path, &out, api_fn), out);
}

fn callHandleStringApi(
    handle: ?*ClientHandle,
    comptime api_fn: fn (std.mem.Allocator, []const u8) anyerror![]u8,
) ?[*:0]u8 {
    var out: ?[*:0]u8 = null;
    return legacyStringFromStatus(callHandleStringApiEx(handle, &out, api_fn), out);
}

fn callStringApiEx(
    socket_path: ?[*:0]const u8,
    out_response: ?*?[*:0]u8,
    comptime api_fn: fn (std.mem.Allocator, []const u8) anyerror![]u8,
) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const path = cStringSlice(socket_path) orelse return .null_argument;
    const allocator = std.heap.c_allocator;
    return writeOwnedStringResult(allocator, out, api_fn(allocator, path));
}

fn callHandleStringApiEx(
    handle: ?*ClientHandle,
    out_response: ?*?[*:0]u8,
    comptime api_fn: fn (std.mem.Allocator, []const u8) anyerror![]u8,
) MuxlyStatus {
    const out = initStringOut(out_response) orelse return .null_argument;
    const client = handle orelse return .null_argument;
    return writeOwnedStringResult(client.allocator, out, api_fn(client.allocator, client.socket_path));
}

fn writeOwnedStringResult(
    allocator: std.mem.Allocator,
    out_response: *?[*:0]u8,
    result: anyerror![]u8,
) MuxlyStatus {
    const response = result catch |err| return mapStatus(err);
    const owned = allocator.allocSentinel(u8, response.len, 0) catch {
        allocator.free(response);
        return .allocation_failure;
    };
    @memcpy(owned[0..response.len], response);
    allocator.free(response);
    out_response.* = owned.ptr;
    return .ok;
}

fn legacyStringFromStatus(status: MuxlyStatus, value: ?[*:0]u8) ?[*:0]u8 {
    return if (status == .ok) value else null;
}

fn legacyHandleFromStatus(status: MuxlyStatus, value: ?*ClientHandle) ?*ClientHandle {
    return if (status == .ok) value else null;
}

fn initStringOut(out_response: ?*?[*:0]u8) ?*?[*:0]u8 {
    const out = out_response orelse return null;
    out.* = null;
    return out;
}

fn initHandleOut(out_handle: ?*?*ClientHandle) ?*?*ClientHandle {
    const out = out_handle orelse return null;
    out.* = null;
    return out;
}

fn cStringSlice(value: ?[*:0]const u8) ?[]const u8 {
    const ptr = value orelse return null;
    return std.mem.span(ptr);
}

fn mapStatus(err: anyerror) MuxlyStatus {
    return switch (err) {
        error.OutOfMemory => .allocation_failure,
        error.InvalidArguments => .invalid_argument,
        error.UnsupportedPlatform => .unsupported_platform,
        else => .transport_failure,
    };
}
