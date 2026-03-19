const std = @import("std");
const muxly = @import("muxly");
const viewer_app = muxly.viewer_app;

const Viewport = struct {
    rows: u16 = 24,
    cols: u16 = 80,
};

const TerminalGuard = struct {
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    saved_termios: ?std.posix.termios,

    fn init(stdin_file: std.fs.File, stdout_file: std.fs.File) !TerminalGuard {
        var guard = TerminalGuard{
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .saved_termios = null,
        };

        if (std.posix.isatty(stdin_file.handle)) {
            const original = try std.posix.tcgetattr(stdin_file.handle);
            var raw = original;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            try std.posix.tcsetattr(stdin_file.handle, .NOW, raw);
            guard.saved_termios = original;
        }

        try stdout_file.writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
        return guard;
    }

    fn deinit(self: *TerminalGuard) void {
        if (self.saved_termios) |termios| {
            std.posix.tcsetattr(self.stdin_file.handle, .NOW, termios) catch {};
        }
        self.stdout_file.writeAll("\x1b[?25h\x1b[?1049l") catch {};
    }
};

const SignalGuards = struct {
    old_int: std.posix.Sigaction,
    old_term: std.posix.Sigaction,
    old_winch: std.posix.Sigaction,

    fn install() SignalGuards {
        live_exit_requested.store(false, .monotonic);
        live_resize_requested.store(false, .monotonic);

        var action = std.mem.zeroes(std.posix.Sigaction);
        action.handler = .{ .handler = handleSignal };
        action.mask = std.posix.sigemptyset();
        action.flags = 0;

        var guards: SignalGuards = undefined;
        std.posix.sigaction(std.posix.SIG.INT, &action, &guards.old_int);
        std.posix.sigaction(std.posix.SIG.TERM, &action, &guards.old_term);
        std.posix.sigaction(std.posix.SIG.WINCH, &action, &guards.old_winch);
        return guards;
    }

    fn deinit(self: *const SignalGuards) void {
        std.posix.sigaction(std.posix.SIG.INT, &self.old_int, null);
        std.posix.sigaction(std.posix.SIG.TERM, &self.old_term, null);
        std.posix.sigaction(std.posix.SIG.WINCH, &self.old_winch, null);
    }
};

var live_exit_requested = std.atomic.Value(bool).init(false);
var live_resize_requested = std.atomic.Value(bool).init(false);

fn handleSignal(signal: i32) callconv(.c) void {
    switch (signal) {
        std.posix.SIG.INT, std.posix.SIG.TERM => live_exit_requested.store(true, .monotonic),
        std.posix.SIG.WINCH => live_resize_requested.store(true, .monotonic),
        else => {},
    }
}

const InputState = enum {
    idle,
    quit,
    closed,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const default_socket_path = try muxly.api.socketPathFromEnv(allocator);
    defer allocator.free(default_socket_path);
    const config = viewer_app.parseArgs(default_socket_path, args) catch |err| switch (err) {
        error.ShowUsage => {
            try std.fs.File.stderr().writeAll(viewer_app.usage);
            return;
        },
        else => return err,
    };

    const stdout_file = std.fs.File.stdout();
    const run_mode = viewer_app.selectRunMode(
        std.posix.isatty(stdout_file.handle),
        config.snapshot_requested,
    );

    switch (run_mode) {
        .snapshot => {
            const frame = try buildFrame(allocator, config.socket_path);
            defer allocator.free(frame);
            try stdout_file.writeAll(frame);
        },
        .live => try runLiveViewer(
            allocator,
            config.socket_path,
            std.fs.File.stdin(),
            stdout_file,
            config.refresh_ms,
        ),
    }
}

fn runLiveViewer(
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    refresh_ms: u32,
) !void {
    var signal_guards = SignalGuards.install();
    defer signal_guards.deinit();

    var terminal_guard = try TerminalGuard.init(stdin_file, stdout_file);
    defer terminal_guard.deinit();

    var viewport = readViewport(stdout_file);
    var force_redraw = true;
    var previous_frame: ?[]u8 = null;
    defer if (previous_frame) |frame| allocator.free(frame);

    while (!live_exit_requested.load(.monotonic)) {
        if (live_resize_requested.swap(false, .monotonic)) force_redraw = true;

        const updated_viewport = readViewport(stdout_file);
        if (updated_viewport.rows != viewport.rows or updated_viewport.cols != viewport.cols) {
            viewport = updated_viewport;
            force_redraw = true;
        }

        const frame = try buildFrame(allocator, socket_path);
        defer allocator.free(frame);

        if (force_redraw or previous_frame == null or !std.mem.eql(u8, previous_frame.?, frame)) {
            try stdout_file.writeAll("\x1b[2J\x1b[H");
            try stdout_file.writeAll(frame);

            if (previous_frame) |previous| allocator.free(previous);
            previous_frame = try allocator.dupe(u8, frame);
            force_redraw = false;
        }

        switch (try pollInput(stdin_file, @intCast(refresh_ms))) {
            .idle => {},
            .quit, .closed => break,
        }
    }
}

fn buildFrame(allocator: std.mem.Allocator, socket_path: []const u8) ![]u8 {
    const response = try muxly.api.viewGet(allocator, socket_path);
    defer allocator.free(response);

    const parsed_response = try std.json.parseFromSlice(std.json.Value, allocator, response, .{
        .allocate = .alloc_always,
    });
    defer parsed_response.deinit();

    if (parsed_response.value != .object) return allocator.dupe(u8, response);

    const result = parsed_response.value.object.get("result") orelse {
        return allocator.dupe(u8, response);
    };

    var rendered = std.array_list.Managed(u8).init(allocator);
    errdefer rendered.deinit();
    try muxly.viewer_render.renderDocumentValue(allocator, result, rendered.writer());
    return rendered.toOwnedSlice();
}

fn readViewport(file: std.fs.File) Viewport {
    var winsize: std.posix.winsize = .{
        .row = 0,
        .col = 0,
        .xpixel = 0,
        .ypixel = 0,
    };
    const rc = std.posix.system.ioctl(file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(rc) == .SUCCESS and winsize.row != 0 and winsize.col != 0) {
        return .{
            .rows = winsize.row,
            .cols = winsize.col,
        };
    }
    return .{};
}

fn pollInput(stdin_file: std.fs.File, timeout_ms: i32) !InputState {
    var pollfds = [_]std.posix.pollfd{
        .{
            .fd = stdin_file.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
    };

    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return .idle;

    const revents = pollfds[0].revents;
    if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
        return .closed;
    }
    if ((revents & std.posix.POLL.IN) == 0) return .idle;

    var input_buffer: [64]u8 = undefined;
    const bytes_read = try stdin_file.read(&input_buffer);
    if (bytes_read == 0) return .closed;

    for (input_buffer[0..bytes_read]) |byte| {
        if (byte == 'q' or byte == 'Q') return .quit;
    }
    return .idle;
}
