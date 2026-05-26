const std = @import("std");
const config = @import("../config.zig");
const doubao = @import("../doubao/client.zig");
const key = @import("../key.zig");
const ibus = @import("ibus.zig");
const mic = @import("mic.zig");
const mute = @import("mute.zig");
const notify = @import("notify.zig");
const output = @import("output.zig");

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
    logger.info("kbd", "{s}", .{keyboard_device});

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
        try runHotkeyLoop(allocator, io, logger, cfg, keyboard_device, service);
        return;
    };
    logger.info("ibus", "Switched to ASR input method", .{});
    if (!waitForServiceReady(io, service, 4000)) {
        logger.debug("ibus", "service not ready yet", .{});
    }

    try runHotkeyLoop(allocator, io, logger, cfg, keyboard_device, service);
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
    logger: output.Logger,
    cfg: config.Config,
    keyboard_device: []const u8,
    service: *ibus.gio_ibus.Service,
) !void {
    const file = try std.Io.Dir.cwd().openFile(io, keyboard_device, .{});
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(file, io, &read_buffer);
    var state: key.State = .{};
    output.keyWait(logger);
    while (true) {
        const event = try key.readNextEvent(&reader.interface, &state, key.right_alt);
        if (event == .release) continue;
        output.keyEvent(logger, .press);
        var callback_ctx = DoubaoCallbacks{
            .logger = logger,
            .service = service,
        };
        var session = doubao.StreamingSession.init(allocator, io, cfg, .{
            .debug = true,
            .on_interim = onDoubaoInterim,
            .interim_ctx = @ptrCast(&callback_ctx),
            .on_final = onDoubaoFinal,
            .final_ctx = @ptrCast(&callback_ctx),
        }) catch |err| {
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
        notify.playMicReadyNotification(allocator, io);
        logger.info("doubao", "🎤", .{});
        var captured_audio: std.ArrayList(u8) = .empty;
        defer captured_audio.deinit(allocator);
        var stream_state = StreamCaptureState{
            .allocator = allocator,
            .session = &session,
            .captured_audio = &captured_audio,
        };
        var speaker_guard = SpeakerMuteGuard.init(allocator, io, logger);
        defer speaker_guard.release();
        logger.debug("mic", "open", .{});
        const capture_summary = mic.captureStreamUntilKeyRelease(io, keyboard_device, key.right_alt, .{
            .sample_rate = cfg.sample_rate,
            .channels = cfg.channels,
            .frame_duration_ms = cfg.frame_duration_ms,
        }, .{
            .on_chunk = onDoubaoAudioChunk,
            .chunk_ctx = @ptrCast(&stream_state),
        }) catch |err| {
            logger.err("doubao", "capture failed: {s}", .{@errorName(err)});
            output.keyWait(logger);
            continue;
        };
        output.keyEvent(logger, .release);
        logger.debug("mic", "close chunks={d} bytes={d}", .{ capture_summary.chunk_count, capture_summary.byte_count });
        speaker_guard.release();

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
    callbacks.logger.info("doubao", "🚀 {s}", .{text});
    const commit_status = callbacks.service.commitStatus(text);
    if (!std.mem.startsWith(u8, commit_status, "OK ")) {
        callbacks.logger.err("ibus", "❌ {s}", .{commit_status});
        return;
    }
    callbacks.logger.info("ibus", "✅", .{});
}

fn onDoubaoAudioChunk(ctx: ?*anyopaque, chunk: []const u8) !void {
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
    stream_error: ?anyerror = null,
};

const DoubaoCallbacks = struct {
    logger: output.Logger,
    service: *ibus.gio_ibus.Service,
};

const SpeakerMuteGuard = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    active: bool = false,

    fn init(allocator: std.mem.Allocator, io: std.Io, logger: output.Logger) SpeakerMuteGuard {
        logger.debug("speaker", "mute", .{});
        mute.muteSpeaker(allocator, io);
        return .{
            .allocator = allocator,
            .io = io,
            .logger = logger,
            .active = true,
        };
    }

    fn release(guard: *SpeakerMuteGuard) void {
        if (!guard.active) return;
        guard.logger.debug("speaker", "unmute", .{});
        mute.unmuteSpeaker(guard.allocator, guard.io);
        guard.active = false;
    }
};
