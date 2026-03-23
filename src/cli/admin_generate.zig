const std = @import("std");
const muxly = @import("muxly");

pub const Kind = enum {
    caddy,
    systemd,
};

pub fn run(
    allocator: std.mem.Allocator,
    kind: Kind,
    args: []const []const u8,
) !void {
    var descriptor_text: ?[]const u8 = null;
    var mode: muxly.trds.Mode = .user;
    var output_dir: ?[]const u8 = null;
    var upstream_port: u16 = muxly.trds.default_upstream_port;
    var upstream_host: []const u8 = muxly.trds.default_upstream_host;
    var upstream_path: []const u8 = muxly.trds.default_upstream_path;
    var caddy_bin: []const u8 = "/usr/bin/caddy";
    var system_user: []const u8 = "muxly";
    var system_group: []const u8 = "muxly";
    var muxlyd_bin: ?[]u8 = null;
    defer if (muxlyd_bin) |value| allocator.free(value);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--descriptor")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            descriptor_text = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--mode")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            mode = try muxly.trds.Mode.parse(args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--output-dir")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            output_dir = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--upstream-port")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            upstream_port = try std.fmt.parseInt(u16, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--upstream-host")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            upstream_host = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--upstream-path")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            upstream_path = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--muxlyd-bin")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            muxlyd_bin = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--caddy-bin")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            caddy_bin = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--service-user")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            system_user = args[index];
            continue;
        }
        if (std.mem.eql(u8, arg, "--service-group")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            system_group = args[index];
            continue;
        }

        return error.InvalidArguments;
    }

    const final_descriptor_text = descriptor_text orelse return error.InvalidArguments;
    const final_output_dir = output_dir orelse return error.InvalidArguments;
    if (muxlyd_bin == null) muxlyd_bin = try defaultMuxlydBin(allocator);

    var descriptor = try muxly.trds.parse(allocator, final_descriptor_text);
    defer descriptor.deinit(allocator);

    const options = muxly.trds.GenerateOptions{
        .mode = mode,
        .output_dir = final_output_dir,
        .upstream_host = upstream_host,
        .upstream_port = upstream_port,
        .upstream_path = upstream_path,
        .muxlyd_bin = muxlyd_bin.?,
        .caddy_bin = caddy_bin,
        .system_user = system_user,
        .system_group = system_group,
    };

    var generated = switch (kind) {
        .caddy => try muxly.trds.writeCaddyArtifacts(allocator, descriptor, options),
        .systemd => try muxly.trds.writeSystemdArtifacts(allocator, descriptor, options),
    };
    defer generated.deinit(allocator);

    try std.fs.File.stdout().deprecatedWriter().print(
        "generated:\n  muxlyd_unit={s}\n  caddy_file={s}\n  caddy_companion={s}\n",
        .{ generated.muxlyd_unit, generated.caddy_file, generated.caddy_unit_or_snippet },
    );
}

fn defaultMuxlydBin(allocator: std.mem.Allocator) ![]u8 {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const dir = std.fs.path.dirname(self_exe) orelse return error.InvalidArguments;
    return try std.fs.path.join(allocator, &.{ dir, "muxlyd" });
}
