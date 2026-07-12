const std = @import("std");
const key = @import("../key.zig");
const shutdown = @import("shutdown.zig");

pub const CaptureOptions = struct {
    sample_rate: u32 = 16000,
    channels: u16 = 1,
    frame_duration_ms: u16 = 100,
    device: ?[]const u8 = null,
};

pub const StreamOptions = struct {
    on_chunk: *const fn (ctx: ?*anyopaque, chunk: []const u8) anyerror!void,
    chunk_ctx: ?*anyopaque = null,
    on_started: ?*const fn (ctx: ?*anyopaque) anyerror!void = null,
    started_ctx: ?*anyopaque = null,
    on_stopped: ?*const fn (ctx: ?*anyopaque) void = null,
    stopped_ctx: ?*anyopaque = null,
};

pub const StreamSummary = struct {
    chunk_count: usize = 0,
    byte_count: usize = 0,
};

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
    var start_signal = StartSignal{};
    var stream_thread = try std.Thread.spawn(.{}, streamAudioThread, .{ &child, io, &stream_result, stream, &stop_requested, &start_signal });

    start_signal.wait(io) catch |err| {
        stopCaptureAndJoin(io, &stop_requested, stopChild, @ptrCast(&child), joinThread, @ptrCast(&stream_thread), .{});
        return err;
    };
    if (stream.on_started) |on_started| {
        on_started(stream.started_ctx) catch |err| {
            stopCaptureAndJoin(io, &stop_requested, stopChild, @ptrCast(&child), joinThread, @ptrCast(&stream_thread), .{});
            return err;
        };
    }

    // Release or process shutdown ends the hold; other read failures also stop capture.
    key.waitForDeviceReleaseOrShutdown(io, key_file, key_state, key_code, shutdown.isRequested) catch {};
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

const StreamResult = struct {
    summary: StreamSummary = .{},
    err: ?anyerror = null,
};

const StartSignal = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    started: bool = false,
    err: ?anyerror = null,

    fn notify(signal: *StartSignal, io: std.Io, err: ?anyerror) void {
        signal.mutex.lockUncancelable(io);
        defer {
            signal.cond.broadcast(io);
            signal.mutex.unlock(io);
        }
        signal.started = true;
        signal.err = err;
    }

    fn wait(signal: *StartSignal, io: std.Io) !void {
        signal.mutex.lockUncancelable(io);
        defer signal.mutex.unlock(io);
        while (!signal.started) {
            // Cancelable wait: Select/shutdown cancel can wake capture setup.
            signal.cond.wait(io, &signal.mutex) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
        }
        if (signal.err) |err| return err;
    }
};

fn streamAudioThread(
    child: *std.process.Child,
    io: std.Io,
    result: *StreamResult,
    stream: StreamOptions,
    stop_requested: *std.atomic.Value(bool),
    start_signal: *StartSignal,
) void {
    const source = child.stdout orelse {
        result.err = error.MissingChildStdout;
        start_signal.notify(io, error.MissingChildStdout);
        return;
    };
    var reader_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(source, io, &reader_buffer);
    var chunk: [4096]u8 = undefined;
    start_signal.notify(io, null);

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

test "stream options default to no started callback" {
    const options = StreamOptions{
        .on_chunk = struct {
            fn onChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
                _ = ctx;
                _ = chunk;
            }
        }.onChunk,
    };
    try std.testing.expect(options.on_started == null);
    try std.testing.expect(options.started_ctx == null);
}
