const std = @import("std");

pub const default_refresh_ms: u32 = 150;

pub const RunMode = enum {
    live,
    snapshot,
};

pub const Config = struct {
    socket_path: []const u8,
    snapshot_requested: bool = false,
    refresh_ms: u32 = default_refresh_ms,
};

pub const ParseError = error{
    InvalidArguments,
    ShowUsage,
};

pub const usage =
    \\usage: muxview [--socket PATH] [--snapshot]
    \\
    \\  --snapshot    render one snapshot and exit
    \\  --socket      connect to an explicit muxly socket
    \\  --help        show this help text
    \\
    \\interactive keys (live mode):
    \\  j/k, arrows   select region
    \\  Enter, right   drill into selected region
    \\  Esc, left      back out / exit focused mode
    \\  e              toggle elide on selected region
    \\  t              toggle follow-tail on tty region
    \\  r              reset view (clear root and elision)
    \\  q              quit
    \\
;

pub fn parseArgs(default_socket_path: []const u8, args: []const []const u8) ParseError!Config {
    var config = Config{
        .socket_path = default_socket_path,
    };

    var index: usize = if (args.len > 0) 1 else 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--snapshot")) {
            config.snapshot_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--socket")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.socket_path = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.ShowUsage;
        }
        return error.InvalidArguments;
    }

    return config;
}

pub fn selectRunMode(stdout_is_tty: bool, snapshot_requested: bool) RunMode {
    if (snapshot_requested or !stdout_is_tty) return .snapshot;
    return .live;
}
