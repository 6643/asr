const std = @import("std");

pub const default_websocket_url = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws";
pub const default_aid = "401734";
pub const default_user_agent =
    "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)";
pub const default_credential_path = "config/doubao.json";
pub const default_baidu_credential_path = "config/baidu.json";
pub const default_baidu_ws_url = "wss://vse.baidu.com/ws_api";

pub const Credentials = struct {
    device_id: []const u8 = "",
    token: []const u8 = "",
    cdid: []const u8 = "",
    sami_token: []const u8 = "",

    pub fn deinit(creds: Credentials, allocator: std.mem.Allocator) void {
        if (creds.device_id.len > 0) allocator.free(creds.device_id);
        if (creds.token.len > 0) allocator.free(creds.token);
        if (creds.cdid.len > 0) allocator.free(creds.cdid);
        if (creds.sami_token.len > 0) allocator.free(creds.sami_token);
    }
};

pub const Config = struct {
    url: []const u8 = default_websocket_url,
    aid: []const u8 = default_aid,
    user_agent: []const u8 = default_user_agent,
    credential_path: []const u8 = default_credential_path,
    sample_rate: u32 = 16000,
    channels: u16 = 1,
    frame_duration_ms: u16 = 100,
    device_id: []const u8 = "",
    token: []const u8 = "",
    sami_token: []const u8 = "",
};

pub const AudioParams = struct {
    sample_rate: u32 = 16000,
    channels: u16 = 1,
    frame_duration_ms: u16 = 100,
};

pub const BaiduConfig = struct {
    url: []const u8 = "",
    sample_rate: u32 = 16000,
    channels: u16 = 1,
    frame_duration_ms: u16 = 100,
    user: []const u8 = "baidu_pc",
    dev_key: []const u8 = "com.baidu.searchbox.fangyan",
    dev_pid: u32 = 8068,
    vad_type: u32 = 1,
    vad_mode: u32 = 0,
    enable_punctuation: bool = true,
    owns_url: bool = false,
    owns_user: bool = false,
    owns_dev_key: bool = false,

    pub fn deinit(cfg: BaiduConfig, allocator: std.mem.Allocator) void {
        if (cfg.owns_url) allocator.free(cfg.url);
        if (cfg.owns_user) allocator.free(cfg.user);
        if (cfg.owns_dev_key) allocator.free(cfg.dev_key);
    }
};

pub fn withCredentials(base: Config, creds: Credentials) Config {
    var cfg = base;
    if (cfg.device_id.len == 0) cfg.device_id = creds.device_id;
    if (cfg.token.len == 0) cfg.token = creds.token;
    if (cfg.sami_token.len == 0) cfg.sami_token = creds.sami_token;
    return cfg;
}

pub fn frameBytes(cfg: anytype) u32 {
    const sample_rate = if (@hasField(@TypeOf(cfg), "sample_rate") and cfg.sample_rate != 0)
        cfg.sample_rate
    else
        @as(u32, 16000);
    const channels = if (@hasField(@TypeOf(cfg), "channels") and cfg.channels != 0)
        cfg.channels
    else
        @as(u16, 1);
    const duration = if (@hasField(@TypeOf(cfg), "frame_duration_ms") and cfg.frame_duration_ms != 0)
        cfg.frame_duration_ms
    else
        @as(u16, 100);
    return (sample_rate * duration / 1000) * channels * 2;
}

pub fn headers(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    const host = try hostFromUrl(allocator, cfg.url);
    defer allocator.free(host);
    return std.fmt.allocPrint(
        allocator,
        "Host: {s}\r\nUser-Agent: {s}\r\nproto-version: v2\r\nx-custom-keepalive: true\r\nX-Device-Id: {s}\r\n",
        .{ host, cfg.user_agent, cfg.device_id },
    );
}

pub fn wsUrl(allocator: std.mem.Allocator, cfg: Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}?aid={s}&device_id={s}", .{ cfg.url, cfg.aid, cfg.device_id });
}

pub fn parseCredentials(allocator: std.mem.Allocator, bytes: []const u8) !Credentials {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var creds: Credentials = .{};
    errdefer creds.deinit(allocator);
    creds.device_id = try dupeJsonString(allocator, obj.get("device_id"));
    creds.token = try dupeJsonString(allocator, obj.get("token"));
    creds.cdid = try dupeJsonString(allocator, obj.get("cdid"));
    creds.sami_token = try dupeJsonString(allocator, obj.get("sami_token"));
    return creds;
}

pub fn loadCredentials(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Credentials {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().readFileAlloc(io, "../config/doubao.json", allocator, .limited(1024 * 1024)),
        else => |e| return e,
    };
    defer allocator.free(bytes);
    return parseCredentials(allocator, bytes);
}

fn dupeJsonString(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const v = value orelse return "";
    if (v != .string) return "";
    return allocator.dupe(u8, v.string);
}

pub fn loadBaiduConfig(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !BaiduConfig {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().readFileAlloc(io, "../config/baidu.json", allocator, .limited(1024 * 1024)),
        else => |e| return e,
    };
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    var cfg: BaiduConfig = .{};
    if (obj.get("url")) |v| {
        if (v == .string and v.string.len > 0) {
            cfg.url = try allocator.dupe(u8, v.string);
            cfg.owns_url = true;
        }
    }
    if (obj.get("sample_rate")) |v| {
        if (v == .integer) cfg.sample_rate = @intCast(v.integer);
    }
    if (obj.get("channels")) |v| {
        if (v == .integer) cfg.channels = @intCast(v.integer);
    }
    if (obj.get("frame_duration_ms")) |v| {
        if (v == .integer) cfg.frame_duration_ms = @intCast(v.integer);
    }
    if (obj.get("user")) |v| {
        if (v == .string and v.string.len > 0) {
            cfg.user = try allocator.dupe(u8, v.string);
            cfg.owns_user = true;
        }
    }
    if (obj.get("dev_key")) |v| {
        if (v == .string and v.string.len > 0) {
            cfg.dev_key = try allocator.dupe(u8, v.string);
            cfg.owns_dev_key = true;
        }
    }
    if (obj.get("dev_pid")) |v| {
        if (v == .integer) cfg.dev_pid = @intCast(v.integer);
    }
    if (obj.get("vad_type")) |v| {
        if (v == .integer) cfg.vad_type = @intCast(v.integer);
    }
    if (obj.get("vad_mode")) |v| {
        if (v == .integer) cfg.vad_mode = @intCast(v.integer);
    }
    if (obj.get("enable_punctuation")) |v| {
        if (v == .bool) cfg.enable_punctuation = v.bool;
    }
    return cfg;
}

fn hostFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    const component = uri.host orelse return error.MissingHost;
    const host_raw = try component.toRawMaybeAlloc(allocator);
    // toRawMaybeAlloc may return a pointer into `url` (not allocated)
    // or a newly heap-allocated string (percent-decoded). Only free if allocated.
    const ptr = @intFromPtr(host_raw.ptr);
    const url_start = @intFromPtr(url.ptr);
    const is_into_url = ptr >= url_start and ptr < url_start + url.len;
    defer if (!is_into_url) allocator.free(host_raw);
    return allocator.dupe(u8, host_raw);
}

test "uses default audio frame size" {
    try std.testing.expectEqual(@as(u32, 3200), frameBytes(.{}));
}

test "parses credentials json" {
    const allocator = std.testing.allocator;
    const creds = try parseCredentials(allocator, "{\"device_id\":\"dev\",\"token\":\"tok\",\"cdid\":\"cid\",\"sami_token\":\"sami\"}");
    defer creds.deinit(allocator);

    try std.testing.expectEqualStrings("dev", creds.device_id);
    try std.testing.expectEqualStrings("tok", creds.token);
    try std.testing.expectEqualStrings("cid", creds.cdid);
}

test "credentials deinit frees partial fields without double free on empty" {
    const allocator = std.testing.allocator;
    var creds: Credentials = .{};
    creds.device_id = try allocator.dupe(u8, "dev");
    creds.token = try allocator.dupe(u8, "tok");
    // Simulate mid-parse failure: deinit must free only allocated fields.
    try std.testing.expect(creds.cdid.len == 0);
    try std.testing.expect(creds.sami_token.len == 0);
    creds.deinit(allocator);
}

test "builds websocket headers" {
    const allocator = std.testing.allocator;
    const h = try headers(allocator, .{});
    defer allocator.free(h);
    try std.testing.expect(std.mem.indexOf(u8, h, "User-Agent: com.bytedance.android.doubaoime/100102018") != null);
    try std.testing.expect(std.mem.indexOf(u8, h, "proto-version: v2") != null);
}

test "builds websocket url with device id" {
    const allocator = std.testing.allocator;
    const url = try wsUrl(allocator, .{ .device_id = "dev" });
    defer allocator.free(url);
    try std.testing.expectEqualStrings("wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws?aid=401734&device_id=dev", url);
}
