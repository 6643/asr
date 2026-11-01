//! WebSocket endpoint parsing shared by both engines.

const std = @import("std");

pub const Endpoint = struct {
    host: []const u8,
    path: []const u8,
    port: u16,
    tls: bool,

    pub fn deinit(self: Endpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

/// Parses `url` into the pieces the websocket client needs. `url` itself is
/// only borrowed; every returned string is owned by the caller.
pub fn parse(allocator: std.mem.Allocator, url: []const u8) !Endpoint {
    const uri = try std.Uri.parse(url);
    const tls: bool = if (std.mem.eql(u8, uri.scheme, "wss"))
        true
    else if (std.mem.eql(u8, uri.scheme, "ws"))
        false
    else
        return error.UnsupportedWebsocketScheme;

    const host_component = uri.host orelse return error.MissingHost;
    // Hosts are plain ASCII in both endpoints; no percent-decoding needed.
    const host = try allocator.dupe(u8, host_component.percent_encoded);
    errdefer allocator.free(host);
    const path = try formatPath(allocator, uri);
    return .{
        .host = host,
        .path = path,
        .port = uri.port orelse if (tls) @as(u16, 443) else @as(u16, 80),
        .tls = tls,
    };
}

fn formatPath(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    const path = uri.path.percent_encoded;
    if (uri.query) |query| {
        return std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, query.percent_encoded });
    }
    return allocator.dupe(u8, path);
}

test "parses a wss url with a query" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, "wss://example.com/ws?x=1");
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed.tls);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqualStrings("/ws?x=1", parsed.path);
}

test "parses a plain ws url on the default port" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, "ws://127.0.0.1:8080/api");
    defer parsed.deinit(allocator);
    try std.testing.expect(!parsed.tls);
    try std.testing.expectEqual(@as(u16, 8080), parsed.port);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.host);
    try std.testing.expectEqualStrings("/api", parsed.path);
}

test "rejects unsupported schemes" {
    try std.testing.expectError(
        error.UnsupportedWebsocketScheme,
        parse(std.testing.allocator, "https://example.com/ws"),
    );
}
