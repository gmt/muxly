const std = @import("std");
const c = @cImport({
    @cInclude("muxly.h");
});

const TEXT_SESSION_NAME = "muxly-example-zig-freeze-text";
const SURFACE_SESSION_NAME = "muxly-example-zig-freeze-surface";

fn socketPathFromEnv(allocator: std.mem.Allocator) ![:0]u8 {
    const raw = std.process.getEnvVarOwned(allocator, "MUXLY_SOCKET") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return try allocator.dupeZ(u8, "/tmp/muxly.sock"),
        else => return err,
    };
    defer allocator.free(raw);
    return try allocator.dupeZ(u8, raw);
}

fn callJson(response_ptr: ?[*:0]u8) !std.json.Parsed(std.json.Value) {
    const ptr = response_ptr orelse return error.ApiCallFailed;
    defer c.muxly_string_free(ptr);
    return try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, std.mem.span(ptr), .{
        .allocate = .alloc_always,
    });
}

fn parseNodeId(response: std.json.Value) !u64 {
    return @intCast(response.object.get("result").?.object.get("nodeId").?.integer);
}

fn parsePaneId(response: std.json.Value) ![]const u8 {
    return response.object.get("result").?.object.get("source").?.object.get("paneId").?.string;
}

fn parseSectionedText(allocator: std.mem.Allocator, content: []const u8) !std.StringArrayHashMap([]u8) {
    var sections = std.StringArrayHashMap([]u8).init(allocator);
    errdefer {
        var it = sections.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        sections.deinit();
    }

    var current = try allocator.dupe(u8, "body");
    defer allocator.free(current);
    try sections.put(try allocator.dupe(u8, current), try allocator.dupe(u8, ""));

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len >= 3 and line[0] == '[' and line[line.len - 1] == ']') {
            allocator.free(current);
            current = try allocator.dupe(u8, line[1 .. line.len - 1]);
            if (!sections.contains(current)) {
                try sections.put(try allocator.dupe(u8, current), try allocator.dupe(u8, ""));
            }
            continue;
        }

        const existing = sections.getPtr(current).?;
        var buffer = std.array_list.Managed(u8).fromOwnedSlice(allocator, existing.*);
        defer buffer.deinit();
        if (buffer.items.len > 0) try buffer.append('\n');
        try buffer.appendSlice(line);
        existing.* = try buffer.toOwnedSlice();
    }

    return sections;
}

fn waitForPaneContent(client: ?*c.muxly_client, pane_id: [:0]const u8, needle: []const u8) !void {
    const deadline_ms = std.time.milliTimestamp() + 4000;
    while (std.time.milliTimestamp() < deadline_ms) {
        var parsed = try callJson(c.muxly_client_pane_capture(client, pane_id.ptr));
        defer parsed.deinit();
        const content = parsed.value.object.get("result").?.object.get("content").?.string;
        if (std.mem.indexOf(u8, content, needle) != null) return;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    return error.Timeout;
}

fn cleanupTmuxSession(session_name: []const u8) void {
    const argv = [_][]const u8{ "tmux", "kill-session", "-t", session_name };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch {};
}

fn printSection(writer: anytype, title: []const u8, response: std.json.Value) !void {
    try writer.print("\n== {s} ==\n", .{title});
    try writer.print("{f}\n", .{std.json.fmt(response.object.get("result").?, .{ .whitespace = .indent_2 })});
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const socket_path = try socketPathFromEnv(allocator);
    _ = args.next();
    const surface_script_path = args.next() orelse return error.MissingSurfaceScriptPath;
    const client = c.muxly_client_create(socket_path.ptr) orelse return error.ClientCreateFailed;
    defer c.muxly_client_destroy(client);

    cleanupTmuxSession(TEXT_SESSION_NAME);
    cleanupTmuxSession(SURFACE_SESSION_NAME);
    defer cleanupTmuxSession(TEXT_SESSION_NAME);
    defer cleanupTmuxSession(SURFACE_SESSION_NAME);

    try stdout.print("muxly version: {s}\n", .{std.mem.span(c.muxly_version())});
    try stdout.print("socket path: {s}\n", .{socket_path});

    const text_session_command = "sh -lc 'printf \"%s\\n\" zig-freeze-text; sleep 5'";
    var text_session = try callJson(c.muxly_client_session_create(client, TEXT_SESSION_NAME, text_session_command));
    defer text_session.deinit();
    const text_node_id = try parseNodeId(text_session.value);

    var text_node = try callJson(c.muxly_client_node_get(client, text_node_id));
    defer text_node.deinit();
    const text_pane_id = try allocator.dupeZ(u8, try parsePaneId(text_node.value));
    try waitForPaneContent(client, text_pane_id, "zig-freeze-text");

    var frozen_text = try callJson(c.muxly_client_node_freeze(client, text_node_id, "text"));
    defer frozen_text.deinit();
    var frozen_text_node = try callJson(c.muxly_client_node_get(client, text_node_id));
    defer frozen_text_node.deinit();

    const surface_command_raw = try std.fmt.allocPrint(
        allocator,
        "sh -lc 'python3 -u {s}'",
        .{surface_script_path},
    );
    const surface_command = try allocator.dupeZ(u8, surface_command_raw);
    var surface_session = try callJson(c.muxly_client_session_create(client, SURFACE_SESSION_NAME, surface_command.ptr));
    defer surface_session.deinit();
    const surface_node_id = try parseNodeId(surface_session.value);

    var surface_node = try callJson(c.muxly_client_node_get(client, surface_node_id));
    defer surface_node.deinit();
    const surface_pane_id = try allocator.dupeZ(u8, try parsePaneId(surface_node.value));
    try waitForPaneContent(client, surface_pane_id, "muxly surface demo");

    var frozen_surface = try callJson(c.muxly_client_node_freeze(client, surface_node_id, "surface"));
    defer frozen_surface.deinit();
    var frozen_surface_node = try callJson(c.muxly_client_node_get(client, surface_node_id));
    defer frozen_surface_node.deinit();

    try printSection(stdout, "text freeze response", frozen_text.value);
    try printSection(stdout, "text frozen node", frozen_text_node.value);
    try printSection(stdout, "surface freeze response", frozen_surface.value);
    try printSection(stdout, "surface frozen node", frozen_surface_node.value);

    try stdout.writeAll("\n== parsed surface sections ==\n");
    const surface_content = frozen_surface_node.value.object.get("result").?.object.get("content").?.string;
    var sections = try parseSectionedText(allocator, surface_content);
    defer {
        var it = sections.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        sections.deinit();
    }
    try stdout.writeAll("{\n");
    for (sections.keys(), 0..) |key, idx| {
        const value = sections.get(key).?;
        try stdout.print("  \"{s}\": {f}", .{ key, std.json.fmt(value, .{}) });
        if (idx + 1 < sections.count()) try stdout.writeAll(",");
        try stdout.writeByte('\n');
    }
    try stdout.writeAll("}\n");
}
