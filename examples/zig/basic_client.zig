const std = @import("std");
const c = @cImport({
    @cInclude("muxly.h");
});

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
    const session_name_text = try std.fmt.allocPrint(allocator, "muxly-zig-example-{d}", .{std.time.milliTimestamp()});
    const session_name = try allocator.dupeZ(u8, session_name_text);
    const command = "sh -lc 'printf hello-from-zig-binding\\n; sleep 1'";

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

    const session_ptr = c.muxly_client_session_create(client, session_name.ptr, command);
    if (session_ptr == null) return error.SessionCreateFailed;
    defer c.muxly_string_free(session_ptr);
    try stdout.print("session create => {s}\n", .{std.mem.span(session_ptr)});

    std.Thread.sleep(200 * std.time.ns_per_ms);

    const document_ptr = c.muxly_client_document_get(client);
    if (document_ptr == null) return error.DocumentGetFailed;
    defer c.muxly_string_free(document_ptr);
    try stdout.print("document => {s}\n", .{std.mem.span(document_ptr)});

    const graph_ptr = c.muxly_client_graph_get(client);
    if (graph_ptr == null) return error.GraphGetFailed;
    defer c.muxly_string_free(graph_ptr);
    try stdout.print("graph => {s}\n", .{std.mem.span(graph_ptr)});
}
