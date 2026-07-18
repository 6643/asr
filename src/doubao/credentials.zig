const std = @import("std");

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
