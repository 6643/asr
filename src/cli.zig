const std = @import("std");

pub const ModeTag = enum {
    app,
    ibus_service,
    ibus_xml,
    once_pcm,
};

pub const Engine = enum { baidu, doubao };

pub const Mode = union(ModeTag) {
    app: void,
    ibus_service: void,
    ibus_xml: void,
    once_pcm: []const u8,
};

pub const Options = struct {
    mode: Mode,
    engine: Engine = .baidu,
    debug: bool = false,
};

pub fn optionsFromArgs(args: []const [:0]const u8) Options {
    return .{
        .mode = modeFromArgs(args),
        .engine = if (hasArg(args, "--baidu")) .baidu else .doubao,
        .debug = hasArg(args, "--debug"),
    };
}

fn modeFromArgs(args: []const [:0]const u8) Mode {
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
    const opts = optionsFromArgs(&args);
    try std.testing.expectEqual(ModeTag.app, std.meta.activeTag(opts.mode));
    try std.testing.expect(!opts.debug);
}

test "recognizes ibus xml mode" {
    const args = [_][:0]const u8{ "asr", "--ibus-xml" };
    try std.testing.expectEqual(ModeTag.ibus_xml, std.meta.activeTag(optionsFromArgs(&args).mode));
}

test "recognizes once pcm mode" {
    const args = [_][:0]const u8{ "asr", "--once-pcm", "/tmp/asr-debug.pcm" };
    const opts = optionsFromArgs(&args);
    try std.testing.expectEqual(ModeTag.once_pcm, std.meta.activeTag(opts.mode));
    try std.testing.expectEqualStrings("/tmp/asr-debug.pcm", opts.mode.once_pcm);
}

test "recognizes debug flag" {
    const args = [_][:0]const u8{ "asr", "--debug" };
    try std.testing.expect(optionsFromArgs(&args).debug);
}

test "defaults to doubao engine" {
    const args = [_][:0]const u8{"asr"};
    try std.testing.expectEqual(Engine.doubao, optionsFromArgs(&args).engine);
}

test "recognizes explicit baidu engine" {
    const args = [_][:0]const u8{ "asr", "--baidu" };
    try std.testing.expectEqual(Engine.baidu, optionsFromArgs(&args).engine);
}
