const std = @import("std");
const websocket = @import("websocket");
const config = @import("../config.zig");
const proto = @import("proto.zig");

pub const EventType = enum {
    interim,
    final,
    vad,
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

pub const StreamFinish = union(enum) {
    none,
    text: []const u8,
    err: []const u8,
};

const StreamingResolution = enum {
    pending,
    final,
    session_finished,
    err,
};

const RemoteErrorKind = enum { quota, other };

fn classifyRemoteError(message: []const u8) RemoteErrorKind {
    if (std.mem.indexOf(u8, message, "concurrency quota exceeded") != null) return .quota;
    return .other;
}

const StreamingResultState = struct {
    final_text: ?[]const u8 = null,
    final_seen: bool = false,
    error_message: ?[]const u8 = null,
    session_finished: bool = false,
    reader_closed: bool = false,

    fn deinit(state: *StreamingResultState, allocator: std.mem.Allocator) void {
        if (state.final_text) |text| allocator.free(text);
        if (state.error_message) |message| allocator.free(message);
        state.* = initStreamingResultState();
    }
};

fn initStreamingResultState() StreamingResultState {
    return .{};
}

fn currentStreamingResolution(state: StreamingResultState) StreamingResolution {
    if (state.error_message != null) return .err;
    if (state.final_text != null) return .final;
    if (state.session_finished or state.reader_closed) return .session_finished;
    return .pending;
}

fn takeResolvedResultLocked(state: *StreamingResultState) StreamFinish {
    return switch (currentStreamingResolution(state.*)) {
        .final => blk: {
            const text = state.final_text orelse break :blk .none;
            state.final_text = null;
            break :blk .{ .text = text };
        },
        .err => blk: {
            const message = state.error_message orelse break :blk .none;
            state.error_message = null;
            break :blk .{ .err = message };
        },
        .pending, .session_finished => .none,
    };
}

fn updateStreamingResultState(allocator: std.mem.Allocator, state: *StreamingResultState, event: Event) StreamingResolution {
    switch (event.kind) {
        .interim, .vad => return currentStreamingResolution(state.*),
        .session_finished => {
            state.session_finished = true;
            return currentStreamingResolution(state.*);
        },
        .final => {
            state.final_seen = true;
            if (state.final_text) |text| allocator.free(text);
            state.final_text = event.text;
            return currentStreamingResolution(state.*);
        },
        .err => {
            if (state.error_message) |message| allocator.free(message);
            state.error_message = event.message;
            return .err;
        },
    }
}

pub const StreamingSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    options: StreamOptions,
    client: websocket.Client,
    request_id: []const u8,
    frame_bytes: usize,
    sent_frame_count: usize = 0,
    pending_audio: std.ArrayList(u8),
    state_mutex: std.Io.Mutex = .init,
    state_cond: std.Io.Condition = .init,
    state: StreamingResultState = initStreamingResultState(),
    write_mutex: std.Io.Mutex = .init,
    read_thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finish_sent: bool = false,
    last_frame_sent_at_ms: ?i64 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        cfg: config.Config,
        options: StreamOptions,
    ) !StreamingSession {
        const frame_bytes_u32 = config.frameBytes(cfg);
        if (frame_bytes_u32 == 0) return error.InvalidFrameBytes;
        const frame_bytes: usize = @intCast(frame_bytes_u32);

        var client = try connect(allocator, io, cfg);
        errdefer client.deinit();

        const request_id = try requestId(allocator, io);
        errdefer allocator.free(request_id);

        try initializeSession(allocator, &client, cfg, request_id, options.debug);

        var pending_audio = try std.ArrayList(u8).initCapacity(allocator, @max(frame_bytes * 3, @as(usize, 8192)));
        errdefer pending_audio.deinit(allocator);

        return .{
            .allocator = allocator,
            .io = io,
            .cfg = cfg,
            .options = options,
            .client = client,
            .request_id = request_id,
            .frame_bytes = frame_bytes,
            .pending_audio = pending_audio,
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
        session.state.deinit(session.allocator);
        session.pending_audio.deinit(session.allocator);
        session.allocator.free(session.request_id);
        session.client.deinit();
    }

    pub fn sendChunk(session: *StreamingSession, chunk: []const u8) !void {
        if (session.finish_sent) return error.SessionAlreadyFinished;
        if (session.shouldAbortAudio()) return error.SessionStreamClosed;
        try session.pending_audio.appendSlice(session.allocator, chunk);
        try session.flushReadyFrames();
    }

    /// Max time to wait for server final/session_finished after FinishSession.
    pub const finish_timeout_ms: i64 = 5_000;

    pub fn finish(session: *StreamingSession) !StreamFinish {
        if (session.shouldAbortAudio()) {
            session.finish_sent = true;
            return session.takeResolvedResult();
        }
        if (!session.finish_sent) {
            try session.flushTrailingFrame();
            try session.sendFinishRequest();
            session.finish_sent = true;
        }

        return try session.waitForFinish(finish_timeout_ms);
    }

    pub fn finishAfterStreamFailure(session: *StreamingSession) StreamFinish {
        if (!session.finish_sent) {
            session.sendFinishRequestQuiet();
            session.finish_sent = true;
        }
        session.stopReadLoop();
        session.joinReadThread();
        return session.takeResolvedResult();
    }

    pub fn hasFinalEvent(session: *StreamingSession) bool {
        session.state_mutex.lockUncancelable(session.io);
        defer session.state_mutex.unlock(session.io);
        return session.state.final_seen;
    }

    pub fn serverMessage(session: *StreamingSession, data: []u8, tpe: websocket.MessageTextType) !void {
        if (tpe != .binary) return;
        var response = try proto.parseResponse(session.allocator, data);
        defer response.deinit(session.allocator);
        session.handleResponse(&response);
    }

    pub fn serverClose(session: *StreamingSession, data: []u8) !void {
        const close_info = parseServerClose(data);
        session.recordServerClose(close_info);
        if (!session.options.debug) return;
        if (close_info.reason.len == 0) {
            std.log.warn("doubao server close: code={d}", .{close_info.code});
            return;
        }
        std.log.warn("doubao server close: code={d} reason={s}", .{ close_info.code, close_info.reason });
    }

    pub fn readLoopError(session: *StreamingSession, err: anyerror) void {
        if (session.shouldIgnoreReadLoopError(err)) return;
        if (session.options.debug) {
            std.log.warn("doubao read loop failed: {s}", .{@errorName(err)});
        }
        session.recordReadLoopError(err);
    }

    pub fn close(session: *StreamingSession) void {
        session.state_mutex.lockUncancelable(session.io);
        defer session.state_mutex.unlock(session.io);
        session.state.reader_closed = true;
        session.state_cond.broadcast(session.io);
    }

    /// Write binary data to the WebSocket. The vendored library's writeBin
    /// takes []u8 but does not mutate the payload — it only reads from it.
    fn writeBinSafe(session: *StreamingSession, data: []const u8) !void {
        session.write_mutex.lockUncancelable(session.io);
        defer session.write_mutex.unlock(session.io);
        try session.client.writeBin(@constCast(data));
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

    fn shouldIgnoreReadLoopError(session: *StreamingSession, err: anyerror) bool {
        if (session.stop_requested.load(.acquire)) return true;
        if (err != error.ReadFailed) return false;
        session.state_mutex.lockUncancelable(session.io);
        defer session.state_mutex.unlock(session.io);
        return session.state.final_seen;
    }

    fn shouldAbortAudio(session: *StreamingSession) bool {
        session.state_mutex.lockUncancelable(session.io);
        defer session.state_mutex.unlock(session.io);
        return session.state.error_message != null or
            session.state.reader_closed or
            session.state.session_finished;
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

    fn handleResponse(session: *StreamingSession, response: *proto.Response) void {
        switch (response.kind) {
            .interim => {
                if (response.text.len == 0) return;
                if (session.options.on_interim) |on_interim| {
                    on_interim(session.options.interim_ctx, response.text);
                    return;
                }
                if (session.options.debug) std.log.info("interim: {s}", .{response.text});
            },
            .final => {
                const text = response.text;
                response.text = "";
                if (session.options.on_final) |on_final| {
                    session.noteFinalSeen();
                    on_final(session.options.final_ctx, text);
                    session.allocator.free(text);
                    return;
                }
                session.recordEvent(.{ .kind = .final, .text = text });
            },
            .session_finished => session.recordEvent(.{ .kind = .session_finished }),
            .err => {
                const message = response.error_message;
                response.error_message = "";
                session.recordEvent(.{ .kind = .err, .message = message });
            },
            .vad, .unknown, .task_started, .session_started => {},
        }
    }

    fn recordEvent(session: *StreamingSession, event: Event) void {
        session.state_mutex.lockUncancelable(session.io);
        defer {
            session.state_cond.broadcast(session.io);
            session.state_mutex.unlock(session.io);
        }
        _ = updateStreamingResultState(session.allocator, &session.state, event);
    }

    fn recordServerClose(session: *StreamingSession, close_info: ServerClose) void {
        session.state_mutex.lockUncancelable(session.io);
        defer {
            session.state_cond.broadcast(session.io);
            session.state_mutex.unlock(session.io);
        }
        if (session.state.final_text != null) return;
        if (session.state.error_message != null) return;
        const message = std.fmt.allocPrint(session.allocator, "server closed: code={d}", .{close_info.code}) catch return;
        session.state.error_message = message;
    }

    fn recordReadLoopError(session: *StreamingSession, err: anyerror) void {
        session.state_mutex.lockUncancelable(session.io);
        defer {
            session.state_cond.broadcast(session.io);
            session.state_mutex.unlock(session.io);
        }
        if (session.state.final_seen or session.state.final_text != null) return;
        const message = session.allocator.dupe(u8, @errorName(err)) catch return;
        if (session.state.error_message) |existing| session.allocator.free(existing);
        session.state.error_message = message;
    }

    fn noteFinalSeen(session: *StreamingSession) void {
        session.state_mutex.lockUncancelable(session.io);
        defer {
            session.state_cond.broadcast(session.io);
            session.state_mutex.unlock(session.io);
        }
        session.state.final_seen = true;
    }

    fn waitForFinish(session: *StreamingSession, timeout_ms: i64) !StreamFinish {
        // Race condition wait vs timeout via Io.Select — first arm wins.
        // Both arms return void so cancel cannot leak StreamFinish allocations.
        const SelectResult = union(enum) {
            done: void,
            timeout: void,
        };
        var slots: [2]SelectResult = undefined;
        var select = std.Io.Select(SelectResult).init(session.io, &slots);

        select.concurrent(.done, waitFinishUntilResolved, .{session}) catch {
            select.async(.done, waitFinishUntilResolved, .{session});
        };
        select.concurrent(.timeout, finishTimeoutSleep, .{ session.io, timeout_ms }) catch {
            select.async(.timeout, finishTimeoutSleep, .{ session.io, timeout_ms });
        };

        _ = select.await() catch {};
        select.cancelDiscard();
        return session.takeResolvedResult();
    }

    /// Block until the streaming session is terminal (cancelable).
    ///
    /// Mid-hold VAD finals set `final_seen` / `final_text` while more speech
    /// may still be recognized. Do not treat those as session completion —
    /// wait for SessionFinished, reader close, or error. Timeout is handled
    /// by the Select arm racing this wait.
    fn waitFinishUntilResolved(session: *StreamingSession) void {
        session.state_mutex.lockUncancelable(session.io);
        defer session.state_mutex.unlock(session.io);

        while (true) {
            if (session.state.error_message != null) return;
            if (session.state.session_finished or session.state.reader_closed) return;
            session.state_cond.wait(session.io, &session.state_mutex) catch return;
        }
    }

    fn finishTimeoutSleep(io: std.Io, timeout_ms: i64) void {
        std.Io.sleep(io, .fromMilliseconds(timeout_ms), .awake) catch {};
    }

    fn takeResolvedResult(session: *StreamingSession) StreamFinish {
        session.state_mutex.lockUncancelable(session.io);
        defer session.state_mutex.unlock(session.io);
        return takeResolvedResultLocked(&session.state);
    }

    fn flushReadyFrames(session: *StreamingSession) !void {
        while (session.pending_audio.items.len >= session.frame_bytes) {
            try session.writeFrame(session.pending_audio.items[0..session.frame_bytes]);
            session.discardPendingPrefix(session.frame_bytes);
        }
    }

    fn flushTrailingFrame(session: *StreamingSession) !void {
        if (session.pending_audio.items.len == 0) return;
        const frame = try paddedFrame(session.allocator, session.pending_audio.items, session.frame_bytes);
        defer session.allocator.free(frame);
        if (session.shouldAbortAudio()) return error.SessionStreamClosed;
        const timestamp_ms = std.Io.Timestamp.now(session.io, .real).toMilliseconds();
        session.write_mutex.lockUncancelable(session.io);
        defer session.write_mutex.unlock(session.io);
        try sendAudioFrame(session.allocator, &session.client, session.request_id, &session.sent_frame_count, frame, timestamp_ms);
        session.pending_audio.items.len = 0;
    }

    fn writeFrame(session: *StreamingSession, frame: []const u8) !void {
        if (session.shouldAbortAudio()) return error.SessionStreamClosed;
        const timestamp_ms = session.nextFrameTimestampMs();
        session.write_mutex.lockUncancelable(session.io);
        defer session.write_mutex.unlock(session.io);
        try sendAudioFrame(session.allocator, &session.client, session.request_id, &session.sent_frame_count, frame, timestamp_ms);
    }

    fn discardPendingPrefix(session: *StreamingSession, prefix_len: usize) void {
        const remaining = session.pending_audio.items.len - prefix_len;
        std.mem.copyForwards(u8, session.pending_audio.items[0..remaining], session.pending_audio.items[prefix_len..]);
        session.pending_audio.items.len = remaining;
    }

    fn sendFinishRequest(session: *StreamingSession) !void {
        if (session.shouldAbortAudio()) return error.SessionStreamClosed;
        const finish_request = try proto.buildFinishSession(session.allocator, session.request_id, session.cfg.token);
        defer session.allocator.free(finish_request);
        try session.writeBinSafe(finish_request);
    }

    fn sendFinishRequestQuiet(session: *StreamingSession) void {
        const finish_request = proto.buildFinishSession(session.allocator, session.request_id, session.cfg.token) catch return;
        defer session.allocator.free(finish_request);
        session.writeBinSafe(finish_request) catch {};
    }

    /// Stamp frames with wall-clock time without real-time pacing sleep.
    /// Live capture already produces ~frame_duration audio; sleeping here
    /// blocked the mic thread and delayed finish when buffered frames flushed.
    fn nextFrameTimestampMs(session: *StreamingSession) i64 {
        const timestamp_ms = std.Io.Timestamp.now(session.io, .real).toMilliseconds();
        session.last_frame_sent_at_ms = timestamp_ms;
        return timestamp_ms;
    }
};

const ServerClose = struct {
    code: u16 = 1005,
    reason: []const u8 = "",
};

fn parseServerClose(data: []const u8) ServerClose {
    if (data.len < 2) return .{};
    const code = (@as(u16, data[0]) << 8) | data[1];
    return .{
        .code = code,
        .reason = data[2..],
    };
}

pub fn transcribePcmFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
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

pub fn transcribePcmBytes(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    audio: []const u8,
    options: OnceOptions,
) !?[]u8 {
    var client = try connect(allocator, io, cfg);
    defer client.deinit();

    const request_id = try requestId(allocator, io);
    defer allocator.free(request_id);

    try initializeSession(allocator, &client, cfg, request_id, options.debug);
    try sendAudio(allocator, io, &client, cfg, request_id, audio);

    while (true) {
        const event = try readEvent(allocator, &client);
        defer event.deinit(allocator);
        switch (event.kind) {
            .final => return try allocator.dupe(u8, event.text),
            .session_finished => return null,
            .err => return switch (classifyRemoteError(event.message)) {
                .quota => error.RemoteAsrQuotaExceeded,
                .other => error.RemoteAsrError,
            },
            .interim, .vad => {
                if (event.text.len == 0) continue;
                if (options.on_interim) |on_interim| {
                    on_interim(options.interim_ctx, event.text);
                    continue;
                }
                if (options.debug) {
                    std.log.info("interim: {s}", .{event.text});
                }
            },
        }
    }
}

fn connect(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !websocket.Client {
    const parsed = try parseWsUrl(allocator, try config.wsUrl(allocator, cfg));
    defer parsed.deinit(allocator);
    const headers = try config.headers(allocator, cfg);
    defer allocator.free(headers);

    var client = try websocket.Client.init(io, allocator, .{
        .port = parsed.port,
        .host = parsed.host,
        .tls = parsed.tls,
        .max_size = 1024 * 1024,
        .buffer_size = 16 * 1024,
    });
    errdefer client.deinit();
    try client.handshake(parsed.path, .{
        .timeout_ms = 10_000,
        .headers = headers,
    });
    return client;
}

fn initializeSession(allocator: std.mem.Allocator, client: *websocket.Client, cfg: config.Config, request_id: []const u8, debug: bool) !void {
    const start_task = try proto.buildStartTask(allocator, request_id, cfg.token);
    defer allocator.free(start_task);
    try client.writeBin(@constCast(start_task));
    try expectResponse(allocator, client, .task_started, debug);

    const start_session = try proto.buildStartSession(allocator, request_id, cfg.token, .{
        .sample_rate = cfg.sample_rate,
        .channels = cfg.channels,
        .device_id = cfg.device_id,
        .app_name = "com.android.chrome",
        .enable_punctuation = true,
    });
    defer allocator.free(start_session);
    try client.writeBin(@constCast(start_session));
    try expectResponse(allocator, client, .session_started, debug);
}

fn sendAudio(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *websocket.Client,
    cfg: config.Config,
    request_id: []const u8,
    audio: []const u8,
) !void {
    const frame_bytes_u32 = config.frameBytes(cfg);
    if (frame_bytes_u32 == 0) return error.InvalidFrameBytes;
    const frame_bytes: usize = @intCast(frame_bytes_u32);
    var offset: usize = 0;
    var frame_count: usize = 0;
    while (offset < audio.len) {
        const remaining = audio.len - offset;
        const take = @min(remaining, frame_bytes);
        const source = audio[offset .. offset + take];
        var frame = source;
        var owned_frame: ?[]u8 = null;
        if (take != frame_bytes) {
            const padded = try paddedFrame(allocator, source, frame_bytes);
            frame = padded;
            owned_frame = padded;
        }
        defer if (owned_frame) |buf| allocator.free(buf);
        const timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        try sendAudioFrame(allocator, client, request_id, &frame_count, frame, timestamp_ms);
        offset += take;
    }

    const finish = try proto.buildFinishSession(allocator, request_id, cfg.token);
    defer allocator.free(finish);
    try client.writeBin(@constCast(finish));
}

fn sendAudioFrame(
    allocator: std.mem.Allocator,
    client: *websocket.Client,
    request_id: []const u8,
    frame_count: *usize,
    frame: []const u8,
    timestamp_ms: i64,
) !void {
    const state: proto.FrameState = if (frame_count.* == 0) .first else .middle;
    const request = try proto.buildAudioRequest(allocator, request_id, frame, state, timestamp_ms);
    defer allocator.free(request);
    try client.writeBin(@constCast(request));
    frame_count.* += 1;
}

fn nextFrameDelayMs(last_frame_sent_at_ms: ?i64, now_ms: i64, frame_duration_ms: u16) i64 {
    const interval_ms: i64 = if (frame_duration_ms == 0) 100 else frame_duration_ms;
    const last_frame_sent = last_frame_sent_at_ms orelse return 0;
    const next_allowed_ms = last_frame_sent + interval_ms;
    if (next_allowed_ms <= now_ms) return 0;
    return next_allowed_ms - now_ms;
}

fn paddedFrame(allocator: std.mem.Allocator, bytes: []const u8, len: usize) ![]u8 {
    const out = try allocator.alloc(u8, len);
    @memset(out, 0);
    @memcpy(out[0..bytes.len], bytes);
    return out;
}

fn expectResponse(allocator: std.mem.Allocator, client: *websocket.Client, expected: proto.ResponseType, debug: bool) !void {
    const event = try readProtoResponse(allocator, client);
    defer event.deinit(allocator);
    if (event.kind == .err) {
        if (debug) std.log.err("remote asr error: {s}", .{event.error_message});
        return switch (classifyRemoteError(event.error_message)) {
            .quota => error.RemoteAsrQuotaExceeded,
            .other => error.RemoteAsrError,
        };
    }
    if (event.kind != expected) {
        if (debug) std.log.err("unexpected response: expected={s} actual={s}", .{ @tagName(expected), @tagName(event.kind) });
        return error.UnexpectedResponse;
    }
}

fn readEvent(allocator: std.mem.Allocator, client: *websocket.Client) !Event {
    const resp = try readProtoResponse(allocator, client);
    defer resp.deinit(allocator);
    return switch (resp.kind) {
        .interim => .{ .kind = .interim, .text = try allocator.dupe(u8, resp.text) },
        .final => .{ .kind = .final, .text = try allocator.dupe(u8, resp.text) },
        .vad => .{ .kind = .vad },
        .session_finished => .{ .kind = .session_finished },
        .err => .{ .kind = .err, .message = try allocator.dupe(u8, resp.error_message) },
        else => .{ .kind = .interim },
    };
}

fn readProtoResponse(allocator: std.mem.Allocator, client: *websocket.Client) !proto.Response {
    while (true) {
        const message = try client.read() orelse continue;
        defer client.done(message);
        if (message.type != .binary) continue;
        return proto.parseResponse(allocator, message.data);
    }
}

const ParsedWsUrl = struct {
    host: []const u8,
    path: []const u8,
    port: u16,
    tls: bool,

    fn deinit(self: ParsedWsUrl, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

fn parseWsUrl(allocator: std.mem.Allocator, url: []const u8) !ParsedWsUrl {
    defer allocator.free(url);
    const uri = try std.Uri.parse(url);
    const tls = if (std.mem.eql(u8, uri.scheme, "wss"))
        true
    else if (std.mem.eql(u8, uri.scheme, "ws"))
        false
    else
        return error.UnsupportedWebsocketScheme;

    const host_component = uri.host orelse return error.MissingHost;
    const host_raw = try host_component.toRawMaybeAlloc(allocator);
    // toRawMaybeAlloc may return a pointer into `url` (no allocation)
    // or a newly heap-allocated string (percent-decoded). Only free if allocated.
    const ptr = @intFromPtr(host_raw.ptr);
    const url_start = @intFromPtr(url.ptr);
    const is_into_url = ptr >= url_start and ptr < url_start + url.len;
    defer if (!is_into_url) allocator.free(host_raw);
    const host = try allocator.dupe(u8, host_raw);
    const port = uri.port orelse if (tls) @as(u16, 443) else @as(u16, 80);
    const path = try formatPath(allocator, uri);
    return .{ .host = host, .path = path, .port = port, .tls = tls };
}

fn formatPath(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    const path = uri.path.percent_encoded;
    if (uri.query) |query| {
        return std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, query.percent_encoded });
    }
    return allocator.dupe(u8, path);
}

fn requestId(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
}

test "parses websocket url" {
    const allocator = std.testing.allocator;
    const parsed = try parseWsUrl(allocator, try allocator.dupe(u8, "wss://example.com/ws?x=1"));
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.tls);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqualStrings("/ws?x=1", parsed.path);
}

test "classifies only explicit concurrency quota errors as quota" {
    try std.testing.expectEqual(RemoteErrorKind.quota, classifyRemoteError("concurrency quota exceeded: value=5"));
    try std.testing.expectEqual(RemoteErrorKind.other, classifyRemoteError("authentication failed"));
    try std.testing.expectEqual(RemoteErrorKind.other, classifyRemoteError("TlsConnectionTruncated"));
}

test "pads final pcm frame" {
    const allocator = std.testing.allocator;
    const frame = try paddedFrame(allocator, "abc", 6);
    defer allocator.free(frame);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c', 0, 0, 0 }, frame);
}

test "server close without final records an error" {
    const allocator = std.testing.allocator;
    var session: StreamingSession = undefined;
    session.allocator = allocator;
    session.io = std.testing.io;
    session.options = .{};
    session.state_mutex = .init;
    session.state_cond = .init;
    session.state = initStreamingResultState();
    defer session.state.deinit(allocator);

    var close_bytes = [_]u8{ 0x03, 0xF3, 'b', 'y', 'e' };
    try session.serverClose(close_bytes[0..]);
    const finish = takeResolvedResultLocked(&session.state);
    switch (finish) {
        .err => |message| {
            defer allocator.free(message);
            try std.testing.expect(std.mem.indexOf(u8, message, "1011") != null);
        },
        else => return error.TestExpectedError,
    }
}

test "streaming result state keeps final text after reader closed" {
    const allocator = std.testing.allocator;
    var state = initStreamingResultState();
    defer state.deinit(allocator);

    const final_text = try allocator.dupe(u8, "实时识别。");
    const final_event = Event{ .kind = .final, .text = final_text };
    try std.testing.expectEqual(
        StreamingResolution.final,
        updateStreamingResultState(allocator, &state, final_event),
    );
    state.reader_closed = true;
    try std.testing.expectEqual(StreamingResolution.final, currentStreamingResolution(state));
    try std.testing.expectEqualStrings("实时识别。", state.final_text.?);
    try std.testing.expect(state.final_seen);
}

test "final text does not mask later error" {
    const allocator = std.testing.allocator;
    var state = initStreamingResultState();
    defer state.deinit(allocator);

    const text = try allocator.dupe(u8, "语音识别测试。");
    _ = updateStreamingResultState(allocator, &state, .{ .kind = .final, .text = text });
    const message = try allocator.dupe(u8, "SessionFailed");
    try std.testing.expectEqual(
        StreamingResolution.err,
        updateStreamingResultState(allocator, &state, .{ .kind = .err, .message = message }),
    );
    const finish = takeResolvedResultLocked(&state);
    switch (finish) {
        .err => |actual| {
            defer allocator.free(actual);
            try std.testing.expectEqualStrings("SessionFailed", actual);
        },
        else => return error.TestExpectedError,
    }
}

test "next frame delay uses configured frame interval" {
    try std.testing.expectEqual(@as(i64, 0), nextFrameDelayMs(null, 1_000, 100));
    try std.testing.expectEqual(@as(i64, 40), nextFrameDelayMs(1_000, 1_060, 100));
    try std.testing.expectEqual(@as(i64, 0), nextFrameDelayMs(1_000, 1_100, 100));
}

test "wait for finish does not resolve on mid-hold final_seen alone" {
    // Multi-utterance: first VAD final sets final_seen via on_final callback.
    // finish() must keep waiting for SessionFinished so later finals can arrive.
    var session: StreamingSession = undefined;
    session.allocator = std.testing.allocator;
    session.io = std.testing.io;
    session.state_mutex = .init;
    session.state_cond = .init;
    session.state = initStreamingResultState();
    defer session.state.deinit(std.testing.allocator);
    session.state.final_seen = true;

    const started = std.Io.Timestamp.now(session.io, .real).toMilliseconds();
    const finish = try session.waitForFinish(80);
    const elapsed = std.Io.Timestamp.now(session.io, .real).toMilliseconds() - started;
    try std.testing.expect(finish == .none);
    try std.testing.expect(elapsed >= 60);
    try std.testing.expect(elapsed < 500);
}

test "wait for finish resolves when session finished after earlier final callback" {
    var session: StreamingSession = undefined;
    session.allocator = std.testing.allocator;
    session.io = std.testing.io;
    session.state_mutex = .init;
    session.state_cond = .init;
    session.state = initStreamingResultState();
    defer session.state.deinit(std.testing.allocator);
    session.state.final_seen = true;
    session.state.session_finished = true;

    const started = std.Io.Timestamp.now(session.io, .real).toMilliseconds();
    const finish = try session.waitForFinish(1_000);
    const elapsed = std.Io.Timestamp.now(session.io, .real).toMilliseconds() - started;
    try std.testing.expect(finish == .none);
    try std.testing.expect(elapsed < 200);
}

test "wait for finish does not resolve on final_text alone before session end" {
    const allocator = std.testing.allocator;
    var session: StreamingSession = undefined;
    session.allocator = allocator;
    session.io = std.testing.io;
    session.state_mutex = .init;
    session.state_cond = .init;
    session.state = initStreamingResultState();
    defer session.state.deinit(allocator);
    session.state.final_text = try allocator.dupe(u8, "第一段。");
    session.state.final_seen = true;

    const started = std.Io.Timestamp.now(session.io, .real).toMilliseconds();
    const finish = try session.waitForFinish(80);
    const elapsed = std.Io.Timestamp.now(session.io, .real).toMilliseconds() - started;
    // Still holding final_text for take after session end / timeout.
    switch (finish) {
        .text => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("第一段。", text);
        },
        else => return error.TestExpectedText,
    }
    try std.testing.expect(elapsed >= 60);
}

test "wait for finish times out when server never resolves" {
    var session: StreamingSession = undefined;
    session.allocator = std.testing.allocator;
    session.io = std.testing.io;
    session.state_mutex = .init;
    session.state_cond = .init;
    session.state = initStreamingResultState();
    defer session.state.deinit(std.testing.allocator);

    const started = std.Io.Timestamp.now(session.io, .real).toMilliseconds();
    const finish = try session.waitForFinish(80);
    const elapsed = std.Io.Timestamp.now(session.io, .real).toMilliseconds() - started;
    try std.testing.expect(finish == .none);
    try std.testing.expect(elapsed >= 60);
    try std.testing.expect(elapsed < 500);
}

test "parses server close code and reason" {
    const close_info = parseServerClose(&.{ 0x03, 0xF3, 'b', 'y', 'e' });
    try std.testing.expectEqual(@as(u16, 1011), close_info.code);
    try std.testing.expectEqualStrings("bye", close_info.reason);
}

test "suppresses read loop warning after local stop request" {
    var session: StreamingSession = undefined;
    session.stop_requested = std.atomic.Value(bool).init(false);
    session.io = std.testing.io;
    session.state_mutex = .init;
    session.state = initStreamingResultState();
    defer session.state.deinit(std.testing.allocator);
    try std.testing.expect(!session.shouldIgnoreReadLoopError(error.ReadFailed));
    session.stop_requested.store(true, .release);
    try std.testing.expect(session.shouldIgnoreReadLoopError(error.ReadFailed));
}

test "suppresses read failed warning after final seen" {
    var session: StreamingSession = undefined;
    session.stop_requested = std.atomic.Value(bool).init(false);
    session.io = std.testing.io;
    session.state_mutex = .init;
    session.state = initStreamingResultState();
    defer session.state.deinit(std.testing.allocator);
    session.state.final_seen = true;

    try std.testing.expect(session.shouldIgnoreReadLoopError(error.ReadFailed));
    try std.testing.expect(!session.shouldIgnoreReadLoopError(error.UnexpectedResponse));
}

test "read loop error is ignored after final seen" {
    var session: StreamingSession = undefined;
    session.allocator = std.testing.allocator;
    session.io = std.testing.io;
    session.state_mutex = .init;
    session.state_cond = .init;
    session.state = initStreamingResultState();
    defer session.state.deinit(std.testing.allocator);
    session.state.final_seen = true;

    session.recordReadLoopError(error.ReadFailed);
    try std.testing.expect(session.state.error_message == null);
}

test "stream failure stops audio sending" {
    const allocator = std.testing.allocator;
    var session: StreamingSession = undefined;
    session.allocator = allocator;
    session.io = std.testing.io;
    session.state_mutex = .init;
    session.state_cond = .init;
    session.state = initStreamingResultState();
    defer session.state.deinit(allocator);

    try std.testing.expect(!session.shouldAbortAudio());

    const message = try allocator.dupe(u8, "ReadFailed");
    session.state.error_message = message;
    try std.testing.expect(session.shouldAbortAudio());
}

test "finish after stream failure returns recorded error without writing" {
    const allocator = std.testing.allocator;
    var session: StreamingSession = undefined;
    session.allocator = allocator;
    session.io = std.testing.io;
    session.state_mutex = .init;
    session.state_cond = .init;
    session.state = initStreamingResultState();
    session.finish_sent = false;
    defer session.state.deinit(allocator);

    const message = try allocator.dupe(u8, "ReadFailed");
    session.state.error_message = message;

    const finish = try session.finish();
    try std.testing.expect(session.finish_sent);
    switch (finish) {
        .err => |actual| {
            defer allocator.free(actual);
            try std.testing.expectEqualStrings("ReadFailed", actual);
        },
        else => return error.TestExpectedError,
    }
}
