const std = @import("std");
const muxly = @import("muxly");

test "user config candidate prefers XDG config home" {
    const path = (try muxly.runtime_config.userConfigCandidateOwned(
        std.testing.allocator,
        "/tmp/xdg-home",
        "/tmp/home",
    )).?;
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/xdg-home/muxly/config.json", path);
}

test "daemon implicit config prefers user config over system config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("xdg/muxly");
    try tmp.dir.makePath("etc/muxly");

    try tmp.dir.writeFile(.{
        .sub_path = "xdg/muxly/config.json",
        .data = "{}",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "etc/muxly/config.json",
        .data = "{}",
    });

    const xdg_home = try tmp.dir.realpathAlloc(std.testing.allocator, "xdg");
    defer std.testing.allocator.free(xdg_home);
    const user_config_path = try tmp.dir.realpathAlloc(std.testing.allocator, "xdg/muxly/config.json");
    defer std.testing.allocator.free(user_config_path);
    const system_config_path = try tmp.dir.realpathAlloc(std.testing.allocator, "etc/muxly/config.json");
    defer std.testing.allocator.free(system_config_path);

    const resolved = (try muxly.runtime_config.resolveConfigPathOwned(
        std.testing.allocator,
        .{
            .mode = .daemon,
            .xdg_config_home = xdg_home,
            .system_config_path = system_config_path,
        },
    )).?;
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(user_config_path, resolved);
}

test "runtime limits load from JSON file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "config.json",
        .data =
        \\{"limits":{"maxMessageBytes":4096,"maxDocumentContentBytes":8192}}
        ,
    });

    const config_path = try tmp.dir.realpathAlloc(std.testing.allocator, "config.json");
    defer std.testing.allocator.free(config_path);

    const resolved = try muxly.runtime_config.loadLimitsFromPath(
        std.testing.allocator,
        config_path,
    );

    try std.testing.expectEqual(@as(usize, 4096), resolved.max_message_bytes);
    try std.testing.expectEqual(@as(usize, 8192), resolved.max_document_content_bytes);
}
