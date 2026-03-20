const std = @import("std");
const muxly = @import("muxly");
const viewer_app = muxly.viewer_app;

test "viewer argument parser accepts snapshot and socket flags" {
    const args = [_][]const u8{
        "muxview",
        "--snapshot",
        "--transport",
        "tcp://169.254.1.20:4488",
        "--socket",
        "/tmp/muxly-viewer.sock",
        "--i-know-this-is-unencrypted-and-unauthenticated",
    };

    const config = try viewer_app.parseArgs("/tmp/default.sock", &args);
    try std.testing.expect(config.snapshot_requested);
    try std.testing.expect(config.allow_insecure_tcp);
    try std.testing.expectEqualStrings("/tmp/muxly-viewer.sock", config.transport_spec);
}

test "viewer argument parser keeps default socket when none is provided" {
    const args = [_][]const u8{
        "muxview",
    };

    const config = try viewer_app.parseArgs("/tmp/default.sock", &args);
    try std.testing.expect(!config.snapshot_requested);
    try std.testing.expect(!config.allow_insecure_tcp);
    try std.testing.expectEqualStrings("/tmp/default.sock", config.transport_spec);
}

test "viewer argument parser rejects unknown flags" {
    const args = [_][]const u8{
        "muxview",
        "--mystery",
    };

    try std.testing.expectError(
        error.InvalidArguments,
        viewer_app.parseArgs("/tmp/default.sock", &args),
    );
}

test "viewer mode selection prefers live attachment for tty stdout" {
    try std.testing.expectEqual(
        viewer_app.RunMode.live,
        viewer_app.selectRunMode(true, false),
    );
    try std.testing.expectEqual(
        viewer_app.RunMode.snapshot,
        viewer_app.selectRunMode(false, false),
    );
    try std.testing.expectEqual(
        viewer_app.RunMode.snapshot,
        viewer_app.selectRunMode(true, true),
    );
}
