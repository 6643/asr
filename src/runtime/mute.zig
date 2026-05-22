const std = @import("std");
const cmd = @import("cmd.zig");

const sink = "@DEFAULT_AUDIO_SINK@";

const MuteState = struct {
    mutex: std.Io.Mutex = .init,
    muted_by_us: bool = false,
};

var state: MuteState = .{};

pub fn muteSpeaker(allocator: std.mem.Allocator, io: std.Io) void {
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    if (state.muted_by_us) return;
    if (speakerIsMuted(allocator, io)) return;
    state.muted_by_us = runMute(allocator, io, true);
}

pub fn unmuteSpeaker(allocator: std.mem.Allocator, io: std.Io) void {
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    if (!state.muted_by_us) return;
    state.muted_by_us = !runMute(allocator, io, false);
}

pub fn resetMuteState(io: std.Io) void {
    state.mutex.lockUncancelable(io);
    state.muted_by_us = false;
    state.mutex.unlock(io);
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
    return std.mem.indexOf(u8, output, "[MUTED]") != null;
}

test "detects muted output" {
    try std.testing.expect(isMutedOutput("Volume: 0.45 [MUTED]\n"));
    try std.testing.expect(!isMutedOutput("Volume: 0.45\n"));
}
