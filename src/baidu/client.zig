const std = @import("std");
const websocket = @import("websocket");
const common = @import("../common.zig");
const config = @import("../config.zig");
const finish_grace = @import("../runtime/finish_grace.zig");
const streaming_state = @import("../streaming_state.zig");
const ws_url = @import("../ws_url.zig");
const proto = @import("proto.zig");

pub const EventType = enum {
    interim,
    final,
    session_finished,
    err,
};

pub const Event = struct {
    kind: EventType,
    text: []const u8 = "",
    message: []const u8 = "",

    pub fn deinit(event: Event, allocator: std.mem.Allocator) void {
        if (event.text.len > 0) allocator.free(event.text);
        if (event.message.len > 0) allocator.free(event.message);
    }
};

pub const OnceOptions = struct {
    pcm_path: []const u8,
    debug: bool = false,
    on_interim: ?*const fn (ctx: ?*const anyopaque, text: []const u8) void = null,
    interim_ctx: ?*const anyopaque = null,
};

pub const StreamOptions = struct {
    debug: bool = false,
    on_interim: ?*const fn (ctx: ?*const anyopaque, text: []const u8) void = null,
    interim_ctx: ?*const anyopaque = null,
    on_final: ?*const fn (ctx: ?*const anyopaque, text: []const u8) void = null,
    final_ctx: ?*const anyopaque = null,
};

pub const StreamFinish = streaming_state.Finish;

/// Streaming session for real-time Baidu voice recognition.
///
/// Protocol flow:
/// 1. Connect to wss://vse.baidu.com/ws_api?sn=<uuid>
/// 2. Send START JSON text frame
/// 3. Send audio as binary frames (raw PCM 16kHz 16-bit mono)
/// 4. Receive JSON text frames (MID_TEXT interim, FIN_TEXT final, HEARTBEAT)
/// 5. Send FINISH JSON text frame
/// 6. Receive SESSION_FINISH
/// 7. Close connection
pub const StreamingSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.BaiduConfig,
    options: StreamOptions,
    client: websocket.Client,
    frame_bytes: usize,
    pending_audio: std.ArrayList(u8),
    waiter: streaming_state.Waiter,
    write_mutex: std.Io.Mutex = .init,
    read_thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finish_sent: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        cfg: config.BaiduConfig,
        options: StreamOptions,
    ) !StreamingSession {
        const frame_bytes_u32 = config.frameBytes(.{
            .sample_rate = cfg.sample_rate,
            .channels = cfg.channels,
            .frame_duration_ms = cfg.frame_duration_ms,
        });
        if (frame_bytes_u32 == 0) return error.InvalidFrameBytes;
        const frame_bytes: usize = @intCast(frame_bytes_u32);

        var client = try connect(allocator, io, cfg);
        errdefer client.deinit();

        const sn = try common.randomHexId(allocator, io);
        defer allocator.free(sn);

        try initializeSession(allocator, io, &client, cfg, sn, options.debug);

        var pending_audio = try std.ArrayList(u8).initCapacity(allocator, @max(frame_bytes * 3, @as(usize, 8192)));
        errdefer pending_audio.deinit(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .options = options,
            .client = client,
            .frame_bytes = frame_bytes,
            .pending_audio = pending_audio,
            .waiter = .{ .io = io },
        };
    }

    pub fn start(session: *StreamingSession) !void {
        if (session.read_thread != null) return error.SessionAlreadyStarted;
        session.read_thread = try std.Thread.spawn(.{}, readLoopThread, .{session});
    }

    pub fn deinit(session: *StreamingSession) void {
        if (!session.finish_sent) {
            session.sendFinishRequestQuiet();
            session.finish_sent = true;
        }
        session.stopReadLoop();
        session.joinReadThread();
        session.waiter.deinit(session.allocator);
        session.pending_audio.deinit(session.allocator);
        session.client.deinit();
    }

    pub fn sendChunk(session: *StreamingSession, chunk: []const u8) !void {
        if (session.finish_sent) return error.SessionAlreadyFinished;
        if (session.waiter.abortAudio()) return error.SessionStreamClosed;
        try session.pending_audio.appendSlice(session.allocator, chunk);
        try session.flushReadyFrames();
    }

    /// Max time to wait for server final/session_finished after FinishSession.
    pub const finish_timeout_ms: i64 = 5_000;

    /// Extra window for a late final result once `finish_timeout_ms` expired.
    pub const finish_grace_ms: i64 = finish_grace.default_grace_ms;

    pub fn finish(session: *StreamingSession) !StreamFinish {
        if (session.waiter.abortAudio()) {
            session.finish_sent = true;
            return session.waiter.take();
        }
        if (!session.finish_sent) {
            try session.flushTrailingFrame();
            try session.sendFinishRequest();
            session.finish_sent = true;
        }

        const first = session.waiter.waitForFinish(finish_timeout_ms);
        if (first == .none and session.waiter.shouldWaitGrace(finish_grace_ms)) {
            return session.waiter.waitForFinish(finish_grace_ms);
        }
        return first;
    }

    pub fn finishAfterStreamFailure(session: *StreamingSession) StreamFinish {
        if (!session.finish_sent) {
            session.sendFinishRequestQuiet();
            session.finish_sent = true;
        }
        session.stopReadLoop();
        session.joinReadThread();
        return session.waiter.take();
    }

    pub fn hasFinalEvent(session: *StreamingSession) bool {
        return session.waiter.hasFinal();
    }

    pub fn serverMessage(session: *StreamingSession, data: []u8, tpe: websocket.MessageTextType) !void {
        // Baidu sends control messages as text (JSON) and audio data as binary
        if (tpe == .binary) {
            // Binary frames from server are unexpected in this protocol
            if (session.options.debug) {
                std.log.scoped(.baidu).debug("unexpected binary frame ({d} bytes)", .{data.len});
            }
            return;
        }

        var response = try proto.parseServerMessage(session.allocator, data);
        defer response.deinit(session.allocator);
        session.handleResponse(&response);
    }

    pub fn serverClose(session: *StreamingSession, data: []u8) !void {
        _ = data;
        session.waiter.recordErrorMessage(session.allocator, "server closed");
    }

    pub fn readLoopError(session: *StreamingSession, err: anyerror) void {
        if (session.waiter.ignoresReadError(session.stop_requested.load(.acquire), err)) return;
        if (session.options.debug) {
            std.log.scoped(.baidu).warn("read loop failed: {s}", .{@errorName(err)});
        }
        session.waiter.recordErrorMessage(session.allocator, @errorName(err));
    }

    pub fn close(session: *StreamingSession) void {
        session.waiter.markReaderClosed();
    }

    // ── Internal helpers ──

    fn writeBinSafe(session: *StreamingSession, data: []const u8) !void {
        session.write_mutex.lockUncancelable(session.io);
        defer session.write_mutex.unlock(session.io);
        try session.client.writeBin(@constCast(data));
    }

    fn writeTextSafe(session: *StreamingSession, data: []const u8) !void {
        session.write_mutex.lockUncancelable(session.io);
        defer session.write_mutex.unlock(session.io);
        try session.client.writeText(@constCast(data));
    }

    fn writeClientFrame(session: *StreamingSession, op_code: websocket.OpCode, data: []u8) !void {
        session.write_mutex.lockUncancelable(session.io);
        defer session.write_mutex.unlock(session.io);
        try session.client.writeFrame(op_code, data);
    }

    fn joinReadThread(session: *StreamingSession) void {
        if (session.read_thread) |thread| {
            thread.join();
            session.read_thread = null;
        }
    }

    fn stopReadLoop(session: *StreamingSession) void {
        if (session.read_thread == null) return;
        session.stop_requested.store(true, .release);
        session.client.writeFrame(.close, "") catch {};
        session.shutdownReadSocket();
    }

    fn shutdownReadSocket(session: *StreamingSession) void {
        const fd = session.client.stream.stream.socket.handle;
        _ = std.os.linux.shutdown(fd, std.os.linux.SHUT.RDWR);
    }

    fn readLoopThread(session: *StreamingSession) void {
        while (true) {
            const message = session.client.read() catch |err| switch (err) {
                error.Closed => {
                    session.close();
                    return;
                },
                else => {
                    session.readLoopError(err);
                    session.close();
                    return;
                },
            } orelse continue;
            defer session.client.done(message);

            switch (message.type) {
                .text, .binary => session.serverMessage(message.data, if (message.type == .text) .text else .binary) catch |err| {
                    session.readLoopError(err);
                    session.close();
                    return;
                },
                .close => {
                    session.serverClose(message.data) catch |err| {
                        session.readLoopError(err);
                    };
                    session.close();
                    return;
                },
                .ping => session.writeClientFrame(.pong, @constCast(message.data)) catch |err| {
                    session.readLoopError(err);
                    session.close();
                    return;
                },
                .pong => {},
            }
        }
    }

    fn handleResponse(session: *StreamingSession, response: *proto.ServerMessage) void {
        switch (response.kind) {
            .mid_text => {
                if (response.text.len == 0) return;
                if (session.options.on_interim) |on_interim| {
                    on_interim(session.options.interim_ctx, response.text);
                    return;
                }
                if (session.options.debug) std.log.scoped(.baidu).info("interim: {s}", .{response.text});
            },
            .fin_text => {
                const text = response.text;
                response.text = "";
                if (session.options.on_final) |on_final| {
                    session.waiter.markFinalSeen();
                    on_final(session.options.final_ctx, text);
                    session.allocator.free(text);
                    return;
                }
                session.waiter.record(session.allocator, .{ .final = text });
            },
            .session_finish => session.waiter.record(session.allocator, .session_finished),
            .err => {
                if (response.err_no == -4) {
                    session.waiter.record(session.allocator, .session_finished);
                    return;
                }
                const message = response.error_message;
                response.error_message = "";
                session.waiter.record(session.allocator, .{ .err = message });
            },
            .heartbeat, .unknown => {},
        }
    }

    fn flushReadyFrames(session: *StreamingSession) !void {
        while (session.pending_audio.items.len >= session.frame_bytes) {
            try session.writeFrame(session.pending_audio.items[0..session.frame_bytes]);
            session.discardPendingPrefix(session.frame_bytes);
        }
    }

    fn flushTrailingFrame(session: *StreamingSession) !void {
        if (session.pending_audio.items.len == 0) return;
        const frame = try common.paddedFrame(session.allocator, session.pending_audio.items, session.frame_bytes);
        defer session.allocator.free(frame);
        if (session.waiter.abortAudio()) return error.SessionStreamClosed;
        try session.writeBinSafe(frame);
        session.pending_audio.items.len = 0;
    }

    fn writeFrame(session: *StreamingSession, frame: []const u8) !void {
        if (session.waiter.abortAudio()) return error.SessionStreamClosed;
        try session.writeBinSafe(frame);
    }

    fn discardPendingPrefix(session: *StreamingSession, prefix_len: usize) void {
        const remaining = session.pending_audio.items.len - prefix_len;
        std.mem.copyForwards(u8, session.pending_audio.items[0..remaining], session.pending_audio.items[prefix_len..]);
        session.pending_audio.items.len = remaining;
    }

    fn sendFinishRequest(session: *StreamingSession) !void {
        if (session.waiter.abortAudio()) return error.SessionStreamClosed;
        const finish_msg = try proto.buildFinishMessage(session.allocator);
        defer session.allocator.free(finish_msg);
        try session.writeTextSafe(finish_msg);
    }

    fn sendFinishRequestQuiet(session: *StreamingSession) void {
        const finish_msg = proto.buildFinishMessage(session.allocator) catch return;
        defer session.allocator.free(finish_msg);
        session.writeTextSafe(finish_msg) catch {};
    }
};

/// Transcribe a PCM file using Baidu ASR (once-off mode).
pub fn transcribePcmFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.BaiduConfig,
    options: OnceOptions,
) !?[]u8 {
    const audio = try std.Io.Dir.cwd().readFileAlloc(io, options.pcm_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(audio);
    return transcribePcmBytes(allocator, io, cfg, audio, .{
        .pcm_path = options.pcm_path,
        .debug = options.debug,
        .on_interim = options.on_interim,
        .interim_ctx = options.interim_ctx,
    });
}

/// Transcribe PCM audio bytes using Baidu ASR (once-off mode).
pub fn transcribePcmBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.BaiduConfig,
    audio: []const u8,
    options: OnceOptions,
) !?[]u8 {
    var client = try connect(allocator, io, cfg);
    defer client.deinit();

    const sn = try common.randomHexId(allocator, io);
    defer allocator.free(sn);

    try initializeSession(allocator, io, &client, cfg, sn, options.debug);
    try sendAudio(allocator, &client, audio);

    // Read response loop
    while (true) {
        const message = try client.read() orelse continue;
        defer client.done(message);

        if (message.type != .text) continue;

        var response = try proto.parseServerMessage(allocator, message.data);
        defer response.deinit(allocator);

        switch (response.kind) {
            .fin_text => return try allocator.dupe(u8, response.text),
            .session_finish => return null,
            .err => return error.RemoteAsrError,
            .mid_text => {
                if (response.text.len == 0) continue;
                if (options.on_interim) |on_interim| {
                    on_interim(options.interim_ctx, response.text);
                    continue;
                }
                if (options.debug) {
                    std.log.scoped(.baidu).info("interim: {s}", .{response.text});
                }
            },
            .heartbeat, .unknown => continue,
        }
    }
}

// ── Internal connection helpers ──

const default_baidu_ws_url = config.default_baidu_ws_url;

fn connect(allocator: std.mem.Allocator, io: std.Io, cfg: config.BaiduConfig) !websocket.Client {
    const url = if (cfg.url.len > 0) cfg.url else default_baidu_ws_url;

    const sn = try common.randomHexId(allocator, io);
    defer allocator.free(sn);

    const ws_url_text = try std.fmt.allocPrint(allocator, "{s}?sn={s}", .{ url, sn });
    defer allocator.free(ws_url_text);

    const parsed = try ws_url.parse(allocator, ws_url_text);
    defer parsed.deinit(allocator);

    var client = try websocket.Client.init(io, allocator, .{
        .port = parsed.port,
        .host = parsed.host,
        .tls = parsed.tls,
        .max_size = 1024 * 1024,
        .buffer_size = 16 * 1024,
    });
    errdefer client.deinit();

    const headers = try std.fmt.allocPrint(
        allocator,
        "Host: {s}\r\n",
        .{parsed.host},
    );
    defer allocator.free(headers);

    try client.handshake(parsed.path, .{
        .timeout_ms = common.ws_handshake_timeout_ms,
        .headers = headers,
    });
    return client;
}

fn initializeSession(allocator: std.mem.Allocator, io: std.Io, client: *websocket.Client, cfg: config.BaiduConfig, sn: []const u8, debug: bool) !void {
    // Send START message
    const audio_cfg = proto.AudioConfig{
        .user = cfg.user,
        .dev_key = cfg.dev_key,
        .dev_pid = cfg.dev_pid,
        .sample_rate = cfg.sample_rate,
        .format = "pcm",
        .channels = cfg.channels,
        .vad_type = cfg.vad_type,
        .vad_mode = cfg.vad_mode,
        .need_punctuation = cfg.enable_punctuation,
    };
    const ts = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const start_msg = try proto.buildStartMessage(allocator, audio_cfg, ts);
    defer allocator.free(start_msg);

    try client.writeText(@constCast(start_msg));

    if (debug) {
        std.log.scoped(.baidu).info("START sent (sn={s})", .{sn});
    }
}

fn sendAudio(allocator_param: std.mem.Allocator, client: *websocket.Client, audio: []const u8) !void {
    // Baidu: just send raw PCM as binary frames
    const allocator = allocator_param;
    if (audio.len > 0) {
        try client.writeBin(@constCast(audio));
    }

    // Send FINISH
    const finish_msg = try proto.buildFinishMessage(allocator);
    defer allocator.free(finish_msg);
    try client.writeText(@constCast(finish_msg));
}

test "parses a baidu websocket url" {
    const allocator = std.testing.allocator;
    const url = try std.fmt.allocPrint(allocator, "{s}?sn=abc123", .{default_baidu_ws_url});
    defer allocator.free(url);
    const parsed = try ws_url.parse(allocator, url);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.tls);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("vse.baidu.com", parsed.host);
}

test "server close without final records an error" {
    const allocator = std.testing.allocator;
    var waiter: streaming_state.Waiter = .{ .io = std.testing.io };
    defer waiter.deinit(allocator);

    waiter.recordErrorMessage(allocator, "server closed");
    switch (waiter.take()) {
        .err => |actual| {
            defer allocator.free(actual);
            try std.testing.expectEqualStrings("server closed", actual);
        },
        else => return error.TestExpectedError,
    }
}

test "no effective speech finishes without an error" {
    const allocator = std.testing.allocator;
    var session: StreamingSession = undefined;
    session.allocator = allocator;
    session.io = std.testing.io;
    session.options = .{};
    session.waiter = .{ .io = std.testing.io };
    defer session.waiter.deinit(allocator);

    var response = proto.ServerMessage{
        .kind = .err,
        .error_message = try allocator.dupe(u8, "asr server not find effective speech[info:-4]"),
        .err_no = -4,
    };
    defer response.deinit(allocator);

    session.handleResponse(&response);
    try std.testing.expectEqual(streaming_state.Resolution.session_finished, session.waiter.state.resolution());
    try std.testing.expect(session.waiter.state.error_message == null);
}

test "read loop errors are suppressed after a final result" {
    const allocator = std.testing.allocator;
    var waiter: streaming_state.Waiter = .{ .io = std.testing.io };
    defer waiter.deinit(allocator);

    try std.testing.expect(!waiter.ignoresReadError(false, error.ReadFailed));
    waiter.markFinalSeen();
    try std.testing.expect(waiter.ignoresReadError(false, error.ReadFailed));
    waiter.recordErrorMessage(allocator, "ReadFailed");
    try std.testing.expect(waiter.state.error_message == null);
}
