//! Callback lifetime contract.
//!
//! Every context handed to the engine and capture callbacks (`?*anyopaque`)
//! borrows the stack frame of the *current* recording in `app.runHotkeyLoop`:
//! `CaptureStartedState`, `CaptureReleaseState`, `StreamCaptureState` and
//! `EngineCallbacks` are locals of that loop body. Nothing may keep those
//! pointers alive after the iteration ends, which is why every future and
//! thread started here is finished before then: the bell future is awaited, the
//! session-init future is cancelled (and, when it already produced one, its
//! session is deinitialised), and `Session.deinit` joins the session read
//! thread. The pipeline is the one long-lived collaborator; it outlives every
//! recording. Keep this invariant when adding a task or a callback.

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

pub fn onEngineInterim(ctx: ?*const anyopaque, text: []const u8) void {
    if (text.len == 0) return;
    const callbacks = @as(*const EngineCallbacks, @ptrCast(@alignCast(ctx orelse return)));
    callbacks.pipeline.logger.info(callbacks.pipeline.provider, "🎤 {s}", .{text});
}

pub fn onEngineFinal(ctx: ?*const anyopaque, text: []const u8) void {
    if (text.len == 0) return;
    const callbacks = @as(*const EngineCallbacks, @ptrCast(@alignCast(ctx orelse return)));
    callbacks.pipeline.submitFinal(text);
}

pub fn onEngineAudioChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
    const state = @as(*StreamCaptureState, @ptrCast(@alignCast(ctx orelse return error.MissingChunkSession)));
    try state.gate.handleChunk(chunk, @ptrCast(state), sendEngineAudioChunk);
}

fn sendEngineAudioChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
    const state = @as(*StreamCaptureState, @ptrCast(@alignCast(ctx orelse return error.MissingChunkSession)));
    if (state.captured_audio.items.len < max_captured_audio_bytes) {
        try state.captured_audio.appendSlice(state.allocator, chunk);
    }
    if (state.stream_error != null) return;
    const session = state.session orelse return;
    session.sendChunk(chunk) catch |err| {
        state.stream_error = err;
    };
}

pub const StreamCaptureState = struct {
    allocator: std.mem.Allocator,
    session: ?*engine.Session,
    captured_audio: *std.ArrayList(u8),
    gate: *audio_gate.AudioGate,
    stream_error: ?anyerror = null,
};

pub const EngineCallbacks = struct {
    pipeline: *postprocess.Pipeline,
};

const SessionInitResult = @typeInfo(@TypeOf(initSessionWithRetry)).@"fn".return_type.?;
pub const SessionFuture = std.Io.Future(SessionInitResult);

pub fn onHoldTimeout(ctx: ?*anyopaque) void {
    const state: *const CaptureStartedState = @ptrCast(@alignCast(ctx orelse return));
    state.logger.info("mic", "max hold reached; stopping", .{});
}

pub const CaptureStartedState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    gate: *audio_gate.AudioGate,
    speaker_guard: *SpeakerMuteGuard,
    stream_state: *StreamCaptureState,
    session: *engine.Session,
    has_session: *bool,
    session_future_opt: *?SessionFuture,
    session_future_taken: *bool,
    cfg: engine.Config,
    callback_ctx: *const EngineCallbacks,
    debug: bool,
};

pub const CaptureReleaseState = struct {
    logger: output.Logger,
    speaker_guard: *SpeakerMuteGuard,
};

pub const SpeakerMuteGuard = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    active: bool = false,

    pub fn muteAfterPrompt(guard: *SpeakerMuteGuard) void {
        guard.logger.debug("speaker", "mute", .{});
        mute.muteSpeaker(guard.allocator, guard.io);
        guard.active = true;
    }

    pub fn release(guard: *SpeakerMuteGuard) void {
        if (!guard.active) return;
        guard.logger.debug("speaker", "unmute", .{});
        mute.unmuteSpeaker(guard.allocator, guard.io);
        guard.active = false;
    }
};

fn playBellTask(allocator: std.mem.Allocator, io: std.Io) void {
    notify.playMicReadyNotification(allocator, io);
}

fn resolveSession(state: *CaptureStartedState) !void {
    if (state.has_session.*) return;

    if (state.session_future_opt.*) |future_value| {
        var future = future_value;
        state.session_future_opt.* = null;
        state.session_future_taken.* = true;
        state.session.* = try future.await(state.io);
        state.has_session.* = true;
    } else {
        state.session.* = try initSessionWithRetry(
            state.allocator,
            state.io,
            state.cfg,
            state.callback_ctx,
            state.logger,
            state.debug,
        );
        state.has_session.* = true;
    }

    try state.session.start();
    state.stream_state.session = state.session;
}

pub fn onCaptureRecorder(ctx: ?*anyopaque, program: []const u8) void {
    const state = @as(*CaptureStartedState, @ptrCast(@alignCast(ctx orelse return)));
    state.logger.debug("mic", "recorder {s}", .{program});
}

pub fn onCaptureStarted(ctx: ?*anyopaque) !void {
    const state = @as(*CaptureStartedState, @ptrCast(@alignCast(ctx orelse return error.MissingCaptureStartedState)));

    if (state.io.concurrent(playBellTask, .{ state.allocator, state.io })) |bell_future_value| {
        var bell_future = bell_future_value;
        resolveSession(state) catch |err| {
            _ = bell_future.await(state.io);
            state.logger.err(engine.label(state.cfg), "session failed: {s}", .{@errorName(err)});
            return err;
        };
        _ = bell_future.await(state.io);
        state.speaker_guard.muteAfterPrompt();
    } else |_| {
        playBellTask(state.allocator, state.io);
        state.speaker_guard.muteAfterPrompt();
        resolveSession(state) catch |err| {
            state.logger.err(engine.label(state.cfg), "session failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    try state.gate.openAndFlush(@ptrCast(state.stream_state), sendEngineAudioChunk);
    state.logger.info(engine.label(state.cfg), "🎤", .{});
}

pub fn onCaptureStopped(ctx: ?*anyopaque) void {
    const state = @as(*CaptureReleaseState, @ptrCast(@alignCast(ctx orelse return)));
    output.keyEvent(state.logger, .release);
    state.speaker_guard.release();
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
pub fn initSessionWithRetry(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: engine.Config,
    callback_ctx: *const EngineCallbacks,
    logger: output.Logger,
    debug: bool,
) !engine.Session {
    if (engine.kind(cfg) == .baidu) {
        return engine.Session.init(allocator, io, cfg, .{
            .debug = debug,
            .on_interim = onEngineInterim,
            .interim_ctx = @ptrCast(callback_ctx),
            .on_final = onEngineFinal,
            .final_ctx = @ptrCast(callback_ctx),
        });
    }
    var delay_ms: i64 = 1000;
    var attempt: usize = 0;
    while (true) {
        if (shutdown.isRequested()) return error.Canceled;
        if (engine.Session.init(allocator, io, cfg, .{
            .debug = debug,
            .on_interim = onEngineInterim,
            .interim_ctx = @ptrCast(callback_ctx),
            .on_final = onEngineFinal,
            .final_ctx = @ptrCast(callback_ctx),
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
