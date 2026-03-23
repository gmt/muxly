const std = @import("std");
const muxly = @import("muxly");
const viewer_app = muxly.viewer_app;
const viewer_state = @import("state.zig");

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
        enableMouseTracking(stdout_file);
        return guard;
    }

    fn deinit(self: *TerminalGuard) void {
        disableMouseTracking(self.stdout_file);
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

const InputAction = enum {
    none,
    quit,
    closed,
    select_next,
    select_prev,
    drill_in,
    back_out,
    toggle_elide,
    toggle_follow_tail,
    reset_view,
    pane_input,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const default_transport_spec = try muxly.api.transportSpecFromEnv(allocator);
    defer allocator.free(default_transport_spec);
    const config = viewer_app.parseArgs(default_transport_spec, args) catch |err| switch (err) {
        error.ShowUsage => {
            try std.fs.File.stderr().writeAll(viewer_app.usage);
            return;
        },
        else => return err,
    };
    if (config.allow_insecure_tcp and muxly.trds.isDescriptor(config.transport_spec)) {
        try std.fs.File.stderr().writeAll(viewer_app.usage);
        return;
    }
    const transport_input = if (config.allow_insecure_tcp)
        try muxly.transport.withUnsafeTcpPrefix(allocator, config.transport_spec)
    else
        try allocator.dupe(u8, config.transport_spec);
    defer allocator.free(transport_input);
    var resolved_transport = try muxly.client.resolveTransportInput(allocator, transport_input, .{
        .tls_ca_file = config.tls_ca_file,
        .tls_pin_sha256 = config.tls_pin_sha256,
        .tls_server_name = config.tls_server_name,
    });
    defer resolved_transport.deinit(allocator);
    const transport_spec = resolved_transport.transport_spec;

    const stdout_file = std.fs.File.stdout();
    const run_mode = viewer_app.selectRunMode(
        std.posix.isatty(stdout_file.handle),
        config.snapshot_requested,
    );

    switch (run_mode) {
        .snapshot => {
            const frame = try buildFrame(allocator, transport_spec, .{});
            defer allocator.free(frame);
            try stdout_file.writeAll(frame);
        },
        .live => try runLiveViewer(
            allocator,
            transport_spec,
            std.fs.File.stdin(),
            stdout_file,
            config.refresh_ms,
        ),
    }
}

fn runLiveViewer(
    allocator: std.mem.Allocator,
    transport_spec: []const u8,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,
    refresh_ms: u32,
) !void {
    var signal_guards = SignalGuards.install();
    defer signal_guards.deinit();

    var terminal_guard = try TerminalGuard.init(stdin_file, stdout_file);
    defer terminal_guard.deinit();

    var session = try viewer_state.ViewerSession.init(allocator, transport_spec);
    defer session.deinit();

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

        const chrome_rows: u16 = 2;
        const content_rows = if (viewport.rows > chrome_rows) viewport.rows - chrome_rows else 1;

        const selected_region = session.selectedRegion();
        const focused_id: ?u64 = if (selected_region) |r| r.node_id else null;

        var projection_params = std.array_list.Managed(u8).init(allocator);
        defer projection_params.deinit();
        muxly.projection.writeRequestJson(projection_params.writer(), .{
            .rows = content_rows,
            .cols = viewport.cols,
            .local_state = .{ .focused_node_id = focused_id },
        }) catch {
            std.Thread.sleep(@as(u64, refresh_ms) * 1_000_000);
            continue;
        };

        const response = session.client.request("projection.get", projection_params.items) catch {
            std.Thread.sleep(@as(u64, refresh_ms) * 1_000_000);
            continue;
        };
        defer allocator.free(response);

        const parsed_response = std.json.parseFromSlice(std.json.Value, allocator, response, .{
            .allocate = .alloc_always,
        }) catch continue;
        defer parsed_response.deinit();

        if (parsed_response.value != .object) continue;
        const result = parsed_response.value.object.getPtr("result") orelse continue;

        var frame = muxly.viewer_render.parseProjectionValue(allocator, result.*) catch continue;
        defer frame.deinit(allocator);

        session.refreshRegions(&frame);
        session.drainTtyOutput();
        session.overlayTtyFrame(&frame);

        var rendered = std.array_list.Managed(u8).init(allocator);
        defer rendered.deinit();
        muxly.viewer_render.renderProjectionFrame(allocator, &frame, rendered.writer()) catch continue;

        writeStatusBar(&rendered, &session, viewport.cols) catch {};

        const rendered_frame = rendered.toOwnedSlice() catch continue;
        defer allocator.free(rendered_frame);

        if (force_redraw or previous_frame == null or !std.mem.eql(u8, previous_frame.?, rendered_frame)) {
            try stdout_file.writeAll("\x1b[2J\x1b[H");
            try stdout_file.writeAll(rendered_frame);

            if (previous_frame) |previous| allocator.free(previous);
            previous_frame = allocator.dupe(u8, rendered_frame) catch null;
            force_redraw = false;
        }

        const action = pollInput(stdin_file, &session, @intCast(refresh_ms)) catch .none;
        switch (action) {
            .quit, .closed => break,
            .select_next => session.selectNext(),
            .select_prev => session.selectPrev(),
            .drill_in => session.drillIn(),
            .back_out => session.backOut(),
            .toggle_elide => session.toggleElide(),
            .toggle_follow_tail => session.toggleFollowTail(),
            .reset_view => session.resetView(),
            .pane_input, .none => {},
        }
    }
}

fn writeStatusBar(buffer: *std.array_list.Managed(u8), session: *const viewer_state.ViewerSession, cols: u16) !void {
    const writer = buffer.writer();
    const mode_label: []const u8 = switch (session.local.mode) {
        .navigate => "NAV",
        .tty_interact => "TTY",
    };

    var sel_label_buf: [128]u8 = undefined;
    const sel_label = if (session.selectedRegion()) |region|
        std.fmt.bufPrint(&sel_label_buf, "{s}", .{region.title}) catch "?"
    else
        "-";

    const scope_label: []const u8 = if (session.local.shared_view_root_node_id != null) "scoped" else "root";

    try writer.print("\x1b[7m [{s}] {s} | {s}", .{ mode_label, sel_label, scope_label });

    if (session.local.status_message.len > 0) {
        try writer.print(" | {s}", .{session.local.status_message});
    }

    var wrote: usize = 10 + mode_label.len + sel_label.len + scope_label.len + session.local.status_message.len;
    while (wrote < cols) : (wrote += 1) {
        try writer.writeByte(' ');
    }
    try writer.writeAll("\x1b[0m\n");

    try writer.writeAll("\x1b[7m j/k:nav Enter:drill Esc:back e:elide t:tail r:reset q:quit ");
    wrote = 60;
    while (wrote < cols) : (wrote += 1) {
        try writer.writeByte(' ');
    }
    try writer.writeAll("\x1b[0m");
}

fn buildFrame(allocator: std.mem.Allocator, socket_path: []const u8, viewport: Viewport) ![]u8 {
    const response = try muxly.api.projectionGet(allocator, socket_path, .{
        .rows = viewport.rows,
        .cols = viewport.cols,
    });
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
    try muxly.viewer_render.renderProjectionValue(allocator, result, rendered.writer());
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

fn pollInput(stdin_file: std.fs.File, session: *viewer_state.ViewerSession, timeout_ms: i32) !InputAction {
    var pollfds = [_]std.posix.pollfd{
        .{
            .fd = stdin_file.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
            .revents = 0,
        },
    };

    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready == 0) return .none;

    const revents = pollfds[0].revents;
    if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
        return .closed;
    }
    if ((revents & std.posix.POLL.IN) == 0) return .none;

    var input_buffer: [64]u8 = undefined;
    const bytes_read = try stdin_file.read(&input_buffer);
    if (bytes_read == 0) return .closed;

    const input = input_buffer[0..bytes_read];

    if (session.local.mode == .tty_interact) {
        if (bytes_read == 1 and input[0] == 0x1b) return .back_out;
        if (bytes_read >= 3 and input[0] == 0x1b and input[1] == '[') {
            if (bytes_read >= 4 and input[2] == '1' and input[3] == '~') return .back_out;
        }
        session.sendTtyInput(input);
        return .pane_input;
    }

    if (bytes_read >= 3 and input[0] == 0x1b and input[1] == '[') {
        if (input[2] == '<') {
            if (parseMouseClick(input)) |click| {
                selectRegionByPosition(session, click.x, click.y);
                return .none;
            }
        }
        return switch (input[2]) {
            'A' => .select_prev,
            'B' => .select_next,
            'C' => .drill_in,
            'D' => .back_out,
            else => .none,
        };
    }

    if (bytes_read == 1) {
        return switch (input[0]) {
            'q', 'Q' => .quit,
            'j' => .select_next,
            'k' => .select_prev,
            '\r', '\n' => .drill_in,
            0x1b => .back_out,
            'e' => .toggle_elide,
            't' => .toggle_follow_tail,
            'r' => .reset_view,
            else => .none,
        };
    }

    return .none;
}

fn enableMouseTracking(stdout_file: std.fs.File) void {
    stdout_file.writeAll("\x1b[?1000h\x1b[?1006h") catch {};
}

fn disableMouseTracking(stdout_file: std.fs.File) void {
    stdout_file.writeAll("\x1b[?1006l\x1b[?1000l") catch {};
}

fn parseMouseClick(input: []const u8) ?struct { x: u16, y: u16 } {
    if (input.len < 6) return null;
    if (input[0] != 0x1b or input[1] != '[' or input[2] != '<') return null;

    var parts = std.mem.splitScalar(u8, input[3..], ';');
    const button_str = parts.next() orelse return null;
    const x_str = parts.next() orelse return null;
    const rest = parts.rest();

    const button = std.fmt.parseInt(u8, button_str, 10) catch return null;
    if ((button & 0x40) != 0 or (button & 0x20) != 0) return null;
    const base_button = button & 0x03;
    if (base_button > 2) return null;

    const x = std.fmt.parseInt(u16, x_str, 10) catch return null;

    var y_end: usize = 0;
    while (y_end < rest.len and rest[y_end] >= '0' and rest[y_end] <= '9') : (y_end += 1) {}
    if (y_end == 0) return null;
    const y = std.fmt.parseInt(u16, rest[0..y_end], 10) catch return null;

    if (y_end < rest.len and rest[y_end] == 'M') {
        return .{ .x = x -| 1, .y = y -| 1 };
    }
    return null;
}

fn selectRegionByPosition(session: *viewer_state.ViewerSession, x: u16, y: u16) void {
    var best_index: ?usize = null;
    var best_area: u32 = std.math.maxInt(u32);

    for (session.regions.items, 0..) |region, index| {
        const x_u32: u32 = x;
        const y_u32: u32 = y;
        const region_left: u32 = region.x;
        const region_top: u32 = region.y;
        const region_right = region_left + region.width;
        const region_bottom = region_top + region.height;

        if (x_u32 >= region_left and x_u32 < region_right and
            y_u32 >= region_top and y_u32 < region_bottom)
        {
            const area: u32 = @as(u32, region.width) * @as(u32, region.height);
            if (area < best_area) {
                best_area = area;
                best_index = index;
            }
        }
    }

    if (best_index) |index| {
        session.local.selected_index = index;
    }
}
