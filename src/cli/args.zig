const std = @import("std");
const transport = @import("../lib/transport.zig");

pub const Parsed = struct {
    transport_spec: []const u8,
    command_index: usize,
    allow_insecure_tcp: bool,
};

pub const ParseError = error{
    InvalidArguments,
    ShowUsage,
};

pub fn parse(argv: []const []const u8, default_transport_spec: []const u8) ParseError!Parsed {
    var transport_spec = default_transport_spec;
    var allow_insecure_tcp = false;

    var index: usize = if (argv.len > 0) 1 else 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];

        if (std.mem.eql(u8, arg, "--transport")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            transport_spec = argv[index];
            continue;
        }

        if (std.mem.eql(u8, arg, "--socket")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            transport_spec = argv[index];
            continue;
        }

        if (std.mem.eql(u8, arg, transport.unsafe_tcp_flag)) {
            allow_insecure_tcp = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.ShowUsage;
        }

        return .{
            .transport_spec = transport_spec,
            .command_index = index,
            .allow_insecure_tcp = allow_insecure_tcp,
        };
    }

    return .{
        .transport_spec = transport_spec,
        .command_index = index,
        .allow_insecure_tcp = allow_insecure_tcp,
    };
}
