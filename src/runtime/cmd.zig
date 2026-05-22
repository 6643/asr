const std = @import("std");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    timeout_ms: i64,
) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        } },
    });
}

pub fn runDiscard(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    timeout_ms: i64,
) !void {
    const result = try run(allocator, io, argv, timeout_ms);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.CommandFailed;
}

pub fn runText(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    timeout_ms: i64,
) ![]u8 {
    const result = try run(allocator, io, argv, timeout_ms);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}
