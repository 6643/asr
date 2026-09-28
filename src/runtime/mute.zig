const std = @import("std");
const cmd = @import("cmd.zig");

const sink = "@DEFAULT_AUDIO_SINK@";

/// Left behind while we hold the default sink muted, so a crash can be undone
/// on the next start (see `recoverStaleMute`).
pub const marker_name = "asr-speaker-muted";

const MuteState = struct {
    mutex: std.Io.Mutex = .init,
    muted_by_us: bool = false,
    /// Borrowed slice of `marker_path_buffer`: nothing to free at exit.
    marker_path: ?[]const u8 = null,
    marker_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
};

var state: MuteState = .{};

/// Records where the "we muted the sink" marker lives; without
/// `$XDG_RUNTIME_DIR` crash recovery is disabled but muting still works.
pub fn setMarkerPath(io: std.Io, environ: std.process.Environ) void {
    const runtime_dir = std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR");
    const path = markerPathWith(&state.marker_path_buffer, runtime_dir) orelse {
        state.marker_path = null;
        return;
    };
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    state.marker_path = path;
}

/// Undoes a mute we left behind when the process was killed mid-capture.
/// Returns true when a stale marker was found and the sink unmuted.
pub fn recoverStaleMute(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) bool {
    const runtime_dir = std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = markerPathWith(&buffer, runtime_dir) orelse return false;
    if (!markerExists(io, path)) return false;
    const unmuted = runMute(allocator, io, false);
    clearMarker(io, path);
    return unmuted;
}

pub fn markerPathWith(buffer: []u8, runtime_dir: ?[]const u8) ?[]const u8 {
    const dir = runtime_dir orelse return null;
    if (dir.len == 0) return null;
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ dir, marker_name }) catch null;
}

pub fn markerExists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn writeMarker(io: std.Io, path: []const u8) void {
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return;
    file.close(io);
}

pub fn clearMarker(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub fn muteSpeaker(allocator: std.mem.Allocator, io: std.Io) void {
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    if (state.muted_by_us) return;
    if (speakerIsMuted(allocator, io)) return;
    state.muted_by_us = runMute(allocator, io, true);
    if (state.muted_by_us) {
        if (state.marker_path) |path| writeMarker(io, path);
    }
}

pub fn unmuteSpeaker(allocator: std.mem.Allocator, io: std.Io) void {
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    if (!state.muted_by_us) return;
    state.muted_by_us = !runMute(allocator, io, false);
    if (!state.muted_by_us) {
        if (state.marker_path) |path| clearMarker(io, path);
    }
}

fn speakerIsMuted(allocator: std.mem.Allocator, io: std.Io) bool {
    const out = cmd.runText(allocator, io, &.{ "wpctl", "get-volume", sink }, 1000) catch return false;
    defer allocator.free(out);
    return isMutedOutput(out);
}

fn runMute(allocator: std.mem.Allocator, io: std.Io, mute: bool) bool {
    const value = if (mute) "1" else "0";
    cmd.runDiscard(allocator, io, &.{ "wpctl", "set-mute", sink, value }, 1000) catch return false;
    return true;
}

fn isMutedOutput(output: []const u8) bool {
    return std.ascii.findIgnoreCase(output, "MUTED") != null;
}

test "detects muted output regardless of case" {
    try std.testing.expect(isMutedOutput("Volume: 0.45 [MUTED]\n"));
    try std.testing.expect(isMutedOutput("Volume: 0.45 [muted]\n"));
    try std.testing.expect(!isMutedOutput("Volume: 0.45\n"));
}

test "builds the marker path from the runtime dir" {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = markerPathWith(&buffer, "/run/user/1000").?;
    try std.testing.expectEqualStrings("/run/user/1000/asr-speaker-muted", path);
    try std.testing.expect(markerPathWith(&buffer, null) == null);
    try std.testing.expect(markerPathWith(&buffer, "") == null);
}

test "marker round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "asr-speaker-muted" });
    defer std.testing.allocator.free(path);

    try std.testing.expect(!markerExists(std.testing.io, path));
    writeMarker(std.testing.io, path);
    try std.testing.expect(markerExists(std.testing.io, path));
    clearMarker(std.testing.io, path);
    try std.testing.expect(!markerExists(std.testing.io, path));
}
