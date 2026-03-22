const std = @import("std");
const muxly = @import("muxly");
const runtime_config = muxly.runtime_config;

pub const ParseError = error{
    InvalidArguments,
    ShowUsage,
};

pub const usage =
    \\usage: muxlyd [--transport SPEC] [--socket PATH] [--config PATH] [--max-message-bytes N] [--max-document-content-bytes N] [--i-know-this-is-unencrypted-and-unauthenticated]
    \\
    \\  --transport   listen on unix, tcp, http, h2, or h3wt transport specs
    \\  --socket      legacy alias for a unix-domain socket path; defaults to
    \\                ${XDG_RUNTIME_DIR}/muxly.sock or /run/user/<uid>/muxly.sock
    \\  --config      load runtime policy from JSON config at PATH
    \\  --max-message-bytes
    \\                override the buffered whole-message cap
    \\  --max-document-content-bytes
    \\                override the aggregate document content cap
    \\  --i-know-this-is-unencrypted-and-unauthenticated
    \\                allow tcp/http/h2 listeners outside loopback/link-local ranges
    \\  --help        show this help text
    \\
;

pub const Config = struct {
    allocator: std.mem.Allocator,
    transport: muxly.transport.Address,
    runtime_limits: runtime_config.RuntimeLimits,

    pub fn load(allocator: std.mem.Allocator, argv: []const []const u8) !Config {
        const default_transport_spec = try muxly.api.transportSpecFromEnv(allocator);
        defer allocator.free(default_transport_spec);

        var transport_spec: []const u8 = default_transport_spec;
        var allow_insecure_tcp = false;
        var explicit_config_path: ?[]const u8 = null;
        var cli_max_message_bytes: ?usize = null;
        var cli_max_document_content_bytes: ?usize = null;

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

            if (std.mem.eql(u8, arg, "--config")) {
                index += 1;
                if (index >= argv.len) return error.InvalidArguments;
                explicit_config_path = argv[index];
                continue;
            }

            if (std.mem.eql(u8, arg, "--max-message-bytes")) {
                index += 1;
                if (index >= argv.len) return error.InvalidArguments;
                cli_max_message_bytes = std.fmt.parseInt(usize, argv[index], 10) catch return error.InvalidArguments;
                if (cli_max_message_bytes.? == 0) return error.InvalidArguments;
                continue;
            }

            if (std.mem.eql(u8, arg, "--max-document-content-bytes")) {
                index += 1;
                if (index >= argv.len) return error.InvalidArguments;
                cli_max_document_content_bytes = std.fmt.parseInt(usize, argv[index], 10) catch return error.InvalidArguments;
                if (cli_max_document_content_bytes.? == 0) return error.InvalidArguments;
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

        var runtime_limits = try runtime_config.loadDaemonLimits(allocator, explicit_config_path);
        if (cli_max_message_bytes) |value| runtime_limits.max_message_bytes = value;
        if (cli_max_document_content_bytes) |value| runtime_limits.max_document_content_bytes = value;

        return .{
            .allocator = allocator,
            .transport = try muxly.transport.Address.parse(allocator, effective_spec),
            .runtime_limits = runtime_limits,
        };
    }

    pub fn deinit(self: *Config) void {
        self.transport.deinit(self.allocator);
    }
};
