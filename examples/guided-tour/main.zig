const std = @import("std");
const muxly = @import("muxly");

const Viewport = struct {
    rows: u16 = 24,
    cols: u16 = 80,
};

const Config = struct {
    snapshot: bool = false,
    step: usize = muxly.demo.guided_tour.total_steps - 1,
    rows: u16 = 24,
    cols: u16 = 80,
};

const TerminalGuard = struct {
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    saved_termios: ?std.posix.termios,

    fn init(stdin_file: std.fs.File, stdout_file: std.fs.File) !TerminalGuard {
        var guard = TerminalGuard{ .stdin_file = stdin_file, .stdout_file = stdout_file, .saved_termios = null };
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
        if (self.saved_termios) |termios| std.posix.tcsetattr(self.stdin_file.handle, .NOW, termios) catch {};
        self.stdout_file.writeAll("\x1b[?25h\x1b[?1049l") catch {};
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = try parseArgs(args);
    const stdout_file = std.fs.File.stdout();
    if (config.snapshot or !std.posix.isatty(stdout_file.handle)) {
        const frame = try muxly.demo.guided_tour.renderStep(allocator, config.step, config.rows, config.cols);
        defer allocator.free(frame);
        try stdout_file.writeAll(frame);
        return;
    }

    try runLive(allocator, config, std.fs.File.stdin(), stdout_file);
}

fn runLive(
    allocator: std.mem.Allocator,
    config: Config,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
) !void {
    var terminal_guard = try TerminalGuard.init(stdin_file, stdout_file);
    defer terminal_guard.deinit();

    var step: usize = 0;
    var viewport = readViewport(stdout_file, config);
    var next_tick = std.time.milliTimestamp();

    while (true) {
        const updated_viewport = readViewport(stdout_file, config);
        if (updated_viewport.rows != viewport.rows or updated_viewport.cols != viewport.cols) viewport = updated_viewport;

        const frame = try muxly.demo.guided_tour.renderStep(allocator, step, viewport.rows, viewport.cols);
        defer allocator.free(frame);
        try stdout_file.writeAll("\x1b[2J\x1b[H");
        try stdout_file.writeAll(frame);

        const now = std.time.milliTimestamp();
        if (now >= next_tick) {
            step = (step + 1) % muxly.demo.guided_tour.total_steps;
            next_tick = now + 1100;
        }

        if (try pollInput(stdin_file, 120)) break;
    }
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var index: usize = if (args.len > 0) 1 else 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--snapshot")) {
            config.snapshot = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--step")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.step = try std.fmt.parseInt(usize, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--rows")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.rows = try std.fmt.parseInt(u16, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--cols")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.cols = try std.fmt.parseInt(u16, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.fs.File.stdout().writeAll(
                "usage: muxguide [--snapshot] [--step N] [--rows N] [--cols N]\n",
            );
            std.process.exit(0);
        }
        return error.InvalidArguments;
    }
    return config;
}

fn readViewport(stdout_file: std.fs.File, config: Config) Viewport {
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.posix.system.ioctl(stdout_file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(rc) == .SUCCESS and winsize.row != 0 and winsize.col != 0) {
        return .{ .rows = winsize.row, .cols = winsize.col };
    }
    return .{ .rows = config.rows, .cols = config.cols };
}

fn pollInput(stdin_file: std.fs.File, timeout_ms: i32) !bool {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = stdin_file.handle,
        .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return false;
    const revents = pollfds[0].revents;
    if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) return true;
    if ((revents & std.posix.POLL.IN) == 0) return false;

    var input_buffer: [32]u8 = undefined;
    const bytes_read = try stdin_file.read(&input_buffer);
    if (bytes_read == 0) return true;
    for (input_buffer[0..bytes_read]) |byte| {
        if (byte == 'q' or byte == 'Q') return true;
    }
    return false;
}
