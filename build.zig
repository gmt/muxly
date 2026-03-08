const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const muxly_module = b.addModule("muxly", .{
        .root_source_file = b.path("src/muxly.zig"),
        .target = target,
        .optimize = optimize,
    });

    const daemon = b.addExecutable(.{
        .name = "muxlyd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "muxly", .module = muxly_module },
            },
        }),
    });
    b.installArtifact(daemon);

    const cli = b.addExecutable(.{
        .name = "muxly",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "muxly", .module = muxly_module },
            },
        }),
    });
    b.installArtifact(cli);

    const viewer = b.addExecutable(.{
        .name = "muxview",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/viewer/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "muxly", .module = muxly_module },
            },
        }),
    });
    b.installArtifact(viewer);

    const shared = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "muxly",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib/c_abi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "muxly", .module = muxly_module },
            },
        }),
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    shared.linkLibC();
    b.installArtifact(shared);
    const install_header = b.addInstallHeaderFile(b.path("include/muxly.h"), "muxly.h");
    b.getInstallStep().dependOn(&install_header.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "muxly", .module = muxly_module },
            },
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const daemon_step = b.step("muxlyd", "Build muxly daemon");
    daemon_step.dependOn(&daemon.step);

    const cli_step = b.step("muxly", "Build muxly CLI");
    cli_step.dependOn(&cli.step);

    const viewer_step = b.step("muxview", "Build muxview viewer");
    viewer_step.dependOn(&viewer.step);
}
