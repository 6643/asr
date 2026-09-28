const std = @import("std");
const config = @import("../config.zig");
const cli = @import("../cli.zig");
const doubao = @import("../doubao/client.zig");
const engine = @import("engine.zig");
const key = @import("../key.zig");
const keyboard_set = @import("keyboard.zig");
const audio_gate = @import("audio_gate.zig");
const postprocess = @import("postprocess.zig");
const wayland_im = @import("wayland_im.zig");
const mic = @import("mic.zig");
const mute = @import("mute.zig");
const notify = @import("notify.zig");
const output = @import("output.zig");
const shutdown = @import("shutdown.zig");
const posix_system = std.posix.system;

const max_captured_audio_bytes: usize = 64 * 1024 * 1024;

pub fn installSignalHandlers() void {
    shutdown.installSignalHandlers();
}

pub fn isShutdownRequested() bool {
    return shutdown.isRequested();
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    opts: cli.Options,
    log_file: ?*output.LogFile,
) !void {
    installSignalHandlers();
    const debug = opts.debug;
    const engine_kind: engine.Kind = switch (opts.engine) {
        .baidu => .baidu,
        .doubao => .doubao,
    };
    const logger = output.Logger{ .io = io, .level = if (debug) .debug else .info, .log_file = log_file };
    if (mute.recoverStaleMute(allocator, io, environ)) {
        logger.info("speaker", "restored mute state after an unclean exit", .{});
    }
    mute.setMarkerPath(io, environ);
    var cfg: config.Config = .{};
    var baidu_cfg: config.BaiduConfig = undefined;
    var doubao_creds: ?config.Credentials = null;
    var engine_cfg: engine.Config = undefined;
    switch (engine_kind) {
        .baidu => {
            baidu_cfg = try config.loadBaiduConfig(allocator, io, config.default_baidu_credential_path);
            engine_cfg = .{ .baidu = baidu_cfg };
        },
        .doubao => {
            doubao_creds = try config.loadCredentials(allocator, io, cfg.credential_path);
            var creds = &doubao_creds.?;
            switch (config.refreshDoubaoCredentials(allocator, io, cfg.credential_path, debug)) {
                .refreshed => {
                    logger.info("doubao", "credentials refreshed", .{});
                    creds.deinit(allocator);
                    doubao_creds = try config.loadCredentials(allocator, io, cfg.credential_path);
                    creds = &doubao_creds.?;
                },
                .failed => |err| logger.err("doubao", "credential refresh failed: {s}; using existing credentials", .{@errorName(err)}),
            }
            cfg = config.withCredentials(cfg, creds.*);
            if (cfg.device_id.len == 0 or cfg.token.len == 0) return error.MissingCredentials;
            engine_cfg = .{ .doubao = cfg };
        },
    }
    defer if (engine_kind == .baidu) baidu_cfg.deinit(allocator);
    defer if (doubao_creds) |creds| creds.deinit(allocator);

    logger.info("app", "ASR started", .{});
    logger.info(engineLabel(engine_cfg), "engine ready", .{});
    if (engineKind(engine_cfg) == .doubao) {
        logger.info("doubao", "{s}", .{cfg.device_id});
    }

    const keyboard_paths = key.findKeyboardDevices(allocator, io, environ) catch |err| {
        logger.err("kbd", "{s}: {s}", .{ @errorName(err), keyFailureHint(err) });
        return err;
    };
    defer key.freeDeviceList(allocator, keyboard_paths);
    var keyboards = keyboard_set.Set.openAll(allocator, io, logger, keyboard_paths) catch |err| {
        logger.err("kbd", "{s}: {s}", .{ @errorName(err), keyFailureHint(err) });
        return err;
    };
    defer keyboards.closeAll();

    const client = wayland_im.connect(allocator, io, environ) catch |err| {
        logger.err("wayland", "unavailable: {s}: {s}", .{ @errorName(err), waylandFailureHint(err) });
        return err;
    };
    defer client.deinit();
    logger.info("wayland", "input method bound", .{});

    var pipeline = try postprocess.Pipeline.start(
        allocator,
        io,
        logger,
        client,
        &cfg,
        if (engine_kind == .baidu) "baidu" else "doubao",
        opts.rectify,
    );
    defer pipeline.deinit();

    var wayland_loop = WaylandLoop{
        .client = client,
        .io = io,
        .logger = logger,
        .running = std.atomic.Value(bool).init(false),
    };
    var wayland_future_opt: ?std.Io.Future(void) = null;
    var wayland_thread: ?std.Thread = null;
    wayland_loop.running.store(true, .release);
    wayland_future_opt = io.concurrent(runWaylandLoop, .{&wayland_loop}) catch null;
    if (wayland_future_opt == null) {
        wayland_thread = try std.Thread.spawn(.{}, runWaylandLoop, .{&wayland_loop});
    }
    defer {
        wayland_loop.running.store(false, .release);
        if (wayland_future_opt) |*f| {
            _ = f.cancel(io);
        } else if (wayland_thread) |t| {
            t.join();
        }
    }

    var rescan_ctx = RescanCtx{ .environ = environ };
    try runHotkeyLoop(allocator, io, logger, engine_cfg, &keyboards, pipeline, opts, &wayland_loop.failed, &rescan_ctx);
}

/// Re-scan source handed to the keyboard set while it waits.
const RescanCtx = struct {
    environ: std.process.Environ,
};

fn rescanCandidates(ctx: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![][]u8 {
    const source: *const RescanCtx = @ptrCast(@alignCast(ctx.?));
    return key.findKeyboardDevices(allocator, io, source.environ);
}

/// Extra context for a wayland connection failure, shown after the error name.
pub fn waylandFailureHint(err: anyerror) []const u8 {
    return switch (err) {
        error.InputMethodUnavailable => "another ASR instance may already hold the seat input method",
        error.MissingRuntimeDir, error.ConnectionFailed => "check WAYLAND_DISPLAY and that this is a wayland session",
        error.DisplayError => "the compositor rejected this connection",
        else => "",
    };
}

/// Extra context for a keyboard discovery failure, shown after the error name.
pub fn keyFailureHint(err: anyerror) []const u8 {
    return switch (err) {
        error.KeyboardPermissionDenied => "add the user to the 'input' group and log in again",
        error.KeyboardDeviceNotFound => "set ASR_KEYBOARD_DEVICE to pin one",
        else => "",
    };
}

test "wayland failures explain the likely cause" {
    try std.testing.expectEqualStrings(
        "another ASR instance may already hold the seat input method",
        waylandFailureHint(error.InputMethodUnavailable),
    );
    try std.testing.expectEqualStrings("", waylandFailureHint(error.SetupTimeout));
}

test "keyboard failures explain the likely cause" {
    try std.testing.expectEqualStrings(
        "add the user to the 'input' group and log in again",
        keyFailureHint(error.KeyboardPermissionDenied),
    );
    try std.testing.expectEqualStrings("set ASR_KEYBOARD_DEVICE to pin one", keyFailureHint(error.KeyboardDeviceNotFound));
}

const WaylandLoop = struct {
    client: *wayland_im.Client,
    io: std.Io,
    logger: output.Logger,
    running: std.atomic.Value(bool),
    /// Set when the connection dies so the hotkey loop can exit with an error
    /// instead of committing into a dead socket and logging success.
    failed: std.atomic.Value(bool) = .init(false),
};

fn runWaylandLoop(loop: *WaylandLoop) void {
    while (loop.running.load(.acquire) and !isShutdownRequested()) {
        loop.client.pump(0) catch |err| {
            loop.logger.err("wayland", "disconnected: {s}", .{@errorName(err)});
            loop.failed.store(true, .release);
            // Wake the hotkey loop out of its select so it can exit.
            shutdown.request();
            return;
        };
        if (loop.client.takeActiveChange()) |active| {
            loop.logger.debug("wayland", "{s}", .{if (active) "activated" else "deactivated"});
        }
        shutdown.sleepUntilOr(loop.io, 10);
    }
}

fn runHotkeyLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    cfg: engine.Config,
    keyboards: *keyboard_set.Set,
    pipeline: *postprocess.Pipeline,
    opts: cli.Options,
    wayland_failed: *const std.atomic.Value(bool),
    rescan_ctx: *RescanCtx,
) !void {
    const debug = opts.debug;

    output.keyWait(logger);
    while (true) {
        if (isShutdownRequested()) {
            if (wayland_failed.load(.acquire)) {
                logger.err("wayland", "input method connection lost; exiting", .{});
                return error.WaylandDisconnected;
            }
            logger.info("app", "shutting down", .{});
            return;
        }
        const outcome = keyboards.readNextOrShutdown(key.right_alt, isShutdownRequested, rescanCandidates, rescan_ctx) catch |err| {
            if (err == error.Interrupted) continue;
            logger.err("kbd", "{s}", .{@errorName(err)});
            return err;
        };
        const event = switch (outcome) {
            .stop => |reason| switch (reason) {
                // Rescans are handled inside the set; only shutdown surfaces.
                .rescan => continue,
                .shutdown => {
                    if (wayland_failed.load(.acquire)) {
                        logger.err("wayland", "input method connection lost; exiting", .{});
                        return error.WaylandDisconnected;
                    }
                    logger.info("app", "shutting down", .{});
                    return;
                },
            },
            .event => |value| value,
        };
        if (event.kind == .release) continue;
        output.keyEvent(logger, .press);

        var callback_ctx = EngineCallbacks{
            .pipeline = pipeline,
        };

        // Parallel boot: WS handshake overlaps recorder startup + early speech buffer.
        var session_future_opt = io.concurrent(initSessionWithRetry, .{
            allocator,
            io,
            cfg,
            &callback_ctx,
            logger,
            debug,
        }) catch null;
        var session_future_taken = false;
        defer if (session_future_opt) |*f| {
            if (!session_future_taken) {
                if (f.cancel(io)) |owned| {
                    var s = owned;
                    s.deinit();
                } else |_| {}
            }
        };

        // The capture loop consumes the release, so tell the set when the
        // recording is over (and drop presses that piled up meanwhile).
        defer keyboards.endRecording(key.right_alt);
        var captured_audio: std.ArrayList(u8) = .empty;
        defer captured_audio.deinit(allocator);
        var gate = audio_gate.AudioGate.init(allocator, io);
        defer gate.deinit();
        gate.beginBuffering();

        var session: engine.Session = undefined;
        var has_session = false;
        defer if (has_session) session.deinit();

        var stream_state = StreamCaptureState{
            .allocator = allocator,
            .session = null,
            .captured_audio = &captured_audio,
            .gate = &gate,
        };
        var speaker_guard = SpeakerMuteGuard{
            .allocator = allocator,
            .io = io,
            .logger = logger,
        };
        defer speaker_guard.release();
        var started_state = CaptureStartedState{
            .allocator = allocator,
            .io = io,
            .logger = logger,
            .gate = &gate,
            .speaker_guard = &speaker_guard,
            .stream_state = &stream_state,
            .session = &session,
            .has_session = &has_session,
            .session_future_opt = &session_future_opt,
            .session_future_taken = &session_future_taken,
            .cfg = cfg,
            .callback_ctx = &callback_ctx,
            .debug = debug,
        };
        var release_state = CaptureReleaseState{
            .logger = logger,
            .speaker_guard = &speaker_guard,
        };
        const audio_params: mic.CaptureOptions = switch (cfg) {
            .baidu => |value| .{ .sample_rate = value.sample_rate, .channels = value.channels, .frame_duration_ms = value.frame_duration_ms },
            .doubao => |value| .{ .sample_rate = value.sample_rate, .channels = value.channels, .frame_duration_ms = value.frame_duration_ms },
        };
        logger.debug("mic", "open", .{});
        const capture_summary = mic.captureStreamUntilKeyRelease(io, event.device.file, &event.device.state, key.right_alt, audio_params, opts.max_hold_ms, .{
            .on_chunk = onEngineAudioChunk,
            .chunk_ctx = @ptrCast(&stream_state),
            .on_started = onCaptureStarted,
            .started_ctx = @ptrCast(&started_state),
            .on_stopped = onCaptureStopped,
            .stopped_ctx = @ptrCast(&release_state),
            .on_recorder = onCaptureRecorder,
            .recorder_ctx = @ptrCast(&started_state),
            .on_hold_timeout = onHoldTimeout,
            .hold_timeout_ctx = @ptrCast(&started_state),
        }) catch |err| {
            if (isShutdownRequested()) {
                logger.info("app", "shutting down", .{});
                return;
            }
            logger.err(engineLabel(cfg), "capture failed: {s}", .{@errorName(err)});
            output.keyWait(logger);
            continue;
        };
        if (isShutdownRequested()) {
            logger.info("app", "shutting down", .{});
            return;
        }
        var close_message_buf: [128]u8 = undefined;
        const close_message = formatMicCloseMessage(&close_message_buf, capture_summary) catch "stopped";
        logger.debug("mic", "{s}", .{close_message});

        if (noAudioCaptured(capture_summary)) {
            logger.err("mic", "no_audio_captured: recorder produced 0 bytes; check the microphone and PipeWire", .{});
            output.keyWait(logger);
            continue;
        }

        if (!has_session) {
            logger.err(engineLabel(cfg), "session unavailable", .{});
            output.keyWait(logger);
            continue;
        }

        if (stream_state.stream_error) |stream_err| {
            logger.err(engineLabel(cfg), "stream failed: {s}", .{@errorName(stream_err)});
            const finish = session.finishAfterStreamFailure();
            if (!handleFinish(allocator, pipeline, finish) and !session.hasFinalEvent()) {
                if (engineKind(cfg) == .doubao) {
                    const fallback = doubao.transcribePcmBytes(allocator, io, cfg.doubao, captured_audio.items, .{
                        .pcm_path = "",
                        .debug = debug,
                    }) catch |err| {
                        logger.err("doubao", "fallback failed: {s}", .{@errorName(err)});
                        output.keyWait(logger);
                        continue;
                    };
                    if (fallback) |text| {
                        _ = handleFinish(allocator, pipeline, .{ .text = text });
                    } else {
                        logger.info("doubao", "session_finished", .{});
                    }
                }
            }
            output.keyWait(logger);
            continue;
        }

        const finish = session.finish() catch |err| {
            logger.err(engineLabel(cfg), "recognize failed: {s}", .{@errorName(err)});
            output.keyWait(logger);
            continue;
        };
        _ = handleFinish(allocator, pipeline, finish);
        output.keyWait(logger);
    }
}

fn initSessionWithRetry(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: engine.Config,
    callback_ctx: *const EngineCallbacks,
    logger: output.Logger,
    debug: bool,
) !engine.Session {
    if (engineKind(cfg) == .baidu) {
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
        if (isShutdownRequested()) return error.Canceled;
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
                if (isShutdownRequested()) return error.Canceled;
                delay_ms = @min(delay_ms * 2, 10_000);
                continue;
            }
            return err;
        }
    }
}

fn engineKind(cfg: engine.Config) engine.Kind {
    return switch (cfg) {
        .baidu => .baidu,
        .doubao => .doubao,
    };
}

fn engineLabel(cfg: engine.Config) []const u8 {
    return if (engineKind(cfg) == .baidu) "baidu" else "doubao";
}

fn handleFinish(
    allocator: std.mem.Allocator,
    pipeline: *postprocess.Pipeline,
    finish: engine.StreamFinish,
) bool {
    switch (finish) {
        .text => |text| {
            defer allocator.free(text);
            pipeline.submitFinal(text);
            return true;
        },
        .err => |message| {
            defer allocator.free(message);
            pipeline.logger.err(pipeline.provider, "recognize failed: {s}", .{message});
            return false;
        },
        .none => {
            pipeline.logger.info(pipeline.provider, "session_finished", .{});
            return false;
        },
    }
}

fn onEngineInterim(ctx: ?*const anyopaque, text: []const u8) void {
    if (text.len == 0) return;
    const callbacks = @as(*const EngineCallbacks, @ptrCast(@alignCast(ctx orelse return)));
    callbacks.pipeline.logger.info(callbacks.pipeline.provider, "🎤 {s}", .{text});
}

fn onEngineFinal(ctx: ?*const anyopaque, text: []const u8) void {
    if (text.len == 0) return;
    const callbacks = @as(*const EngineCallbacks, @ptrCast(@alignCast(ctx orelse return)));
    callbacks.pipeline.submitFinal(text);
}

fn onEngineAudioChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
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

const StreamCaptureState = struct {
    allocator: std.mem.Allocator,
    session: ?*engine.Session,
    captured_audio: *std.ArrayList(u8),
    gate: *audio_gate.AudioGate,
    stream_error: ?anyerror = null,
};

const EngineCallbacks = struct {
    pipeline: *postprocess.Pipeline,
};

const SessionInitResult = @typeInfo(@TypeOf(initSessionWithRetry)).@"fn".return_type.?;
const SessionFuture = std.Io.Future(SessionInitResult);

fn onHoldTimeout(ctx: ?*anyopaque) void {
    const state: *const CaptureStartedState = @ptrCast(@alignCast(ctx orelse return));
    state.logger.info("mic", "max hold reached; stopping", .{});
}

const CaptureStartedState = struct {
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

const CaptureReleaseState = struct {
    logger: output.Logger,
    speaker_guard: *SpeakerMuteGuard,
};

const SpeakerMuteGuard = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    active: bool = false,

    fn muteAfterPrompt(guard: *SpeakerMuteGuard) void {
        guard.logger.debug("speaker", "mute", .{});
        mute.muteSpeaker(guard.allocator, guard.io);
        guard.active = true;
    }

    fn release(guard: *SpeakerMuteGuard) void {
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

fn onCaptureRecorder(ctx: ?*anyopaque, program: []const u8) void {
    const state = @as(*CaptureStartedState, @ptrCast(@alignCast(ctx orelse return)));
    state.logger.debug("mic", "recorder {s}", .{program});
}

fn onCaptureStarted(ctx: ?*anyopaque) !void {
    const state = @as(*CaptureStartedState, @ptrCast(@alignCast(ctx orelse return error.MissingCaptureStartedState)));

    if (state.io.concurrent(playBellTask, .{ state.allocator, state.io })) |bell_future_value| {
        var bell_future = bell_future_value;
        resolveSession(state) catch |err| {
            _ = bell_future.await(state.io);
            state.logger.err(engineLabel(state.cfg), "session failed: {s}", .{@errorName(err)});
            return err;
        };
        _ = bell_future.await(state.io);
        state.speaker_guard.muteAfterPrompt();
    } else |_| {
        playBellTask(state.allocator, state.io);
        state.speaker_guard.muteAfterPrompt();
        resolveSession(state) catch |err| {
            state.logger.err(engineLabel(state.cfg), "session failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    try state.gate.openAndFlush(@ptrCast(state.stream_state), sendEngineAudioChunk);
    state.logger.info(engineLabel(state.cfg), "🎤", .{});
}

fn onCaptureStopped(ctx: ?*anyopaque) void {
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

fn formatMicCloseMessage(buf: []u8, summary: mic.StreamSummary) ![]const u8 {
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
