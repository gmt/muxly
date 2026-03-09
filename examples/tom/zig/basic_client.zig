const std = @import("std");
const c = @cImport({
    @cInclude("muxly.h");
});

fn parseNodeId(response: []const u8) !u64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, response, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    return @intCast(parsed.value.object.get("result").?.object.get("nodeId").?.integer);
}

fn socketPathFromEnv(allocator: std.mem.Allocator) ![]u8 {
    const raw = std.process.getEnvVarOwned(allocator, "MUXLY_SOCKET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return try allocator.dupeZ(u8, "/tmp/muxly.sock"),
        else => return err,
    };
    defer allocator.free(raw);
    return try allocator.dupeZ(u8, raw);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const socket_path = try socketPathFromEnv(allocator);

    try stdout.print("muxly version => {s}\n", .{std.mem.span(c.muxly_version())});
    try stdout.print("socket path => {s}\n", .{socket_path});

    const client = c.muxly_client_create(socket_path.ptr) orelse return error.ClientCreateFailed;
    defer c.muxly_client_destroy(client);

    const response_ptr = c.muxly_client_ping(client);
    if (response_ptr == null) return error.PingFailed;
    defer c.muxly_string_free(response_ptr);

    try stdout.print("ping => {s}\n", .{std.mem.span(response_ptr)});

    const status_ptr = c.muxly_client_document_status(client);
    if (status_ptr == null) return error.DocumentStatusFailed;
    defer c.muxly_string_free(status_ptr);
    try stdout.print("document status => {s}\n", .{std.mem.span(status_ptr)});

    const append_ptr = c.muxly_client_node_append(client, 1, "subdocument", "zig c abi scaffold");
    if (append_ptr == null) return error.NodeAppendFailed;
    defer c.muxly_string_free(append_ptr);
    try stdout.print("node append => {s}\n", .{std.mem.span(append_ptr)});

    const node_id = try parseNodeId(std.mem.span(append_ptr));

    const update_ptr = c.muxly_client_node_update(client, node_id, null, "hello synthetic api from zig");
    if (update_ptr == null) return error.NodeUpdateFailed;
    defer c.muxly_string_free(update_ptr);
    try stdout.print("node update => {s}\n", .{std.mem.span(update_ptr)});

    const node_ptr = c.muxly_client_node_get(client, node_id);
    if (node_ptr == null) return error.NodeGetFailed;
    defer c.muxly_string_free(node_ptr);
    try stdout.print("node => {s}\n", .{std.mem.span(node_ptr)});

    const set_root_ptr = c.muxly_client_view_set_root(client, node_id);
    if (set_root_ptr == null) return error.ViewSetRootFailed;
    defer c.muxly_string_free(set_root_ptr);
    try stdout.print("view set root => {s}\n", .{std.mem.span(set_root_ptr)});

    const elide_ptr = c.muxly_client_view_elide(client, node_id);
    if (elide_ptr == null) return error.ViewElideFailed;
    defer c.muxly_string_free(elide_ptr);
    try stdout.print("view elide => {s}\n", .{std.mem.span(elide_ptr)});

    const expand_ptr = c.muxly_client_view_expand(client, node_id);
    if (expand_ptr == null) return error.ViewExpandFailed;
    defer c.muxly_string_free(expand_ptr);
    try stdout.print("view expand => {s}\n", .{std.mem.span(expand_ptr)});

    const clear_root_ptr = c.muxly_client_view_clear_root(client);
    if (clear_root_ptr == null) return error.ViewClearRootFailed;
    defer c.muxly_string_free(clear_root_ptr);
    try stdout.print("view clear root => {s}\n", .{std.mem.span(clear_root_ptr)});

    const reset_ptr = c.muxly_client_view_reset(client);
    if (reset_ptr == null) return error.ViewResetFailed;
    defer c.muxly_string_free(reset_ptr);
    try stdout.print("view reset => {s}\n", .{std.mem.span(reset_ptr)});

    const document_ptr = c.muxly_client_document_get(client);
    if (document_ptr == null) return error.DocumentGetFailed;
    defer c.muxly_string_free(document_ptr);
    try stdout.print("document => {s}\n", .{std.mem.span(document_ptr)});

    const graph_ptr = c.muxly_client_graph_get(client);
    if (graph_ptr == null) return error.GraphGetFailed;
    defer c.muxly_string_free(graph_ptr);
    try stdout.print("graph => {s}\n", .{std.mem.span(graph_ptr)});

    const remove_ptr = c.muxly_client_node_remove(client, node_id);
    if (remove_ptr == null) return error.NodeRemoveFailed;
    defer c.muxly_string_free(remove_ptr);
    try stdout.print("node remove => {s}\n", .{std.mem.span(remove_ptr)});
}
