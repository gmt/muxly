const std = @import("std");
const muxly = @import("muxly");
const config_mod = @import("config.zig");
const router = @import("router.zig");
const store_mod = @import("state/store.zig");

pub fn serve(allocator: std.mem.Allocator, config: config_mod.Config) !void {
    var store = try store_mod.Store.init(allocator);
    defer store.deinit();
    var store_mutex = std.Thread.Mutex{};

    var listener = try muxly.transport.Listener.init(allocator, &config.transport);
    defer listener.deinit();
    const single_request_per_connection = switch (listener.target) {
        .proxy => true,
        .unix, .tcp => false,
    };

    const stderr = std.fs.File.stderr().deprecatedWriter();
    try stderr.writeAll("muxlyd listening on ");
    try listener.writeDescription(stderr);
    try stderr.writeByte('\n');

    while (true) {
        const connection = try listener.accept();
        const thread = try std.Thread.spawn(.{}, serveConnection, .{ConnectionContext{
            .store = &store,
            .store_mutex = &store_mutex,
            .connection = connection,
            .single_request_per_connection = single_request_per_connection,
        }});
        thread.detach();
    }
}

const ConnectionContext = struct {
    store: *store_mod.Store,
    store_mutex: *std.Thread.Mutex,
    connection: std.net.Server.Connection,
    single_request_per_connection: bool,
};

fn serveConnection(context: ConnectionContext) void {
    serveConnectionImpl(context) catch |err| {
        std.fs.File.stderr().deprecatedWriter().print("muxlyd connection error: {}\n", .{err}) catch {};
    };
}

fn serveConnectionImpl(context: ConnectionContext) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var connection = context.connection;
    defer connection.stream.close();

    var request_reader = muxly.transport.MessageReader.init(allocator);
    defer request_reader.deinit();
    var broker = muxly.conversation_broker.Broker.init();

    while (true) {
        const request = try request_reader.readMessageLine(
            connection.stream,
            muxly.transport.max_message_bytes,
        ) orelse break;
        defer allocator.free(request);
        if (request.len == 0) continue;

        context.store_mutex.lock();
        var responses = broker.handleLine(allocator, request, context.store, routeRequest) catch |err| {
            context.store_mutex.unlock();
            return err;
        };
        defer responses.deinit();
        context.store_mutex.unlock();

        for (responses.frames.items) |response| {
            try connection.stream.writeAll(response.bytes);
            try connection.stream.writeAll("\n");
        }
        if (context.single_request_per_connection) break;
    }
}

fn routeRequest(
    allocator: std.mem.Allocator,
    store: *store_mod.Store,
    request_json: []const u8,
) ![]u8 {
    return try router.handleRequest(allocator, store, request_json);
}
