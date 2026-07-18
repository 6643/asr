const std = @import("std");

/// Baidu WebSocket ASR API protocol types.
///
/// The Baidu voice recognition API uses JSON text frames for control
/// messages and binary frames for PCM audio data.
///
/// Server → Client message types:
/// - HEARTBEAT:     keep-alive response
/// - MID_TEXT:      interim recognition result (partial)
/// - FIN_TEXT:      final recognition result (utterance end)
/// - SESSION_FINISH: session complete
///
/// Client → Server message types:
/// - START:         initialize session with audio params
/// - HEARTBEAT:     client heartbeat
/// - FINISH:        end the session

pub const ServerMessageType = enum {
    heartbeat,
    mid_text,
    fin_text,
    session_finish,
    err,
    unknown,
};

pub const ServerMessage = struct {
    kind: ServerMessageType,
    text: []const u8 = "",
    error_message: []const u8 = "",
    err_no: i64 = 0,

    pub fn deinit(msg: ServerMessage, allocator: std.mem.Allocator) void {
        if (msg.text.len > 0) allocator.free(msg.text);
        if (msg.error_message.len > 0) allocator.free(msg.error_message);
    }
};

/// Audio format configuration sent in the START message.
pub const AudioConfig = struct {
    user: []const u8 = "baidu_pc",
    dev_key: []const u8 = "com.baidu.searchbox.fangyan",
    dev_pid: u32 = 8068,
    sample_rate: u32 = 16000,
    format: []const u8 = "pcm",
    channels: u32 = 1,
    role_num: u32 = 1,
    vad_type: u32 = 1,
    vad_mode: u32 = 0,
    need_punctuation: bool = true,
    need_session_finish: bool = true,
};

/// Build the START message as a JSON text frame payload.
pub fn buildStartMessage(allocator: std.mem.Allocator, cfg: AudioConfig, timestamp_ms: i64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"START\",\"data\":{{\"user\":\"{s}\",\"dev_key\":\"{s}\",\"dev_pid\":{d},\"cuid\":\"{s}\",\"sample\":{d},\"format\":\"{s}\",\"type\":1,\"role_num\":{d},\"vad_type\":{d},\"vad_mode\":{d},\"channels\":{d},\"need_session_finish\":{},\"punc\":{},\"start_timestamp\":{d}}}}}",
        .{
            cfg.user,
            cfg.dev_key,
            cfg.dev_pid,
            cfg.user, // cuid: use user as fallback
            cfg.sample_rate,
            cfg.format,
            cfg.role_num,
            cfg.vad_type,
            cfg.vad_mode,
            cfg.channels,
            cfg.need_session_finish,
            cfg.need_punctuation,
            timestamp_ms,
        },
    );
}

/// Build the FINISH message.
pub fn buildFinishMessage(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"type\":\"FINISH\"}");
}

/// Build the HEARTBEAT message.
pub fn buildHeartbeatMessage(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"type\":\"HEARTBEAT\"}");
}

/// Parse a server message from a JSON text frame.
pub fn parseServerMessage(allocator: std.mem.Allocator, data: []const u8) !ServerMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return ServerMessage{ .kind = .unknown };

    const obj = root.object;

    // Extract type field
    const type_str = if (obj.get("type")) |v| if (v == .string) v.string else "" else "";

    // Extract err_no (0 = success, non-zero = error)
    const err_no = if (obj.get("err_no")) |v| if (v == .integer) v.integer else @as(i64, 0) else @as(i64, 0);

    // Extract err_msg
    const err_msg = if (obj.get("err_msg")) |v| if (v == .string) v.string else "" else "";

    // Extract result (recognition text)
    const result_text = if (obj.get("result")) |v| if (v == .string) v.string else "" else "";

    // Determine message type
    if (err_no != 0 or std.mem.eql(u8, type_str, "Error") or std.mem.eql(u8, type_str, "ERROR")) {
        return ServerMessage{
            .kind = .err,
            .error_message = try allocator.dupe(u8, err_msg),
            .err_no = err_no,
        };
    }

    if (std.mem.eql(u8, type_str, "HEARTBEAT")) {
        return ServerMessage{ .kind = .heartbeat };
    }

    if (std.mem.eql(u8, type_str, "MID_TEXT")) {
        const text = try allocator.dupe(u8, result_text);
        return ServerMessage{ .kind = .mid_text, .text = text };
    }

    if (std.mem.eql(u8, type_str, "FIN_TEXT")) {
        const text = try allocator.dupe(u8, result_text);
        return ServerMessage{ .kind = .fin_text, .text = text };
    }

    if (std.mem.eql(u8, type_str, "SESSION_FINISH")) {
        return ServerMessage{ .kind = .session_finish };
    }

    return ServerMessage{ .kind = .unknown };
}

test "builds start message with default config" {
    const allocator = std.testing.allocator;
    const msg = try buildStartMessage(allocator, .{}, 1_700_000_000_000);
    defer allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "START") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "baidu_pc") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"sample\":16000") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"format\":\"pcm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"punc\":true") != null);
}

test "parses mid text message" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"MID_TEXT\",\"err_no\":0,\"err_msg\":\"\",\"result\":\"你好\"}";
    const msg = try parseServerMessage(allocator, json);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(ServerMessageType.mid_text, msg.kind);
    try std.testing.expectEqualStrings("你好", msg.text);
}

test "parses fin text message" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"FIN_TEXT\",\"err_no\":0,\"err_msg\":\"\",\"result\":\"语音识别测试。\"}";
    const msg = try parseServerMessage(allocator, json);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(ServerMessageType.fin_text, msg.kind);
    try std.testing.expectEqualStrings("语音识别测试。", msg.text);
}

test "parses heartbeat message" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"HEARTBEAT\"}";
    const msg = try parseServerMessage(allocator, json);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(ServerMessageType.heartbeat, msg.kind);
}

test "parses session finish message" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"SESSION_FINISH\"}";
    const msg = try parseServerMessage(allocator, json);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(ServerMessageType.session_finish, msg.kind);
}

test "parses error message with err_no" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"MID_TEXT\",\"err_no\":-3005,\"err_msg\":\"语音识别错误\",\"result\":\"\"}";
    const msg = try parseServerMessage(allocator, json);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(ServerMessageType.err, msg.kind);
    try std.testing.expectEqualStrings("语音识别错误", msg.error_message);
    try std.testing.expectEqual(@as(i64, -3005), msg.err_no);
}

test "builds finish message" {
    const allocator = std.testing.allocator;
    const msg = try buildFinishMessage(allocator);
    defer allocator.free(msg);

    try std.testing.expectEqualStrings("{\"type\":\"FINISH\"}", msg);
}

test "builds heartbeat message" {
    const allocator = std.testing.allocator;
    const msg = try buildHeartbeatMessage(allocator);
    defer allocator.free(msg);

    try std.testing.expectEqualStrings("{\"type\":\"HEARTBEAT\"}", msg);
}

test "skips unknown message type" {
    const allocator = std.testing.allocator;
    const json = "{\"type\":\"UNKNOWN\",\"err_no\":0,\"err_msg\":\"\",\"result\":\"\"}";
    const msg = try parseServerMessage(allocator, json);
    defer msg.deinit(allocator);

    try std.testing.expectEqual(ServerMessageType.unknown, msg.kind);
}
