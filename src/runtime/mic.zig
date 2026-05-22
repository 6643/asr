const std = @import("std");

pub const CaptureOptions = struct {
    sample_rate: u32 = 16000,
    channels: u16 = 1,
    frame_duration_ms: u16 = 100,
    device: ?[]const u8 = null,
};

pub fn captureUntilKeyRelease(
    allocator: std.mem.Allocator,
    io: std.Io,
    keyboard_device: []const u8,
    key_code: u16,
    options: CaptureOptions,
) ![]u8 {
    var child = try spawnArecord(io, options);
    errdefer child.kill(io);

    var out_file = try createTempPcmFile(allocator, io);
    defer allocator.free(out_file.path);
    defer out_file.file.close(io);

    var copy_result: CopyResult = .{};
    const copy_thread = try std.Thread.spawn(.{}, copyAudioToFileThread, .{ &child, io, &out_file.file, &copy_result });

    waitForRelease(io, keyboard_device, key_code) catch {};
    // Zig 0.16: kill() already waits and reaps child.
    child.kill(io);
    copy_thread.join();
    if (copy_result.err) |e| return e;

    return allocator.dupe(u8, out_file.path);
}

pub fn waitForRelease(io: std.Io, keyboard_device: []const u8, key_code: u16) !void {
    const key = @import("../key.zig");
    const file = try std.Io.Dir.cwd().openFile(io, keyboard_device, .{});
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(file, io, &read_buffer);
    var state: key.State = .{};
    while (true) {
        const event = try key.readNextEvent(&reader.interface, &state, key_code);
        if (event == .release) return;
    }
}

fn spawnArecord(io: std.Io, options: CaptureOptions) !std.process.Child {
    var frame_rate_buf: [16]u8 = undefined;
    const frame_rate = try std.fmt.bufPrint(&frame_rate_buf, "{d}", .{effectiveSampleRate(options)});
    var channels_buf: [8]u8 = undefined;
    const channels = try std.fmt.bufPrint(&channels_buf, "{d}", .{effectiveChannels(options)});

    if (options.device) |device| {
        return std.process.spawn(io, .{
            .argv = &[_][]const u8{ "arecord", "-f", "S16_LE", "-r", frame_rate, "-c", channels, "-t", "raw", "-D", device },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        });
    }
    return std.process.spawn(io, .{
        .argv = &[_][]const u8{ "arecord", "-f", "S16_LE", "-r", frame_rate, "-c", channels, "-t", "raw" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
}

fn effectiveSampleRate(options: CaptureOptions) u32 {
    return if (options.sample_rate == 0) 16000 else options.sample_rate;
}

fn effectiveChannels(options: CaptureOptions) u16 {
    return if (options.channels == 0) 1 else options.channels;
}

const TempFile = struct {
    path: []u8,
    file: std.Io.File,
};

fn createTempPcmFile(allocator: std.mem.Allocator, io: std.Io) !TempFile {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const path = try std.fmt.allocPrint(
        allocator,
        "/tmp/asr-zig-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}.pcm",
        .{
            random_bytes[0],
            random_bytes[1],
            random_bytes[2],
            random_bytes[3],
            random_bytes[4],
            random_bytes[5],
            random_bytes[6],
            random_bytes[7],
        },
    );
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true, .exclusive = false });
    return .{ .path = path, .file = file };
}

const CopyResult = struct {
    err: ?anyerror = null,
};

fn copyAudioToFileThread(child: *std.process.Child, io: std.Io, out: *std.Io.File, result: *CopyResult) void {
    const source = child.stdout orelse {
        result.err = error.MissingChildStdout;
        return;
    };
    var reader_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(source, io, &reader_buffer);
    var chunk: [4096]u8 = undefined;

    while (true) {
        const read_len = reader.interface.readSliceShort(&chunk) catch |err| {
            if (err == error.EndOfStream) return;
            result.err = err;
            return;
        };
        if (read_len == 0) return;
        out.writeStreamingAll(io, chunk[0..read_len]) catch |err| {
            result.err = err;
            return;
        };
    }
}

test "temp file path format" {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "/tmp/asr-zig-{x:0>2}{x:0>2}.pcm", .{ 0x12, 0x34 });
    defer allocator.free(path);
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/asr-zig-"));
}
