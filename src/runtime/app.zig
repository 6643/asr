const std = @import("std");
const config = @import("../config.zig");
const doubao = @import("../doubao/client.zig");
const rectify = @import("../doubao/rectify.zig");
const key = @import("../key.zig");
const audio_gate = @import("audio_gate.zig");
const ibus = @import("ibus.zig");
const mic = @import("mic.zig");
const mute = @import("mute.zig");
const notify = @import("notify.zig");
const output = @import("output.zig");
const posix_system = std.posix.system;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !void {
    const logger = output.Logger{ .io = io, .level = .debug };
    var cfg: config.Config = .{};
    const creds = try config.loadCredentials(allocator, io, cfg.credential_path);
    defer creds.deinit(allocator);
    cfg = config.withCredentials(cfg, creds);
    if (cfg.device_id.len == 0 or cfg.token.len == 0) return error.MissingCredentials;

    logger.info("app", "ASR 启动", .{});
    logger.info("doubao", "{s}", .{cfg.device_id});

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

    var service_loop = ServiceLoop{
        .service = service,
        .io = io,
        .running = std.atomic.Value(bool).init(true),
    };
    const service_thread = try std.Thread.spawn(.{}, runServiceLoop, .{&service_loop});
    defer {
        service_loop.running.store(false, .release);
        service_thread.join();
    }

    ibus.switchToAsrInputMethod(allocator, io) catch |err| {
        logger.err("ibus", "switch failed: {s}", .{@errorName(err)});
        logger.info("ibus", "Auto-switch unavailable; switch to ASR manually", .{});
        try runHotkeyLoop(allocator, io, environ, logger, cfg, keyboard_device, service);
        return;
    };
    logger.info("ibus", "Switched to ASR input method", .{});
    if (!waitForServiceReady(io, service, 4000)) {
        logger.debug("ibus", "service not ready yet", .{});
    }

    try runHotkeyLoop(allocator, io, environ, logger, cfg, keyboard_device, service);
}

const ServiceLoop = struct {
    service: *ibus.gio_ibus.Service,
    io: std.Io,
    running: std.atomic.Value(bool),
};

fn runServiceLoop(loop: *ServiceLoop) void {
    while (loop.running.load(.acquire)) {
        loop.service.iterate();
        sleepMs(loop.io, 10);
    }
}

fn waitForServiceReady(io: std.Io, service: *ibus.gio_ibus.Service, timeout_ms: i64) bool {
    var elapsed: i64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 50) {
        if (std.mem.eql(u8, service.status(), "ready")) return true;
        sleepMs(io, 50);
    }
    return false;
}

fn runHotkeyLoop(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    logger: output.Logger,
    cfg: config.Config,
    initial_keyboard_device: []const u8,
    service: *ibus.gio_ibus.Service,
) !void {
    var keyboard = try KeyboardEventStream.open(allocator, io, environ, logger, initial_keyboard_device);
    defer keyboard.deinit();

    output.keyWait(logger);
    while (true) {
        const event = keyboard.readNext(key.right_alt) catch |err| {
            switch (classifyKeyboardReadFailure(err)) {
                .reopen => {
                    keyboard.reopenAfterReadFailure(err);
                    output.keyWait(logger);
                    continue;
                },
                .fail => return err,
            }
        };
        if (event == .release) continue;
        output.keyEvent(logger, .press);
        var callback_ctx = DoubaoCallbacks{
            .allocator = allocator,
            .io = io,
            .logger = logger,
            .service = service,
            .cfg = &cfg,
        };
        var session = initSessionWithRetry(allocator, io, cfg, &callback_ctx, logger) catch |err| {
            logger.err("doubao", "session failed: {s}", .{@errorName(err)});
            output.keyWait(logger);
            continue;
        };
        defer session.deinit();
        session.start() catch |err| {
            logger.err("doubao", "session failed: {s}", .{@errorName(err)});
            output.keyWait(logger);
            continue;
        };
        defer drainKeyboardEvents(keyboard.file, &keyboard.state, key.right_alt, logger);
        var captured_audio: std.ArrayList(u8) = .empty;
        defer captured_audio.deinit(allocator);
        var gate = audio_gate.AudioGate.init(allocator, io);
        defer gate.deinit();
        var stream_state = StreamCaptureState{
            .allocator = allocator,
            .session = &session,
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
        };
        var release_state = CaptureReleaseState{
            .logger = logger,
            .speaker_guard = &speaker_guard,
        };
        logger.debug("mic", "open", .{});
        const capture_summary = mic.captureStreamUntilKeyRelease(io, keyboard.file, &keyboard.state, key.right_alt, .{
            .sample_rate = cfg.sample_rate,
            .channels = cfg.channels,
            .frame_duration_ms = cfg.frame_duration_ms,
        }, .{
            .on_chunk = onDoubaoAudioChunk,
            .chunk_ctx = @ptrCast(&stream_state),
            .on_started = onCaptureStarted,
            .started_ctx = @ptrCast(&started_state),
            .on_stopped = onCaptureStopped,
            .stopped_ctx = @ptrCast(&release_state),
        }) catch |err| {
            logger.err("doubao", "capture failed: {s}", .{@errorName(err)});
            output.keyWait(logger);
            continue;
        };
        var close_message_buf: [128]u8 = undefined;
        const close_message = formatMicCloseMessage(&close_message_buf, capture_summary) catch "recording already stopped";
        logger.debug("mic", "{s}", .{close_message});

        if (stream_state.stream_error) |stream_err| {
            logger.err("doubao", "stream failed: {s}", .{@errorName(stream_err)});
            const finish = session.finishAfterStreamFailure();
            if (!handleFinish(allocator, logger, service, finish) and !session.hasFinalEvent()) {
                const fallback = doubao.transcribePcmBytes(allocator, io, cfg, captured_audio.items, .{
                    .pcm_path = "",
                    .debug = true,
                }) catch |err| {
                    logger.err("doubao", "fallback failed: {s}", .{@errorName(err)});
                    output.keyWait(logger);
                    continue;
                };
                if (fallback) |text| {
                    _ = handleFinish(allocator, logger, service, .{ .text = text });
                } else {
                    logger.info("doubao", "session_finished", .{});
                }
            }
            output.keyWait(logger);
            continue;
        }

        const finish = session.finish() catch |err| {
            logger.err("doubao", "recognize failed: {s}", .{@errorName(err)});
            output.keyWait(logger);
            continue;
        };
        _ = handleFinish(allocator, logger, service, finish);
        output.keyWait(logger);
    }
}

fn initSessionWithRetry(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    callback_ctx: *const DoubaoCallbacks,
    logger: output.Logger,
) !doubao.StreamingSession {
    var delay_ms: i64 = 1000;
    var attempt: usize = 0;
    while (true) {
        if (doubao.StreamingSession.init(allocator, io, cfg, .{
            .debug = true,
            .on_interim = onDoubaoInterim,
            .interim_ctx = @ptrCast(callback_ctx),
            .on_final = onDoubaoFinal,
            .final_ctx = @ptrCast(callback_ctx),
        })) |session| {
            return session;
        } else |err| {
            attempt += 1;
            if (err == error.RemoteAsrError and attempt < 3) {
                logger.info("doubao", "quota exceeded, retry {d}/3 in {d}ms", .{ attempt, delay_ms });
                std.Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch {};
                delay_ms *= 2;
                continue;
            }
            return err;
        }
    }
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
        return key.readNextDeviceEvent(stream.file, &stream.state, key_code);
    }

    fn reopenAfterReadFailure(stream: *KeyboardEventStream, read_err: anyerror) void {
        stream.logger.err("kbd", "read failed: {s}; reopening keyboard device", .{@errorName(read_err)});
        while (true) {
            const next_path = key.findKeyboardDevice(stream.allocator, stream.io, stream.environ) catch |err| {
                stream.logger.err("kbd", "reopen failed: {s}", .{@errorName(err)});
                sleepMs(stream.io, 500);
                continue;
            };

            const next_file = openKeyboardFile(stream.io, next_path) catch |err| {
                stream.logger.err("kbd", "open failed: {s}: {s}", .{ next_path, @errorName(err) });
                stream.allocator.free(next_path);
                sleepMs(stream.io, 500);
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
    logger: output.Logger,
    service: *ibus.gio_ibus.Service,
    finish: doubao.StreamFinish,
) bool {
    switch (finish) {
        .text => |text| {
            defer allocator.free(text);
            logger.info("doubao", "🚀 {s}", .{text});
            const commit_status = service.commitStatus(text);
            if (!std.mem.startsWith(u8, commit_status, "OK ")) {
                logger.err("ibus", "❌ {s}", .{commit_status});
                return true;
            }
            logger.info("ibus", "✅", .{});
            return true;
        },
        .err => |message| {
            defer allocator.free(message);
            logger.err("doubao", "recognize failed: {s}", .{message});
            return false;
        },
        .none => {
            logger.info("doubao", "session_finished", .{});
            return false;
        },
    }
}

fn sleepMs(io: std.Io, milliseconds: i64) void {
    std.Io.sleep(io, .fromMilliseconds(milliseconds), .awake) catch {};
}

fn onDoubaoInterim(ctx: ?*const anyopaque, text: []const u8) void {
    if (text.len == 0) return;
    const callbacks = @as(*const DoubaoCallbacks, @ptrCast(@alignCast(ctx orelse return)));
    callbacks.logger.info("doubao", "🎤 {s}", .{text});
}

fn onDoubaoFinal(ctx: ?*const anyopaque, text: []const u8) void {
    if (text.len == 0) return;
    const callbacks = @as(*const DoubaoCallbacks, @ptrCast(@alignCast(ctx orelse return)));
    const corrected = rectify.rectifyText(callbacks.allocator, callbacks.io, text, callbacks.cfg.sami_token, callbacks.cfg.device_id) catch null;
    if (corrected) |c| {
        defer callbacks.allocator.free(c);
        callbacks.logger.info("doubao", "🚀 {s} → {s}", .{ text, c });
        const commit_status = callbacks.service.commitStatus(c);
        if (!std.mem.startsWith(u8, commit_status, "OK ")) {
            callbacks.logger.err("ibus", "🟥 {s}", .{commit_status});
            return;
        }
    } else {
        callbacks.logger.info("doubao", "🚀 {s}", .{text});
        callbacks.logger.info("rectify", "🔧 {s}", .{text});
        const commit_status = callbacks.service.commitStatus(text);
        if (!std.mem.startsWith(u8, commit_status, "OK ")) {
            callbacks.logger.err("ibus", "🖍️ {s}", .{commit_status});
            return;
        }
    }
    callbacks.logger.info("ibus", "🖊️", .{});
}

fn onDoubaoAudioChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
    const state = @as(*StreamCaptureState, @ptrCast(@alignCast(ctx orelse return error.MissingChunkSession)));
    try state.gate.handleChunk(chunk, @ptrCast(state), sendDoubaoAudioChunk);
}

fn sendDoubaoAudioChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
    const state = @as(*StreamCaptureState, @ptrCast(@alignCast(ctx orelse return error.MissingChunkSession)));
    try state.captured_audio.appendSlice(state.allocator, chunk);
    if (state.stream_error != null) return;
    state.session.sendChunk(chunk) catch |err| {
        state.stream_error = err;
    };
}

const StreamCaptureState = struct {
    allocator: std.mem.Allocator,
    session: *doubao.StreamingSession,
    captured_audio: *std.ArrayList(u8),
    gate: *audio_gate.AudioGate,
    stream_error: ?anyerror = null,
};

const DoubaoCallbacks = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    service: *ibus.gio_ibus.Service,
    cfg: *const config.Config,
};

const CaptureStartedState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    gate: *audio_gate.AudioGate,
    speaker_guard: *SpeakerMuteGuard,
    stream_state: *StreamCaptureState,
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

fn onCaptureStarted(ctx: ?*anyopaque) !void {
    const state = @as(*CaptureStartedState, @ptrCast(@alignCast(ctx orelse return error.MissingCaptureStartedState)));
    notify.playMicReadyNotification(state.allocator, state.io);
    state.gate.beginBuffering();
    state.speaker_guard.muteAfterPrompt();
    try state.gate.openAndFlush(@ptrCast(state.stream_state), sendDoubaoAudioChunk);
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
