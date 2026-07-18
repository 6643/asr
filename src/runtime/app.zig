const std = @import("std");
const config = @import("../config.zig");
const doubao = @import("../doubao/client.zig");
const credentials = @import("../doubao/credentials.zig");
const engine = @import("engine.zig");
const key = @import("../key.zig");
const audio_gate = @import("audio_gate.zig");
const ibus = @import("ibus.zig");
const postprocess = @import("postprocess.zig");
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
    debug: bool,
    engine_kind: engine.Kind,
) !void {
    installSignalHandlers();
    const logger = output.Logger{ .io = io, .level = if (debug) .debug else .info };
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
            const refresh_ok = blk: {
                const result = credentials.refreshFile(allocator, io, cfg.credential_path, debug) catch |err| {
                    logger.err("doubao", "credential refresh failed: {s}; using existing credentials", .{@errorName(err)});
                    break :blk false;
                };
                break :blk credentials.refreshSucceeded(result);
            };
            if (refresh_ok) {
                logger.info("doubao", "credentials refreshed", .{});
                creds.deinit(allocator);
                doubao_creds = try config.loadCredentials(allocator, io, cfg.credential_path);
                creds = &doubao_creds.?;
            }
            cfg = config.withCredentials(cfg, creds.*);
            if (cfg.device_id.len == 0 or cfg.token.len == 0) return error.MissingCredentials;
            engine_cfg = .{ .doubao = cfg };
        },
    }
    defer if (engine_kind == .baidu) baidu_cfg.deinit(allocator);
    defer if (doubao_creds) |creds| creds.deinit(allocator);

    logger.info("app", "ASR 启动", .{});
    logger.info(engineLabel(engine_cfg), "engine ready", .{});
    if (engineKind(engine_cfg) == .doubao) {
        logger.info("doubao", "{s}", .{cfg.device_id});
    }

    const keyboard_device = try key.findKeyboardDevice(allocator, io, environ);
    defer allocator.free(keyboard_device);

    const component_path = try ibus.initRuntime(allocator, io, environ);
    defer allocator.free(component_path);
    logger.debug("app", "{s}", .{component_path});

    const service = try ibus.startService(allocator, io, environ);
    defer {
        service.stop();
        allocator.destroy(service);
    }

    var pipeline = try postprocess.Pipeline.start(allocator, io, logger, service, &cfg, if (engine_kind == .baidu) "baidu" else "doubao");
    defer pipeline.deinit();

    var service_loop = ServiceLoop{
        .service = service,
        .io = io,
        .running = std.atomic.Value(bool).init(true),
    };
    var service_future_opt = io.concurrent(runServiceLoop, .{&service_loop}) catch null;
    var service_thread: ?std.Thread = null;
    if (service_future_opt == null) {
        service_thread = try std.Thread.spawn(.{}, runServiceLoop, .{&service_loop});
    }
    defer {
        service_loop.running.store(false, .release);
        if (service_future_opt) |*f| {
            _ = f.cancel(io);
        } else if (service_thread) |t| {
            t.join();
        }
    }

    ibus.switchToAsrInputMethod(allocator, io) catch |err| {
        logger.err("ibus", "switch failed: {s}", .{@errorName(err)});
        logger.info("ibus", "Auto-switch unavailable; switch to ASR manually", .{});
        try runHotkeyLoop(allocator, io, environ, logger, engine_cfg, keyboard_device, pipeline, debug);
        return;
    };
    logger.info("ibus", "Switched to ASR input method", .{});
    if (!waitForServiceReady(io, service, 4000)) {
        logger.debug("ibus", "service not ready yet", .{});
    }

    try runHotkeyLoop(allocator, io, environ, logger, engine_cfg, keyboard_device, pipeline, debug);
}

const ServiceLoop = struct {
    service: *ibus.gio_ibus.Service,
    io: std.Io,
    running: std.atomic.Value(bool),
};

fn runServiceLoop(loop: *ServiceLoop) void {
    while (loop.running.load(.acquire) and !isShutdownRequested()) {
        loop.service.iterate();
        shutdown.sleepUntilOr(loop.io, 10);
    }
}

fn waitForServiceReady(io: std.Io, service: *ibus.gio_ibus.Service, timeout_ms: i64) bool {
    var elapsed: i64 = 0;
    while (elapsed <= timeout_ms and !isShutdownRequested()) : (elapsed += 50) {
        if (std.mem.eql(u8, service.status(), "ready")) return true;
        shutdown.sleepUntilOr(io, 50);
    }
    return false;
}

fn runHotkeyLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    logger: output.Logger,
    cfg: engine.Config,
    initial_keyboard_device: []const u8,
    pipeline: *postprocess.Pipeline,
    debug: bool,
) !void {
    var keyboard = try KeyboardEventStream.open(allocator, io, environ, logger, initial_keyboard_device);
    defer keyboard.deinit();

    output.keyWait(logger);
    while (true) {
        if (isShutdownRequested()) {
            logger.info("app", "shutting down", .{});
            return;
        }
        const event_opt = keyboard.readNextOrShutdown(key.right_alt) catch |err| {
            if (err == error.Interrupted) continue;
            switch (classifyKeyboardReadFailure(err)) {
                .reopen => {
                    keyboard.reopenAfterReadFailure(err);
                    if (isShutdownRequested()) {
                        logger.info("app", "shutting down", .{});
                        return;
                    }
                    output.keyWait(logger);
                    continue;
                },
                .fail => return err,
            }
        };
        const event = event_opt orelse {
            logger.info("app", "shutting down", .{});
            return;
        };
        if (event == .release) continue;
        output.keyEvent(logger, .press);

        var callback_ctx = EngineCallbacks{
            .pipeline = pipeline,
        };

        // Parallel boot: WS handshake overlaps arecord + early speech buffer.
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

        defer drainKeyboardEvents(keyboard.file, &keyboard.state, key.right_alt, logger);
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
        const capture_summary = mic.captureStreamUntilKeyRelease(io, keyboard.file, &keyboard.state, key.right_alt, audio_params, .{
            .on_chunk = onEngineAudioChunk,
            .chunk_ctx = @ptrCast(&stream_state),
            .on_started = onCaptureStarted,
            .started_ctx = @ptrCast(&started_state),
            .on_stopped = onCaptureStopped,
            .stopped_ctx = @ptrCast(&release_state),
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
        const close_message = formatMicCloseMessage(&close_message_buf, capture_summary) catch "recording already stopped";
        logger.debug("mic", "{s}", .{close_message});

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

const KeyboardReadFailureAction = enum {
    reopen,
    fail,
};

fn classifyKeyboardReadFailure(err: anyerror) KeyboardReadFailureAction {
    return switch (err) {
        error.KeyboardDeviceDisconnected,
        error.EndOfStream,
        error.ReadFailed,
        => .reopen,
        else => .fail,
    };
}

const KeyboardEventStream = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    logger: output.Logger,
    path: []u8,
    file: std.Io.File,
    state: key.State = .{},

    fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        logger: output.Logger,
        initial_path: []const u8,
    ) !KeyboardEventStream {
        const owned_path = try allocator.dupe(u8, initial_path);
        errdefer allocator.free(owned_path);

        const file = try openKeyboardFile(io, owned_path);
        logger.info("kbd", "{s}", .{owned_path});

        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .logger = logger,
            .path = owned_path,
            .file = file,
        };
    }

    fn deinit(stream: *KeyboardEventStream) void {
        stream.file.close(stream.io);
        stream.allocator.free(stream.path);
    }

    fn readNext(stream: *KeyboardEventStream, key_code: u16) key.DeviceReadError!key.Event {
        return key.readNextDeviceEvent(stream.io, stream.file, &stream.state, key_code);
    }

    fn readNextOrShutdown(stream: *KeyboardEventStream, key_code: u16) key.DeviceReadError!?key.Event {
        return key.waitNextDeviceEventOrShutdown(
            stream.io,
            stream.file,
            &stream.state,
            key_code,
            isShutdownRequested,
        );
    }

    fn reopenAfterReadFailure(stream: *KeyboardEventStream, read_err: anyerror) void {
        stream.logger.err("kbd", "read failed: {s}; reopening keyboard device", .{@errorName(read_err)});
        while (!isShutdownRequested()) {
            const next_path = key.findKeyboardDevice(stream.allocator, stream.io, stream.environ) catch |err| {
                stream.logger.err("kbd", "reopen failed: {s}", .{@errorName(err)});
                shutdown.sleepUntilOr(stream.io, 500);
                continue;
            };

            const next_file = openKeyboardFile(stream.io, next_path) catch |err| {
                stream.logger.err("kbd", "open failed: {s}: {s}", .{ next_path, @errorName(err) });
                stream.allocator.free(next_path);
                shutdown.sleepUntilOr(stream.io, 500);
                continue;
            };

            stream.file.close(stream.io);
            stream.allocator.free(stream.path);
            stream.path = next_path;
            stream.file = next_file;
            stream.state = .{};
            stream.logger.info("kbd", "{s}", .{stream.path});
            return;
        }
    }
};

fn openKeyboardFile(io: std.Io, path: []const u8) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, path, .{});
}

fn drainKeyboardEvents(file: std.Io.File, state: *key.State, key_code: u16, logger: output.Logger) void {
    const fd = file.handle;
    const system = std.posix.system;
    const orig_flags = system.fcntl(fd, system.F.GETFL, @as(usize, 0));
    if (orig_flags < 0) return;
    const nonblock_flag = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = system.fcntl(fd, system.F.SETFL, @as(usize, @intCast(orig_flags)) | nonblock_flag);
    var buf: [key.input_event_size]u8 = undefined;
    var drained: usize = 0;
    while (true) {
        const rc = system.read(fd, &buf, buf.len);
        if (rc <= 0) break;
        _ = key.update(state, buf[0..@as(usize, @intCast(rc))], key_code);
        drained += 1;
    }
    _ = system.fcntl(fd, system.F.SETFL, @as(usize, @intCast(orig_flags)));
    if (drained > 0) {
        logger.debug("kbd", "drained {d} buffered events", .{drained});
    }
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

fn onCaptureStarted(ctx: ?*anyopaque) !void {
    const state = @as(*CaptureStartedState, @ptrCast(@alignCast(ctx orelse return error.MissingCaptureStartedState)));

    if (state.io.concurrent(playBellTask, .{ state.allocator, state.io })) |bell_future_value| {
        var bell_future = bell_future_value;
        resolveSession(state) catch |err| {
            _ = bell_future.await(state.io);
            state.logger.err("doubao", "session failed: {s}", .{@errorName(err)});
            return err;
        };
        _ = bell_future.await(state.io);
        state.speaker_guard.muteAfterPrompt();
    } else |_| {
        playBellTask(state.allocator, state.io);
        state.speaker_guard.muteAfterPrompt();
        resolveSession(state) catch |err| {
            state.logger.err("doubao", "session failed: {s}", .{@errorName(err)});
            return err;
        };
    }

    try state.gate.openAndFlush(@ptrCast(state.stream_state), sendEngineAudioChunk);
    state.logger.info("doubao", "🎤", .{});
}

fn onCaptureStopped(ctx: ?*anyopaque) void {
    const state = @as(*CaptureReleaseState, @ptrCast(@alignCast(ctx orelse return)));
    output.keyEvent(state.logger, .release);
    state.speaker_guard.release();
}

fn formatMicCloseMessage(buf: []u8, summary: mic.StreamSummary) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "recording already stopped; final capture summary chunks={d} bytes={d}",
        .{ summary.chunk_count, summary.byte_count },
    );
}

test "formats mic close log as final capture summary after stop" {
    var buf: [128]u8 = undefined;
    const message = try formatMicCloseMessage(&buf, .{
        .chunk_count = 13,
        .byte_count = 53194,
    });
    try std.testing.expectEqualStrings(
        "recording already stopped; final capture summary chunks=13 bytes=53194",
        message,
    );
}

test "keyboard read failed reopens event reader instead of exiting" {
    try std.testing.expectEqual(KeyboardReadFailureAction.reopen, classifyKeyboardReadFailure(error.KeyboardDeviceDisconnected));
    try std.testing.expectEqual(KeyboardReadFailureAction.reopen, classifyKeyboardReadFailure(error.ReadFailed));
    try std.testing.expectEqual(KeyboardReadFailureAction.fail, classifyKeyboardReadFailure(error.AccessDenied));
}

test "Interrupted is not classified as reopen" {
    try std.testing.expectEqual(KeyboardReadFailureAction.fail, classifyKeyboardReadFailure(error.Interrupted));
}
