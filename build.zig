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
    const install_daemon = b.addInstallArtifact(daemon, .{});
    b.getInstallStep().dependOn(&install_daemon.step);

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
    const install_cli = b.addInstallArtifact(cli, .{});
    b.getInstallStep().dependOn(&install_cli.step);

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
    const install_viewer = b.addInstallArtifact(viewer, .{});
    b.getInstallStep().dependOn(&install_viewer.step);

    const guided_tour = b.addExecutable(.{
        .name = "muxguide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/guided-tour/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "muxly", .module = muxly_module },
            },
        }),
    });
    const install_guided_tour = b.addInstallArtifact(guided_tour, .{});
    b.getInstallStep().dependOn(&install_guided_tour.step);

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
    const install_shared = b.addInstallArtifact(shared, .{});
    b.getInstallStep().dependOn(&install_shared.step);
    const install_header = b.addInstallHeaderFile(b.path("include/muxly.h"), "muxly.h");
    b.getInstallStep().dependOn(&install_header.step);

    const api_docs = b.addObject(.{
        .name = "muxly-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/muxly.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_api_docs = b.addInstallDirectory(.{
        .source_dir = api_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs/api",
    });

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

    const example_deps_step = b.step(
        "example-deps",
        "Build and install the daemon, CLI, shared library, and header needed by example playbooks",
    );
    example_deps_step.dependOn(&install_daemon.step);
    example_deps_step.dependOn(&install_cli.step);
    example_deps_step.dependOn(&install_shared.step);
    example_deps_step.dependOn(&install_header.step);

    const daemon_step = b.step("muxlyd", "Build muxly daemon");
    daemon_step.dependOn(&daemon.step);

    const cli_step = b.step("muxly", "Build muxly CLI");
    cli_step.dependOn(&cli.step);

    const viewer_step = b.step("muxview", "Build muxview viewer");
    viewer_step.dependOn(&viewer.step);

    const guided_tour_step = b.step("muxguide", "Build muxguide guided tour demo");
    guided_tour_step.dependOn(&install_guided_tour.step);

    const docs_step = b.step("docs", "Build generated Zig API documentation");
    docs_step.dependOn(&install_api_docs.step);
}
