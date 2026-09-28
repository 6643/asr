const std = @import("std");

/// Captures raw PCM from PipeWire and writes it to stdout.
pub const Params = struct {
    rate: []const u8,
    channels: []const u8,
};

pub const max_args = 12;

pub const Args = struct {
    items: [max_args][]const u8 = undefined,
    count: usize = 0,

    pub fn slice(self: *const Args) []const []const u8 {
        return self.items[0..self.count];
    }

    fn push(self: *Args, value: []const u8) void {
        std.debug.assert(self.count < max_args);
        self.items[self.count] = value;
        self.count += 1;
    }
};

pub fn program() []const u8 {
    return "pw-record";
}

/// Builds the capture command line; `params` strings must outlive the
/// returned argv.
pub fn buildArgv(params: Params) Args {
    var argv = Args{};
    argv.push(program());
    argv.push("--rate");
    argv.push(params.rate);
    argv.push("--channels");
    argv.push(params.channels);
    argv.push("--format");
    argv.push("s16");
    argv.push("-");
    return argv;
}

pub fn spawn(io: std.Io, params: Params) anyerror!std.process.Child {
    const argv = buildArgv(params);
    return std.process.spawn(io, .{
        .argv = argv.slice(),
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
}

test "pw-record argv captures raw s16 at the requested rate and channels" {
    const argv = buildArgv(.{ .rate = "16000", .channels = "1" });
    try std.testing.expectEqualSlices(
        []const u8,
        &[_][]const u8{ "pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", "-" },
        argv.slice(),
    );
}

test "program is pw-record" {
    try std.testing.expectEqualStrings("pw-record", program());
}
