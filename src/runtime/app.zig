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
const capture = @import("capture.zig");
const mic = @import("mic.zig");
const mute = @import("mute.zig");
const output = @import("output.zig");
const shutdown = @import("shutdown.zig");

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
    logger.info(engine.label(engine_cfg), "engine ready", .{});
    if (engine.kind(engine_cfg) == .doubao) {
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

    const client = connectWithRetry(allocator, io, environ, logger) catch |err| {
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

    var rescan_ctx = keyboard_set.DiscoveryCtx{ .environ = environ };
    try runHotkeyLoop(allocator, io, logger, engine_cfg, &keyboards, pipeline, opts, &wayland_loop.failed, &rescan_ctx);
}

/// Connects to the compositor, retrying once: right after an unclean stop the
/// seat input method may still be held for a moment.
fn connectWithRetry(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    logger: output.Logger,
) wayland_im.ConnectError!*wayland_im.Client {
    return wayland_im.connect(allocator, io, environ) catch |err| {
        if (!wayland_im.shouldRetryBind(err)) return err;
        logger.info("wayland", "retrying bind after {s}", .{@errorName(err)});
        std.Io.sleep(io, .fromMilliseconds(wayland_im.bind_retry_delay_ms), .awake) catch return err;
        return wayland_im.connect(allocator, io, environ);
    };
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
    rescan_ctx: *keyboard_set.DiscoveryCtx,
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
        const outcome = keyboards.readNextOrShutdown(key.right_alt, isShutdownRequested, keyboard_set.discoveryCandidates, rescan_ctx) catch |err| {
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

        var callback_ctx = capture.EngineCallbacks{
            .pipeline = pipeline,
        };

        // Parallel boot: WS handshake overlaps recorder startup + early speech buffer.
        var session_future_opt = io.concurrent(capture.initSessionWithRetry, .{
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

        var stream_state = capture.StreamCaptureState{
            .allocator = allocator,
            .session = null,
            .captured_audio = &captured_audio,
            .gate = &gate,
        };
        var speaker_guard = capture.SpeakerMuteGuard{
            .allocator = allocator,
            .io = io,
            .logger = logger,
        };
        defer speaker_guard.release();
        var started_state = capture.CaptureStartedState{
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
        var release_state = capture.CaptureReleaseState{
            .logger = logger,
            .speaker_guard = &speaker_guard,
        };
        const audio_params: mic.CaptureOptions = switch (cfg) {
            .baidu => |value| .{ .sample_rate = value.sample_rate, .channels = value.channels, .frame_duration_ms = value.frame_duration_ms },
            .doubao => |value| .{ .sample_rate = value.sample_rate, .channels = value.channels, .frame_duration_ms = value.frame_duration_ms },
        };
        logger.debug("mic", "open", .{});
        const capture_summary = mic.captureStreamUntilKeyRelease(io, event.device.file, &event.device.state, key.right_alt, audio_params, opts.max_hold_ms, .{
            .on_chunk = capture.onEngineAudioChunk,
            .chunk_ctx = @ptrCast(&stream_state),
            .on_started = capture.onCaptureStarted,
            .started_ctx = @ptrCast(&started_state),
            .on_stopped = capture.onCaptureStopped,
            .stopped_ctx = @ptrCast(&release_state),
            .on_recorder = capture.onCaptureRecorder,
            .recorder_ctx = @ptrCast(&started_state),
            .on_hold_timeout = capture.onHoldTimeout,
            .hold_timeout_ctx = @ptrCast(&started_state),
        }) catch |err| {
            if (isShutdownRequested()) {
                logger.info("app", "shutting down", .{});
                return;
            }
            logger.err(engine.label(cfg), "capture failed: {s}", .{@errorName(err)});
            output.keyWait(logger);
            continue;
        };
        if (isShutdownRequested()) {
            logger.info("app", "shutting down", .{});
            return;
        }
        var close_message_buf: [128]u8 = undefined;
        const close_message = capture.formatMicCloseMessage(&close_message_buf, capture_summary) catch "stopped";
        logger.debug("mic", "{s}", .{close_message});

        if (capture.noAudioCaptured(capture_summary)) {
            logger.err("mic", "no_audio_captured: recorder produced 0 bytes; check the microphone and PipeWire", .{});
            output.keyWait(logger);
            continue;
        }

        if (!has_session) {
            logger.err(engine.label(cfg), "session unavailable", .{});
            output.keyWait(logger);
            continue;
        }

        if (stream_state.stream_error) |stream_err| {
            logger.err(engine.label(cfg), "stream failed: {s}", .{@errorName(stream_err)});
            const finish = session.finishAfterStreamFailure();
            if (!handleFinish(allocator, pipeline, finish) and !session.hasFinalEvent()) {
                if (engine.kind(cfg) == .doubao) {
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
            logger.err(engine.label(cfg), "recognize failed: {s}", .{@errorName(err)});
            output.keyWait(logger);
            continue;
        };
        _ = handleFinish(allocator, pipeline, finish);
        output.keyWait(logger);
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
