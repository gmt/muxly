const std = @import("std");
const c = @cImport({
    @cInclude("muxly.h");
});

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("muxly version => {s}\n", .{std.mem.span(c.muxly_version())});

    const client = c.muxly_client_create("/tmp/muxly.sock") orelse return error.ClientCreateFailed;
    defer c.muxly_client_destroy(client);

    const response_ptr = c.muxly_client_ping(client);
    if (response_ptr == null) return error.PingFailed;
    defer c.muxly_string_free(response_ptr);

    try stdout.print("ping => {s}\n", .{std.mem.span(response_ptr)});

    const document_ptr = c.muxly_client_document_get(client);
    if (document_ptr == null) return error.DocumentGetFailed;
    defer c.muxly_string_free(document_ptr);

    try stdout.print("document => {s}\n", .{std.mem.span(document_ptr)});

    const root_ptr = c.muxly_client_view_set_root(client, 2);
    if (root_ptr == null) return error.ViewSetRootFailed;
    defer c.muxly_string_free(root_ptr);
    try stdout.print("view set root => {s}\n", .{std.mem.span(root_ptr)});

    const graph_ptr = c.muxly_client_graph_get(client);
    if (graph_ptr == null) return error.GraphGetFailed;
    defer c.muxly_string_free(graph_ptr);
    try stdout.print("graph => {s}\n", .{std.mem.span(graph_ptr)});
}
