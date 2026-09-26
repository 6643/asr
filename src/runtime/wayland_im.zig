const std = @import("std");

pub const max_commit_bytes: usize = 4000;

const header_size: usize = 8;

pub const Message = struct {
    object_id: u32,
    opcode: u16,
    payload: []const u8,
    total_size: usize,
};

pub fn appendMessage(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    object_id: u32,
    opcode: u16,
    payload: []const u8,
) !void {
    const size = header_size + payload.len;
    std.debug.assert(size % 4 == 0);
    var header: [header_size]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], object_id, .little);
    std.mem.writeInt(u32, header[4..8], (@as(u32, @intCast(size)) << 16) | opcode, .little);
    try buf.appendSlice(allocator, &header);
    try buf.appendSlice(allocator, payload);
}

pub fn appendString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(text.len + 1), .little);
    try buf.appendSlice(allocator, &length_bytes);
    try buf.appendSlice(allocator, text);
    try buf.append(allocator, 0);
    const padded = (text.len + 1 + 3) & ~@as(usize, 3);
    try buf.appendNTimes(allocator, 0, padded - (text.len + 1));
}

pub fn encodeCommitString(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    im_id: u32,
    text: []const u8,
) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try appendString(allocator, &payload, text);
    try appendMessage(allocator, buf, im_id, 0, payload.items);
}

pub fn encodeCommit(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), im_id: u32, serial: u32) !void {
    var payload: [4]u8 = undefined;
    std.mem.writeInt(u32, &payload, serial, .little);
    try appendMessage(allocator, buf, im_id, 3, &payload);
}

pub fn extractMessage(buf: *const std.ArrayList(u8)) ?Message {
    if (buf.items.len < header_size) return null;
    const object_id = std.mem.readInt(u32, buf.items[0..4], .little);
    const word = std.mem.readInt(u32, buf.items[4..8], .little);
    const size: usize = word >> 16;
    const opcode: u16 = @truncate(word);
    if (size < header_size or size % 4 != 0) return null;
    if (buf.items.len < size) return null;
    return .{
        .object_id = object_id,
        .opcode = opcode,
        .payload = buf.items[header_size..size],
        .total_size = size,
    };
}

pub fn consumeMessage(buf: *std.ArrayList(u8), total_size: usize) void {
    std.debug.assert(total_size <= buf.items.len);
    const remaining = buf.items.len - total_size;
    std.mem.copyForwards(u8, buf.items[0..remaining], buf.items[total_size..]);
    buf.items.len = remaining;
}

pub fn readU32(payload: []const u8) ?u32 {
    if (payload.len < 4) return null;
    return std.mem.readInt(u32, payload[0..4], .little);
}

pub fn readString(payload: []const u8, offset: *usize) ?[]const u8 {
    if (payload.len < offset.* + 4) return null;
    const length: usize = std.mem.readInt(u32, payload[offset.*..][0..4], .little);
    if (length == 0) return null;
    const data_start = offset.* + 4;
    if (payload.len < data_start + length) return null;
    const bytes = payload[data_start .. data_start + length];
    if (bytes[bytes.len - 1] != 0) return null;
    offset.* = data_start + ((length + 3) & ~@as(usize, 3));
    return bytes[0 .. bytes.len - 1];
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    mutex: std.Io.Mutex = .init,
    next_id: u32 = 2,
    registry_id: u32 = 0,
    callback_id: u32 = 0,
    seat_id: u32 = 0,
    manager_id: u32 = 0,
    im_id: u32 = 0,
    seat_global_name: u32 = 0,
    manager_global_name: u32 = 0,
    done_count: u32 = 0,
    active: bool = false,
    pending_active: bool = false,
    sync_done: bool = false,
    dead: bool = false,
    read_buf: std.ArrayList(u8) = .empty,

    pub fn allocId(self: *Client) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn applyMessage(self: *Client, object_id: u32, opcode: u16, payload: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (object_id == 1) {
            if (opcode == 0) {
                self.dead = true;
                return error.DisplayError;
            }
            return; // delete_id
        }
        if (object_id == self.registry_id and opcode == 0) {
            const name = readU32(payload) orelse return;
            var offset: usize = 4;
            const interface = readString(payload, &offset) orelse return;
            if (std.mem.eql(u8, interface, "wl_seat")) self.seat_global_name = name;
            if (std.mem.eql(u8, interface, "zwp_input_method_manager_v2")) self.manager_global_name = name;
            return;
        }
        if (object_id == self.callback_id and opcode == 0) {
            self.sync_done = true;
            return;
        }
        if (object_id == self.im_id) {
            switch (opcode) {
                0 => self.pending_active = true,
                1 => self.pending_active = false,
                5 => {
                    self.done_count += 1;
                    self.active = self.pending_active;
                },
                6 => self.dead = true,
                else => {},
            }
            return;
        }
    }

    pub fn isActive(self: *Client) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.active;
    }

    pub fn pump(self: *Client, timeout_ms: i32) !void {
        var fds = [_]std.posix.pollfd{.{ .fd = self.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, timeout_ms) catch return error.ConnectionFailed;
        if (ready == 0) return;

        var buf: [4096]u8 = undefined;
        while (true) {
            const rc = std.posix.system.read(self.stream.socket.handle, &buf, buf.len);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) {
                        self.dead = true;
                        return error.ConnectionFailed;
                    }
                    self.read_buf.appendSlice(self.allocator, buf[0..rc]) catch return error.ConnectionFailed;
                },
                .INTR => continue,
                .AGAIN => break,
                else => {
                    self.dead = true;
                    return error.ConnectionFailed;
                },
            }
        }

        while (extractMessage(&self.read_buf)) |message| {
            try self.applyMessage(message.object_id, message.opcode, message.payload);
            consumeMessage(&self.read_buf, message.total_size);
        }
    }

    pub fn deinit(self: *Client) void {
        if (!self.dead) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            appendMessage(self.allocator, &out, self.im_id, 6, &.{}) catch {};
            appendMessage(self.allocator, &out, self.manager_id, 1, &.{}) catch {};
            writeAll(self, out.items) catch {};
        }
        destroyConnection(self);
    }
};

pub const listen_display_default = "wayland-0";
pub const setup_timeout_ms: i64 = 2000;
pub const unavailable_probe_ms: i64 = 200;

pub const ConnectError = error{
    MissingRuntimeDir,
    ConnectionFailed,
    InputMethodUnavailable,
    SetupTimeout,
    DisplayError,
    OutOfMemory,
};

fn le32(value: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    return bytes;
}

pub fn resolveSocketPath(allocator: std.mem.Allocator, environ: std.process.Environ) ConnectError![]u8 {
    if (std.process.Environ.getPosix(environ, "WAYLAND_DISPLAY")) |display| {
        if (std.mem.startsWith(u8, display, "/")) return try allocator.dupe(u8, display);
    }
    const runtime = std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDir;
    const display = std.process.Environ.getPosix(environ, "WAYLAND_DISPLAY") orelse listen_display_default;
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ runtime, display });
}

fn writeAll(client: *Client, bytes: []const u8) ConnectError!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.posix.system.write(client.stream.socket.handle, bytes.ptr + written, bytes.len - written);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ConnectionFailed;
                written += rc;
            },
            .INTR => continue,
            else => return error.ConnectionFailed,
        }
    }
}

fn appendBind(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    registry_id: u32,
    name: u32,
    interface: []const u8,
    version: u32,
    new_id: u32,
) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, &le32(name));
    try appendString(allocator, &payload, interface);
    try payload.appendSlice(allocator, &le32(version));
    try payload.appendSlice(allocator, &le32(new_id));
    try appendMessage(allocator, buf, registry_id, 0, payload.items);
}

fn destroyConnection(client: *Client) void {
    client.stream.close(client.io);
    client.read_buf.deinit(client.allocator);
    client.allocator.destroy(client);
}

pub fn connect(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ConnectError!*Client {
    const path = try resolveSocketPath(allocator, environ);
    defer allocator.free(path);
    const address = std.Io.net.UnixAddress.init(path) catch return error.ConnectionFailed;
    const stream = address.connect(io) catch return error.ConnectionFailed;
    const client = allocator.create(Client) catch return error.OutOfMemory;
    client.* = .{ .allocator = allocator, .io = io, .stream = stream };
    errdefer destroyConnection(client);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    client.registry_id = client.allocId();
    try appendMessage(allocator, &out, 1, 1, &le32(client.registry_id)); // get_registry
    client.callback_id = client.allocId();
    try appendMessage(allocator, &out, 1, 0, &le32(client.callback_id)); // sync
    try writeAll(client, out.items);

    var elapsed: i64 = 0;
    while (!client.sync_done and elapsed <= setup_timeout_ms) : (elapsed += 10) {
        try client.pump(10);
    }
    if (!client.sync_done) return error.SetupTimeout;
    if (client.seat_global_name == 0 or client.manager_global_name == 0) return error.InputMethodUnavailable;

    out.clearRetainingCapacity();
    client.seat_id = client.allocId();
    try appendBind(allocator, &out, client.registry_id, client.seat_global_name, "wl_seat", 1, client.seat_id);
    client.manager_id = client.allocId();
    try appendBind(allocator, &out, client.registry_id, client.manager_global_name, "zwp_input_method_manager_v2", 1, client.manager_id);
    client.im_id = client.allocId();
    var im_payload: [8]u8 = undefined;
    std.mem.writeInt(u32, im_payload[0..4], client.seat_id, .little);
    std.mem.writeInt(u32, im_payload[4..8], client.im_id, .little);
    try appendMessage(allocator, &out, client.manager_id, 0, &im_payload);
    try writeAll(client, out.items);

    elapsed = 0;
    while (!client.dead and client.done_count == 0 and elapsed <= unavailable_probe_ms) : (elapsed += 10) {
        try client.pump(10);
    }
    if (client.dead) return error.InputMethodUnavailable;
    return client;
}

test "appendString pads length-prefixed strings to four bytes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendString(std.testing.allocator, &buf, "a");
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x00, 0x00, 0x00, 'a', 0x00, 0x00, 0x00 }, buf.items);
}

test "encodeCommitString writes header and string payload" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeCommitString(std.testing.allocator, &buf, 5, "hi");
    try std.testing.expectEqualSlices(u8, &.{
        0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, // object 5, size 16, opcode 0
        0x03, 0x00, 0x00, 0x00, 'h',  'i',  0x00, 0x00,
    }, buf.items);
}

test "encodeCommit writes serial argument" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeCommit(std.testing.allocator, &buf, 5, 3);
    try std.testing.expectEqualSlices(u8, &.{
        0x05, 0x00, 0x00, 0x00, 0x03, 0x00, 0x0c, 0x00, 0x03, 0x00, 0x00, 0x00,
    }, buf.items);
}

test "extractMessage waits for the complete message" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendMessage(std.testing.allocator, &buf, 5, 3, &.{ 0x03, 0x00, 0x00, 0x00 });
    try buf.replaceRange(std.testing.allocator, 8, buf.items.len - 8, &.{}); // 只留前 8 字节 header
    try std.testing.expect(extractMessage(&buf) == null);
    try buf.appendSlice(std.testing.allocator, &.{ 0x03, 0x00, 0x00, 0x00 });
    const message = extractMessage(&buf).?;
    try std.testing.expectEqual(@as(u32, 5), message.object_id);
    try std.testing.expectEqual(@as(u16, 3), message.opcode);
    try std.testing.expectEqual(@as(u32, 3), readU32(message.payload).?);
}

test "readString returns unterminated-safe slices" {
    var offset: usize = 0;
    const payload = [_]u8{ 0x08, 0x00, 0x00, 0x00, 'w', 'l', '_', 's', 'e', 'a', 't', 0x00 };
    try std.testing.expectEqualStrings("wl_seat", readString(&payload, &offset).?);
    try std.testing.expectEqual(@as(usize, 12), offset);
    const truncated = [_]u8{ 0x08, 0x00, 0x00, 0x00, 'w', 'l' };
    offset = 0;
    try std.testing.expect(readString(&truncated, &offset) == null);
}

fn testClient() Client {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .stream = undefined,
        .registry_id = 2,
        .callback_id = 3,
        .seat_id = 4,
        .manager_id = 5,
        .im_id = 6,
    };
}

test "done events advance serial and apply pending active state" {
    var client = testClient();
    try client.applyMessage(6, 0, &.{}); // activate
    try std.testing.expect(!client.isActive());
    try client.applyMessage(6, 5, &.{}); // done
    try std.testing.expect(client.isActive());
    try std.testing.expectEqual(@as(u32, 1), client.done_count);
    try client.applyMessage(6, 1, &.{}); // deactivate
    try client.applyMessage(6, 5, &.{}); // done
    try std.testing.expect(!client.isActive());
    try std.testing.expectEqual(@as(u32, 2), client.done_count);
}

test "unavailable marks client dead" {
    var client = testClient();
    try client.applyMessage(6, 6, &.{});
    try std.testing.expect(client.dead);
}

test "display error is reported and marks dead" {
    var client = testClient();
    const payload = [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 'o', 'o', 'p', 's', 0, 0, 0, 0 };
    try std.testing.expectError(error.DisplayError, client.applyMessage(1, 0, &payload));
    try std.testing.expect(client.dead);
}

test "registry globals record seat and manager names" {
    var client = testClient();
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);
    try payload.appendSlice(std.testing.allocator, &.{ 40, 0, 0, 0 });
    try appendString(std.testing.allocator, &payload, "wl_seat");
    try payload.appendSlice(std.testing.allocator, &.{ 9, 0, 0, 0 });
    try client.applyMessage(2, 0, payload.items);
    try std.testing.expectEqual(@as(u32, 40), client.seat_global_name);
    payload.clearRetainingCapacity();
    try payload.appendSlice(std.testing.allocator, &.{ 24, 0, 0, 0 });
    try appendString(std.testing.allocator, &payload, "zwp_input_method_manager_v2");
    try payload.appendSlice(std.testing.allocator, &.{ 1, 0, 0, 0 });
    try client.applyMessage(2, 0, payload.items);
    try std.testing.expectEqual(@as(u32, 24), client.manager_global_name);
}

test "identifiers are allocated strictly sequentially" {
    var client = testClient();
    try std.testing.expectEqual(@as(u32, 2), client.allocId());
    try std.testing.expectEqual(@as(u32, 3), client.allocId());
    try std.testing.expectEqual(@as(u32, 4), client.allocId());
}

test "resolves socket path from runtime dir and display" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("XDG_RUNTIME_DIR", "/run/user/1000");
    try env_map.put("WAYLAND_DISPLAY", "wayland-1");
    const block = try env_map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const path = try resolveSocketPath(std.testing.allocator, .{ .block = block });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1000/wayland-1", path);
}

test "absolute wayland display path wins over runtime dir" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("WAYLAND_DISPLAY", "/tmp/wayland-test");
    const block = try env_map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const path = try resolveSocketPath(std.testing.allocator, .{ .block = block });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/wayland-test", path);
}

test "missing runtime dir fails" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("WAYLAND_DISPLAY", "wayland-1");
    const block = try env_map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingRuntimeDir, resolveSocketPath(std.testing.allocator, .{ .block = block }));
}

test "default display name is used when unset" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("XDG_RUNTIME_DIR", "/run/user/1000");
    const block = try env_map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const path = try resolveSocketPath(std.testing.allocator, .{ .block = block });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1000/wayland-0", path);
}
