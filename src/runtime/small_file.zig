const std = @import("std");

pub const max_bytes_default: usize = 1024 * 1024;

/// Reads a small file in streaming mode. procfs/sysfs report `stat.size == 0`,
/// so `std.Io.Dir.readFileAlloc` returns an empty buffer for them even though
/// the real content is readable until EOF.
pub fn readAll(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        // EOF arrives as error.EndOfStream; a 0-length read is also treated as
        // end so the loop can never spin forever.
        const n = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        if (out.items.len + n > max_bytes) return error.FileTooBig;
        try out.appendSlice(allocator, buffer[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

test "reads a procfs file that reports size zero" {
    // Streaming must work even though procfs reports stat.size == 0. /proc/self/
    // status is present in every Linux environment (CI containers included).
    const content = try readAll(std.testing.io, std.testing.allocator, "/proc/self/status", max_bytes_default);
    defer std.testing.allocator.free(content);
    try std.testing.expect(content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, content, "Name:") != null);
}

test "reads the kernel input device list when it exists" {
    const content = readAll(std.testing.io, std.testing.allocator, "/proc/bus/input/devices", max_bytes_default) catch |err| {
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer std.testing.allocator.free(content);
    try std.testing.expect(content.len > 0);
}

test "missing file is an error" {
    try std.testing.expectError(
        error.FileNotFound,
        readAll(std.testing.io, std.testing.allocator, "/proc/definitely-not-here", max_bytes_default),
    );
}

test "refuses to read past the cap" {
    try std.testing.expectError(
        error.FileTooBig,
        readAll(std.testing.io, std.testing.allocator, "/proc/self/status", 16),
    );
}
