const std = @import("std");
const transport = @import("../lib/transport.zig");

pub const default_refresh_ms: u32 = 150;

pub const RunMode = enum {
    live,
    snapshot,
};

pub const Config = struct {
    transport_spec: []const u8,
    snapshot_requested: bool = false,
    refresh_ms: u32 = default_refresh_ms,
    allow_insecure_tcp: bool = false,
};

pub const ParseError = error{
    InvalidArguments,
    ShowUsage,
};

pub const usage =
    \\usage: muxview [--transport SPEC] [--socket PATH] [--snapshot] [--i-know-this-is-unencrypted-and-unauthenticated]
    \\
    \\  --snapshot    render one snapshot and exit
    \\  --transport   connect using a unix, tcp, ssh, http, h2, or h3wt transport spec
    \\  --socket      legacy alias for a unix-domain socket path; defaults to
    \\                ${XDG_RUNTIME_DIR}/muxly.sock or /run/user/<uid>/muxly.sock
    \\  --i-know-this-is-unencrypted-and-unauthenticated
    \\                allow tcp/http/h2 transports outside loopback/link-local ranges
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

pub fn parseArgs(default_transport_spec: []const u8, args: []const []const u8) ParseError!Config {
    var config = Config{
        .transport_spec = default_transport_spec,
    };

    var index: usize = if (args.len > 0) 1 else 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--snapshot")) {
            config.snapshot_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--transport")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.transport_spec = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--socket")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            config.transport_spec = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, transport.unsafe_tcp_flag)) {
            config.allow_insecure_tcp = true;
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
