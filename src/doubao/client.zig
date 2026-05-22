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

pub fn transcribePcmFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    options: OnceOptions,
) !?[]u8 {
    const audio = try std.Io.Dir.cwd().readFileAlloc(io, options.pcm_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(audio);

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
            .err => return error.RemoteAsrError,
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
        .app_name = "asr-zig",
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

        const state: proto.FrameState = if (frame_count == 0) .first else .middle;
        const timestamp_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        const request = try proto.buildAudioRequest(allocator, request_id, frame, state, timestamp_ms);
        defer allocator.free(request);
        try client.writeBin(@constCast(request));

        offset += take;
        frame_count += 1;
    }

    const finish = try proto.buildFinishSession(allocator, request_id, cfg.token);
    defer allocator.free(finish);
    try client.writeBin(@constCast(finish));
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
        return error.RemoteAsrError;
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
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15],
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

test "pads final pcm frame" {
    const allocator = std.testing.allocator;
    const frame = try paddedFrame(allocator, "abc", 6);
    defer allocator.free(frame);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 'c', 0, 0, 0 }, frame);
}
