const std = @import("std");

const unit_test_timeout_seconds: u32 = 600;
const transport_bridge_unit_timeout_seconds: u32 = 600;
const transport_integration_timeout_seconds: u32 = 900;
const docker_transport_timeout_seconds: u32 = 1_200;
const transport_stress_timeout_seconds: u32 = 2_700;

fn envVarEnabled(allocator: std.mem.Allocator, name: []const u8) bool {
    const value = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return false,
        else => return false,
    };
    defer allocator.free(value);

    return std.ascii.eqlIgnoreCase(value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on");
}

fn addTimedSystemCommand(
    b: *std.Build,
    timeout_seconds: u32,
    argv: []const []const u8,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "python3", b.pathFromRoot("scripts/run_with_timeout.py") });
    run.addArgs(&.{ "--timeout-seconds", b.fmt("{d}", .{timeout_seconds}), "--" });
    run.addArgs(argv);
    return run;
}

fn setTimedTestExec(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    timeout_seconds: u32,
) void {
    compile.setExecCmd(&.{
        "python3",
        b.pathFromRoot("scripts/run_with_timeout.py"),
        "--timeout-seconds",
        b.fmt("{d}", .{timeout_seconds}),
        "--",
        null,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const docker_tests_enabled = envVarEnabled(b.allocator, "MUXLY_ENABLE_DOCKER_TESTS");
    const build_options = b.addOptions();
    build_options.addOption(
        []const u8,
        "transport_bridge_backend_path",
        b.pathFromRoot("tools/transport_bridge/backend.py"),
    );

    const muxly_module = b.addModule("muxly", .{
        .root_source_file = b.path("src/muxly.zig"),
        .target = target,
        .optimize = optimize,
    });
    muxly_module.addImport("build_options", build_options.createModule());

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

    const async_transport_stress_probe = b.addExecutable(.{
        .name = "muxly-async-transport-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/async_transport_stress_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "muxly", .module = muxly_module },
            },
        }),
    });
    const install_async_transport_stress_probe = b.addInstallArtifact(async_transport_stress_probe, .{});
    b.getInstallStep().dependOn(&install_async_transport_stress_probe.step);

    const install_transport_bridge = b.addInstallDirectory(.{
        .source_dir = b.path("tools/transport_bridge"),
        .install_dir = .prefix,
        .install_subdir = "share/muxly/transport_bridge",
    });
    b.getInstallStep().dependOn(&install_transport_bridge.step);

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
        .install_subdir = "doc/api",
    });

    const ffi_docs_root = b.getInstallPath(.prefix, "doc");
    const ffi_docs_files = b.addWriteFiles();
    const ffi_doxyfile = ffi_docs_files.add("Doxyfile.ffi", b.fmt(
        \\PROJECT_NAME = "libmuxly C API"
        \\PROJECT_NUMBER = "0.1.0"
        \\OUTPUT_DIRECTORY = "{s}"
        \\HTML_OUTPUT = ffi
        \\GENERATE_HTML = YES
        \\GENERATE_LATEX = NO
        \\GENERATE_MAN = NO
        \\GENERATE_RTF = NO
        \\GENERATE_XML = NO
        \\GENERATE_DOCSET = NO
        \\QUIET = YES
        \\WARN_IF_UNDOCUMENTED = NO
        \\WARN_IF_DOC_ERROR = YES
        \\OPTIMIZE_OUTPUT_FOR_C = YES
        \\EXTRACT_ALL = YES
        \\EXTRACT_STATIC = NO
        \\JAVADOC_AUTOBRIEF = YES
        \\FULL_PATH_NAMES = NO
        \\STRIP_FROM_PATH = include
        \\INPUT = doc/ffi.md include/muxly.h
        \\FILE_PATTERNS = *.md *.h
        \\RECURSIVE = NO
        \\USE_MDFILE_AS_MAINPAGE = doc/ffi.md
        \\MARKDOWN_SUPPORT = YES
    , .{ffi_docs_root}));
    const build_ffi_docs = b.addSystemCommand(&.{"doxygen"});
    build_ffi_docs.setCwd(b.path("."));
    // `addFileArg` makes the generated Doxyfile an input dependency of this run step.
    build_ffi_docs.addFileArg(ffi_doxyfile);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/unit/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "muxly", .module = muxly_module },
                .{ .name = "cli_target_arg", .module = b.createModule(.{
                    .root_source_file = b.path("src/cli/target_arg.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "muxly", .module = muxly_module },
                    },
                }) },
                .{ .name = "daemon_router", .module = b.createModule(.{
                    .root_source_file = b.path("src/daemon/router.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "muxly", .module = muxly_module },
                    },
                }) },
            },
        }),
    });
    setTimedTestExec(b, unit_tests, unit_test_timeout_seconds);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const run_docker_transport_tests = addTimedSystemCommand(b, docker_transport_timeout_seconds, &.{
        "python3",
        "tests/integration/docker_transport_test.py",
        "--skip-build",
    });
    run_docker_transport_tests.setCwd(b.path("."));
    run_docker_transport_tests.step.dependOn(&install_cli.step);
    run_docker_transport_tests.step.dependOn(&install_daemon.step);

    const test_docker_step = b.step(
        "test-docker",
        "Run Docker-backed transport integration tests",
    );
    test_docker_step.dependOn(&run_docker_transport_tests.step);

    const run_transport_tests = addTimedSystemCommand(b, transport_integration_timeout_seconds, &.{
        "python3",
        "-m",
        "pytest",
        "-q",
        "tests/integration/http_h3wt_transport_test.py",
    });
    run_transport_tests.setCwd(b.path("."));
    run_transport_tests.step.dependOn(&install_cli.step);
    run_transport_tests.step.dependOn(&install_daemon.step);
    run_transport_tests.step.dependOn(&install_transport_bridge.step);

    const test_transport_step = b.step(
        "test-transport",
        "Run transport integration tests",
    );
    const run_transport_bridge_unit_tests = addTimedSystemCommand(
        b,
        transport_bridge_unit_timeout_seconds,
        &.{ "cargo", "test" },
    );
    run_transport_bridge_unit_tests.setCwd(b.path("tools/transport_bridge"));
    const async_transport_validation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/async_transport_validation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "muxly", .module = muxly_module },
            },
        }),
    });
    setTimedTestExec(b, async_transport_validation_tests, transport_integration_timeout_seconds);
    const run_async_transport_validation_tests = b.addRunArtifact(async_transport_validation_tests);
    run_async_transport_validation_tests.step.dependOn(&install_daemon.step);
    run_async_transport_validation_tests.step.dependOn(&install_transport_bridge.step);
    run_async_transport_validation_tests.setEnvironmentVariable(
        "MUXLY_TEST_DAEMON_BINARY",
        b.getInstallPath(.prefix, "bin/muxlyd"),
    );
    test_transport_step.dependOn(&run_transport_bridge_unit_tests.step);
    test_transport_step.dependOn(&run_transport_tests.step);
    test_transport_step.dependOn(&run_async_transport_validation_tests.step);

    const run_transport_stress_tests = addTimedSystemCommand(b, transport_stress_timeout_seconds, &.{
        "python3",
        "tests/integration/transport_stress_test.py",
        "--skip-build",
    });
    run_transport_stress_tests.setCwd(b.path("."));
    run_transport_stress_tests.step.dependOn(&install_daemon.step);
    run_transport_stress_tests.step.dependOn(&install_transport_bridge.step);
    run_transport_stress_tests.step.dependOn(&install_async_transport_stress_probe.step);
    run_transport_stress_tests.setEnvironmentVariable(
        "MUXLY_TEST_DAEMON_BINARY",
        b.getInstallPath(.prefix, "bin/muxlyd"),
    );
    run_transport_stress_tests.setEnvironmentVariable(
        "MUXLY_ASYNC_STRESS_PROBE_BINARY",
        b.getInstallPath(.prefix, "bin/muxly-async-transport-probe"),
    );

    const test_transport_stress_step = b.step(
        "test-transport-stress",
        "Run randomized transport stress coverage",
    );
    test_transport_stress_step.dependOn(&run_transport_stress_tests.step);

    const test_ci_step = b.step(
        "test-ci",
        "Run CI tests; add Docker transport coverage when MUXLY_ENABLE_DOCKER_TESTS is enabled",
    );
    test_ci_step.dependOn(&run_unit_tests.step);
    if (docker_tests_enabled) {
        test_ci_step.dependOn(&run_docker_transport_tests.step);
    }

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

    const async_transport_stress_probe_step = b.step(
        "async-transport-stress-probe",
        "Build async transport stress probe",
    );
    async_transport_stress_probe_step.dependOn(&install_async_transport_stress_probe.step);

    const ffi_docs_step = b.step("docs-ffi", "Build generated C/FFI reference docs");
    ffi_docs_step.dependOn(&build_ffi_docs.step);

    const docs_step = b.step("docs", "Build generated Zig and C/FFI API documentation");
    docs_step.dependOn(&install_api_docs.step);
    docs_step.dependOn(&build_ffi_docs.step);
}
