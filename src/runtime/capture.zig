//! Per-recording state and the callbacks the capture loop drives.
//!
//! Lifetime contract: one `Recording` is created per hotkey press and lives on
//! the stack frame of that iteration of `app.runHotkeyLoop`. Every
//! `?*anyopaque` context handed to the engine and capture callbacks is the
//! same pointer, cast back to `*Recording`, so nothing can outlive the frame
//! by accident. The session-init future and the session read thread are both
//! finished in `Recording.deinit`, which runs as the iteration's `defer` —
//! before anything else can reuse the frame. The pipeline is the one
//! long-lived collaborator; it outlives every recording.

const std = @import("std");
const doubao = @import("../doubao/client.zig");
const engine = @import("engine.zig");
const mic = @import("mic.zig");
const mute = @import("mute.zig");
const notify = @import("notify.zig");
const output = @import("output.zig");
const postprocess = @import("postprocess.zig");
const shutdown = @import("shutdown.zig");
const audio_gate = @import("audio_gate.zig");

/// Upper bound on the audio we keep for the post-stream fallback upload.
pub const max_captured_audio_bytes: usize = 64 * 1024 * 1024;

/// How long to wait for the recorder's first chunk before prompting anyway: a
/// dead microphone must not stall the hotkey loop.
pub const mic_ready_timeout_ms: i64 = 1500;
/// The chunk arrival itself is signalled by an atomic flag, so this only sets
/// how late the prompt can notice it. 20ms is below human perception and cuts
/// idle wakeups fourfold compared with a 5ms spin.
const mic_ready_poll_ms: i64 = 20;

/// True once the recorder delivered audio; false on timeout or shutdown.
pub fn waitForFirstChunk(gate: *audio_gate.AudioGate, io: std.Io, timeout_ms: i64) bool {
    var waited: i64 = 0;
    while (!gate.sawFirstChunk()) {
        if (shutdown.isRequested()) return false;
        if (waited >= timeout_ms) return false;
        shutdown.sleepUntilOr(io, mic_ready_poll_ms);
        waited += mic_ready_poll_ms;
    }
    return true;
}

const SessionInitResult = @typeInfo(@TypeOf(initSessionWithRetry)).@"fn".return_type.?;
const SessionFuture = std.Io.Future(SessionInitResult);

pub const Recording = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    pipeline: *postprocess.Pipeline,
    cfg: engine.Config,
    debug: bool,

    /// Audio kept for the fallback upload when the stream dies mid-recording.
    captured_audio: std.ArrayList(u8) = .empty,
    gate: audio_gate.AudioGate,
    /// Set by the engine callbacks once the session start was accepted.
    session: engine.Session = undefined,
    has_session: bool = false,
    session_future_opt: ?SessionFuture = null,
    session_future_taken: bool = false,
    /// First send failure; the fallback path uses it to decide what to do.
    stream_error: ?anyerror = null,
    speaker_muted: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        logger: output.Logger,
        pipeline: *postprocess.Pipeline,
        cfg: engine.Config,
        debug: bool,
    ) Recording {
        return .{
            .allocator = allocator,
            .io = io,
            .logger = logger,
            .pipeline = pipeline,
            .cfg = cfg,
            .debug = debug,
            .gate = audio_gate.AudioGate.init(io),
        };
    }

    /// Starts the websocket handshake while the recorder is still starting, so
    /// the two latencies overlap. `Recording.deinit` guarantees the future is
    /// finished (or cancelled) before the frame goes away.
    pub fn startSessionAsync(recording: *Recording) void {
        recording.session_future_opt = recording.io.concurrent(initSessionWithRetry, .{
            recording.allocator,
            recording.io,
            recording.cfg,
            @as(*const anyopaque, @ptrCast(recording)),
            recording.logger,
            recording.debug,
        }) catch null;
    }

    pub fn deinit(recording: *Recording) void {
        if (recording.session_future_opt) |*future| {
            if (!recording.session_future_taken) {
                if (future.cancel(recording.io)) |owned| {
                    var session = owned;
                    session.deinit();
                } else |_| {}
            }
            recording.session_future_opt = null;
        }
        if (recording.has_session) recording.session.deinit();
        recording.captured_audio.deinit(recording.allocator);
        recording.releaseSpeaker();
    }

    /// Options for `mic.captureStreamUntilKeyRelease`. Every context is this
    /// recording, so the callbacks cannot inherit a stale earlier frame.
    pub fn micOptions(recording: *Recording) mic.StreamOptions {
        return .{
            .on_chunk = onEngineAudioChunk,
            .chunk_ctx = @ptrCast(recording),
            .on_started = onCaptureStarted,
            .started_ctx = @ptrCast(recording),
            .on_stopped = onCaptureStopped,
            .stopped_ctx = @ptrCast(recording),
            .on_recorder = onCaptureRecorder,
            .recorder_ctx = @ptrCast(recording),
            .on_hold_timeout = onHoldTimeout,
            .hold_timeout_ctx = @ptrCast(recording),
        };
    }

    fn fromCtx(ctx: ?*anyopaque) ?*Recording {
        return @ptrCast(@alignCast(ctx orelse return null));
    }

    fn fromConstCtx(ctx: ?*const anyopaque) ?*Recording {
        return @ptrCast(@alignCast(@constCast(ctx) orelse return null));
    }

    fn muteSpeaker(recording: *Recording) void {
        recording.logger.debug("speaker", "mute", .{});
        mute.muteSpeaker(recording.allocator, recording.io);
        recording.speaker_muted = true;
    }

    fn releaseSpeaker(recording: *Recording) void {
        if (!recording.speaker_muted) return;
        recording.logger.debug("speaker", "unmute", .{});
        mute.unmuteSpeaker(recording.allocator, recording.io);
        recording.speaker_muted = false;
    }

    fn resolveSession(recording: *Recording) !void {
        if (recording.has_session) return;

        if (recording.session_future_opt) |future_value| {
            var future = future_value;
            recording.session_future_opt = null;
            recording.session_future_taken = true;
            recording.session = try future.await(recording.io);
            recording.has_session = true;
        } else {
            recording.session = try initSessionWithRetry(
                recording.allocator,
                recording.io,
                recording.cfg,
                @ptrCast(recording),
                recording.logger,
                recording.debug,
            );
            recording.has_session = true;
        }

        try recording.session.start();
    }
};

pub fn onEngineInterim(ctx: ?*const anyopaque, text: []const u8) void {
    if (text.len == 0) return;
    const recording = Recording.fromConstCtx(ctx) orelse return;
    recording.pipeline.logger.info(recording.pipeline.provider, "🎤 {s}", .{text});
}

pub fn onEngineFinal(ctx: ?*const anyopaque, text: []const u8) void {
    if (text.len == 0) return;
    const recording = Recording.fromConstCtx(ctx) orelse return;
    recording.pipeline.submitFinal(text);
}

pub fn onEngineAudioChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
    const recording = Recording.fromCtx(ctx) orelse return error.MissingChunkSession;
    try recording.gate.handleChunk(chunk, @ptrCast(recording), sendEngineAudioChunk);
}

fn sendEngineAudioChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
    const recording = Recording.fromCtx(ctx) orelse return error.MissingChunkSession;
    if (recording.captured_audio.items.len < max_captured_audio_bytes) {
        try recording.captured_audio.appendSlice(recording.allocator, chunk);
    }
    if (recording.stream_error != null) return;
    if (!recording.has_session) return;
    recording.session.sendChunk(chunk) catch |err| {
        recording.stream_error = err;
    };
}

pub fn onCaptureRecorder(ctx: ?*anyopaque, program: []const u8) void {
    const recording = Recording.fromCtx(ctx) orelse return;
    recording.logger.debug("mic", "recorder {s}", .{program});
}

pub fn onHoldTimeout(ctx: ?*anyopaque) void {
    const recording = Recording.fromCtx(ctx) orelse return;
    recording.logger.info("mic", "max hold reached; stopping", .{});
}

pub fn onCaptureStarted(ctx: ?*anyopaque) !void {
    const recording = Recording.fromCtx(ctx) orelse return error.MissingCaptureStartedState;

    // The ding is the "you can speak" cue, so it has to wait for the session
    // and for the recorder: ringing it while the handshake ran is what made it
    // lie. Audio captured before the cue is dropped, not buffered.
    recording.resolveSession() catch |err| {
        recording.logger.err(engine.label(recording.cfg), "session failed: {s}", .{@errorName(err)});
        return err;
    };
    if (shutdown.isRequested()) return error.Canceled;
    if (!waitForFirstChunk(&recording.gate, recording.io, mic_ready_timeout_ms)) {
        if (shutdown.isRequested()) return error.Canceled;
        recording.logger.info("mic", "no audio arrived before the prompt", .{});
    }

    // Open first: speech that starts together with the ding must be kept.
    recording.gate.open();
    recording.logger.debug("speaker", "prompt", .{});
    notify.playMicReadyNotification(recording.allocator, recording.io);
    recording.muteSpeaker();

    recording.logger.info(engine.label(recording.cfg), "🎤", .{});
}

pub fn onCaptureStopped(ctx: ?*anyopaque) void {
    const recording = Recording.fromCtx(ctx) orelse return;
    output.keyEvent(recording.logger, .release);
    recording.releaseSpeaker();
}

/// A recorder that produced no bytes at all means the capture path is broken
/// (no microphone, wrong PipeWire node): say so instead of finishing a silent
/// session as if nothing happened.
pub fn noAudioCaptured(summary: mic.StreamSummary) bool {
    return summary.byte_count == 0;
}

pub fn formatMicCloseMessage(buf: []u8, summary: mic.StreamSummary) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "stopped: {d} chunks, {d} bytes",
        .{ summary.chunk_count, summary.byte_count },
    );
}

test "formats mic close log as a short capture summary" {
    var buf: [128]u8 = undefined;
    const message = try formatMicCloseMessage(&buf, .{
        .chunk_count = 13,
        .byte_count = 53194,
    });
    try std.testing.expectEqualStrings(
        "stopped: 13 chunks, 53194 bytes",
        message,
    );
}

test "flags a capture that produced no audio" {
    try std.testing.expect(noAudioCaptured(.{}));
    try std.testing.expect(noAudioCaptured(.{ .chunk_count = 3 }));
    try std.testing.expect(!noAudioCaptured(.{ .chunk_count = 1, .byte_count = 1 }));
}

test "mic ready wait returns as soon as a chunk arrived" {
    var gate = audio_gate.AudioGate.init(std.testing.io);
    try gate.handleChunk("first", null, discardChunk);
    try std.testing.expect(waitForFirstChunk(&gate, std.testing.io, 1000));
}

test "mic ready wait gives up once the timeout passes" {
    var gate = audio_gate.AudioGate.init(std.testing.io);
    try std.testing.expect(!waitForFirstChunk(&gate, std.testing.io, 20));
}

fn discardChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
    _ = ctx;
    _ = chunk;
}

test "recording init builds every callback context from one pointer" {
    const logger: output.Logger = .{ .io = std.testing.io, .level = .err };
    var pipeline: postprocess.Pipeline = undefined;
    var recording = Recording.init(
        std.testing.allocator,
        std.testing.io,
        logger,
        &pipeline,
        .{ .baidu = .{} },
        false,
    );
    const options = recording.micOptions();
    const self_ptr: *Recording = @ptrCast(@alignCast(options.started_ctx.?));
    try std.testing.expectEqual(@intFromPtr(&recording), @intFromPtr(self_ptr));
    try std.testing.expectEqual(@intFromPtr(&recording), @intFromPtr(@as(*Recording, @ptrCast(@alignCast(options.chunk_ctx.?)))));
    try std.testing.expectEqual(@intFromPtr(&recording), @intFromPtr(@as(*Recording, @ptrCast(@alignCast(options.stopped_ctx.?)))));
    recording.captured_audio.deinit(recording.allocator);
    recording.gate = audio_gate.AudioGate.init(std.testing.io);
}

test "captured audio stays under the fallback cap" {
    const logger: output.Logger = .{ .io = std.testing.io, .level = .err };
    var pipeline: postprocess.Pipeline = undefined;
    var recording = Recording.init(
        std.testing.allocator,
        std.testing.io,
        logger,
        &pipeline,
        .{ .baidu = .{} },
        false,
    );
    defer recording.captured_audio.deinit(recording.allocator);

    // Gate open, no session: the send is skipped but the fallback copy kept.
    recording.gate.open();
    var iter: usize = 0;
    const chunk_len = 4096;
    while (iter < max_captured_audio_bytes / chunk_len + 2) : (iter += 1) {
        var chunk: [chunk_len]u8 = undefined;
        try onEngineAudioChunk(@ptrCast(&recording), &chunk);
    }
    try std.testing.expect(recording.captured_audio.items.len <= max_captured_audio_bytes);
    try std.testing.expect(recording.stream_error == null);
}

pub fn initSessionWithRetry(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: engine.Config,
    callback_ctx: *const anyopaque,
    logger: output.Logger,
    debug: bool,
) !engine.Session {
    if (engine.kind(cfg) == .baidu) {
        return engine.Session.init(allocator, io, cfg, .{
            .debug = debug,
            .on_interim = onEngineInterim,
            .interim_ctx = callback_ctx,
            .on_final = onEngineFinal,
            .final_ctx = callback_ctx,
        });
    }
    var delay_ms: i64 = 1000;
    var attempt: usize = 0;
    while (true) {
        if (shutdown.isRequested()) return error.Canceled;
        if (engine.Session.init(allocator, io, cfg, .{
            .debug = debug,
            .on_interim = onEngineInterim,
            .interim_ctx = callback_ctx,
            .on_final = onEngineFinal,
            .final_ctx = callback_ctx,
        })) |session| {
            return session;
        } else |err| {
            attempt += 1;
            if (err == error.RemoteAsrQuotaExceeded and attempt < 3) {
                var rand_buf: [8]u8 = undefined;
                io.random(&rand_buf);
                const rand_val = std.mem.readInt(u64, &rand_buf, .little);
                const half_delay = @divTrunc(delay_ms, 2);
                const jitter: i64 = @as(i64, @intCast(rand_val % @as(u64, @intCast(@max(half_delay, 1)))));
                const sleep_time = delay_ms + jitter;
                logger.info("doubao", "concurrency quota exceeded, retry {d}/3 in {d}ms", .{ attempt, sleep_time });
                shutdown.sleepUntilOr(io, sleep_time);
                if (shutdown.isRequested()) return error.Canceled;
                delay_ms = @min(delay_ms * 2, 10_000);
                continue;
            }
            return err;
        }
    }
}
