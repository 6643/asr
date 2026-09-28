const std = @import("std");

pub const ModeTag = enum {
    app,
    once_pcm,
    help,
};

pub const Engine = enum { baidu, doubao };

pub const Mode = union(ModeTag) {
    app: void,
    once_pcm: []const u8,
    help: void,
};

/// Capture stops on its own after this many milliseconds of holding the
/// hotkey, so a lost key-release event cannot leave a session running.
pub const default_max_hold_ms: i64 = 120_000;

pub const Options = struct {
    mode: Mode = .app,
    engine: Engine = .doubao,
    debug: bool = false,
    rectify: bool = true,
    max_hold_ms: i64 = default_max_hold_ms,
    log_file: ?[]const u8 = null,
};

pub const usage_text =
    \\usage: asr [options]
    \\
    \\  --doubao              use the doubao engine (default)
    \\  --baidu               use the baidu engine
    \\  --once-pcm <path>     transcribe one raw PCM file and exit
    \\  --debug               verbose logging
    \\  --no-rectify          skip result rectification
    \\  --max-hold-ms <n>     stop capture after n ms (0 = unlimited, default 120000)
    \\  --log-file <path>     append logs to a file instead of the terminal
    \\  --help                show this message
    \\
;

pub const ArgError = error{
    UnknownArgument,
    MissingArgumentValue,
    InvalidArgumentValue,
};

pub fn optionsFromArgs(args: []const [:0]const u8) ArgError!Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.mode = .help;
        } else if (std.mem.eql(u8, arg, "--doubao")) {
            options.engine = .doubao;
        } else if (std.mem.eql(u8, arg, "--baidu")) {
            options.engine = .baidu;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            options.debug = true;
        } else if (std.mem.eql(u8, arg, "--no-rectify")) {
            options.rectify = false;
        } else if (std.mem.eql(u8, arg, "--once-pcm")) {
            options.mode = .{ .once_pcm = try valueAfter(args, &index) };
        } else if (std.mem.eql(u8, arg, "--max-hold-ms")) {
            const value = try valueAfter(args, &index);
            options.max_hold_ms = std.fmt.parseInt(i64, value, 10) catch return error.InvalidArgumentValue;
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            options.log_file = try valueAfter(args, &index);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArgument;
        }
    }
    return options;
}

fn valueAfter(args: []const [:0]const u8, index: *usize) ArgError![]const u8 {
    if (index.* + 1 >= args.len) return error.MissingArgumentValue;
    index.* += 1;
    return args[index.*];
}

test "no args starts app mode" {
    const args = [_][:0]const u8{"asr"};
    const opts = try optionsFromArgs(&args);
    try std.testing.expectEqual(ModeTag.app, std.meta.activeTag(opts.mode));
    try std.testing.expect(!opts.debug);
    try std.testing.expect(opts.rectify);
    try std.testing.expectEqual(@as(i64, 120_000), opts.max_hold_ms);
    try std.testing.expect(opts.log_file == null);
}

test "recognizes once pcm mode" {
    const args = [_][:0]const u8{ "asr", "--once-pcm", "/tmp/asr-debug.pcm" };
    const opts = try optionsFromArgs(&args);
    try std.testing.expectEqual(ModeTag.once_pcm, std.meta.activeTag(opts.mode));
    try std.testing.expectEqualStrings("/tmp/asr-debug.pcm", opts.mode.once_pcm);
}

test "recognizes debug flag" {
    const args = [_][:0]const u8{ "asr", "--debug" };
    try std.testing.expect((try optionsFromArgs(&args)).debug);
}

test "defaults to doubao engine" {
    const args = [_][:0]const u8{"asr"};
    try std.testing.expectEqual(Engine.doubao, (try optionsFromArgs(&args)).engine);
}

test "recognizes explicit baidu engine" {
    const args = [_][:0]const u8{ "asr", "--baidu" };
    try std.testing.expectEqual(Engine.baidu, (try optionsFromArgs(&args)).engine);
}

test "rejects unknown arguments" {
    const args = [_][:0]const u8{ "asr", "--nope" };
    try std.testing.expectError(error.UnknownArgument, optionsFromArgs(&args));
}

test "rejects options without a value" {
    const once_pcm = [_][:0]const u8{ "asr", "--once-pcm" };
    try std.testing.expectError(error.MissingArgumentValue, optionsFromArgs(&once_pcm));
    const max_hold = [_][:0]const u8{ "asr", "--max-hold-ms" };
    try std.testing.expectError(error.MissingArgumentValue, optionsFromArgs(&max_hold));
    const log_file = [_][:0]const u8{ "asr", "--log-file" };
    try std.testing.expectError(error.MissingArgumentValue, optionsFromArgs(&log_file));
}

test "rejects a non numeric max hold duration" {
    const args = [_][:0]const u8{ "asr", "--max-hold-ms", "soon" };
    try std.testing.expectError(error.InvalidArgumentValue, optionsFromArgs(&args));
}

test "parses hardening flags" {
    const args = [_][:0]const u8{ "asr", "--no-rectify", "--max-hold-ms", "3000", "--log-file", "/tmp/a.log" };
    const opts = try optionsFromArgs(&args);
    try std.testing.expect(!opts.rectify);
    try std.testing.expectEqual(@as(i64, 3000), opts.max_hold_ms);
    try std.testing.expectEqualStrings("/tmp/a.log", opts.log_file.?);
}

test "help mode prints usage" {
    const args = [_][:0]const u8{ "asr", "--help" };
    try std.testing.expectEqual(ModeTag.help, std.meta.activeTag((try optionsFromArgs(&args)).mode));
    try std.testing.expect(std.mem.indexOf(u8, usage_text, "--max-hold-ms") != null);
}
