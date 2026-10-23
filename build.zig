const std = @import("std");
const builtin = @import("builtin");
const package = @import("build.zig.zon");
const required_zig = std.mem.trim(u8, @embedFile(".zigversion"), "\r\n");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, required_zig)) {
        @compileError("Use the exact Zig version in .zigversion");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    options.addOption([]const u8, "version", package.version);
    const core = b.addModule("shulvyr", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core.addOptions("build_options", options);
    core.addAnonymousImport("bedrock_data", .{
        .root_source_file = b.path("data/bedrock/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const executable = b.addExecutable(.{
        .name = "shulvyr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "shulvyr", .module = core }},
        }),
    });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run the foundation runtime").dependOn(&run.step);

    const unit_tests = b.addTest(.{ .root_module = core });
    const test_step = b.step("test", "Run unit and CLI integration tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    const compile_tests = b.step("test-compile", "Compile tests without running them");
    compile_tests.dependOn(&unit_tests.step);

    const version = b.addRunArtifact(executable);
    version.addArg("--version");
    version.expectStdOutEqual(b.fmt("Shulvyr {s}\n", .{package.version}));
    version.expectStdErrEqual("");
    test_step.dependOn(&version.step);

    const finite_run = b.addRunArtifact(executable);
    finite_run.addArgs(&.{ "--ticks", "2", "--tick-rate", "1000" });
    finite_run.expectStdOutEqual(b.fmt("Shulvyr {s} foundation runtime\nStopped after 2 ticks\n", .{package.version}));
    finite_run.expectStdErrEqual("");
    test_step.dependOn(&finite_run.step);

    const invalid = b.addRunArtifact(executable);
    invalid.addArgs(&.{ "--ticks", "0" });
    invalid.expectExitCode(2);
    invalid.expectStdOutEqual("");
    invalid.expectStdErrEqual("error: InvalidValue\n");
    test_step.dependOn(&invalid.step);

    const fixture_module = b.createModule(.{
        .root_source_file = b.path("tools/check_transport_fixtures.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixture_checker = b.addExecutable(.{ .name = "check-transport-fixtures", .root_module = fixture_module });
    const check_fixtures = b.addRunArtifact(fixture_checker);
    check_fixtures.setCwd(b.path("."));
    check_fixtures.has_side_effects = true;
    const fixture_step = b.step("check-transport-fixtures", "Verify signaling and SDP fixtures using Zig");
    fixture_step.dependOn(&check_fixtures.step);
    const fixture_tests = b.addTest(.{ .root_module = fixture_module });
    fixture_step.dependOn(&b.addRunArtifact(fixture_tests).step);

    const all_fixture_module = b.createModule(.{
        .root_source_file = b.path("tools/check_fixtures.zig"),
        .target = target,
        .optimize = optimize,
    });
    const all_fixture_checker = b.addExecutable(.{ .name = "check-fixtures", .root_module = all_fixture_module });
    const check_all_fixtures = b.addRunArtifact(all_fixture_checker);
    check_all_fixtures.setCwd(b.path("."));
    check_all_fixtures.has_side_effects = true;
    const all_fixture_step = b.step("check-fixtures", "Verify all oracle fixtures using Zig");
    all_fixture_step.dependOn(&check_all_fixtures.step);
    const all_fixture_tests = b.addTest(.{ .root_module = all_fixture_module });
    all_fixture_step.dependOn(&b.addRunArtifact(all_fixture_tests).step);

    const transport_test = b.step("test-native-transport", "Run the optional native WebRTC C API probe");
    if (b.option([]const u8, "native-transport-prefix", "Prefix produced by tools/native-transport/build_probe.py")) |prefix| {
        const api = b.addTranslateC(.{
            .root_source_file = b.path("src/transport/webrtc/rtc_api.h"),
            .target = target,
            .optimize = optimize,
        });
        api.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        const rtc = api.createModule();
        const webrtc = b.addModule("webrtc", .{
            .root_source_file = b.path("src/transport/webrtc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "shulvyr", .module = core },
                .{ .name = "rtc", .module = rtc },
            },
        });
        const library_path = b.pathJoin(&.{ prefix, "lib" });
        webrtc.addLibraryPath(.{ .cwd_relative = library_path });
        webrtc.addRPath(.{ .cwd_relative = library_path });
        webrtc.linkSystemLibrary("datachannel", .{});
        const probe_module = b.createModule(.{
            .root_source_file = b.path("tools/native-transport/probe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "shulvyr", .module = core },
                .{ .name = "webrtc", .module = webrtc },
            },
        });
        const probe = b.addExecutable(.{ .name = "transport-probe", .root_module = probe_module });
        const run_probe = b.addRunArtifact(probe);
        const native_tests = b.addTest(.{ .root_module = webrtc, .filters = &.{"WebRTC"} });
        const run_native_tests = b.addRunArtifact(native_tests);
        run_native_tests.has_side_effects = true;
        if (target.result.os.tag == .windows) {
            run_probe.setEnvironmentVariable("PATH", b.fmt("{s};{s}", .{
                b.pathJoin(&.{ prefix, "bin" }), b.graph.environ_map.get("PATH") orelse "",
            }));
            run_native_tests.setEnvironmentVariable("PATH", b.fmt("{s};{s}", .{
                b.pathJoin(&.{ prefix, "bin" }), b.graph.environ_map.get("PATH") orelse "",
            }));
        }
        transport_test.dependOn(&run_probe.step);
        transport_test.dependOn(&run_native_tests.step);
    } else {
        transport_test.dependOn(&b.addFail("Run tools/native-transport/build_probe.py and supply -Dnative-transport-prefix").step);
    }
}
