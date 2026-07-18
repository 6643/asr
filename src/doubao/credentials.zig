const std = @import("std");

const asr_settings_url = "https://is.snssdk.com/service/settings/v3/";
const sami_config_url = "https://ime.oceancloudapi.com/api/v1/user/get_config";
const aid = "401734";
const app_name = "oime";
const app_version = "1.1.2";
const user_agent =
    "com.bytedance.android.doubaoime/100102018 (Linux; U; Android 16; en_US; Pixel 7 Pro; Build/BP2A.250605.031.A2; Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)";
const sami_app_key = "SYlxZr6LnvBaIVmF";
const request_timeout_seconds = "15";

pub const RefreshResult = enum { updated };

pub const RefreshIds = struct {
    device_id: []const u8,
    cdid: []const u8,

    pub fn deinit(ids: RefreshIds, allocator: std.mem.Allocator) void {
        allocator.free(ids.device_id);
        allocator.free(ids.cdid);
    }
};

pub fn extractCredentialRefreshIds(allocator: std.mem.Allocator, source: []const u8) !RefreshIds {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCredentialJson;

    const device_id = try duplicateObjectString(allocator, parsed.value.object, "device_id");
    errdefer allocator.free(device_id);
    const cdid = try duplicateObjectString(allocator, parsed.value.object, "cdid");
    return .{ .device_id = device_id, .cdid = cdid };
}

pub fn updateCredentialJson(
    allocator: std.mem.Allocator,
    source: []const u8,
    token: []const u8,
    sami_token: []const u8,
) ![]u8 {
    if (token.len == 0 or sami_token.len == 0) return error.EmptyCredentialToken;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const json_allocator = arena.allocator();
    var value = try std.json.parseFromSliceLeaky(std.json.Value, json_allocator, source, .{});
    if (value != .object) return error.InvalidCredentialJson;

    try putOwnedString(json_allocator, &value.object, "token", token);
    try putOwnedString(json_allocator, &value.object, "sami_token", sami_token);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &output.writer);
    return try output.toOwnedSlice();
}

fn combineRefreshTokens(
    allocator: std.mem.Allocator,
    source: []const u8,
    token: []const u8,
    sami_token: []const u8,
) ![]u8 {
    return updateCredentialJson(allocator, source, token, sami_token);
}

pub fn refreshFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    debug: bool,
) !RefreshResult {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(source);

    const ids = try extractCredentialRefreshIds(allocator, source);
    defer ids.deinit(allocator);

    const token = try fetchAsrToken(allocator, io, ids.device_id, ids.cdid, debug);
    defer allocator.free(token);
    const sami_token = try fetchSamiToken(allocator, io, ids.cdid, debug);
    defer allocator.free(sami_token);

    const updated = try combineRefreshTokens(allocator, source, token, sami_token);
    defer allocator.free(updated);
    try writeAtomic(io, path, updated);
    return .updated;
}

const HttpResponse = struct {
    body: []u8,
    status: u16,

    fn deinit(response: HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(response.body);
    }
};

fn fetchAsrToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    device_id: []const u8,
    cdid: []const u8,
    debug: bool,
) ![]u8 {
    const body = "body=null";
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}?device_platform=android&os=android&ssmix=a&_rticket={d}&cdid={s}&channel=official&aid={s}&app_name={s}&version_code=100102018&version_name={s}&device_id={s}",
        .{ asr_settings_url, std.Io.Timestamp.now(io, .real).toMilliseconds(), cdid, aid, app_name, app_version, device_id },
    );
    defer allocator.free(url);

    var stub: [32]u8 = undefined;
    md5HexUpper(body, &stub);
    const stub_header = try std.fmt.allocPrint(allocator, "x-ss-stub: {s}", .{stub});
    defer allocator.free(stub_header);

    var response = try curlPost(allocator, io, url, body, &.{
        "Content-Type: application/json",
        stub_header,
    });
    defer response.deinit(allocator);
    if (response.status != 200) {
        if (debug) std.log.warn("credential refresh ASR request status={d}", .{response.status});
        return error.CredentialRefreshHttpFailed;
    }
    return try parseTokenField(allocator, response.body, &.{ "data", "settings", "asr_config", "app_key" });
}

fn fetchSamiToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    cdid: []const u8,
    debug: bool,
) ![]u8 {
    const body = "{\"sami_app_key\":\"SYlxZr6LnvBaIVmF\"}";
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}?device_platform=android&os=android&ssmix=a&_rticket={d}&cdid={s}&channel=official&aid={s}&app_name={s}&version_code=100102018&version_name={s}&manifest_version_code=100102018&update_version_code=100102018&resolution=1080*2400&dpi=420&device_type=Pixel%%207%%20Pro&device_brand=google&language=zh&os_api=34&os_version=16&ac=wifi",
        .{ sami_config_url, std.Io.Timestamp.now(io, .real).toMilliseconds(), cdid, aid, app_name, app_version },
    );
    defer allocator.free(url);

    var stub: [64]u8 = undefined;
    sha256HexUpper(body, &stub);
    const stub_header = try std.fmt.allocPrint(allocator, "x-ss-stub: {s}", .{stub});
    defer allocator.free(stub_header);

    var response = try curlPost(allocator, io, url, body, &.{
        "Content-Type: application/json",
        "app_version: 1.1.2",
        "app_id: 401734",
        "os_type: Android",
        stub_header,
    });
    defer response.deinit(allocator);
    if (response.status != 200) {
        if (debug) std.log.warn("credential refresh SAMI request status={d}", .{response.status});
        return error.CredentialRefreshHttpFailed;
    }
    return try parseTokenField(allocator, response.body, &.{ "data", "sami_token" });
}

fn curlPost(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
    headers: []const []const u8,
) !HttpResponse {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "curl", "-sS", "-X", "POST", url, "--max-time", request_timeout_seconds });
    for (headers) |header| try argv.appendSlice(allocator, &.{ "-H", header });
    try argv.appendSlice(allocator, &.{ "-d", body, "-w", "\n%{http_code}" });

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    });
    errdefer child.kill(io);
    const stdout = child.stdout orelse return error.MissingChildStdout;

    var response_bytes: std.ArrayList(u8) = .empty;
    errdefer response_bytes.deinit(allocator);
    var reader_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(stdout, io, &reader_buffer);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const count = reader.interface.readSliceShort(&chunk) catch break;
        if (count == 0) break;
        try response_bytes.appendSlice(allocator, chunk[0..count]);
    }
    _ = child.wait(io) catch {};

    const raw = try response_bytes.toOwnedSlice(allocator);
    errdefer allocator.free(raw);
    const separator = std.mem.lastIndexOfScalar(u8, raw, '\n') orelse return error.InvalidCredentialHttpResponse;
    const status = try std.fmt.parseInt(u16, std.mem.trim(u8, raw[separator + 1 ..], " \r\n"), 10);
    const body_copy = try allocator.dupe(u8, raw[0..separator]);
    allocator.free(raw);
    return .{ .body = body_copy, .status = status };
}

fn parseTokenField(allocator: std.mem.Allocator, body: []const u8, path: []const []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    var current = parsed.value;
    for (path) |field| {
        if (current != .object) return error.InvalidCredentialResponse;
        current = current.object.get(field) orelse return error.InvalidCredentialResponse;
    }
    if (current != .string or current.string.len == 0) return error.InvalidCredentialResponse;
    return allocator.dupe(u8, current.string);
}

fn writeAtomic(io: std.Io, path: []const u8, contents: []const u8) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .fromMode(0o600),
        .replace = true,
    });
    defer atomic_file.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try writer.interface.writeAll(contents);
    try writer.interface.flush();
    try atomic_file.replace(io);
}

fn md5HexUpper(input: []const u8, output: *[32]u8) void {
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    hexUpper(&digest, output);
}

fn sha256HexUpper(input: []const u8, output: *[64]u8) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &digest, .{});
    hexUpper(&digest, output);
}

fn hexUpper(input: []const u8, output: []u8) void {
    const digits = "0123456789ABCDEF";
    for (input, 0..) |byte, index| {
        output[index * 2] = digits[byte >> 4];
        output[index * 2 + 1] = digits[byte & 0x0f];
    }
}

fn duplicateObjectString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field: []const u8,
) ![]u8 {
    const value = object.get(field) orelse return error.MissingCredentialField;
    if (value != .string or value.string.len == 0) return error.InvalidCredentialField;
    return allocator.dupe(u8, value.string);
}

fn putOwnedString(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    field: []const u8,
    value: []const u8,
) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    if (object.getPtr(field)) |existing| {
        existing.* = .{ .string = owned_value };
        return;
    }
    const owned_field = try allocator.dupe(u8, field);
    errdefer allocator.free(owned_field);
    try object.put(allocator, owned_field, .{ .string = owned_value });
}

test "updates only token fields and preserves other credential fields" {
    const source =
        "{\"device_id\":\"dev\",\"install_id\":\"install\",\"cdid\":\"cid\",\"unknown\":42,\"token\":\"old\",\"sami_token\":\"old-sami\"}";
    const updated = try updateCredentialJson(std.testing.allocator, source, "new", "new-sami");
    defer std.testing.allocator.free(updated);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, updated, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("dev", parsed.value.object.get("device_id").?.string);
    try std.testing.expectEqualStrings("cid", parsed.value.object.get("cdid").?.string);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("unknown").?.integer);
    try std.testing.expectEqualStrings("new", parsed.value.object.get("token").?.string);
    try std.testing.expectEqualStrings("new-sami", parsed.value.object.get("sami_token").?.string);
}

test "extracts fixed refresh identifiers" {
    const ids = try extractCredentialRefreshIds(std.testing.allocator, "{\"device_id\":\"dev\",\"cdid\":\"cid\"}");
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dev", ids.device_id);
    try std.testing.expectEqualStrings("cid", ids.cdid);
}

test "does not build refreshed credentials when either token is empty" {
    const source = "{\"device_id\":\"dev\",\"cdid\":\"cid\",\"token\":\"old\",\"sami_token\":\"old-sami\"}";
    try std.testing.expectError(
        error.EmptyCredentialToken,
        combineRefreshTokens(std.testing.allocator, source, "new", ""),
    );
}
