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
};

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
