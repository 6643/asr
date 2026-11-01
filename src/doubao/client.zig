const std = @import("std");
const websocket = @import("websocket");
const common = @import("../common.zig");
const config = @import("../config.zig");
const streaming_state = @import("../streaming_state.zig");
const ws_url = @import("../ws_url.zig");
const finish_grace = @import("../runtime/finish_grace.zig");
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

pub const StreamFinish = streaming_state.Finish;

const RemoteErrorKind = enum { quota, other };

fn classifyRemoteError(message: []const u8) RemoteErrorKind {
    if (std.mem.indexOf(u8, message, "concurrency quota exceeded") != null) return .quota;
    return .other;
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
    waiter: streaming_state.Waiter,
    write_mutex: std.Io.Mutex = .init,
    read_thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finish_sent: bool = false,

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

        const request_id = try common.randomHexId(allocator, io);
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
        session.allocator.free(session.request_id);
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
        if (tpe != .binary) return;
        var response = try proto.parseResponse(session.allocator, data);
        defer response.deinit(session.allocator);
        session.handleResponse(&response);
    }

    pub fn serverClose(session: *StreamingSession, data: []u8) !void {
        const close_info = parseServerClose(data);
        var buf: [48]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "server closed: code={d}", .{close_info.code}) catch "server closed";
        session.waiter.recordErrorMessage(session.allocator, message);
        if (!session.options.debug) return;
        if (close_info.reason.len == 0) {
            std.log.scoped(.doubao).warn("server close: code={d}", .{close_info.code});
            return;
        }
        std.log.scoped(.doubao).warn("server close: code={d} reason={s}", .{ close_info.code, close_info.reason });
    }

    pub fn readLoopError(session: *StreamingSession, err: anyerror) void {
        if (session.waiter.ignoresReadError(session.stop_requested.load(.acquire), err)) return;
        if (session.options.debug) {
            std.log.scoped(.doubao).warn("read loop failed: {s}", .{@errorName(err)});
        }
        session.waiter.recordErrorMessage(session.allocator, @errorName(err));
    }

    pub fn close(session: *StreamingSession) void {
        session.waiter.markReaderClosed();
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
                if (session.options.debug) std.log.scoped(.doubao).info("interim: {s}", .{response.text});
            },
            .final => {
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
            .session_finished => session.waiter.record(session.allocator, .session_finished),
            .err => {
                const message = response.error_message;
                response.error_message = "";
                session.waiter.record(session.allocator, .{ .err = message });
            },
            .vad, .unknown, .task_started, .session_started => {},
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
        const timestamp_ms = std.Io.Timestamp.now(session.io, .real).toMilliseconds();
        session.write_mutex.lockUncancelable(session.io);
        defer session.write_mutex.unlock(session.io);
        try sendAudioFrame(session.allocator, &session.client, session.request_id, &session.sent_frame_count, frame, timestamp_ms);
        session.pending_audio.items.len = 0;
    }

    fn writeFrame(session: *StreamingSession, frame: []const u8) !void {
        if (session.waiter.abortAudio()) return error.SessionStreamClosed;
        const timestamp_ms = std.Io.Timestamp.now(session.io, .real).toMilliseconds();
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
        if (session.waiter.abortAudio()) return error.SessionStreamClosed;
        const finish_request = try proto.buildFinishSession(session.allocator, session.request_id, session.cfg.token);
        defer session.allocator.free(finish_request);
        try session.writeBinSafe(finish_request);
    }

    fn sendFinishRequestQuiet(session: *StreamingSession) void {
        const finish_request = proto.buildFinishSession(session.allocator, session.request_id, session.cfg.token) catch return;
        defer session.allocator.free(finish_request);
        session.writeBinSafe(finish_request) catch {};
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

    const request_id = try common.randomHexId(allocator, io);
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
                    std.log.scoped(.doubao).info("interim: {s}", .{event.text});
                }
            },
        }
    }
}

fn connect(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config) !websocket.Client {
    const url = try config.wsUrl(allocator, cfg);
    defer allocator.free(url);
    const parsed = try ws_url.parse(allocator, url);
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
        .timeout_ms = common.ws_handshake_timeout_ms,
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
        .asr_params = cfg.asr_params,
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
            const padded = try common.paddedFrame(allocator, source, frame_bytes);
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

fn expectResponse(allocator: std.mem.Allocator, client: *websocket.Client, expected: proto.ResponseType, debug: bool) !void {
    const event = try readProtoResponse(allocator, client);
    defer event.deinit(allocator);
    if (event.kind == .err) {
        if (debug) std.log.scoped(.doubao).err("remote asr error: {s}", .{event.error_message});
        return switch (classifyRemoteError(event.error_message)) {
            .quota => error.RemoteAsrQuotaExceeded,
            .other => error.RemoteAsrError,
        };
    }
    if (event.kind != expected) {
        if (debug) std.log.scoped(.doubao).err("unexpected response: expected={s} actual={s}", .{ @tagName(expected), @tagName(event.kind) });
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

test "classifies only explicit concurrency quota errors as quota" {
    try std.testing.expectEqual(RemoteErrorKind.quota, classifyRemoteError("concurrency quota exceeded: value=5"));
    try std.testing.expectEqual(RemoteErrorKind.other, classifyRemoteError("authentication failed"));
    try std.testing.expectEqual(RemoteErrorKind.other, classifyRemoteError("TlsConnectionTruncated"));
}

test "server close without final records an error" {
    const allocator = std.testing.allocator;
    var waiter: streaming_state.Waiter = .{ .io = std.testing.io };
    defer waiter.deinit(allocator);

    var close_bytes = [_]u8{ 0x03, 0xF3, 'b', 'y', 'e' };
    const close_info = parseServerClose(&close_bytes);
    var buf: [48]u8 = undefined;
    const message = try std.fmt.bufPrint(&buf, "server closed: code={d}", .{close_info.code});
    waiter.recordErrorMessage(allocator, message);

    switch (waiter.take()) {
        .err => |actual| {
            defer allocator.free(actual);
            try std.testing.expect(std.mem.indexOf(u8, actual, "1011") != null);
        },
        else => return error.TestExpectedError,
    }
}

test "parses server close code and reason" {
    const close_info = parseServerClose(&.{ 0x03, 0xF3, 'b', 'y', 'e' });
    try std.testing.expectEqual(@as(u16, 1011), close_info.code);
    try std.testing.expectEqualStrings("bye", close_info.reason);
}

test "read loop errors are suppressed after a final result" {
    const allocator = std.testing.allocator;
    var waiter: streaming_state.Waiter = .{ .io = std.testing.io };
    defer waiter.deinit(allocator);

    try std.testing.expect(!waiter.ignoresReadError(false, error.ReadFailed));
    waiter.markFinalSeen();
    try std.testing.expect(waiter.ignoresReadError(false, error.ReadFailed));
    try std.testing.expect(!waiter.ignoresReadError(false, error.UnexpectedResponse));
    waiter.recordErrorMessage(allocator, "ReadFailed");
    try std.testing.expect(waiter.state.error_message == null);
}
