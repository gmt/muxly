const std = @import("std");
const transport = @import("../lib/transport.zig");

pub const Parsed = struct {
    transport_spec: []const u8,
    command_index: usize,
    allow_insecure_tcp: bool,
    tls_ca_file: ?[]const u8 = null,
    tls_pin_sha256: ?[]const u8 = null,
    tls_server_name: ?[]const u8 = null,
};

pub const ParseError = error{
    InvalidArguments,
    ShowUsage,
};

pub fn parse(argv: []const []const u8, default_transport_spec: []const u8) ParseError!Parsed {
    var transport_spec = default_transport_spec;
    var allow_insecure_tcp = false;
    var tls_ca_file: ?[]const u8 = null;
    var tls_pin_sha256: ?[]const u8 = null;
    var tls_server_name: ?[]const u8 = null;

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

        if (std.mem.eql(u8, arg, "--tls-ca-file")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            tls_ca_file = argv[index];
            continue;
        }

        if (std.mem.eql(u8, arg, "--tls-pin-sha256")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            tls_pin_sha256 = argv[index];
            continue;
        }

        if (std.mem.eql(u8, arg, "--tls-server-name")) {
            index += 1;
            if (index >= argv.len) return error.InvalidArguments;
            tls_server_name = argv[index];
            continue;
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.ShowUsage;
        }

        return .{
            .transport_spec = transport_spec,
            .command_index = index,
            .allow_insecure_tcp = allow_insecure_tcp,
            .tls_ca_file = tls_ca_file,
            .tls_pin_sha256 = tls_pin_sha256,
            .tls_server_name = tls_server_name,
        };
    }

    return .{
        .transport_spec = transport_spec,
        .command_index = index,
        .allow_insecure_tcp = allow_insecure_tcp,
        .tls_ca_file = tls_ca_file,
        .tls_pin_sha256 = tls_pin_sha256,
        .tls_server_name = tls_server_name,
    };
}
