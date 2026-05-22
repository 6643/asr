const std = @import("std");

pub const ModeTag = enum {
    app,
    ibus_service,
    ibus_xml,
    once_pcm,
};

pub const Mode = union(ModeTag) {
    app: void,
    ibus_service: void,
    ibus_xml: void,
    once_pcm: []const u8,
};

pub fn modeFromArgs(args: []const [:0]const u8) Mode {
    if (hasArg(args, "--ibus-xml")) return .ibus_xml;
    if (hasArg(args, "--ibus")) return .ibus_service;
    if (findArgValue(args, "--once-pcm")) |pcm_path| return .{ .once_pcm = pcm_path };
    return .app;
}

pub fn hasArg(args: []const [:0]const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

pub fn findArgValue(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| {
        if (!std.mem.eql(u8, arg, name)) continue;
        if (index + 1 >= args.len) return null;
        return args[index + 1];
    }
    return null;
}

test "no args starts app mode" {
    const args = [_][:0]const u8{"asr"};
    try std.testing.expectEqual(ModeTag.app, std.meta.activeTag(modeFromArgs(&args)));
}

test "recognizes ibus xml mode" {
    const args = [_][:0]const u8{ "asr", "--ibus-xml" };
    try std.testing.expectEqual(ModeTag.ibus_xml, std.meta.activeTag(modeFromArgs(&args)));
}

test "recognizes once pcm mode" {
    const args = [_][:0]const u8{ "asr", "--once-pcm", "/tmp/asr-debug.pcm" };
    const mode = modeFromArgs(&args);
    try std.testing.expectEqual(ModeTag.once_pcm, std.meta.activeTag(mode));
    try std.testing.expectEqualStrings("/tmp/asr-debug.pcm", mode.once_pcm);
}
