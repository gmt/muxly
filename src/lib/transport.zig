//! Shared transport parsing and stream helpers for muxly client/server code.

const builtin = @import("builtin");
const std = @import("std");
const build_options = @import("build_options");
const limits = @import("../core/limits.zig");
const unix_socket = @import("../platform/unix_socket.zig");

/// Default whole-message cap used when a caller does not load runtime policy.
pub const max_message_bytes: usize = limits.default_max_message_bytes;
pub const unsafe_tcp_prefix = "unsafe+";
pub const unsafe_tcp_flag = "--i-know-this-is-unencrypted-and-unauthenticated";
pub const http_default_path = "/rpc";
pub const h3wt_default_path = "/mux";

pub const MessageReader = struct {
    allocator: std.mem.Allocator,
    pending: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) MessageReader {
        return .{
            .allocator = allocator,
            .pending = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *MessageReader) void {
        self.pending.deinit();
    }

    pub fn readMessageLine(self: *MessageReader, reader: anytype, max_bytes: usize) !?[]u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |newline_index| {
                const line = try self.allocator.dupe(u8, self.pending.items[0..newline_index]);
                const remaining_len = self.pending.items.len - newline_index - 1;
                std.mem.copyForwards(
                    u8,
                    self.pending.items[0..remaining_len],
                    self.pending.items[newline_index + 1 ..],
                );
                self.pending.items.len = remaining_len;
                return line;
            }

            var buffer: [4096]u8 = undefined;
            const bytes_read = try reader.read(&buffer);
            if (bytes_read == 0) {
                if (self.pending.items.len == 0) return null;

                const line = try self.pending.toOwnedSlice();
                self.pending = std.array_list.Managed(u8).init(self.allocator);
                return line;
            }

            try self.pending.appendSlice(buffer[0..bytes_read]);
            if (self.pending.items.len > max_bytes) return error.MessageTooLarge;
        }
    }
};

pub const Address = struct {
    allow_insecure_tcp: bool = false,
    target: Target,

    pub const Target = union(enum) {
        unix: []u8,
        tcp: TcpAddress,
        ssh: SshAddress,
        http: HttpAddress,
        h3wt: H3wtAddress,
    };

    pub const TcpAddress = struct {
        host: []u8,
        port: u16,

        pub fn resolve(self: TcpAddress) !std.net.Address {
            return try std.net.Address.resolveIp(self.host, self.port);
        }
    };

    pub const SshAddress = struct {
        destination: []u8,
        port: ?u16,
        remote_spec: []u8,
    };

    pub const HttpAddress = struct {
        host: []u8,
        port: u16,
        path: []u8,

        pub fn resolve(self: HttpAddress) !std.net.Address {
            return try std.net.Address.resolveIp(self.host, self.port);
        }
    };

    pub const H3wtAddress = struct {
        host: []u8,
        port: u16,
        path: []u8,
        certificate_hash: ?[]u8,

        pub fn resolve(self: H3wtAddress) !std.net.Address {
            return try std.net.Address.resolveIp(self.host, self.port);
        }
    };

    pub fn parse(allocator: std.mem.Allocator, spec: []const u8) !Address {
        var allow_insecure_tcp = false;
        var trimmed = spec;
        if (std.mem.startsWith(u8, trimmed, unsafe_tcp_prefix)) {
            allow_insecure_tcp = true;
            trimmed = trimmed[unsafe_tcp_prefix.len..];
        }

        if (std.mem.startsWith(u8, trimmed, "tcp://")) {
            const tcp = try parseTcp(allocator, trimmed["tcp://".len..]);
            return .{
                .allow_insecure_tcp = allow_insecure_tcp,
                .target = .{ .tcp = tcp },
            };
        }

        if (std.mem.startsWith(u8, trimmed, "ssh://")) {
            const ssh = try parseSsh(allocator, trimmed["ssh://".len..]);
            return .{
                .allow_insecure_tcp = allow_insecure_tcp,
                .target = .{ .ssh = ssh },
            };
        }

        if (std.mem.startsWith(u8, trimmed, "http://")) {
            const http = try parseHttp(allocator, trimmed["http://".len..]);
            return .{
                .allow_insecure_tcp = allow_insecure_tcp,
                .target = .{ .http = http },
            };
        }

        if (std.mem.startsWith(u8, trimmed, "h3wt://")) {
            const h3wt = try parseH3wt(allocator, trimmed["h3wt://".len..]);
            return .{
                .allow_insecure_tcp = allow_insecure_tcp,
                .target = .{ .h3wt = h3wt },
            };
        }

        if (std.mem.startsWith(u8, trimmed, "wt://")) {
            const h3wt = try parseH3wt(allocator, trimmed["wt://".len..]);
            return .{
                .allow_insecure_tcp = allow_insecure_tcp,
                .target = .{ .h3wt = h3wt },
            };
        }

        if (std.mem.startsWith(u8, trimmed, "unix://")) {
            return .{
                .allow_insecure_tcp = allow_insecure_tcp,
                .target = .{ .unix = try allocator.dupe(u8, trimmed["unix://".len..]) },
            };
        }

        if (std.mem.startsWith(u8, trimmed, "unix:")) {
            return .{
                .allow_insecure_tcp = allow_insecure_tcp,
                .target = .{ .unix = try allocator.dupe(u8, trimmed["unix:".len..]) },
            };
        }

        return .{
            .allow_insecure_tcp = allow_insecure_tcp,
            .target = .{ .unix = try allocator.dupe(u8, trimmed) },
        };
    }

    pub fn deinit(self: *Address, allocator: std.mem.Allocator) void {
        switch (self.target) {
            .unix => |path| allocator.free(path),
            .tcp => |tcp| allocator.free(tcp.host),
            .ssh => |ssh| {
                allocator.free(ssh.destination);
                allocator.free(ssh.remote_spec);
            },
            .http => |http| {
                allocator.free(http.host);
                allocator.free(http.path);
            },
            .h3wt => |h3wt| {
                allocator.free(h3wt.host);
                allocator.free(h3wt.path);
                if (h3wt.certificate_hash) |value| allocator.free(value);
            },
        }
    }

    pub fn write(self: Address, writer: anytype) !void {
        if (self.allow_insecure_tcp) {
            try writer.writeAll(unsafe_tcp_prefix);
        }

        switch (self.target) {
            .unix => |path| try writer.print("unix://{s}", .{path}),
            .tcp => |tcp| try writeTcpSpec(writer, tcp.host, tcp.port),
            .ssh => |ssh| {
                try writer.print("ssh://{s}", .{ssh.destination});
                if (ssh.port) |port| {
                    try writer.print(":{d}", .{port});
                }
                if (ssh.remote_spec.len > 0) {
                    try writer.writeByte('/');
                    try writer.writeAll(ssh.remote_spec);
                }
            },
            .http => |http| try writeHttpLikeSpec(writer, "http", http.host, http.port, http.path, null),
            .h3wt => |h3wt| try writeHttpLikeSpec(writer, "h3wt", h3wt.host, h3wt.port, h3wt.path, h3wt.certificate_hash),
        }
    }

    pub fn isTcpLocalOnly(self: Address) !bool {
        return switch (self.target) {
            .tcp => |tcp| isLocalOnlyTcpAddress(try tcp.resolve()),
            .http => |http| isLocalOnlyTcpAddress(try http.resolve()),
            else => true,
        };
    }

    pub fn validateForClient(self: Address) !void {
        switch (self.target) {
            .tcp, .http => {
                if (!self.allow_insecure_tcp and !(try self.isTcpLocalOnly())) {
                    return error.InsecureTcpAddressRequiresExplicitOverride;
                }
            },
            .unix, .ssh, .h3wt => {},
        }
    }

    pub fn validateForServer(self: Address) !void {
        switch (self.target) {
            .tcp, .http => {
                if (!self.allow_insecure_tcp and !(try self.isTcpLocalOnly())) {
                    return error.InsecureTcpAddressRequiresExplicitOverride;
                }
            },
            .unix, .h3wt => {},
            .ssh => return error.UnsupportedTransportForDaemon,
        }
    }
};

pub fn withUnsafeTcpPrefix(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, spec, unsafe_tcp_prefix)) {
        return try allocator.dupe(u8, spec);
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ unsafe_tcp_prefix, spec });
}

pub const Connection = union(enum) {
    socket: std.net.Stream,
    process: ProcessSession,

    pub fn close(self: *Connection) void {
        switch (self.*) {
            .socket => |stream| stream.close(),
            .process => |*process| process.close(),
        }
    }

    pub fn read(self: *Connection, buffer: []u8) !usize {
        return switch (self.*) {
            .socket => |stream| try stream.read(buffer),
            .process => |*process| try process.read(buffer),
        };
    }

    pub fn writeAll(self: *Connection, bytes: []const u8) !void {
        switch (self.*) {
            .socket => |stream| try stream.writeAll(bytes),
            .process => |*process| try process.writeAll(bytes),
        }
    }
};

pub const ProcessSession = struct {
    child: std.process.Child,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,

    pub fn initSsh(allocator: std.mem.Allocator, ssh: Address.SshAddress, allow_insecure_tcp: bool) !ProcessSession {
        const remote_command = try buildRemoteRelayCommand(allocator, ssh.remote_spec, allow_insecure_tcp);
        defer allocator.free(remote_command);
        const ssh_config_path = std.process.getEnvVarOwned(allocator, "MUXLY_SSH_CONFIG") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        defer if (ssh_config_path) |path| allocator.free(path);

        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        try argv.append("ssh");
        try argv.append("-T");
        if (ssh_config_path) |path| {
            try argv.append("-F");
            try argv.append(path);
        }
        var port_buffer: [16]u8 = undefined;
        if (ssh.port) |port| {
            const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{port});
            try argv.append("-p");
            try argv.append(port_text);
        }
        try argv.append(ssh.destination);
        try argv.append(remote_command);

        return try spawn(allocator, argv.items);
    }

    pub fn initHttp(allocator: std.mem.Allocator, http: Address.HttpAddress) !ProcessSession {
        return try initHttpWithMaxMessageBytes(allocator, http, max_message_bytes);
    }

    pub fn initHttpWithMaxMessageBytes(
        allocator: std.mem.Allocator,
        http: Address.HttpAddress,
        max_message_bytes_value: usize,
    ) !ProcessSession {
        var port_buffer: [16]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{http.port});

        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        const bridge = try appendBridgeCommandPrefix(allocator, &argv);
        defer bridge.deinit(allocator);
        try argv.append("http-client");
        try argv.append("--host");
        try argv.append(http.host);
        try argv.append("--port");
        try argv.append(port_text);
        try argv.append("--path");
        try argv.append(http.path);
        const max_message_bytes_text = try std.fmt.allocPrint(allocator, "{d}", .{max_message_bytes_value});
        defer allocator.free(max_message_bytes_text);
        try argv.append("--max-message-bytes");
        try argv.append(max_message_bytes_text);
        return try spawn(allocator, argv.items);
    }

    pub fn initH3wt(allocator: std.mem.Allocator, h3wt: Address.H3wtAddress) !ProcessSession {
        return try initH3wtWithMaxMessageBytes(allocator, h3wt, max_message_bytes);
    }

    pub fn initH3wtWithMaxMessageBytes(
        allocator: std.mem.Allocator,
        h3wt: Address.H3wtAddress,
        max_message_bytes_value: usize,
    ) !ProcessSession {
        var port_buffer: [16]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{h3wt.port});

        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        const bridge = try appendBridgeCommandPrefix(allocator, &argv);
        defer bridge.deinit(allocator);
        try argv.append("h3wt-client");
        try argv.append("--host");
        try argv.append(h3wt.host);
        try argv.append("--port");
        try argv.append(port_text);
        try argv.append("--path");
        try argv.append(h3wt.path);
        const max_message_bytes_text = try std.fmt.allocPrint(allocator, "{d}", .{max_message_bytes_value});
        defer allocator.free(max_message_bytes_text);
        try argv.append("--max-message-bytes");
        try argv.append(max_message_bytes_text);
        if (h3wt.certificate_hash) |hash| {
            try argv.append("--sha256");
            try argv.append(hash);
        }
        return try spawn(allocator, argv.items);
    }

    pub fn initH3wtConversation(allocator: std.mem.Allocator, h3wt: Address.H3wtAddress) !ProcessSession {
        return try initH3wtConversationWithMaxMessageBytes(allocator, h3wt, max_message_bytes);
    }

    pub fn initH3wtConversationWithMaxMessageBytes(
        allocator: std.mem.Allocator,
        h3wt: Address.H3wtAddress,
        max_message_bytes_value: usize,
    ) !ProcessSession {
        var port_buffer: [16]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{h3wt.port});

        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        const bridge = try appendBridgeCommandPrefix(allocator, &argv);
        defer bridge.deinit(allocator);
        try argv.append("h3wt-session-client");
        try argv.append("--host");
        try argv.append(h3wt.host);
        try argv.append("--port");
        try argv.append(port_text);
        try argv.append("--path");
        try argv.append(h3wt.path);
        const max_message_bytes_text = try std.fmt.allocPrint(allocator, "{d}", .{max_message_bytes_value});
        defer allocator.free(max_message_bytes_text);
        try argv.append("--max-message-bytes");
        try argv.append(max_message_bytes_text);
        if (h3wt.certificate_hash) |hash| {
            try argv.append("--sha256");
            try argv.append(hash);
        }
        return try spawn(allocator, argv.items);
    }

    pub fn close(self: *ProcessSession) void {
        self.stdin_file.close();
        self.stdout_file.close();
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
    }

    pub fn read(self: *ProcessSession, buffer: []u8) !usize {
        return try self.stdout_file.read(buffer);
    }

    pub fn writeAll(self: *ProcessSession, bytes: []const u8) !void {
        try self.stdin_file.writeAll(bytes);
    }

    fn spawn(allocator: std.mem.Allocator, argv: []const []const u8) !ProcessSession {
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;
        try child.spawn();

        const stdin_file = child.stdin orelse return error.MissingChildPipe;
        const stdout_file = child.stdout orelse return error.MissingChildPipe;
        child.stdin = null;
        child.stdout = null;

        return .{
            .child = child,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
        };
    }
};

pub const Listener = struct {
    allow_insecure_tcp: bool,
    target: Target,

    pub const Target = union(enum) {
        unix: unix_socket.Listener,
        tcp: std.net.Server,
        proxy: ProxyListener,
    };

    pub fn init(allocator: std.mem.Allocator, address: *const Address) !Listener {
        return try initWithMaxMessageBytes(allocator, address, max_message_bytes);
    }

    pub fn initWithMaxMessageBytes(
        allocator: std.mem.Allocator,
        address: *const Address,
        max_message_bytes_value: usize,
    ) !Listener {
        try address.validateForServer();

        return switch (address.target) {
            .unix => |path| .{
                .allow_insecure_tcp = address.allow_insecure_tcp,
                .target = .{ .unix = try unix_socket.Listener.init(path) },
            },
            .tcp => |tcp| .{
                .allow_insecure_tcp = address.allow_insecure_tcp,
                .target = .{ .tcp = try (try tcp.resolve()).listen(.{}) },
            },
            .http => |http| .{
                .allow_insecure_tcp = address.allow_insecure_tcp,
                .target = .{ .proxy = try ProxyListener.initHttp(allocator, address.allow_insecure_tcp, http, max_message_bytes_value) },
            },
            .h3wt => |h3wt| .{
                .allow_insecure_tcp = address.allow_insecure_tcp,
                .target = .{ .proxy = try ProxyListener.initH3wt(allocator, h3wt, max_message_bytes_value) },
            },
            .ssh => error.UnsupportedTransportForDaemon,
        };
    }

    pub fn deinit(self: *Listener) void {
        switch (self.target) {
            .unix => |*listener| listener.deinit(),
            .tcp => |*server| server.deinit(),
            .proxy => |*proxy| proxy.deinit(),
        }
    }

    pub fn accept(self: *Listener) !std.net.Server.Connection {
        return switch (self.target) {
            .unix => |*listener| try listener.accept(),
            .tcp => |*server| try server.accept(),
            .proxy => |*proxy| try proxy.accept(),
        };
    }

    pub fn writeDescription(self: *const Listener, writer: anytype) !void {
        if (self.allow_insecure_tcp) {
            try writer.writeAll(unsafe_tcp_prefix);
        }

        switch (self.target) {
            .unix => |listener| try writer.print("unix://{s}", .{listener.socket_path}),
            .tcp => |server| try writer.print("tcp://{f}", .{server.listen_address}),
            .proxy => |proxy| try writer.writeAll(proxy.description),
        }
    }
};

pub fn connect(allocator: std.mem.Allocator, address: *const Address) !Connection {
    return try connectWithMaxMessageBytes(allocator, address, max_message_bytes);
}

pub fn connectWithMaxMessageBytes(
    allocator: std.mem.Allocator,
    address: *const Address,
    max_message_bytes_value: usize,
) !Connection {
    try address.validateForClient();

    return switch (address.target) {
        .unix => |path| .{ .socket = try unix_socket.connect(path) },
        .tcp => |tcp| .{ .socket = try std.net.tcpConnectToAddress(try tcp.resolve()) },
        .ssh => |ssh| .{ .process = try ProcessSession.initSsh(allocator, ssh, address.allow_insecure_tcp) },
        .http => |http| .{ .process = try ProcessSession.initHttpWithMaxMessageBytes(allocator, http, max_message_bytes_value) },
        .h3wt => |h3wt| .{ .process = try ProcessSession.initH3wtWithMaxMessageBytes(allocator, h3wt, max_message_bytes_value) },
    };
}

pub fn readMessageLine(allocator: std.mem.Allocator, reader: anytype, max_bytes: usize) !?[]u8 {
    var message_reader = MessageReader.init(allocator);
    defer message_reader.deinit();
    return try message_reader.readMessageLine(reader, max_bytes);
}

fn parseTcp(allocator: std.mem.Allocator, spec: []const u8) !Address.TcpAddress {
    const split = try splitHostPort(spec);
    return .{
        .host = try allocator.dupe(u8, split.host),
        .port = split.port,
    };
}

fn parseSsh(allocator: std.mem.Allocator, spec: []const u8) !Address.SshAddress {
    const slash_index = std.mem.indexOfScalar(u8, spec, '/');
    const destination = if (slash_index) |index| spec[0..index] else spec;
    if (destination.len == 0) return error.InvalidTransportAddress;
    const parsed_destination = try parseSshDestination(destination);

    const remote_spec = if (slash_index) |index|
        spec[index + 1 ..]
    else
        "";

    return .{
        .destination = try allocator.dupe(u8, parsed_destination.destination),
        .port = parsed_destination.port,
        .remote_spec = try allocator.dupe(u8, remote_spec),
    };
}

fn parseHttp(allocator: std.mem.Allocator, spec: []const u8) !Address.HttpAddress {
    const parsed = try parseHttpLike(allocator, spec, 80, http_default_path, false);
    errdefer allocator.free(parsed.host);
    errdefer allocator.free(parsed.path);
    return .{
        .host = parsed.host,
        .port = parsed.port,
        .path = parsed.path,
    };
}

fn parseH3wt(allocator: std.mem.Allocator, spec: []const u8) !Address.H3wtAddress {
    const parsed = try parseHttpLike(allocator, spec, 443, h3wt_default_path, true);
    errdefer allocator.free(parsed.host);
    errdefer allocator.free(parsed.path);
    errdefer if (parsed.sha256) |value| allocator.free(value);
    return .{
        .host = parsed.host,
        .port = parsed.port,
        .path = parsed.path,
        .certificate_hash = parsed.sha256,
    };
}

const HostPort = struct { host: []const u8, port: u16 };

fn splitHostPort(spec: []const u8) !HostPort {
    return try splitHostPortWithDefault(spec, null, false);
}

fn splitHostPortAllowZero(spec: []const u8, default_port: ?u16) !HostPort {
    return try splitHostPortWithDefault(spec, default_port, true);
}

fn splitHostPortWithDefault(
    spec: []const u8,
    default_port: ?u16,
    allow_zero: bool,
) !HostPort {
    if (spec.len == 0) return error.InvalidTransportAddress;

    if (spec[0] == '[') {
        const end = std.mem.indexOfScalar(u8, spec, ']') orelse return error.InvalidTransportAddress;
        if (end + 1 == spec.len) {
            const port = default_port orelse return error.InvalidTransportAddress;
            return .{ .host = spec[1..end], .port = port };
        }
        if (spec[end + 1] != ':') return error.InvalidTransportAddress;
        const host = spec[1..end];
        const port = try parsePort(spec[end + 2 ..], allow_zero);
        return .{ .host = host, .port = port };
    }

    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse {
        const port = default_port orelse return error.InvalidTransportAddress;
        return .{ .host = spec, .port = port };
    };
    const host = spec[0..colon];
    if (host.len == 0) return error.InvalidTransportAddress;
    const port = try parsePort(spec[colon + 1 ..], allow_zero);
    return .{ .host = host, .port = port };
}

fn parsePort(port_text: []const u8, allow_zero: bool) !u16 {
    const port = try std.fmt.parseInt(u16, port_text, 10);
    if (port == 0 and !allow_zero) return error.InvalidTransportAddress;
    return port;
}

fn writeTcpSpec(writer: anytype, host: []const u8, port: u16) !void {
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        try writer.print("tcp://[{s}]:{d}", .{ host, port });
    } else {
        try writer.print("tcp://{s}:{d}", .{ host, port });
    }
}

fn parseHttpLike(
    allocator: std.mem.Allocator,
    spec: []const u8,
    default_port: u16,
    default_path: []const u8,
    allow_hash_query: bool,
) !struct { host: []u8, port: u16, path: []u8, sha256: ?[]u8 } {
    const slash_index = std.mem.indexOfScalar(u8, spec, '/');
    const question_index = std.mem.indexOfScalar(u8, spec, '?');
    const authority_end = blk: {
        if (slash_index) |index| break :blk index;
        if (question_index) |index| break :blk index;
        break :blk spec.len;
    };
    const authority = spec[0..authority_end];
    const split = try splitHostPortAllowZero(authority, default_port);

    var path = default_path;
    var query: []const u8 = "";
    if (authority_end < spec.len and spec[authority_end] == '/') {
        const path_start = authority_end;
        if (question_index) |index| {
            if (index > path_start) path = spec[path_start..index];
            query = spec[index + 1 ..];
        } else {
            path = spec[path_start..];
        }
    } else if (authority_end < spec.len and spec[authority_end] == '?') {
        query = spec[authority_end + 1 ..];
    }

    var sha256: ?[]u8 = null;
    if (query.len != 0) {
        if (!allow_hash_query) return error.InvalidTransportAddress;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            if (std.mem.startsWith(u8, entry, "sha256=")) {
                sha256 = try allocator.dupe(u8, entry["sha256=".len..]);
                continue;
            }
            return error.InvalidTransportAddress;
        }
    }

    return .{
        .host = try allocator.dupe(u8, split.host),
        .port = split.port,
        .path = try allocator.dupe(u8, path),
        .sha256 = sha256,
    };
}

fn writeHttpLikeSpec(
    writer: anytype,
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    sha256: ?[]const u8,
) !void {
    try writer.writeAll(scheme);
    try writer.writeAll("://");
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        try writer.print("[{s}]:{d}", .{ host, port });
    } else {
        try writer.print("{s}:{d}", .{ host, port });
    }
    try writer.writeAll(path);
    if (sha256) |hash| {
        try writer.writeAll("?sha256=");
        try writer.writeAll(hash);
    }
}

fn parseSshDestination(spec: []const u8) !struct { destination: []const u8, port: ?u16 } {
    if (spec.len == 0) return error.InvalidTransportAddress;

    const at_index = std.mem.lastIndexOfScalar(u8, spec, '@');
    const host_start = if (at_index) |index| index + 1 else 0;
    const host_part = spec[host_start..];
    if (host_part.len == 0) return error.InvalidTransportAddress;

    if (host_part[0] == '[') {
        const close_index = std.mem.indexOfScalar(u8, host_part, ']') orelse return error.InvalidTransportAddress;
        if (close_index == host_part.len - 1) {
            return .{
                .destination = spec,
                .port = null,
            };
        }
        if (host_part[close_index + 1] != ':') return error.InvalidTransportAddress;
        return .{
            .destination = spec[0 .. host_start + close_index + 1],
            .port = try parsePort(host_part[close_index + 2 ..], false),
        };
    }

    const colon_index = std.mem.lastIndexOfScalar(u8, host_part, ':') orelse return .{
        .destination = spec,
        .port = null,
    };

    if (std.mem.indexOfScalar(u8, host_part[0..colon_index], ':') != null) {
        return .{
            .destination = spec,
            .port = null,
        };
    }

    return .{
        .destination = spec[0 .. host_start + colon_index],
        .port = try parsePort(host_part[colon_index + 1 ..], false),
    };
}

pub const ProxyListener = struct {
    allocator: std.mem.Allocator,
    description: []u8,
    socket_path: []u8,
    ready_file_path: []u8,
    internal_listener: unix_socket.Listener,
    child: std.process.Child,

    pub fn initHttp(
        allocator: std.mem.Allocator,
        allow_insecure_tcp: bool,
        http: Address.HttpAddress,
        max_message_bytes_value: usize,
    ) !ProxyListener {
        const temp_paths = try makeProxyTempPaths(allocator, "http");
        errdefer allocator.free(temp_paths.socket_path);
        errdefer allocator.free(temp_paths.ready_path);

        const internal_listener = try unix_socket.Listener.init(temp_paths.socket_path);
        errdefer {
            var listener = internal_listener;
            listener.deinit();
        }

        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        const bridge = try appendBridgeCommandPrefix(allocator, &argv);
        defer bridge.deinit(allocator);
        try argv.append("http-server");
        try argv.append("--listen-host");
        try argv.append(http.host);
        var port_buffer: [16]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{http.port});
        try argv.append("--listen-port");
        try argv.append(port_text);
        try argv.append("--path");
        try argv.append(http.path);
        try argv.append("--upstream-unix");
        try argv.append(temp_paths.socket_path);
        try argv.append("--ready-file");
        try argv.append(temp_paths.ready_path);
        const max_message_bytes_text = try std.fmt.allocPrint(allocator, "{d}", .{max_message_bytes_value});
        defer allocator.free(max_message_bytes_text);
        try argv.append("--max-message-bytes");
        try argv.append(max_message_bytes_text);
        if (allow_insecure_tcp) {
            try argv.append("--allow-insecure");
        }

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        const ready = try waitForProxyReady(allocator, temp_paths.ready_path);
        defer ready.deinit(allocator);
        const description = try buildHttpDescription(
            allocator,
            allow_insecure_tcp,
            ready.host,
            ready.port,
            ready.path,
        );
        errdefer allocator.free(description);

        return .{
            .allocator = allocator,
            .description = description,
            .socket_path = temp_paths.socket_path,
            .ready_file_path = temp_paths.ready_path,
            .internal_listener = internal_listener,
            .child = child,
        };
    }

    pub fn initH3wt(
        allocator: std.mem.Allocator,
        h3wt: Address.H3wtAddress,
        max_message_bytes_value: usize,
    ) !ProxyListener {
        const temp_paths = try makeProxyTempPaths(allocator, "h3wt");
        errdefer allocator.free(temp_paths.socket_path);
        errdefer allocator.free(temp_paths.ready_path);

        const internal_listener = try unix_socket.Listener.init(temp_paths.socket_path);
        errdefer {
            var listener = internal_listener;
            listener.deinit();
        }

        var argv = std.array_list.Managed([]const u8).init(allocator);
        defer argv.deinit();
        const bridge = try appendBridgeCommandPrefix(allocator, &argv);
        defer bridge.deinit(allocator);
        try argv.append("h3wt-server");
        try argv.append("--listen-host");
        try argv.append(h3wt.host);
        var port_buffer: [16]u8 = undefined;
        const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{h3wt.port});
        try argv.append("--listen-port");
        try argv.append(port_text);
        try argv.append("--path");
        try argv.append(h3wt.path);
        try argv.append("--upstream-unix");
        try argv.append(temp_paths.socket_path);
        try argv.append("--ready-file");
        try argv.append(temp_paths.ready_path);
        const max_message_bytes_text = try std.fmt.allocPrint(allocator, "{d}", .{max_message_bytes_value});
        defer allocator.free(max_message_bytes_text);
        try argv.append("--max-message-bytes");
        try argv.append(max_message_bytes_text);

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        const ready = try waitForProxyReady(allocator, temp_paths.ready_path);
        defer ready.deinit(allocator);
        const description = try buildH3wtDescription(
            allocator,
            ready.host,
            ready.port,
            ready.path,
            ready.sha256,
        );
        errdefer allocator.free(description);

        return .{
            .allocator = allocator,
            .description = description,
            .socket_path = temp_paths.socket_path,
            .ready_file_path = temp_paths.ready_path,
            .internal_listener = internal_listener,
            .child = child,
        };
    }

    pub fn deinit(self: *ProxyListener) void {
        self.internal_listener.deinit();
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        std.fs.deleteFileAbsolute(self.ready_file_path) catch {};
        self.allocator.free(self.description);
        self.allocator.free(self.socket_path);
        self.allocator.free(self.ready_file_path);
    }

    pub fn accept(self: *ProxyListener) !std.net.Server.Connection {
        return try self.internal_listener.accept();
    }
};

const ProxyReady = struct {
    host: []u8,
    port: u16,
    path: []u8,
    sha256: ?[]u8,

    fn deinit(self: *const ProxyReady, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
        if (self.sha256) |value| allocator.free(value);
    }
};

const BridgeCommand = struct {
    program: []const u8,
    backend_path: []const u8,
    owned_backend_path: ?[]u8 = null,

    fn deinit(self: BridgeCommand, allocator: std.mem.Allocator) void {
        if (self.owned_backend_path) |path| allocator.free(path);
    }
};

fn appendBridgeCommandPrefix(
    allocator: std.mem.Allocator,
    argv: *std.array_list.Managed([]const u8),
) !BridgeCommand {
    const command = try resolveBridgeCommand(allocator);
    try argv.append(command.program);
    try argv.append(command.backend_path);
    return command;
}

fn resolveBridgeCommand(allocator: std.mem.Allocator) !BridgeCommand {
    if (std.process.getEnvVarOwned(allocator, "MUXLY_TRANSPORT_BRIDGE_BACKEND")) |path| {
        return .{
            .program = "python3",
            .backend_path = path,
            .owned_backend_path = path,
        };
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    if (try installedBridgeBackendPath(allocator)) |path| {
        return .{
            .program = "python3",
            .backend_path = path,
            .owned_backend_path = path,
        };
    }

    if (std.fs.path.isAbsolute(build_options.transport_bridge_backend_path)) {
        if (std.fs.accessAbsolute(build_options.transport_bridge_backend_path, .{})) |_| {
            return .{
                .program = "python3",
                .backend_path = build_options.transport_bridge_backend_path,
            };
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    return error.TransportBridgeBackendNotFound;
}

fn installedBridgeBackendPath(allocator: std.mem.Allocator) !?[]u8 {
    const exe_path = std.fs.selfExePathAlloc(allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return null;
    const candidate = try std.fs.path.resolve(
        allocator,
        &.{ exe_dir, "..", "share", "muxly", "transport_bridge", "backend.py" },
    );
    var keep_candidate = false;
    defer if (!keep_candidate) allocator.free(candidate);

    std.fs.accessAbsolute(candidate, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    keep_candidate = true;
    return candidate;
}

fn makeProxyTempPaths(
    allocator: std.mem.Allocator,
    prefix: []const u8,
) !struct { socket_path: []u8, ready_path: []u8 } {
    const runtime_dir = try runtimeDirOwned(allocator);
    defer allocator.free(runtime_dir);

    const nonce = std.time.nanoTimestamp();
    return .{
        .socket_path = try std.fmt.allocPrint(
            allocator,
            "{s}/muxly-{s}-{d}.sock",
            .{ runtime_dir, prefix, nonce },
        ),
        .ready_path = try std.fmt.allocPrint(
            allocator,
            "{s}/muxly-{s}-{d}.json",
            .{ runtime_dir, prefix, nonce },
        ),
    };
}

fn runtimeDirOwned(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .windows) {
        return try allocator.dupe(u8, ".");
    }

    if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |value| {
        return value;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    const uid = std.posix.getuid();
    const candidate = try std.fmt.allocPrint(allocator, "/run/user/{d}", .{uid});
    std.fs.accessAbsolute(candidate, .{}) catch {
        allocator.free(candidate);
        return try allocator.dupe(u8, "/tmp");
    };
    return candidate;
}

fn waitForProxyReady(allocator: std.mem.Allocator, ready_file_path: []const u8) !ProxyReady {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        var file = std.fs.openFileAbsolute(ready_file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, 1 << 20);
        defer allocator.free(bytes);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidTransportBridgeReadyFile;
        const host_value = parsed.value.object.get("host") orelse return error.InvalidTransportBridgeReadyFile;
        const port_value = parsed.value.object.get("port") orelse return error.InvalidTransportBridgeReadyFile;
        const path_value = parsed.value.object.get("path") orelse return error.InvalidTransportBridgeReadyFile;
        if (host_value != .string or port_value != .integer or path_value != .string) {
            return error.InvalidTransportBridgeReadyFile;
        }

        const sha256_value = parsed.value.object.get("sha256");
        return .{
            .host = try allocator.dupe(u8, host_value.string),
            .port = @intCast(port_value.integer),
            .path = try allocator.dupe(u8, path_value.string),
            .sha256 = if (sha256_value) |value|
                if (value == .string) try allocator.dupe(u8, value.string) else return error.InvalidTransportBridgeReadyFile
            else
                null,
        };
    }

    return error.TransportBridgeReadyTimeout;
}

fn buildHttpDescription(
    allocator: std.mem.Allocator,
    _: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();
    try writeHttpLikeSpec(buffer.writer(), "http", host, port, path, null);
    return try buffer.toOwnedSlice();
}

fn buildH3wtDescription(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    sha256: ?[]const u8,
) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    errdefer buffer.deinit();
    try writeHttpLikeSpec(buffer.writer(), "h3wt", host, port, path, sha256);
    return try buffer.toOwnedSlice();
}

fn buildRemoteRelayCommand(
    allocator: std.mem.Allocator,
    remote_spec: []const u8,
    allow_insecure_tcp: bool,
) ![]u8 {
    var command = std.array_list.Managed(u8).init(allocator);
    errdefer command.deinit();

    try command.appendSlice("exec muxly");
    if (remote_spec.len > 0) {
        try command.appendSlice(" --transport ");
        try appendShellSingleQuoted(command.writer(), remote_spec);
    }
    if (allow_insecure_tcp) {
        try command.appendSlice(" ");
        try command.appendSlice(unsafe_tcp_flag);
    }
    try command.appendSlice(" transport relay");

    return try command.toOwnedSlice();
}

fn appendShellSingleQuoted(writer: anytype, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\"'\"'");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

fn isLocalOnlyTcpAddress(address: std.net.Address) bool {
    return switch (address.any.family) {
        std.posix.AF.INET => isLocalOnlyIpv4(address.in),
        std.posix.AF.INET6 => isLocalOnlyIpv6(address.in6),
        else => false,
    };
}

fn isLocalOnlyIpv4(address: std.net.Ip4Address) bool {
    const bytes: *const [4]u8 = @ptrCast(&address.sa.addr);
    return bytes[0] == 127 or (bytes[0] == 169 and bytes[1] == 254);
}

fn isLocalOnlyIpv6(address: std.net.Ip6Address) bool {
    const bytes = address.sa.addr;
    const is_loopback = std.mem.allEqual(u8, bytes[0..15], 0) and bytes[15] == 1;
    const is_link_local = bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80;
    return is_loopback or is_link_local;
}
