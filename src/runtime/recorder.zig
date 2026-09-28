const std = @import("std");

/// External PCM recorders we know how to drive. `arecord` stays first for
/// compatibility; `pw-record` is the PipeWire-only fallback.
pub const Kind = enum { arecord, pw_record };

/// Pre-formatted capture parameters shared by every recorder command line.
pub const Params = struct {
    rate: []const u8,
    channels: []const u8,
    device: ?[]const u8 = null,
};

pub const max_args = 12;

pub const Argv = struct {
    items: [max_args][]const u8 = undefined,
    count: usize = 0,

    pub fn slice(self: *const Argv) []const []const u8 {
        return self.items[0..self.count];
    }

    fn push(self: *Argv, value: []const u8) void {
        std.debug.assert(self.count < max_args);
        self.items[self.count] = value;
        self.count += 1;
    }
};

pub const candidates = [_]Kind{ .arecord, .pw_record };

pub fn program(kind: Kind) []const u8 {
    return switch (kind) {
        .arecord => "arecord",
        .pw_record => "pw-record",
    };
}

/// Builds one recorder's capture command line; `params` strings must outlive
/// the returned argv.
pub fn buildArgv(kind: Kind, params: Params) Argv {
    var argv = Argv{};
    switch (kind) {
        .arecord => {
            argv.push(program(kind));
            argv.push("-f");
            argv.push("S16_LE");
            argv.push("-r");
            argv.push(params.rate);
            argv.push("-c");
            argv.push(params.channels);
            argv.push("-t");
            argv.push("raw");
            if (params.device) |device| {
                argv.push("-D");
                argv.push(device);
            }
        },
        .pw_record => {
            argv.push(program(kind));
            argv.push("--rate");
            argv.push(params.rate);
            argv.push("--channels");
            argv.push(params.channels);
            argv.push("--format");
            argv.push("s16");
            if (params.device) |device| {
                argv.push("--target");
                argv.push(device);
            }
            argv.push("-");
        },
    }
    return argv;
}

pub const SpawnFn = *const fn (io: std.Io, argv: []const []const u8) anyerror!std.process.Child;

pub const Spawned = struct {
    child: std.process.Child,
    kind: Kind,
};

/// Spawns the first available recorder. A missing binary (FileNotFound) moves
/// on to the next candidate; any other spawn error aborts the fallback.
pub fn spawnFirstWith(io: std.Io, params: Params, spawn_fn: SpawnFn) !Spawned {
    var last_error: anyerror = error.FileNotFound;
    for (candidates) |kind| {
        const argv = buildArgv(kind, params);
        if (spawn_fn(io, argv.slice())) |child| {
            return .{ .child = child, .kind = kind };
        } else |err| {
            if (err != error.FileNotFound) return err;
            last_error = err;
        }
    }
    return last_error;
}

pub fn spawn(io: std.Io, argv: []const []const u8) anyerror!std.process.Child {
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
}

pub fn spawnFirst(io: std.Io, params: Params) anyerror!Spawned {
    return spawnFirstWith(io, params, spawn);
}

test "arecord argv captures raw s16 at the requested rate and channels" {
    const argv = buildArgv(.arecord, .{ .rate = "16000", .channels = "1" });
    try std.testing.expectEqualSlices(
        []const u8,
        &[_][]const u8{ "arecord", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw" },
        argv.slice(),
    );
}

test "arecord argv passes an explicit device through -D" {
    const argv = buildArgv(.arecord, .{ .rate = "16000", .channels = "1", .device = "plughw:1,0" });
    try std.testing.expectEqualSlices(
        []const u8,
        &[_][]const u8{ "arecord", "-f", "S16_LE", "-r", "16000", "-c", "1", "-t", "raw", "-D", "plughw:1,0" },
        argv.slice(),
    );
}

test "pw-record argv writes raw s16 to stdout" {
    const argv = buildArgv(.pw_record, .{ .rate = "16000", .channels = "1" });
    try std.testing.expectEqualSlices(
        []const u8,
        &[_][]const u8{ "pw-record", "--rate", "16000", "--channels", "1", "--format", "s16", "-" },
        argv.slice(),
    );
}

test "pw-record argv maps an explicit device to --target" {
    const argv = buildArgv(.pw_record, .{ .rate = "16000", .channels = "1", .device = "alsa_input.pci-0000_00_1f.3.analog-stereo" });
    try std.testing.expectEqualSlices(
        []const u8,
        &[_][]const u8{
            "pw-record",
            "--rate",
            "16000",
            "--channels",
            "1",
            "--format",
            "s16",
            "--target",
            "alsa_input.pci-0000_00_1f.3.analog-stereo",
            "-",
        },
        argv.slice(),
    );
}

test "recorder candidates prefer arecord and fall back to pw-record" {
    try std.testing.expectEqualSlices(Kind, &[_]Kind{ .arecord, .pw_record }, &candidates);
    try std.testing.expectEqualStrings("arecord", program(.arecord));
    try std.testing.expectEqualStrings("pw-record", program(.pw_record));
}

var test_spawn_log: [4][]const u8 = undefined;
var test_spawn_count: usize = 0;
var test_spawn_errors: [4]anyerror = undefined;

fn testSpawn(io: std.Io, argv: []const []const u8) anyerror!std.process.Child {
    _ = io;
    test_spawn_log[test_spawn_count] = argv[0];
    const err = test_spawn_errors[test_spawn_count];
    test_spawn_count += 1;
    return err;
}

fn resetTestSpawn(errors: []const anyerror) void {
    test_spawn_count = 0;
    for (errors, 0..) |err, index| test_spawn_errors[index] = err;
}

test "falls back to pw-record when arecord is missing" {
    resetTestSpawn(&[_]anyerror{ error.FileNotFound, error.StopHere });
    try std.testing.expectError(error.StopHere, spawnFirstWith(std.testing.io, .{ .rate = "16000", .channels = "1" }, testSpawn));
    try std.testing.expectEqual(@as(usize, 2), test_spawn_count);
    try std.testing.expectEqualStrings("arecord", test_spawn_log[0]);
    try std.testing.expectEqualStrings("pw-record", test_spawn_log[1]);
}

test "reports FileNotFound when no recorder binary is available" {
    resetTestSpawn(&[_]anyerror{ error.FileNotFound, error.FileNotFound });
    try std.testing.expectError(error.FileNotFound, spawnFirstWith(std.testing.io, .{ .rate = "16000", .channels = "1" }, testSpawn));
    try std.testing.expectEqual(@as(usize, 2), test_spawn_count);
}

test "spawn errors other than a missing binary abort the fallback" {
    resetTestSpawn(&[_]anyerror{ error.AccessDenied, error.StopHere });
    try std.testing.expectError(error.AccessDenied, spawnFirstWith(std.testing.io, .{ .rate = "16000", .channels = "1" }, testSpawn));
    try std.testing.expectEqual(@as(usize, 1), test_spawn_count);
}

test "spawning a missing binary reports FileNotFound" {
    try std.testing.expectError(
        error.FileNotFound,
        spawn(std.testing.io, &[_][]const u8{"asr-definitely-missing-recorder-binary"}),
    );
}
