const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("asr_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket", .module = websocket_dep.module("websocket") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "asr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asr_zig", .module = mod },
                .{ .name = "websocket", .module = websocket_dep.module("websocket") },
            },
        }),
    });
    b.installArtifact(exe);

    const install_exe = b.addExecutable(.{
        .name = "asr-install",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/install.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "asr_zig", .module = mod },
            },
        }),
    });
    b.installArtifact(install_exe);

    const run_step = b.step("run", "Run ASR");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const install_run_step = b.step("install-ibus", "Install IBus component XML");
    const install_run_cmd = b.addRunArtifact(install_exe);
    install_run_cmd.step.dependOn(b.getInstallStep());
    install_run_step.dependOn(&install_run_cmd.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
