//! Secure descriptor parsing and config rendering helpers.
//!
//! `trds://...` descriptors remain the deployment/share vocabulary for
//! Caddy-fronted HTTPS muxly instances, and in this slice they also become the
//! preferred secure native client-facing descriptor family for selecting
//! between muxly-native WebTransport and secure HTTP transports.

const std = @import("std");
const protocol = @import("../core/protocol.zig");

pub const default_https_port: u16 = 443;
pub const default_https_path = "/rpc";
pub const default_upstream_host = "127.0.0.1";
pub const default_upstream_port: u16 = 4489;
pub const default_upstream_path = "/rpc";

pub const SecureTransportCode = enum {
    auto,
    wt,
    ht,
    h3,
    h2,
    h1,

    pub fn parse(text: []const u8) !SecureTransportCode {
        if (text.len == 0) return .auto;
        if (std.mem.eql(u8, text, "wt")) return .wt;
        if (std.mem.eql(u8, text, "ht")) return .ht;
        if (std.mem.eql(u8, text, "h3")) return .h3;
        if (std.mem.eql(u8, text, "h2") or std.mem.eql(u8, text, "ht2")) return .h2;
        if (std.mem.eql(u8, text, "h1") or std.mem.eql(u8, text, "ht1")) return .h1;
        return error.UnsupportedResourceTransport;
    }

    pub fn asSlugText(self: SecureTransportCode) []const u8 {
        return switch (self) {
            .auto => "auto",
            .wt => "wt",
            .ht => "ht",
            .h3 => "h3",
            .h2 => "h2",
            .h1 => "h1",
        };
    }
};

pub const Mode = enum {
    user,
    system,

    pub fn parse(text: []const u8) !Mode {
        if (std.mem.eql(u8, text, "user")) return .user;
        if (std.mem.eql(u8, text, "system")) return .system;
        return error.InvalidArguments;
    }
};

pub const Parsed = struct {
    transport_code: SecureTransportCode = .auto,
    host: []u8,
    port: u16,
    https_path: []u8,
    document_path: []u8,
    selector: ?[]u8 = null,
    certificate_hash: ?[]u8 = null,
    server_name: ?[]u8 = null,
    ca_file: ?[]u8 = null,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.https_path);
        allocator.free(self.document_path);
        if (self.selector) |value| allocator.free(value);
        if (self.certificate_hash) |value| allocator.free(value);
        if (self.server_name) |value| allocator.free(value);
        if (self.ca_file) |value| allocator.free(value);
    }

    pub fn siteAddress(self: Parsed, allocator: std.mem.Allocator) ![]u8 {
        if (hostNeedsBrackets(self.host)) {
            return try std.fmt.allocPrint(allocator, "https://[{s}]:{d}", .{ self.host, self.port });
        }
        return try std.fmt.allocPrint(allocator, "https://{s}:{d}", .{ self.host, self.port });
    }

    pub fn slug(self: Parsed, allocator: std.mem.Allocator) ![]u8 {
        var value = std.array_list.Managed(u8).init(allocator);
        errdefer value.deinit();

        try appendSlugComponent(&value, self.host);
        if (self.port != default_https_port) {
            try value.writer().print("-p{d}", .{self.port});
        }
        if (!std.mem.eql(u8, self.https_path, default_https_path)) {
            const trimmed = std.mem.trimLeft(u8, self.https_path, "/");
            if (trimmed.len != 0) {
                try value.appendSlice("-");
                try appendSlugComponent(&value, trimmed);
            }
        }
        if (self.transport_code != .auto) {
            try value.appendSlice("-");
            try appendSlugComponent(&value, self.transport_code.asSlugText());
        }
        if (value.items.len == 0) try value.appendSlice("secure");
        return try value.toOwnedSlice();
    }

    pub fn isLikelyLocal(self: Parsed) bool {
        return std.mem.eql(u8, self.host, "localhost") or
            std.mem.eql(u8, self.host, "127.0.0.1") or
            std.mem.eql(u8, self.host, "::1");
    }
};

pub const Resolved = struct {
    transport_spec: []u8,
    document_path: []u8,
    selector: ?[]u8,

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        allocator.free(self.transport_spec);
        allocator.free(self.document_path);
        if (self.selector) |value| allocator.free(value);
    }
};

pub const GenerateOptions = struct {
    mode: Mode,
    output_dir: []const u8,
    upstream_host: []const u8 = default_upstream_host,
    upstream_port: u16 = default_upstream_port,
    upstream_path: []const u8 = default_upstream_path,
    muxlyd_bin: []const u8,
    caddy_bin: []const u8 = "/usr/bin/caddy",
    system_user: []const u8 = "muxly",
    system_group: []const u8 = "muxly",
};

pub const GeneratedPaths = struct {
    muxlyd_unit: []u8,
    caddy_file: []u8,
    caddy_unit_or_snippet: []u8,

    pub fn deinit(self: *GeneratedPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.muxlyd_unit);
        allocator.free(self.caddy_file);
        allocator.free(self.caddy_unit_or_snippet);
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Parsed {
    if (!std.mem.startsWith(u8, text, "trds://")) return error.InvalidResourceDescriptor;

    const payload_with_selector = text["trds://".len..];
    if (payload_with_selector.len == 0) return error.InvalidResourceDescriptor;

    var payload = payload_with_selector;
    var selector: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, payload_with_selector, '#')) |hash_index| {
        selector = payload_with_selector[hash_index + 1 ..];
        payload = payload_with_selector[0..hash_index];
    }

    var authority_and_path = payload;
    var document_path_text: ?[]const u8 = null;
    if (std.mem.indexOf(u8, payload, "//")) |doc_sep| {
        authority_and_path = payload[0..doc_sep];
        document_path_text = payload[doc_sep + 2 ..];
    }

    if (authority_and_path.len == 0) return error.InvalidResourceDescriptor;

    var transport_code: SecureTransportCode = .auto;
    var authority_path_payload = authority_and_path;
    if (std.mem.indexOfScalar(u8, authority_and_path, '|')) |pipe_index| {
        transport_code = try SecureTransportCode.parse(authority_and_path[0..pipe_index]);
        authority_path_payload = authority_and_path[pipe_index + 1 ..];
    }

    const slash_index = std.mem.indexOfScalar(u8, authority_path_payload, '/');
    const authority_text = if (slash_index) |index| authority_path_payload[0..index] else authority_path_payload;
    const raw_https_path_text = if (slash_index) |index| authority_path_payload[index..] else default_https_path;
    if (authority_text.len == 0) return error.InvalidResourceDescriptor;

    const split = try splitHostPort(allocator, authority_text);
    errdefer allocator.free(split.host);

    const parsed_path = try parseHttpsPathAndTrust(allocator, raw_https_path_text);
    defer parsed_path.deinit(allocator);
    const owned_path = try allocator.dupe(u8, parsed_path.https_path);
    errdefer allocator.free(owned_path);
    const owned_document_path = if (document_path_text) |value|
        try normalizeDocumentPathOwned(allocator, value)
    else
        try allocator.dupe(u8, protocol.default_document_path);
    errdefer allocator.free(owned_document_path);
    const owned_selector = if (selector) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_selector) |value| allocator.free(value);
    const owned_certificate_hash = if (parsed_path.certificate_hash) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_certificate_hash) |value| allocator.free(value);
    const owned_server_name = if (parsed_path.server_name) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_server_name) |value| allocator.free(value);
    const owned_ca_file = if (parsed_path.ca_file) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (owned_ca_file) |value| allocator.free(value);

    return .{
        .transport_code = transport_code,
        .host = split.host,
        .port = split.port,
        .https_path = owned_path,
        .document_path = owned_document_path,
        .selector = owned_selector,
        .certificate_hash = owned_certificate_hash,
        .server_name = owned_server_name,
        .ca_file = owned_ca_file,
    };
}

pub fn isDescriptor(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "trds://");
}

pub fn resolve(allocator: std.mem.Allocator, text: []const u8) !Resolved {
    var parsed = try parse(allocator, text);
    defer parsed.deinit(allocator);
    return try resolveParsed(allocator, parsed);
}

pub fn resolveParsed(allocator: std.mem.Allocator, parsed: Parsed) !Resolved {
    const transport_spec = try parsedTransportSpec(allocator, parsed);
    errdefer allocator.free(transport_spec);
    return .{
        .transport_spec = transport_spec,
        .document_path = try allocator.dupe(u8, parsed.document_path),
        .selector = if (parsed.selector) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn parsedTransportSpec(allocator: std.mem.Allocator, parsed: Parsed) ![]u8 {
    var buffer = std.array_list.Managed(u8).init(allocator);
    defer buffer.deinit();
    const scheme = switch (parsed.transport_code) {
        .wt => "h3wt",
        .ht => "https",
        .h2 => "https2",
        .h1 => "https1",
        .auto, .h3 => return error.UnsupportedResourceTransport,
    };
    try buffer.writer().print("{s}://", .{scheme});
    if (hostNeedsBrackets(parsed.host)) {
        try buffer.writer().print("[{s}]:{d}", .{ parsed.host, parsed.port });
    } else {
        try buffer.writer().print("{s}:{d}", .{ parsed.host, parsed.port });
    }
    try buffer.appendSlice(parsed.https_path);

    var wrote_query = false;
    if (parsed.certificate_hash) |value| {
        try buffer.appendSlice(if (wrote_query) "&" else "?");
        wrote_query = true;
        try buffer.appendSlice("sha256=");
        try buffer.appendSlice(value);
    }
    if (parsed.server_name) |value| {
        try buffer.appendSlice(if (wrote_query) "&" else "?");
        wrote_query = true;
        try buffer.appendSlice("sni=");
        try buffer.appendSlice(value);
    }
    if (parsed.ca_file) |value| {
        try buffer.appendSlice(if (wrote_query) "&" else "?");
        try buffer.appendSlice("ca=");
        try buffer.appendSlice(value);
    }

    return try buffer.toOwnedSlice();
}

pub fn caddyFileName(allocator: std.mem.Allocator, descriptor: Parsed) ![]u8 {
    const slug = try descriptor.slug(allocator);
    defer allocator.free(slug);
    return try std.fmt.allocPrint(allocator, "muxly-{s}.Caddyfile", .{slug});
}

pub fn caddyCompanionFileName(allocator: std.mem.Allocator, descriptor: Parsed, mode: Mode) ![]u8 {
    const slug = try descriptor.slug(allocator);
    defer allocator.free(slug);
    return switch (mode) {
        .user => try std.fmt.allocPrint(allocator, "muxly-caddy-{s}.service", .{slug}),
        .system => try std.fmt.allocPrint(allocator, "muxly-caddy-{s}.conf", .{slug}),
    };
}

pub fn muxlydUnitFileName(allocator: std.mem.Allocator, descriptor: Parsed) ![]u8 {
    const slug = try descriptor.slug(allocator);
    defer allocator.free(slug);
    return try std.fmt.allocPrint(allocator, "muxlyd-{s}.service", .{slug});
}

pub fn writeCaddyArtifacts(
    allocator: std.mem.Allocator,
    descriptor: Parsed,
    options: GenerateOptions,
) !GeneratedPaths {
    try std.fs.cwd().makePath(options.output_dir);

    const caddy_name = try caddyFileName(allocator, descriptor);
    errdefer allocator.free(caddy_name);
    const caddy_path = try std.fs.path.join(allocator, &.{ options.output_dir, caddy_name });
    errdefer allocator.free(caddy_path);
    defer allocator.free(caddy_name);

    const companion_name = try caddyCompanionFileName(allocator, descriptor, options.mode);
    errdefer allocator.free(companion_name);
    const companion_path = try std.fs.path.join(allocator, &.{ options.output_dir, companion_name });
    errdefer allocator.free(companion_path);
    defer allocator.free(companion_name);

    const placeholder_muxlyd_unit_name = try muxlydUnitFileName(allocator, descriptor);
    defer allocator.free(placeholder_muxlyd_unit_name);
    const placeholder_muxlyd_unit_path = try std.fs.path.join(allocator, &.{ options.output_dir, placeholder_muxlyd_unit_name });
    defer allocator.free(placeholder_muxlyd_unit_path);

    const caddy_contents = try renderCaddyfile(allocator, descriptor, options);
    defer allocator.free(caddy_contents);
    try std.fs.cwd().writeFile(.{ .sub_path = caddy_path, .data = caddy_contents });

    const companion_contents = switch (options.mode) {
        .user => try renderUserCaddyUnit(
            allocator,
            descriptor,
            options,
            caddy_path,
            placeholder_muxlyd_unit_name,
        ),
        .system => try renderSystemCaddySnippet(allocator, descriptor, options),
    };
    defer allocator.free(companion_contents);
    try std.fs.cwd().writeFile(.{ .sub_path = companion_path, .data = companion_contents });

    return .{
        .muxlyd_unit = try allocator.dupe(u8, placeholder_muxlyd_unit_path),
        .caddy_file = caddy_path,
        .caddy_unit_or_snippet = companion_path,
    };
}

pub fn writeSystemdArtifacts(
    allocator: std.mem.Allocator,
    descriptor: Parsed,
    options: GenerateOptions,
) !GeneratedPaths {
    try std.fs.cwd().makePath(options.output_dir);

    const muxlyd_name = try muxlydUnitFileName(allocator, descriptor);
    errdefer allocator.free(muxlyd_name);
    const muxlyd_path = try std.fs.path.join(allocator, &.{ options.output_dir, muxlyd_name });
    errdefer allocator.free(muxlyd_path);
    defer allocator.free(muxlyd_name);

    const caddy_name = try caddyFileName(allocator, descriptor);
    errdefer allocator.free(caddy_name);
    const caddy_path = try std.fs.path.join(allocator, &.{ options.output_dir, caddy_name });
    errdefer allocator.free(caddy_path);
    defer allocator.free(caddy_name);

    const companion_name = try caddyCompanionFileName(allocator, descriptor, options.mode);
    errdefer allocator.free(companion_name);
    const companion_path = try std.fs.path.join(allocator, &.{ options.output_dir, companion_name });
    errdefer allocator.free(companion_path);
    defer allocator.free(companion_name);

    const muxlyd_contents = switch (options.mode) {
        .user => try renderUserMuxlydUnit(allocator, descriptor, options),
        .system => try renderSystemMuxlydUnit(allocator, descriptor, options),
    };
    defer allocator.free(muxlyd_contents);
    try std.fs.cwd().writeFile(.{ .sub_path = muxlyd_path, .data = muxlyd_contents });

    if (options.mode == .user) {
        const caddy_unit_contents = try renderUserCaddyUnit(
            allocator,
            descriptor,
            options,
            caddy_path,
            muxlyd_name,
        );
        defer allocator.free(caddy_unit_contents);
        try std.fs.cwd().writeFile(.{ .sub_path = companion_path, .data = caddy_unit_contents });
    } else {
        const caddy_snippet = try renderSystemCaddySnippet(allocator, descriptor, options);
        defer allocator.free(caddy_snippet);
        try std.fs.cwd().writeFile(.{ .sub_path = companion_path, .data = caddy_snippet });
    }

    return .{
        .muxlyd_unit = muxlyd_path,
        .caddy_file = caddy_path,
        .caddy_unit_or_snippet = companion_path,
    };
}

pub fn renderCaddyfile(
    allocator: std.mem.Allocator,
    descriptor: Parsed,
    options: GenerateOptions,
) ![]u8 {
    const site = try descriptor.siteAddress(allocator);
    defer allocator.free(site);

    const handle_path = try std.fmt.allocPrint(allocator, "{s}*", .{descriptor.https_path});
    defer allocator.free(handle_path);

    const upstream = if (hostNeedsBrackets(options.upstream_host))
        try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ options.upstream_host, options.upstream_port })
    else
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ options.upstream_host, options.upstream_port });
    defer allocator.free(upstream);

    const tls_line = switch (options.mode) {
        .user => "    tls internal\n",
        .system => if (descriptor.isLikelyLocal()) "    tls internal\n" else "",
    };

    return try std.fmt.allocPrint(
        allocator,
        \\{{
        \\    auto_https disable_redirects
        \\    admin off
        \\    skip_install_trust
        \\}}
        \\
        \\# Note: for plain `trds://...` and `trds://wt|...`, this generated
        \\# Caddy site still provisions the
        \\# secure HTTP fallback endpoint. Native H3/WebTransport attach remains a
        \\# direct client capability in this slice.
        \\
        \\{s} {{
        \\{s}    handle {s} {{
        \\        reverse_proxy h2c://{s}
        \\    }}
        \\}}
        \\
    ,
        .{ site, tls_line, handle_path, upstream },
    );
}

pub fn renderUserCaddyUnit(
    allocator: std.mem.Allocator,
    descriptor: Parsed,
    options: GenerateOptions,
    caddyfile_path: []const u8,
    muxlyd_unit_name: []const u8,
) ![]u8 {
    _ = descriptor;
    const config_home = try std.fs.path.join(allocator, &.{ options.output_dir, "caddy-config" });
    defer allocator.free(config_home);
    const data_home = try std.fs.path.join(allocator, &.{ options.output_dir, "caddy-data" });
    defer allocator.free(data_home);
    return try std.fmt.allocPrint(
        allocator,
        \\# Generated by muxly for a user-scoped trds deployment.
        \\[Unit]
        \\Description=Caddy HTTPS front door for muxly
        \\Requires={s}
        \\After={s}
        \\
        \\[Service]
        \\Type=simple
        \\Environment=XDG_CONFIG_HOME={s}
        \\Environment=XDG_DATA_HOME={s}
        \\ExecStart={s} run --config {s} --adapter caddyfile
        \\Restart=on-failure
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    ,
        .{ muxlyd_unit_name, muxlyd_unit_name, config_home, data_home, options.caddy_bin, caddyfile_path },
    );
}

pub fn renderSystemCaddySnippet(
    allocator: std.mem.Allocator,
    descriptor: Parsed,
    options: GenerateOptions,
) ![]u8 {
    const site = try descriptor.siteAddress(allocator);
    defer allocator.free(site);
    const handle_path = try std.fmt.allocPrint(allocator, "{s}*", .{descriptor.https_path});
    defer allocator.free(handle_path);
    const upstream = if (hostNeedsBrackets(options.upstream_host))
        try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ options.upstream_host, options.upstream_port })
    else
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ options.upstream_host, options.upstream_port });
    defer allocator.free(upstream);
    const tls_line = if (descriptor.isLikelyLocal()) "    tls internal\n" else "";

    return try std.fmt.allocPrint(
        allocator,
        \\# Generated by muxly for {s}
        \\# Install this as a Caddy site snippet.
        \\{s} {{
        \\{s}    handle {s} {{
        \\        reverse_proxy h2c://{s}
        \\    }}
        \\}}
        \\
    ,
        .{ site, site, tls_line, handle_path, upstream },
    );
}

pub fn renderUserMuxlydUnit(
    allocator: std.mem.Allocator,
    descriptor: Parsed,
    options: GenerateOptions,
) ![]u8 {
    const site = try descriptor.siteAddress(allocator);
    defer allocator.free(site);
    return try std.fmt.allocPrint(
        allocator,
        \\# Generated by muxly for {s}
        \\# For plain `trds://...` and `trds://wt|...`, this unit still
        \\# provisions the secure HTTP
        \\# fallback upstream used by the generated Caddy front door.
        \\[Unit]
        \\Description=muxlyd secure upstream for {s}
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s} --transport h2://{s}:{d}{s}
        \\Restart=on-failure
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    ,
        .{ site, site, options.muxlyd_bin, options.upstream_host, options.upstream_port, options.upstream_path },
    );
}

pub fn renderSystemMuxlydUnit(
    allocator: std.mem.Allocator,
    descriptor: Parsed,
    options: GenerateOptions,
) ![]u8 {
    const site = try descriptor.siteAddress(allocator);
    defer allocator.free(site);
    return try std.fmt.allocPrint(
        allocator,
        \\# Generated by muxly for {s}
        \\# Review User= and Group= if your packaging uses different names.
        \\# For plain `trds://...` and `trds://wt|...`, this unit still
        \\# provisions the secure HTTP
        \\# fallback upstream used by the generated Caddy site.
        \\[Unit]
        \\Description=muxlyd secure upstream for {s}
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\User={s}
        \\Group={s}
        \\ExecStart={s} --transport h2://{s}:{d}{s}
        \\Restart=on-failure
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    ,
        .{
            site,
            site,
            options.system_user,
            options.system_group,
            options.muxlyd_bin,
            options.upstream_host,
            options.upstream_port,
            options.upstream_path,
        },
    );
}

const HostPort = struct {
    host: []u8,
    port: u16,
};

fn splitHostPort(allocator: std.mem.Allocator, authority: []const u8) !HostPort {
    if (authority.len == 0) return error.InvalidResourceDescriptor;

    if (authority[0] == '[') {
        const closing = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidResourceDescriptor;
        const host = try allocator.dupe(u8, authority[1..closing]);
        const remainder = authority[closing + 1 ..];
        if (remainder.len == 0) return .{ .host = host, .port = default_https_port };
        if (remainder[0] != ':') {
            allocator.free(host);
            return error.InvalidResourceDescriptor;
        }
        const port = try std.fmt.parseInt(u16, remainder[1..], 10);
        return .{ .host = host, .port = port };
    }

    const first_colon = std.mem.indexOfScalar(u8, authority, ':');
    const last_colon = std.mem.lastIndexOfScalar(u8, authority, ':');
    if (first_colon != null and first_colon.? != last_colon.?) return error.InvalidResourceDescriptor;

    if (last_colon) |index| {
        const host = try allocator.dupe(u8, authority[0..index]);
        errdefer allocator.free(host);
        const port = try std.fmt.parseInt(u16, authority[index + 1 ..], 10);
        return .{ .host = host, .port = port };
    }

    return .{
        .host = try allocator.dupe(u8, authority),
        .port = default_https_port,
    };
}

fn normalizeHttpsPathOwned(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return try allocator.dupe(u8, default_https_path);
    if (value[0] != '/') return error.InvalidResourceDescriptor;
    if (std.mem.endsWith(u8, value, "/") and value.len > 1) return error.InvalidResourceDescriptor;
    if (std.mem.indexOf(u8, value, "//") != null) return error.InvalidResourceDescriptor;
    return try allocator.dupe(u8, value);
}

const ParsedHttpsPathAndTrust = struct {
    https_path: []u8,
    certificate_hash: ?[]u8 = null,
    server_name: ?[]u8 = null,
    ca_file: ?[]u8 = null,

    fn deinit(self: ParsedHttpsPathAndTrust, allocator: std.mem.Allocator) void {
        allocator.free(self.https_path);
        if (self.certificate_hash) |value| allocator.free(value);
        if (self.server_name) |value| allocator.free(value);
        if (self.ca_file) |value| allocator.free(value);
    }
};

fn parseHttpsPathAndTrust(allocator: std.mem.Allocator, value: []const u8) !ParsedHttpsPathAndTrust {
    const question_index = std.mem.indexOfScalar(u8, value, '?');
    const path_text = if (question_index) |index| value[0..index] else value;
    const query_text = if (question_index) |index| value[index + 1 ..] else "";

    const https_path = try normalizeHttpsPathOwned(allocator, path_text);

    var parsed: ParsedHttpsPathAndTrust = .{
        .https_path = https_path,
    };
    errdefer parsed.deinit(allocator);

    if (query_text.len == 0) return parsed;

    var it = std.mem.splitScalar(u8, query_text, '&');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        if (std.mem.startsWith(u8, entry, "sha256=")) {
            if (parsed.certificate_hash != null) return error.InvalidResourceDescriptor;
            parsed.certificate_hash = try allocator.dupe(u8, entry["sha256=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, entry, "sni=")) {
            if (parsed.server_name != null) return error.InvalidResourceDescriptor;
            parsed.server_name = try allocator.dupe(u8, entry["sni=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, entry, "ca=")) {
            return error.InvalidResourceDescriptor;
        }
        return error.InvalidResourceDescriptor;
    }

    return parsed;
}

fn normalizeDocumentPathOwned(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return try allocator.dupe(u8, protocol.default_document_path);

    const document_path = if (value[0] == '/')
        try allocator.dupe(u8, value)
    else
        try std.fmt.allocPrint(allocator, "/{s}", .{value});
    errdefer allocator.free(document_path);

    if (!std.mem.eql(u8, document_path, protocol.default_document_path)) {
        if (std.mem.endsWith(u8, document_path, "/")) return error.InvalidDocumentPath;
        if (std.mem.indexOf(u8, document_path, "//") != null) return error.InvalidDocumentPath;
    }

    var it = std.mem.tokenizeScalar(u8, document_path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return error.InvalidDocumentPath;
        }
    }

    return document_path;
}

fn appendSlugComponent(buffer: *std.array_list.Managed(u8), text: []const u8) !void {
    for (text) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try buffer.append(std.ascii.toLower(char));
        } else {
            if (buffer.items.len == 0 or buffer.items[buffer.items.len - 1] != '-') {
                try buffer.append('-');
            }
        }
    }

    while (buffer.items.len > 0 and buffer.items[buffer.items.len - 1] == '-') {
        _ = buffer.pop();
    }
}

fn hostNeedsBrackets(host: []const u8) bool {
    return std.mem.indexOfScalar(u8, host, ':') != null;
}
