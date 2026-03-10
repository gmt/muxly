const std = @import("std");
const events = @import("events.zig");
const parser = @import("parser.zig");

pub const ControlConnection = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    stderr_file: std.fs.File,

    pub fn init(allocator: std.mem.Allocator, session_name: []const u8) !ControlConnection {
        var argv = [_][]const u8{ "tmux", "-C", "new-session", "-A", "-D", "-s", session_name };
        return try initWithArgv(allocator, &argv);
    }

    pub fn initAttach(allocator: std.mem.Allocator, session_name: []const u8) !ControlConnection {
        var argv = [_][]const u8{ "tmux", "-C", "attach-session", "-t", session_name };
        return try initWithArgv(allocator, &argv);
    }

    fn initWithArgv(allocator: std.mem.Allocator, argv: []const []const u8) !ControlConnection {
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        const stdin_pipe = child.stdin orelse return error.ControlModeUnavailable;
        const stdout_pipe = child.stdout orelse return error.ControlModeUnavailable;
        const stderr_pipe = child.stderr orelse return error.ControlModeUnavailable;

        var connection: ControlConnection = .{
            .allocator = allocator,
            .child = child,
            .stdin_file = stdin_pipe,
            .stdout_file = stdout_pipe,
            .stderr_file = stderr_pipe,
        };
        try connection.drainPending(200);
        return connection;
    }

    pub fn deinit(self: *ControlConnection) void {
        self.stdin_file.writeAll("detach-client\n") catch {};
        const term = self.child.kill() catch self.child.wait() catch return;
        _ = term;
    }

    pub fn sendCommand(self: *ControlConnection, command: []const u8) !void {
        try self.stdin_file.writeAll(command);
        try self.stdin_file.writeAll("\n");
    }

    pub fn drainPending(self: *ControlConnection, initial_timeout_ms: i32) !void {
        var timeout_ms = initial_timeout_ms;
        while (try stdoutReadable(self.stdout_file, timeout_ms)) {
            const maybe_line = try readLineAlloc(self.allocator, self.stdout_file, 1 << 20);
            if (maybe_line == null) return;
            defer self.allocator.free(maybe_line.?);
            _ = try parser.parseLine(maybe_line.?);
            timeout_ms = 10;
        }
    }

    pub fn runCommandBlock(self: *ControlConnection, command: []const u8) !events.CommandBlock {
        try self.sendCommand(command);

        var block_started = false;
        var block = events.CommandBlock.init(self.allocator, .{ .timestamp = 0, .command_number = 0, .flags = 0 });
        errdefer block.deinit();

        while (true) {
            const maybe_line = try readLineAlloc(self.allocator, self.stdout_file, 1 << 20);
            const line = maybe_line orelse return error.UnexpectedEof;
            defer self.allocator.free(line);
            const event = try parser.parseLine(line);

            switch (event) {
                .begin => |boundary| {
                    if (!block_started) {
                        block.deinit();
                        block = events.CommandBlock.init(self.allocator, boundary);
                        block_started = true;
                    }
                },
                .output => |output_line| {
                    if (!block_started) continue;
                    try block.output_lines.append(try self.allocator.dupe(u8, output_line));
                },
                .pane_output => {},
                .end => |boundary| {
                    if (!block_started) continue;
                    if (boundary.command_number != block.boundary.command_number) continue;
                    block.completed = true;
                    return block;
                },
                .command_error => |boundary| {
                    if (!block_started) continue;
                    if (boundary.command_number != block.boundary.command_number) continue;
                    block.completed = true;
                    block.failed = true;
                    return block;
                },
                .notification => {},
                .exit => return error.ControlModeExited,
            }
        }
    }

    pub fn drainEvents(self: *ControlConnection, initial_timeout_ms: i32, context: anytype, handler: anytype) !void {
        var timeout_ms = initial_timeout_ms;
        while (try stdoutReadable(self.stdout_file, timeout_ms)) {
            const maybe_line = try readLineAlloc(self.allocator, self.stdout_file, 1 << 20);
            if (maybe_line == null) return;
            defer self.allocator.free(maybe_line.?);
            try handler(context, try parser.parseLine(maybe_line.?));
            timeout_ms = 10;
        }
    }
};

fn readLineAlloc(allocator: std.mem.Allocator, file: std.fs.File, max_bytes: usize) !?[]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();
    var byte_buffer: [1]u8 = undefined;

    while (true) {
        const bytes_read = try file.read(&byte_buffer);
        if (bytes_read == 0) {
            if (buffer.items.len == 0) return null;
            break;
        }
        const byte = byte_buffer[0];

        if (byte == '\n') break;
        try buffer.append(byte);
        if (buffer.items.len > max_bytes) return error.MessageTooLarge;
    }

    return try buffer.toOwnedSlice();
}

fn stdoutReadable(file: std.fs.File, timeout_ms: i32) !bool {
    var pollfds = [_]std.posix.pollfd{
        .{
            .fd = file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };

    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return false;
    return (pollfds[0].revents & std.posix.POLL.IN) != 0;
}
