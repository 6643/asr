const std = @import("std");
const key = @import("../key.zig");

pub const CaptureOptions = struct {
    sample_rate: u32 = 16000,
    channels: u16 = 1,
    frame_duration_ms: u16 = 100,
    device: ?[]const u8 = null,
};

pub const StreamOptions = struct {
    on_chunk: *const fn (ctx: ?*anyopaque, chunk: []const u8) anyerror!void,
    chunk_ctx: ?*anyopaque = null,
    on_stopped: ?*const fn (ctx: ?*anyopaque) void = null,
    stopped_ctx: ?*anyopaque = null,
};

pub const StreamSummary = struct {
    chunk_count: usize = 0,
    byte_count: usize = 0,
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
    var stop_requested = std.atomic.Value(bool).init(false);

    var out_file = try createTempPcmFile(allocator, io);
    defer allocator.free(out_file.path);
    defer out_file.file.close(io);

    var copy_result: CopyResult = .{};
    var copy_thread = try std.Thread.spawn(.{}, copyAudioToFileThread, .{ &child, io, &out_file.file, &copy_result, &stop_requested });

    waitForRelease(io, keyboard_device, key_code) catch {};
    // Zig 0.16: kill() already waits and reaps child.
    stop_requested.store(true, .release);
    child.kill(io);
    copy_thread.join();
    if (copy_result.err) |e| return e;

    return allocator.dupe(u8, out_file.path);
}

pub fn waitForRelease(io: std.Io, keyboard_device: []const u8, key_code: u16) !void {
    const file = try std.Io.Dir.cwd().openFile(io, keyboard_device, .{});
    defer file.close(io);

    var state: key.State = .{};
    try key.waitForDeviceRelease(file, &state, key_code);
}

pub fn captureStreamUntilKeyRelease(
    io: std.Io,
    key_file: std.Io.File,
    key_state: *key.State,
    key_code: u16,
    options: CaptureOptions,
    stream: StreamOptions,
) !StreamSummary {
    var child = try spawnArecord(io, options);
    errdefer child.kill(io);
    var stop_requested = std.atomic.Value(bool).init(false);

    var stream_result: StreamResult = .{};
    var stream_thread = try std.Thread.spawn(.{}, streamAudioThread, .{ &child, io, &stream_result, stream, &stop_requested });

    key.waitForDeviceRelease(key_file, key_state, key_code) catch {};
    stopCaptureAndJoin(io, &stop_requested, stopChild, @ptrCast(&child), joinThread, @ptrCast(&stream_thread), .{
        .fn_ptr = stream.on_stopped,
        .ctx = stream.stopped_ctx,
    });
    if (stream_result.err) |err| return err;
    return stream_result.summary;
}

const StopCallback = struct {
    fn_ptr: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

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

const StreamResult = struct {
    summary: StreamSummary = .{},
    err: ?anyerror = null,
};

fn copyAudioToFileThread(
    child: *std.process.Child,
    io: std.Io,
    out: *std.Io.File,
    result: *CopyResult,
    stop_requested: *std.atomic.Value(bool),
) void {
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
            if (stop_requested.load(.acquire) and isExpectedStopReadError(err)) return;
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

fn streamAudioThread(
    child: *std.process.Child,
    io: std.Io,
    result: *StreamResult,
    stream: StreamOptions,
    stop_requested: *std.atomic.Value(bool),
) void {
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
            if (stop_requested.load(.acquire) and isExpectedStopReadError(err)) return;
            result.err = err;
            return;
        };
        if (read_len == 0) return;
        stream.on_chunk(stream.chunk_ctx, chunk[0..read_len]) catch |err| {
            result.err = err;
            return;
        };
        result.summary.chunk_count += 1;
        result.summary.byte_count += read_len;
    }
}

fn stopCaptureAndJoin(
    io: std.Io,
    stop_requested: *std.atomic.Value(bool),
    stop_fn: *const fn (ctx: ?*anyopaque, io: std.Io) void,
    stop_ctx: ?*anyopaque,
    join_fn: *const fn (ctx: ?*anyopaque) void,
    join_ctx: ?*anyopaque,
    callback: StopCallback,
) void {
    stop_requested.store(true, .release);
    stop_fn(stop_ctx, io);
    if (callback.fn_ptr) |fn_ptr| fn_ptr(callback.ctx);
    join_fn(join_ctx);
}

fn stopChild(ctx: ?*anyopaque, io: std.Io) void {
    const child = @as(*std.process.Child, @ptrCast(@alignCast(ctx orelse return)));
    child.kill(io);
}

fn joinThread(ctx: ?*anyopaque) void {
    const thread = @as(*std.Thread, @ptrCast(@alignCast(ctx orelse return)));
    thread.join();
}

fn isExpectedStopReadError(err: anyerror) bool {
    return switch (err) {
        error.ReadFailed,
        error.BrokenPipe,
        error.NotOpenForReading,
        error.ConnectionResetByPeer,
        => true,
        else => false,
    };
}

test "temp file path format" {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, "/tmp/asr-zig-{x:0>2}{x:0>2}.pcm", .{ 0x12, 0x34 });
    defer allocator.free(path);
    try std.testing.expect(std.mem.startsWith(u8, path, "/tmp/asr-zig-"));
}

test "stop capture notifies before join returns" {
    const Step = enum {
        stop,
        notify,
        join,
    };
    const Recorder = struct {
        steps: [3]Step = undefined,
        len: usize = 0,

        fn push(recorder: *@This(), step: Step) void {
            recorder.steps[recorder.len] = step;
            recorder.len += 1;
        }
    };
    const Hooks = struct {
        fn stop(ctx: ?*anyopaque, io: std.Io) void {
            _ = io;
            const recorder = @as(*Recorder, @ptrCast(@alignCast(ctx orelse return)));
            recorder.push(.stop);
        }

        fn notify(ctx: ?*anyopaque) void {
            const recorder = @as(*Recorder, @ptrCast(@alignCast(ctx orelse return)));
            recorder.push(.notify);
        }

        fn join(ctx: ?*anyopaque) void {
            const recorder = @as(*Recorder, @ptrCast(@alignCast(ctx orelse return)));
            recorder.push(.join);
        }
    };

    var stop_requested = std.atomic.Value(bool).init(false);
    var recorder = Recorder{};

    stopCaptureAndJoin(std.testing.io, &stop_requested, Hooks.stop, @ptrCast(&recorder), Hooks.join, @ptrCast(&recorder), .{
        .fn_ptr = Hooks.notify,
        .ctx = @ptrCast(&recorder),
    });

    try std.testing.expect(stop_requested.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), recorder.len);
    try std.testing.expectEqual(Step.stop, recorder.steps[0]);
    try std.testing.expectEqual(Step.notify, recorder.steps[1]);
    try std.testing.expectEqual(Step.join, recorder.steps[2]);
}
