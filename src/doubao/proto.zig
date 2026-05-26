const std = @import("std");

const req_field_token = 2;
const req_field_service = 3;
const req_field_method = 5;
const req_field_payload = 6;
const req_field_audio_data = 7;
const req_field_request_id = 8;
const req_field_frame_state = 9;

const res_field_message_type = 4;
const res_field_status_msg = 6;
const res_field_result_json = 7;

pub const FrameState = enum(u64) {
    unspecified = 0,
    first = 1,
    middle = 3,
    last = 9,
};

pub const ResponseType = enum {
    unknown,
    task_started,
    session_started,
    session_finished,
    interim,
    final,
    vad,
    err,
};

pub const Response = struct {
    kind: ResponseType,
    text: []const u8 = "",
    error_message: []const u8 = "",

    pub fn deinit(resp: Response, allocator: std.mem.Allocator) void {
        if (resp.text.len > 0) allocator.free(resp.text);
        if (resp.error_message.len > 0) allocator.free(resp.error_message);
    }
};

pub const Request = struct {
    token: []const u8 = "",
    service: []const u8 = "",
    method: []const u8 = "",
    payload: []const u8 = "",
    audio_data: []const u8 = "",
    request_id: []const u8 = "",
    frame_state: FrameState = .unspecified,
};

pub fn buildStartTask(allocator: std.mem.Allocator, request_id: []const u8, token: []const u8) ![]u8 {
    return encodeRequest(allocator, .{
        .token = token,
        .service = "ASR",
        .method = "StartTask",
        .request_id = request_id,
    });
}

pub fn buildFinishSession(allocator: std.mem.Allocator, request_id: []const u8, token: []const u8) ![]u8 {
    return encodeRequest(allocator, .{
        .token = token,
        .service = "ASR",
        .method = "FinishSession",
        .request_id = request_id,
    });
}

pub fn buildStartSession(allocator: std.mem.Allocator, request_id: []const u8, token: []const u8, cfg: SessionConfig) ![]u8 {
    const payload = try sessionConfigJson(allocator, cfg);
    defer allocator.free(payload);
    return encodeRequest(allocator, .{
        .token = token,
        .service = "ASR",
        .method = "StartSession",
        .request_id = request_id,
        .payload = payload,
    });
}

pub fn buildAudioRequest(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    audio: []const u8,
    state: FrameState,
    timestamp_ms: i64,
) ![]u8 {
    var payload_buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{{\"extra\":{{}},\"timestamp_ms\":{d}}}", .{timestamp_ms});
    return encodeRequest(allocator, .{
        .service = "ASR",
        .method = "TaskRequest",
        .payload = payload,
        .audio_data = audio,
        .request_id = request_id,
        .frame_state = state,
    });
}

pub fn encodeRequest(allocator: std.mem.Allocator, req: Request) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    if (req.token.len > 0) try encodeStringField(&out, allocator, req_field_token, req.token);
    if (req.service.len > 0) try encodeStringField(&out, allocator, req_field_service, req.service);
    if (req.method.len > 0) try encodeStringField(&out, allocator, req_field_method, req.method);
    if (req.payload.len > 0) try encodeStringField(&out, allocator, req_field_payload, req.payload);
    if (req.audio_data.len > 0) try encodeBytesField(&out, allocator, req_field_audio_data, req.audio_data);
    if (req.request_id.len > 0) try encodeStringField(&out, allocator, req_field_request_id, req.request_id);
    if (req.frame_state != .unspecified) try encodeVarintField(&out, allocator, req_field_frame_state, @intFromEnum(req.frame_state));

    return out.toOwnedSlice(allocator);
}

pub fn parseResponse(allocator: std.mem.Allocator, data: []const u8) !Response {
    var offset: usize = 0;
    var message_type: []const u8 = "";
    var status_message: []const u8 = "";
    var result_json: []const u8 = "";

    while (offset < data.len) {
        const tag = try decodeVarint(data, &offset);
        const field_number = tag >> 3;
        const wire_type = tag & 0x7;

        switch (field_number) {
            res_field_message_type => message_type = try decodeString(data, &offset),
            res_field_status_msg => status_message = try decodeString(data, &offset),
            res_field_result_json => result_json = try decodeString(data, &offset),
            else => try skipField(data, &offset, wire_type),
        }
    }

    if (std.mem.eql(u8, message_type, "TaskStarted")) return .{ .kind = .task_started };
    if (std.mem.eql(u8, message_type, "SessionStarted")) return .{ .kind = .session_started };
    if (std.mem.eql(u8, message_type, "SessionFinished")) return .{ .kind = .session_finished };
    if (std.mem.eql(u8, message_type, "TaskFailed") or std.mem.eql(u8, message_type, "SessionFailed")) {
        return .{ .kind = .err, .error_message = try allocator.dupe(u8, status_message) };
    }
    if (result_json.len == 0) return .{ .kind = .unknown };

    return parseResultJson(allocator, result_json);
}

fn parseResultJson(allocator: std.mem.Allocator, bytes: []const u8) !Response {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("extra")) |extra_value| {
        if (extra_value == .object) {
            if (extra_value.object.get("vad_start")) |vad_start| {
                if (vad_start == .bool and vad_start.bool) return .{ .kind = .vad };
            }
        }
    }
    if (root.get("text")) |text_value| {
        if (text_value == .string) return .{ .kind = .final, .text = try allocator.dupe(u8, text_value.string) };
    }
    if (root.get("results")) |results_value| {
        if (results_value != .array) return .{ .kind = .unknown };
        return parseResultsArray(allocator, results_value.array.items);
    }
    if (root.get("result")) |result_value| {
        if (result_value != .object) return .{ .kind = .unknown };
        const result = result_value.object;
        if (result.get("text")) |text_value| {
            if (text_value == .string) return .{ .kind = .final, .text = try allocator.dupe(u8, text_value.string) };
        }
    }
    return .{ .kind = .unknown };
}

fn parseResultsArray(allocator: std.mem.Allocator, items: []const std.json.Value) !Response {
    if (items.len == 0) return .{ .kind = .unknown };
    var final = false;
    var vad_finished = false;
    var text: []const u8 = "";
    for (items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        if (obj.get("text")) |text_value| {
            if (text_value == .string and text_value.string.len > 0) text = text_value.string;
        }
        if (obj.get("is_interim")) |is_interim| {
            if (is_interim == .bool and !is_interim.bool) final = true;
        }
        if (obj.get("is_vad_finished")) |is_vad_finished| {
            if (is_vad_finished == .bool and is_vad_finished.bool) vad_finished = true;
        }
        if (obj.get("extra")) |extra_value| {
            if (extra_value == .object) {
                if (extra_value.object.get("nonstream_result")) |nonstream| {
                    if (nonstream == .bool and nonstream.bool) final = true;
                }
            }
        }
    }
    if (text.len == 0) return .{ .kind = .unknown };
    const copied = try allocator.dupe(u8, text);
    if (final and vad_finished) return .{ .kind = .final, .text = copied };
    return .{ .kind = .interim, .text = copied };
}

pub const SessionConfig = struct {
    sample_rate: u32 = 16000,
    channels: u16 = 1,
    device_id: []const u8,
    app_name: []const u8 = "com.android.chrome",
    enable_punctuation: bool = true,
};

pub fn sessionConfigJson(allocator: std.mem.Allocator, cfg: SessionConfig) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"audio_info\":{{\"channel\":{d},\"format\":\"pcm\",\"sample_rate\":{d}}},\"enable_punctuation\":{},\"enable_speech_rejection\":false,\"extra\":{{\"app_name\":\"{s}\",\"cell_compress_rate\":8,\"did\":\"{s}\",\"enable_asr_threepass\":true,\"enable_asr_twopass\":true,\"input_mode\":\"tool\"}}}}",
        .{ cfg.channels, cfg.sample_rate, cfg.enable_punctuation, cfg.app_name, cfg.device_id },
    );
}

pub fn encodeVarint(allocator: std.mem.Allocator, value: u64) ![]u8 {
    var buf: [10]u8 = undefined;
    const len = encodeVarintIntoBuf(&buf, value);
    return allocator.dupe(u8, buf[0..len]);
}

fn encodeVarintInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [10]u8 = undefined;
    const len = encodeVarintIntoBuf(&buf, value);
    try out.appendSlice(allocator, buf[0..len]);
}

fn encodeVarintIntoBuf(buf: *[10]u8, value: u64) usize {
    var current = value;
    var index: usize = 0;
    while (current >= 0x80) : (index += 1) {
        buf[index] = @as(u8, @truncate(current)) | 0x80;
        current >>= 7;
    }
    buf[index] = @as(u8, @truncate(current));
    return index + 1;
}

fn encodeVarintField(out: *std.ArrayList(u8), allocator: std.mem.Allocator, field_number: u64, value: u64) !void {
    try encodeVarintInto(out, allocator, (field_number << 3) | 0);
    try encodeVarintInto(out, allocator, value);
}

fn encodeStringField(out: *std.ArrayList(u8), allocator: std.mem.Allocator, field_number: u64, value: []const u8) !void {
    try encodeBytesField(out, allocator, field_number, value);
}

fn encodeBytesField(out: *std.ArrayList(u8), allocator: std.mem.Allocator, field_number: u64, value: []const u8) !void {
    try encodeVarintInto(out, allocator, (field_number << 3) | 2);
    try encodeVarintInto(out, allocator, value.len);
    try out.appendSlice(allocator, value);
}

fn decodeVarint(data: []const u8, offset: *usize) !u64 {
    if (offset.* >= data.len) return error.VarintOffsetOutOfRange;
    var shift: u6 = 0;
    var result: u64 = 0;
    while (offset.* < data.len) {
        const byte = data[offset.*];
        offset.* += 1;
        result |= (@as(u64, byte & 0x7f) << shift);
        if ((byte & 0x80) == 0) return result;
        if (shift >= 63) return error.InvalidVarint;
        shift += 7;
    }
    return error.InvalidVarint;
}

fn decodeString(data: []const u8, offset: *usize) ![]const u8 {
    const len = try decodeVarint(data, offset);
    if (len > std.math.maxInt(usize)) return error.StringTooLong;
    const start = offset.*;
    const end = start + @as(usize, @intCast(len));
    if (end < start or end > data.len) return error.StringOutOfRange;
    offset.* = end;
    return data[start..end];
}

fn skipField(data: []const u8, offset: *usize, wire_type: u64) !void {
    switch (wire_type) {
        0 => _ = try decodeVarint(data, offset),
        1 => {
            if (offset.* + 8 > data.len) return error.Fixed64Overflow;
            offset.* += 8;
        },
        2 => _ = try decodeString(data, offset),
        5 => {
            if (offset.* + 4 > data.len) return error.Fixed32Overflow;
            offset.* += 4;
        },
        else => return error.UnsupportedWireType,
    }
}

test "encodes varint" {
    const allocator = std.testing.allocator;
    const bytes = try encodeVarint(allocator, 300);
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x02 }, bytes);
}

test "encodes start task request fields" {
    const allocator = std.testing.allocator;
    const bytes = try buildStartTask(allocator, "req-1", "tok");
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "ASR") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "StartTask") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "req-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "tok") != null);
}

test "parses session started response" {
    const allocator = std.testing.allocator;
    const bytes = try encodeRequest(allocator, .{ .method = "unused" });
    allocator.free(bytes);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try encodeStringField(&out, allocator, res_field_message_type, "SessionStarted");

    const resp = try parseResponse(allocator, out.items);
    defer resp.deinit(allocator);
    try std.testing.expectEqual(ResponseType.session_started, resp.kind);
}

test "parses final text from result json" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try encodeStringField(&out, allocator, res_field_result_json, "{\"text\":\"语音识别测试。\"}");

    const resp = try parseResponse(allocator, out.items);
    defer resp.deinit(allocator);
    try std.testing.expectEqual(ResponseType.final, resp.kind);
    try std.testing.expectEqualStrings("语音识别测试。", resp.text);
}

test "parses remote failed status message" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try encodeStringField(&out, allocator, res_field_message_type, "TaskFailed");
    try encodeStringField(&out, allocator, res_field_status_msg, "quota exceeded");

    const resp = try parseResponse(allocator, out.items);
    defer resp.deinit(allocator);
    try std.testing.expectEqual(ResponseType.err, resp.kind);
    try std.testing.expectEqualStrings("quota exceeded", resp.error_message);
}

test "builds start session payload" {
    const allocator = std.testing.allocator;
    const bytes = try buildStartSession(allocator, "req-1", "tok", .{ .device_id = "dev" });
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "StartSession") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"sample_rate\":16000") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"did\":\"dev\"") != null);
}

test "parses final text from results array" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try encodeStringField(&out, allocator, res_field_result_json, "{\"results\":[{\"text\":\"完成。\",\"is_interim\":false,\"is_vad_finished\":true}]}");

    const resp = try parseResponse(allocator, out.items);
    defer resp.deinit(allocator);
    try std.testing.expectEqual(ResponseType.final, resp.kind);
    try std.testing.expectEqualStrings("完成。", resp.text);
}
