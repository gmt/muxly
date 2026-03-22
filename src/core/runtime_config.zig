//! Runtime discovery and loading for small shared muxly policy knobs.

const builtin = @import("builtin");
const std = @import("std");
const limits = @import("limits.zig");

pub const RuntimeLimits = struct {
    max_message_bytes: usize = limits.default_max_message_bytes,
    max_document_content_bytes: usize = limits.default_max_document_content_bytes,
};

pub const LoadMode = enum {
    client,
    daemon,
};

pub const LoadOptions = struct {
    mode: LoadMode,
    explicit_config_path: ?[]const u8 = null,
    xdg_config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    system_config_path: ?[]const u8 = null,
};

const FileConfig = struct {
    limits: ?FileLimits = null,

    const FileLimits = struct {
        maxMessageBytes: ?u64 = null,
        maxDocumentContentBytes: ?u64 = null,
    };
};

pub fn loadClientLimits(allocator: std.mem.Allocator) !RuntimeLimits {
    return try loadLimits(allocator, .{
        .mode = .client,
    });
}

pub fn loadDaemonLimits(
    allocator: std.mem.Allocator,
    explicit_config_path: ?[]const u8,
) !RuntimeLimits {
    return try loadLimits(allocator, .{
        .mode = .daemon,
        .explicit_config_path = explicit_config_path,
    });
}

pub fn loadLimits(allocator: std.mem.Allocator, options: LoadOptions) !RuntimeLimits {
    var resolved = RuntimeLimits{};

    const config_path = try resolveConfigPathOwned(allocator, options);
    defer if (config_path) |path| allocator.free(path);

    if (config_path) |path| {
        resolved = try loadLimitsFromPath(allocator, path);
    }

    return resolved;
}

pub fn userConfigCandidateOwned(
    allocator: std.mem.Allocator,
    xdg_config_home_override: ?[]const u8,
    home_override: ?[]const u8,
) !?[]u8 {
    if (builtin.os.tag == .windows) return null;

    const xdg_config_home = try envValueOwned(allocator, "XDG_CONFIG_HOME", xdg_config_home_override);
    defer if (xdg_config_home) |value| allocator.free(value);
    if (xdg_config_home) |value| {
        return try std.fs.path.join(allocator, &.{ value, "muxly", "config.json" });
    }

    const home = try envValueOwned(allocator, "HOME", home_override);
    defer if (home) |value| allocator.free(value);
    if (home) |value| {
        return try std.fs.path.join(allocator, &.{ value, ".config", "muxly", "config.json" });
    }

    return null;
}

pub fn resolveConfigPathOwned(
    allocator: std.mem.Allocator,
    options: LoadOptions,
) !?[]u8 {
    if (options.explicit_config_path) |path| {
        return try allocator.dupe(u8, path);
    }

    const env_path = try envValueOwned(allocator, "MUXLY_CONFIG", null);
    if (env_path) |value| {
        return value;
    }

    switch (options.mode) {
        .client => {
            const user_path = try userConfigCandidateOwned(
                allocator,
                options.xdg_config_home,
                options.home,
            );
            if (user_path) |path| {
                errdefer allocator.free(path);
                if (try pathExists(path)) return path;
                allocator.free(path);
            }
            return null;
        },
        .daemon => {
            const user_path = try userConfigCandidateOwned(
                allocator,
                options.xdg_config_home,
                options.home,
            );
            if (user_path) |path| {
                errdefer allocator.free(path);
                if (try pathExists(path)) return path;
                allocator.free(path);
            }

            const system_path = options.system_config_path orelse "/etc/muxly/config.json";
            if (try pathExists(system_path)) {
                return try allocator.dupe(u8, system_path);
            }
            return null;
        },
    }
}

pub fn loadLimitsFromPath(allocator: std.mem.Allocator, path: []const u8) !RuntimeLimits {
    const bytes = try readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(FileConfig, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var resolved = RuntimeLimits{};
    if (parsed.value.limits) |configured| {
        if (configured.maxMessageBytes) |value| {
            resolved.max_message_bytes = try checkedU64ToUsize(value);
            if (resolved.max_message_bytes == 0) return error.InvalidRuntimeConfig;
        }
        if (configured.maxDocumentContentBytes) |value| {
            resolved.max_document_content_bytes = try checkedU64ToUsize(value);
            if (resolved.max_document_content_bytes == 0) return error.InvalidRuntimeConfig;
        }
    }

    return resolved;
}

fn checkedU64ToUsize(value: u64) !usize {
    if (value > std.math.maxInt(usize)) return error.InvalidRuntimeConfig;
    return @intCast(value);
}

fn envValueOwned(
    allocator: std.mem.Allocator,
    name: []const u8,
    override_value: ?[]const u8,
) !?[]u8 {
    if (override_value) |value| {
        return try allocator.dupe(u8, value);
    }
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

fn pathExists(path: []const u8) !bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }

    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, max_bytes);
    }
    return try std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
}
