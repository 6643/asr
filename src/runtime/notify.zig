const std = @import("std");
const cmd = @import("cmd.zig");

/// Bell files we try in order: the NixOS system profile (where the
/// freedesktop sounds actually live) before the conventional FHS path.
pub const bell_candidates = [_][]const u8{
    "/run/current-system/sw/share/sounds/freedesktop/stereo/bell.oga",
    "/usr/share/sounds/freedesktop/stereo/bell.oga",
};

/// Index of the first candidate the caller can see, or null when none exists
/// (a missing sound must never block the mic-ready notification path).
pub fn selectBellIndex(
    candidates: []const []const u8,
    ctx: ?*anyopaque,
    exists_fn: *const fn (ctx: ?*anyopaque, path: []const u8) bool,
) ?usize {
    for (candidates, 0..) |path, index| {
        if (exists_fn(ctx, path)) return index;
    }
    return null;
}

fn bellExists(ctx: ?*anyopaque, path: []const u8) bool {
    const io: *const std.Io = @ptrCast(@alignCast(ctx.?));
    const file = std.Io.Dir.cwd().openFile(io.*, path, .{}) catch return false;
    file.close(io.*);
    return true;
}

pub fn playMicReadyNotification(allocator: std.mem.Allocator, io: std.Io) void {
    var io_ctx = io;
    const index = selectBellIndex(&bell_candidates, &io_ctx, bellExists) orelse return;
    cmd.runDiscard(allocator, io, &.{ "pw-play", bell_candidates[index] }, 2000) catch {};
}

test "selects the first existing bell candidate" {
    const only_second = struct {
        fn exists(ctx: ?*anyopaque, path: []const u8) bool {
            _ = ctx;
            return std.mem.endsWith(u8, path, "second.oga");
        }
    }.exists;
    const candidates = [_][]const u8{ "/a/first.oga", "/b/second.oga" };
    try std.testing.expectEqual(@as(?usize, 1), selectBellIndex(&candidates, null, only_second));

    const never = struct {
        fn exists(ctx: ?*anyopaque, path: []const u8) bool {
            _ = ctx;
            _ = path;
            return false;
        }
    }.exists;
    try std.testing.expect(selectBellIndex(&candidates, null, never) == null);
}

test "bell candidates prefer the nixos system profile" {
    try std.testing.expectEqualSlices([]const u8, &.{
        "/run/current-system/sw/share/sounds/freedesktop/stereo/bell.oga",
        "/usr/share/sounds/freedesktop/stereo/bell.oga",
    }, &bell_candidates);
}
