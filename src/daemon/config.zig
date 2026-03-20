const std = @import("std");
const muxly = @import("muxly");

pub const ParseError = error{
    InvalidArguments,
    ShowUsage,
};

pub const usage =
    \\usage: muxlyd [--transport SPEC] [--socket PATH] [--i-know-this-is-unencrypted-and-unauthenticated]
    \\
    \\  --transport   listen on unix, tcp, or prefixed unsafe+tcp transport specs
    \\  --socket      legacy alias for a unix-domain socket path
    \\  --i-know-this-is-unencrypted-and-unauthenticated
    \\                allow tcp listeners outside loopback/link-local ranges
    \\  --help        show this help text
    \\
;

pub const Config = struct {
    allocator: std.mem.Allocator,
    transport: muxly.transport.Address,

    pub fn load(allocator: std.mem.Allocator, argv: []const []const u8) !Config {
        const default_transport_spec = try muxly.api.transportSpecFromEnv(allocator);
        defer allocator.free(default_transport_spec);

        var transport_spec: []const u8 = default_transport_spec;
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

            if (std.mem.eql(u8, arg, muxly.transport.unsafe_tcp_flag)) {
                allow_insecure_tcp = true;
                continue;
            }

            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return error.ShowUsage;
            }

            return error.InvalidArguments;
        }

        const effective_spec = if (allow_insecure_tcp)
            try muxly.transport.withUnsafeTcpPrefix(allocator, transport_spec)
        else
            try allocator.dupe(u8, transport_spec);
        defer allocator.free(effective_spec);

        return .{
            .allocator = allocator,
            .transport = try muxly.transport.Address.parse(allocator, effective_spec),
        };
    }

    pub fn deinit(self: *Config) void {
        self.transport.deinit(self.allocator);
    }
};
