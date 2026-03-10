const std = @import("std");
const builtin = @import("builtin");
const muxly = @import("muxly");
const commands = muxly.daemon.tmux.commands;
const parser = muxly.daemon.tmux.parser;
const control_mode = muxly.daemon.tmux.control_mode;

test "tmux control-mode parser handles boundaries notifications and output" {
    const begin = try parser.parseLine("%begin 1773104611 562 0");
    try std.testing.expect(begin == .begin);
    try std.testing.expectEqual(@as(u64, 1773104611), begin.begin.timestamp);
    try std.testing.expectEqual(@as(u64, 562), begin.begin.command_number);
    try std.testing.expectEqual(@as(i64, 0), begin.begin.flags);

    const notification = try parser.parseLine("%session-changed $0 muxly-control-probe");
    try std.testing.expect(notification == .notification);
    try std.testing.expectEqualStrings("session-changed", notification.notification.name);
    try std.testing.expectEqualStrings("$0 muxly-control-probe", notification.notification.payload);

    const output = try parser.parseLine("muxly-control-probe\t$0\t@0\ttmux\t%0\tproof-pane\t1");
    try std.testing.expect(output == .output);
    try std.testing.expectEqualStrings("muxly-control-probe\t$0\t@0\ttmux\t%0\tproof-pane\t1", output.output);

    const pane_snapshot = try parser.parsePaneSnapshotLine("muxly-control-probe\t$0\t@0\ttmux\t%0\tproof-pane\t1");
    try std.testing.expectEqualStrings("muxly-control-probe", pane_snapshot.session_name);
    try std.testing.expectEqualStrings("$0", pane_snapshot.session_id);
    try std.testing.expectEqualStrings("@0", pane_snapshot.window_id);
    try std.testing.expectEqualStrings("tmux", pane_snapshot.window_name);
    try std.testing.expectEqualStrings("%0", pane_snapshot.pane_id);
    try std.testing.expectEqualStrings("proof-pane", pane_snapshot.pane_title);
    try std.testing.expect(pane_snapshot.pane_active);

    const exit = try parser.parseLine("%exit");
    try std.testing.expect(exit == .exit);
}

test "tmux control-mode connection can collect a command block" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const session_name = "muxly-control-mode-test";
    cleanupSession(session_name);

    var connection = control_mode.ControlConnection.init(allocator, session_name) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer {
        connection.deinit();
        cleanupSession(session_name);
    }

    const command = try commands.listPanesAll(allocator);
    defer allocator.free(command);

    const block = try connection.runCommandBlock(command);
    defer {
        var owned = block;
        owned.deinit();
    }

    try std.testing.expect(block.completed);
    try std.testing.expect(!block.failed);
    try std.testing.expect(block.output_lines.items.len >= 1);

    const first_line = block.output_lines.items[0];
    const pane_snapshot = try parser.parsePaneSnapshotLine(first_line);
    try std.testing.expectEqualStrings(session_name, pane_snapshot.session_name);
    try std.testing.expect(pane_snapshot.window_id.len != 0);
    try std.testing.expect(pane_snapshot.pane_id.len != 0);
}

test "tmux control-mode connection can reattach after attached session exits" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const session_a = "muxly-control-mode-reconnect-a";
    const session_b = "muxly-control-mode-reconnect-b";
    cleanupSession(session_a);
    cleanupSession(session_b);
    try createSession(session_a);
    defer cleanupSession(session_a);
    try createSession(session_b);
    defer cleanupSession(session_b);

    var connection = control_mode.ControlConnection.initAttach(allocator, session_a) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer connection.deinit();

    try killSession(allocator, session_a);

    var saw_exit = false;
    connection.drainEvents(1000, &saw_exit, struct {
        fn handle(flag: *bool, event: muxly.daemon.tmux.events.Event) !void {
            switch (event) {
                .exit => {
                    flag.* = true;
                    return error.ControlModeExited;
                },
                else => {},
            }
        }
    }.handle) catch |err| switch (err) {
        error.ControlModeExited => {},
        else => return err,
    };
    try std.testing.expect(saw_exit);

    var reattached = control_mode.ControlConnection.initAttach(allocator, session_b) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer reattached.deinit();

    const command = try commands.listPanesAll(allocator);
    defer allocator.free(command);

    const block = try reattached.runCommandBlock(command);
    defer {
        var owned = block;
        owned.deinit();
    }

    try std.testing.expect(block.completed);
    try std.testing.expect(!block.failed);
    try std.testing.expect(block.output_lines.items.len >= 1);
    const pane_snapshot = try parser.parsePaneSnapshotLine(block.output_lines.items[0]);
    try std.testing.expectEqualStrings(session_b, pane_snapshot.session_name);
}

fn createSession(session_name: []const u8) !void {
    var child = std.process.Child.init(
        &[_][]const u8{ "tmux", "new-session", "-d", "-s", session_name, "sh -lc 'printf reconnect\\n; sleep 5'" },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.TmuxCommandFailed,
        else => return error.TmuxCommandFailed,
    }
}

fn killSession(allocator: std.mem.Allocator, session_name: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tmux", "kill-session", "-t", session_name },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.TmuxCommandFailed,
        else => return error.TmuxCommandFailed,
    }
}

fn cleanupSession(session_name: []const u8) void {
    var child = std.process.Child.init(&[_][]const u8{ "tmux", "kill-session", "-t", session_name }, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch {};
}
