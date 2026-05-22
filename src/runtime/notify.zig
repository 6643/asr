const std = @import("std");
const cmd = @import("cmd.zig");

const mic_ready_sound_path = "/usr/share/sounds/freedesktop/stereo/bell.oga";

pub fn playMicReadyNotification(allocator: std.mem.Allocator, io: std.Io) void {
    cmd.runDiscard(allocator, io, &.{ "pw-play", mic_ready_sound_path }, 2000) catch {};
}
