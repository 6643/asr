const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const websocket_mod = b.addModule("websocket", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .root_source_file = b.path("vendor/websocket/src/websocket.zig"),
    });
    {
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", false);
        websocket_mod.addOptions("build", options);
    }

    const mod = b.addModule("asr_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket", .module = websocket_mod },
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
                .{ .name = "websocket", .module = websocket_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run ASR");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig" }, .check = true });
    const check_step = b.step("check", "zig fmt --check plus tests");
    check_step.dependOn(&fmt_check.step);
    check_step.dependOn(&run_tests.step);
}
