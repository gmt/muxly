//! Shared transport parsing and stream helpers for muxly client/server code.

const builtin = @import("builtin");
const std = @import("std");
const unix_socket = @import("../platform/unix_socket.zig");

pub const max_message_bytes: usize = 1 << 20;
pub const unsafe_tcp_prefix = "unsafe+";
pub const unsafe_tcp_flag = "--i-know-this-is-unencrypted-and-unauthenticated";

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
        }
    }

    pub fn isTcpLocalOnly(self: Address) !bool {
        return switch (self.target) {
            .tcp => |tcp| isLocalOnlyTcpAddress(try tcp.resolve()),
            else => true,
        };
    }

    pub fn validateForClient(self: Address) !void {
        switch (self.target) {
            .tcp => {
                if (!self.allow_insecure_tcp and !(try self.isTcpLocalOnly())) {
                    return error.InsecureTcpAddressRequiresExplicitOverride;
                }
            },
            .unix, .ssh => {},
        }
    }

    pub fn validateForServer(self: Address) !void {
        switch (self.target) {
            .tcp => {
                if (!self.allow_insecure_tcp and !(try self.isTcpLocalOnly())) {
                    return error.InsecureTcpAddressRequiresExplicitOverride;
                }
            },
            .unix => {},
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
    ssh: SshSession,

    pub fn close(self: *Connection) void {
        switch (self.*) {
            .socket => |stream| stream.close(),
            .ssh => |*ssh| ssh.close(),
        }
    }

    pub fn read(self: *Connection, buffer: []u8) !usize {
        return switch (self.*) {
            .socket => |stream| try stream.read(buffer),
            .ssh => |*ssh| try ssh.read(buffer),
        };
    }

    pub fn writeAll(self: *Connection, bytes: []const u8) !void {
        switch (self.*) {
            .socket => |stream| try stream.writeAll(bytes),
            .ssh => |*ssh| try ssh.writeAll(bytes),
        }
    }
};

pub const SshSession = struct {
    child: std.process.Child,
    stdin_file: std.fs.File,
    stdout_file: std.fs.File,

    pub fn init(allocator: std.mem.Allocator, ssh: Address.SshAddress, allow_insecure_tcp: bool) !SshSession {
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

        var child = std.process.Child.init(argv.items, allocator);
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

    pub fn close(self: *SshSession) void {
        self.stdin_file.close();
        self.stdout_file.close();
        _ = self.child.wait() catch {};
    }

    pub fn read(self: *SshSession, buffer: []u8) !usize {
        return try self.stdout_file.read(buffer);
    }

    pub fn writeAll(self: *SshSession, bytes: []const u8) !void {
        try self.stdin_file.writeAll(bytes);
    }
};

pub const Listener = struct {
    allow_insecure_tcp: bool,
    target: Target,

    pub const Target = union(enum) {
        unix: unix_socket.Listener,
        tcp: std.net.Server,
    };

    pub fn init(address: *const Address) !Listener {
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
            .ssh => error.UnsupportedTransportForDaemon,
        };
    }

    pub fn deinit(self: *Listener) void {
        switch (self.target) {
            .unix => |*listener| listener.deinit(),
            .tcp => |*server| server.deinit(),
        }
    }

    pub fn accept(self: *Listener) !std.net.Server.Connection {
        return switch (self.target) {
            .unix => |*listener| try listener.accept(),
            .tcp => |*server| try server.accept(),
        };
    }

    pub fn writeDescription(self: *const Listener, writer: anytype) !void {
        if (self.allow_insecure_tcp) {
            try writer.writeAll(unsafe_tcp_prefix);
        }

        switch (self.target) {
            .unix => |listener| try writer.print("unix://{s}", .{listener.socket_path}),
            .tcp => |server| try writer.print("tcp://{f}", .{server.listen_address}),
        }
    }
};

pub fn connect(allocator: std.mem.Allocator, address: *const Address) !Connection {
    try address.validateForClient();

    return switch (address.target) {
        .unix => |path| .{ .socket = try unix_socket.connect(path) },
        .tcp => |tcp| .{ .socket = try std.net.tcpConnectToAddress(try tcp.resolve()) },
        .ssh => |ssh| .{ .ssh = try SshSession.init(allocator, ssh, address.allow_insecure_tcp) },
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
        defaultRemoteTransportSpec();

    return .{
        .destination = try allocator.dupe(u8, parsed_destination.destination),
        .port = parsed_destination.port,
        .remote_spec = try allocator.dupe(u8, remote_spec),
    };
}

fn splitHostPort(spec: []const u8) !struct { host: []const u8, port: u16 } {
    if (spec.len == 0) return error.InvalidTransportAddress;

    if (spec[0] == '[') {
        const end = std.mem.indexOfScalar(u8, spec, ']') orelse return error.InvalidTransportAddress;
        if (end + 1 >= spec.len or spec[end + 1] != ':') return error.InvalidTransportAddress;
        const host = spec[1..end];
        const port = try parsePort(spec[end + 2 ..]);
        return .{ .host = host, .port = port };
    }

    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return error.InvalidTransportAddress;
    const host = spec[0..colon];
    if (host.len == 0) return error.InvalidTransportAddress;
    const port = try parsePort(spec[colon + 1 ..]);
    return .{ .host = host, .port = port };
}

fn parsePort(port_text: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, port_text, 10);
    if (port == 0) return error.InvalidTransportAddress;
    return port;
}

fn writeTcpSpec(writer: anytype, host: []const u8, port: u16) !void {
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        try writer.print("tcp://[{s}]:{d}", .{ host, port });
    } else {
        try writer.print("tcp://{s}:{d}", .{ host, port });
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
            .port = try parsePort(host_part[close_index + 2 ..]),
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
        .port = try parsePort(host_part[colon_index + 1 ..]),
    };
}

fn buildRemoteRelayCommand(
    allocator: std.mem.Allocator,
    remote_spec: []const u8,
    allow_insecure_tcp: bool,
) ![]u8 {
    var command = std.array_list.Managed(u8).init(allocator);
    errdefer command.deinit();

    try command.appendSlice("exec muxly --transport ");
    try appendShellSingleQuoted(command.writer(), remote_spec);
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

fn defaultRemoteTransportSpec() []const u8 {
    return if (builtin.os.tag == .windows)
        "\\\\.\\pipe\\muxly"
    else
        "/tmp/muxly.sock";
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
