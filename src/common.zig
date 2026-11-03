//! Small primitives shared by both engine clients.

const std = @import("std");

/// Handshake timeout for both engines. Tight on purpose: the session is
/// opened while the user is already holding the hotkey.
pub const ws_handshake_timeout_ms: u32 = 3_000;

/// A 32-character lowercase hex id from `io` randomness, used as a request id
/// (doubao) or session number (baidu).
pub fn randomHexId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return allocator.dupe(u8, &hex);
}

/// Zero-pads the last short audio frame so every frame is `len` bytes.
pub fn paddedFrame(allocator: std.mem.Allocator, bytes: []const u8, len: usize) ![]u8 {
    const out = try allocator.alloc(u8, len);
    @memset(out, 0);
    @memcpy(out[0..bytes.len], bytes);
    return out;
}

/// Builds a `curl` argv whose TLS request goes straight to the host. The
/// engines and both auxiliary endpoints are domestic, so the environment's
/// proxy (`http(s)_proxy`, `all_proxy`) can only add latency and a split of
/// traffic the proxy does not need to see. `--noproxy "*"` overrides
/// `no_proxy` too, which matters because otherwise the env var alone can be
/// re-enabled by the caller's shell.
pub fn directCurlArgv(allocator: std.mem.Allocator, args: []const []const u8) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "curl", "--noproxy", "*" });
    try argv.appendSlice(allocator, args);
    return argv;
}

test "curl argv ignores the environment proxy" {
    const allocator = std.testing.allocator;
    var argv = try directCurlArgv(allocator, &.{ "-s", "https://example.com" });
    defer argv.deinit(allocator);
    try std.testing.expectEqualSlices(
        []const u8,
        &[_][]const u8{ "curl", "--noproxy", "*", "-s", "https://example.com" },
        argv.items,
    );
}

test "random ids are 32 lowercase hex characters" {
    const allocator = std.testing.allocator;
    const id = try randomHexId(allocator, std.testing.io);
    defer allocator.free(id);
    try std.testing.expectEqual(@as(usize, 32), id.len);
    for (id) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
}

test "pads a short final pcm frame" {
    const allocator = std.testing.allocator;
    const frame = try paddedFrame(allocator, "abc", 6);
    defer allocator.free(frame);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c', 0, 0, 0 }, frame);
}
