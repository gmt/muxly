const std = @import("std");
const tmux_commands = @import("commands.zig");
const tmux_events = @import("events.zig");
const tmux_parser = @import("parser.zig");

pub const PaneRef = struct {
    pane_id: []u8,
    window_id: []u8,
    session_name: []u8,

    pub fn deinit(self: *PaneRef, allocator: std.mem.Allocator) void {
        allocator.free(self.pane_id);
        allocator.free(self.window_id);
        allocator.free(self.session_name);
    }
};

pub fn createSession(
    allocator: std.mem.Allocator,
    session_name: []const u8,
    command: ?[]const u8,
) !PaneRef {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "tmux", "new-session", "-d", "-P", "-F", "#{pane_id}\t#{window_id}\t#{session_name}", "-s", session_name });
    if (command) |value| try argv.append(value);

    const result = try run(allocator, argv.items);
    defer freeRunResult(allocator, result);
    return try parsePaneRef(allocator, trimTrailingNewline(result.stdout));
}

pub fn createWindow(
    allocator: std.mem.Allocator,
    target: []const u8,
    window_name: ?[]const u8,
    command: ?[]const u8,
) !PaneRef {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "tmux", "new-window", "-d", "-P", "-F", "#{pane_id}\t#{window_id}\t#{session_name}", "-t", target });
    if (window_name) |value| try argv.appendSlice(&.{ "-n", value });
    if (command) |value| try argv.append(value);

    const result = try run(allocator, argv.items);
    defer freeRunResult(allocator, result);
    return try parsePaneRef(allocator, trimTrailingNewline(result.stdout));
}

pub fn splitPane(
    allocator: std.mem.Allocator,
    target: []const u8,
    direction: []const u8,
    command: ?[]const u8,
) !PaneRef {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();

    try argv.appendSlice(&.{ "tmux", "split-window", "-d", "-P", "-F", "#{pane_id}\t#{window_id}\t#{session_name}", "-t", target });
    if (std.mem.eql(u8, direction, "right") or std.mem.eql(u8, direction, "horizontal")) {
        try argv.append("-h");
    } else {
        try argv.append("-v");
    }
    if (command) |value| try argv.append(value);

    const result = try run(allocator, argv.items);
    defer freeRunResult(allocator, result);
    return try parsePaneRef(allocator, trimTrailingNewline(result.stdout));
}

pub fn capturePane(allocator: std.mem.Allocator, pane_id: []const u8) ![]u8 {
    const result = try run(allocator, &.{ "tmux", "capture-pane", "-p", "-S", "-", "-t", pane_id });
    if (!success(result.term)) {
        defer freeRunResult(allocator, result);
        return error.TmuxCommandFailed;
    }
    allocator.free(result.stderr);
    return result.stdout;
}

pub fn capturePaneVisible(allocator: std.mem.Allocator, pane_id: []const u8) ![]u8 {
    const result = try run(allocator, &.{ "tmux", "capture-pane", "-p", "-t", pane_id });
    if (!success(result.term)) {
        defer freeRunResult(allocator, result);
        return error.TmuxCommandFailed;
    }
    allocator.free(result.stderr);
    return result.stdout;
}

pub fn capturePaneAlternate(allocator: std.mem.Allocator, pane_id: []const u8) ![]u8 {
    const result = run(allocator, &.{ "tmux", "capture-pane", "-p", "-a", "-t", pane_id }) catch |err| switch (err) {
        error.TmuxCommandFailed => return try allocator.dupe(u8, ""),
        else => return err,
    };
    if (!success(result.term)) {
        defer freeRunResult(allocator, result);
        return error.TmuxCommandFailed;
    }
    allocator.free(result.stderr);
    return result.stdout;
}

pub fn capturePaneRange(
    allocator: std.mem.Allocator,
    pane_id: []const u8,
    start_line: i64,
    end_line: i64,
) ![]u8 {
    const start_text = try std.fmt.allocPrint(allocator, "{d}", .{start_line});
    defer allocator.free(start_text);
    const end_text = try std.fmt.allocPrint(allocator, "{d}", .{end_line});
    defer allocator.free(end_text);

    const result = try run(allocator, &.{ "tmux", "capture-pane", "-p", "-S", start_text, "-E", end_text, "-t", pane_id });
    if (!success(result.term)) {
        defer freeRunResult(allocator, result);
        return error.TmuxCommandFailed;
    }
    allocator.free(result.stderr);
    return result.stdout;
}

pub fn resizePane(
    allocator: std.mem.Allocator,
    pane_id: []const u8,
    direction: []const u8,
    amount: i64,
) !void {
    const amount_text = try std.fmt.allocPrint(allocator, "{d}", .{amount});
    defer allocator.free(amount_text);

    const flag = if (std.mem.eql(u8, direction, "left"))
        "-L"
    else if (std.mem.eql(u8, direction, "right"))
        "-R"
    else if (std.mem.eql(u8, direction, "up") or std.mem.eql(u8, direction, "above"))
        "-U"
    else
        "-D";

    const result = try run(allocator, &.{ "tmux", "resize-pane", "-t", pane_id, flag, amount_text });
    defer freeRunResult(allocator, result);
}

pub fn focusPane(allocator: std.mem.Allocator, pane_id: []const u8) !void {
    const result = try run(allocator, &.{ "tmux", "select-pane", "-t", pane_id });
    defer freeRunResult(allocator, result);
}

pub fn sendKeys(allocator: std.mem.Allocator, pane_id: []const u8, keys: []const u8, press_enter: bool) !void {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "tmux", "send-keys", "-t", pane_id, keys });
    if (press_enter) try argv.append("Enter");
    const result = try run(allocator, argv.items);
    defer freeRunResult(allocator, result);
}

pub fn closePane(allocator: std.mem.Allocator, pane_id: []const u8) !void {
    const result = try run(allocator, &.{ "tmux", "kill-pane", "-t", pane_id });
    defer freeRunResult(allocator, result);
}

pub fn listPaneSnapshots(allocator: std.mem.Allocator) ![]tmux_events.PaneSnapshot {
    const result = run(allocator, &.{ "tmux", "list-panes", "-a", "-F", tmux_commands.pane_snapshot_format }) catch |err| switch (err) {
        error.TmuxCommandFailed, error.FileNotFound => return try allocator.alloc(tmux_events.PaneSnapshot, 0),
        else => return err,
    };
    defer freeRunResult(allocator, result);

    var snapshots = std.array_list.Managed(tmux_events.PaneSnapshot).init(allocator);
    errdefer {
        for (snapshots.items) |*snapshot| snapshot.deinit(allocator);
        snapshots.deinit();
    }

    var lines = std.mem.splitScalar(u8, trimTrailingNewline(result.stdout), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try tmux_parser.parsePaneSnapshotLine(line);
        try snapshots.append(try parsed.clone(allocator));
    }

    return try snapshots.toOwnedSlice();
}

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    if (!success(result.term)) {
        defer freeRunResult(allocator, result);
        return error.TmuxCommandFailed;
    }
    return result;
}

fn success(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn parsePaneRef(allocator: std.mem.Allocator, line: []const u8) !PaneRef {
    var parts = std.mem.splitScalar(u8, line, '\t');
    const pane_id = parts.next() orelse return error.BadTmuxOutput;
    const window_id = parts.next() orelse return error.BadTmuxOutput;
    const session_name = parts.next() orelse return error.BadTmuxOutput;
    return .{
        .pane_id = try allocator.dupe(u8, pane_id),
        .window_id = try allocator.dupe(u8, window_id),
        .session_name = try allocator.dupe(u8, session_name),
    };
}

fn trimTrailingNewline(value: []const u8) []const u8 {
    return std.mem.trimRight(u8, value, "\r\n");
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.Child.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}
