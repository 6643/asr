const std = @import("std");
const websocket = @import("websocket");
const config = @import("../config.zig");
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

pub const StreamFinish = union(enum) {
    none,
    text: []const u8,
    err: []const u8,
};

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

const StreamingResolution = enum {
    pending,
    final,
    session_finished,
    err,
};

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
        .interim => return currentStreamingResolution(state.*),
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
    audio_cfg: proto.AudioConfig,
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
    heartbeat_interval_ms: i64 = 10_000,
    last_heartbeat_at_ms: ?i64 = null,

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

        const sn = try requestId(allocator, io);
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
            .audio_cfg = .{
                .user = cfg.user,
                .dev_key = cfg.dev_key,
                .dev_pid = cfg.dev_pid,
                .sample_rate = cfg.sample_rate,
                .format = "pcm",
                .channels = cfg.channels,
                .vad_type = cfg.vad_type,
                .vad_mode = cfg.vad_mode,
                .need_punctuation = cfg.enable_punctuation,
            },
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
        // Baidu sends control messages as text (JSON) and audio data as binary
        if (tpe == .binary) {
            // Binary frames from server are unexpected in this protocol
            if (session.options.debug) {
                std.log.debug("baidu: unexpected binary frame ({d} bytes)", .{data.len});
            }
            return;
        }

        var response = try proto.parseServerMessage(session.allocator, data);
        defer response.deinit(session.allocator);
        session.handleResponse(&response);
    }

    pub fn serverClose(session: *StreamingSession, data: []u8) !void {
        _ = data;
        session.recordServerClose();
    }

    pub fn readLoopError(session: *StreamingSession, err: anyerror) void {
        if (session.shouldIgnoreReadLoopError(err)) return;
        if (session.options.debug) {
            std.log.warn("baidu read loop failed: {s}", .{@errorName(err)});
        }
        session.recordReadLoopError(err);
    }

    pub fn close(session: *StreamingSession) void {
        session.state_mutex.lockUncancelable(session.io);
        defer session.state_mutex.unlock(session.io);
        session.state.reader_closed = true;
        session.state_cond.broadcast(session.io);
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

    fn handleResponse(session: *StreamingSession, response: *proto.ServerMessage) void {
        switch (response.kind) {
            .mid_text => {
                if (response.text.len == 0) return;
                if (session.options.on_interim) |on_interim| {
                    on_interim(session.options.interim_ctx, response.text);
                    return;
                }
                if (session.options.debug) std.log.info("baidu interim: {s}", .{response.text});
            },
            .fin_text => {
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
            .session_finish => session.recordEvent(.{ .kind = .session_finished }),
            .err => {
                const message = response.error_message;
                response.error_message = "";
                session.recordEvent(.{ .kind = .err, .message = message });
            },
            .heartbeat, .unknown => {},
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

    fn recordServerClose(session: *StreamingSession) void {
        session.state_mutex.lockUncancelable(session.io);
        defer {
            session.state_cond.broadcast(session.io);
            session.state_mutex.unlock(session.io);
        }
        if (session.state.final_text != null) return;
        if (session.state.error_message != null) return;
        session.state.error_message = session.allocator.dupe(u8, "server closed") catch return;
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
        try session.writeBinSafe(frame);
        session.pending_audio.items.len = 0;
    }

    fn writeFrame(session: *StreamingSession, frame: []const u8) !void {
        if (session.shouldAbortAudio()) return error.SessionStreamClosed;
        try session.writeBinSafe(frame);
    }

    fn discardPendingPrefix(session: *StreamingSession, prefix_len: usize) void {
        const remaining = session.pending_audio.items.len - prefix_len;
        std.mem.copyForwards(u8, session.pending_audio.items[0..remaining], session.pending_audio.items[prefix_len..]);
        session.pending_audio.items.len = remaining;
    }

    fn sendFinishRequest(session: *StreamingSession) !void {
        if (session.shouldAbortAudio()) return error.SessionStreamClosed;
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

    const sn = try requestId(allocator, io);
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
                    std.log.info("baidu interim: {s}", .{response.text});
                }
            },
            .heartbeat, .unknown => continue,
        }
    }
}

// ── Internal connection helpers ──

const default_baidu_ws_url = "wss://vse.baidu.com/ws_api";

fn connect(allocator: std.mem.Allocator, io: std.Io, cfg: config.BaiduConfig) !websocket.Client {
    const url = if (cfg.url.len > 0) cfg.url else default_baidu_ws_url;

    const sn = try requestId(allocator, io);
    defer allocator.free(sn);

    const ws_url = try std.fmt.allocPrint(allocator, "{s}?sn={s}", .{ url, sn });
    defer allocator.free(ws_url);

    const parsed = try parseWsUrl(allocator, ws_url);
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
        .timeout_ms = 10_000,
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
        std.log.info("baidu: START sent (sn={s})", .{sn});
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

fn paddedFrame(allocator: std.mem.Allocator, bytes: []const u8, len: usize) ![]u8 {
    const out = try allocator.alloc(u8, len);
    @memset(out, 0);
    @memcpy(out[0..bytes.len], bytes);
    return out;
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
    const uri = try std.Uri.parse(url);
    const tls = if (std.mem.eql(u8, uri.scheme, "wss"))
        true
    else if (std.mem.eql(u8, uri.scheme, "ws"))
        false
    else
        return error.UnsupportedWebsocketScheme;

    const host_component = uri.host orelse return error.MissingHost;
    const host_raw = try host_component.toRawMaybeAlloc(allocator);
    const ptr = @intFromPtr(host_raw.ptr);
    const url_ptr = @intFromPtr(url.ptr);
    const is_into_url = ptr >= url_ptr and ptr < url_ptr + url.len;
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

test "parses websocket url" {
    const allocator = std.testing.allocator;
    const url = try std.fmt.allocPrint(allocator, "{s}?sn=abc123", .{default_baidu_ws_url});
    defer allocator.free(url);
    const parsed = try parseWsUrl(allocator, url);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.tls);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("vse.baidu.com", parsed.host);
}

test "pads final pcm frame" {
    const allocator = std.testing.allocator;
    const frame = try paddedFrame(allocator, "abc", 6);
    defer allocator.free(frame);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c', 0, 0, 0 }, frame);
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

    session.recordServerClose();
    const finish = takeResolvedResultLocked(&session.state);
    switch (finish) {
        .err => |message| {
            defer allocator.free(message);
            try std.testing.expectEqualStrings("server closed", message);
        },
        else => return error.TestExpectedError,
    }
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
