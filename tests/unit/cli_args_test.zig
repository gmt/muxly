const std = @import("std");
const muxly = @import("muxly");
const cli_args = muxly.cli_args;

test "cli argument parser accepts transport and unsafe tcp override" {
    const args = [_][]const u8{
        "muxly",
        "--transport",
        "tcp://169.254.12.3:4488",
        "--i-know-this-is-unencrypted-and-unauthenticated",
        "ping",
    };

    const parsed = try cli_args.parse(&args, "/tmp/default.sock");
    try std.testing.expectEqualStrings("tcp://169.254.12.3:4488", parsed.transport_spec);
    try std.testing.expect(parsed.allow_insecure_tcp);
    try std.testing.expectEqual(@as(usize, 4), parsed.command_index);
}

test "cli argument parser keeps default transport until command" {
    const args = [_][]const u8{
        "muxly",
        "list",
    };

    const parsed = try cli_args.parse(&args, "/tmp/default.sock");
    try std.testing.expectEqualStrings("/tmp/default.sock", parsed.transport_spec);
    try std.testing.expect(!parsed.allow_insecure_tcp);
    try std.testing.expectEqual(@as(usize, 1), parsed.command_index);
}

test "cli argument parser surfaces help" {
    const args = [_][]const u8{
        "muxly",
        "--help",
    };

    try std.testing.expectError(error.ShowUsage, cli_args.parse(&args, "/tmp/default.sock"));
}
