const std = @import("std");

pub const right_alt: u16 = 100;
pub const input_event_size: usize = 24;

const ev_key: u16 = 1;
const ev_syn: u16 = 0;
const syn_report: u16 = 0;

pub const Event = enum {
    press,
    release,
};

pub const State = struct {
    key_state: u32 = 0,
    emitted_state: u32 = 0,
};

pub fn update(state: *State, bytes: []const u8, key_code: u16) ?Event {
    if (bytes.len < input_event_size) return null;

    const event_type = std.mem.readInt(u16, bytes[16..18], .little);
    const event_code = std.mem.readInt(u16, bytes[18..20], .little);
    const event_value = std.mem.readInt(u32, bytes[20..24], .little);

    if (event_type == ev_key and event_code == key_code) {
        state.key_state = event_value;
        if (event_value == 1) {
            state.emitted_state = 1;
            return .press;
        }
        if (event_value == 0) {
            state.emitted_state = 0;
            return .release;
        }
    }

    if (event_type != ev_syn or event_code != syn_report) return null;
    if (state.key_state == state.emitted_state) return null;

    state.emitted_state = state.key_state;
    if (state.key_state == 1) return .press;
    if (state.key_state == 0) return .release;
    return null;
}

pub fn findKeyboardDevice(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ![]u8 {
    if (std.process.Environ.getPosix(environ, "ASR_KEYBOARD_DEVICE")) |device| {
        const trimmed = std.mem.trim(u8, device, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }

    const content = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/bus/input/devices", allocator, .limited(1024 * 1024));
    defer allocator.free(content);
    if (findKeyboardDeviceInProcInput(allocator, content)) |path| {
        if (isUsableInputDevice(io, path)) return path;
        allocator.free(path);
    }
    if (findKeyboardDeviceFromSymlinkDirs(allocator, io)) |path| {
        if (isUsableInputDevice(io, path)) return path;
        allocator.free(path);
    }
    return error.KeyboardDeviceNotFound;
}

pub fn findKeyboardDeviceInProcInput(allocator: std.mem.Allocator, content: []const u8) ?[]u8 {
    // Prefer full keyboard handler set (kbd + leds + eventX).
    var blocks = std.mem.splitSequence(u8, content, "\n\n");
    while (blocks.next()) |block| {
        if (eventPathFromPreferredHandlers(allocator, block)) |path| return path;
    }

    // Fallback: name-based keyboard match.
    blocks = std.mem.splitSequence(u8, content, "\n\n");
    while (blocks.next()) |block| {
        if (!isKeyboardBlock(block)) continue;
        if (eventPathFromBlock(allocator, block)) |path| return path;
    }

    // Last fallback: any kbd handler with eventX.
    blocks = std.mem.splitSequence(u8, content, "\n\n");
    while (blocks.next()) |block| {
        if (eventPathFromKbdHandlers(allocator, block)) |path| return path;
    }
    return null;
}

pub fn readNextEvent(reader: *std.Io.Reader, state: *State, key_code: u16) !Event {
    var buf: [input_event_size]u8 = undefined;
    while (true) {
        try reader.readSliceAll(&buf);
        if (update(state, &buf, key_code)) |event| return event;
    }
}

fn isKeyboardBlock(block: []const u8) bool {
    const name = inputName(block) orelse return false;
    var lower: [256]u8 = undefined;
    const len = @min(name.len, lower.len);
    for (name[0..len], 0..) |c, index| {
        lower[index] = std.ascii.toLower(c);
    }
    const value = lower[0..len];
    if (std.mem.indexOf(u8, value, "keyboard") != null) return true;
    if (std.mem.indexOf(u8, value, "atkbd") != null) return true;
    return std.mem.indexOf(u8, value, "kbd") != null;
}

fn inputName(block: []const u8) ?[]const u8 {
    const prefix = "N: Name=\"";
    const start = std.mem.indexOf(u8, block, prefix) orelse return null;
    const name_start = start + prefix.len;
    const rest = block[name_start..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn eventPathFromBlock(allocator: std.mem.Allocator, block: []const u8) ?[]u8 {
    const handlers = handlersLine(block) orelse return null;
    return eventPathFromHandlers(allocator, handlers);
}

fn eventPathFromPreferredHandlers(allocator: std.mem.Allocator, block: []const u8) ?[]u8 {
    const handlers = handlersLine(block) orelse return null;
    if (!hasHandlerToken(handlers, "kbd")) return null;
    if (!hasHandlerToken(handlers, "leds")) return null;
    if (!hasHandlerToken(handlers, "sysrq")) return null;
    return eventPathFromHandlers(allocator, handlers);
}

fn eventPathFromKbdHandlers(allocator: std.mem.Allocator, block: []const u8) ?[]u8 {
    const handlers = handlersLine(block) orelse return null;
    if (!hasHandlerToken(handlers, "kbd")) return null;
    return eventPathFromHandlers(allocator, handlers);
}

fn handlersLine(block: []const u8) ?[]const u8 {
    const prefix = "H: Handlers=";
    const start = std.mem.indexOf(u8, block, prefix) orelse return null;
    const line_start = start + prefix.len;
    const rest = block[line_start..];
    const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return std.mem.trim(u8, rest[0..line_end], " \t\r");
}

fn eventPathFromHandlers(allocator: std.mem.Allocator, handlers: []const u8) ?[]u8 {
    var tokens = std.mem.tokenizeAny(u8, handlers, " \t");
    while (tokens.next()) |token| {
        if (!std.mem.startsWith(u8, token, "event")) continue;
        if (token.len <= "event".len) continue;
        for (token["event".len..]) |digit| {
            if (!std.ascii.isDigit(digit)) return null;
        }
        return std.fmt.allocPrint(allocator, "/dev/input/{s}", .{token}) catch null;
    }
    return null;
}

fn hasHandlerToken(handlers: []const u8, needle: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, handlers, " \t");
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, needle)) return true;
    }
    return false;
}

fn findKeyboardDeviceFromSymlinkDirs(allocator: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (findKeyboardDeviceInSymlinkDir(allocator, io, "/dev/input/by-id")) |path| return path;
    return findKeyboardDeviceInSymlinkDir(allocator, io, "/dev/input/by-path");
}

fn findKeyboardDeviceInSymlinkDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) ?[]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch return null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, "-event-kbd")) continue;
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const link_len = dir.readLink(io, entry.name, &link_buf) catch continue;
        const target = link_buf[0..link_len];
        const event_name = eventNameFromLinkTarget(target) orelse continue;
        return std.fmt.allocPrint(allocator, "/dev/input/{s}", .{event_name}) catch null;
    }
    return null;
}

fn eventNameFromLinkTarget(target: []const u8) ?[]const u8 {
    const event_name = blk: {
        if (std.mem.startsWith(u8, target, "/dev/input/event")) break :blk target["/dev/input/".len..];
        if (std.mem.startsWith(u8, target, "../event")) break :blk target["../".len..];
        if (std.mem.startsWith(u8, target, "event")) break :blk target;
        const slash = std.mem.lastIndexOfScalar(u8, target, '/') orelse return null;
        break :blk target[slash + 1 ..];
    };
    if (!std.mem.startsWith(u8, event_name, "event")) return null;
    if (event_name.len <= "event".len) return null;
    for (event_name["event".len..]) |digit| {
        if (!std.ascii.isDigit(digit)) return null;
    }
    return event_name;
}

fn isUsableInputDevice(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn inputEvent(event_type: u16, code: u16, value: u32) [input_event_size]u8 {
    var out = [_]u8{0} ** input_event_size;
    std.mem.writeInt(u16, out[16..18], event_type, .little);
    std.mem.writeInt(u16, out[18..20], code, .little);
    std.mem.writeInt(u32, out[20..24], value, .little);
    return out;
}

test "emits direct press and release for target key" {
    var state: State = .{};
    const down = inputEvent(ev_key, right_alt, 1);
    const up = inputEvent(ev_key, right_alt, 0);

    try std.testing.expectEqual(Event.press, update(&state, &down, right_alt).?);
    try std.testing.expectEqual(Event.release, update(&state, &up, right_alt).?);
}

test "ignores non target key events" {
    var state: State = .{};
    const down = inputEvent(ev_key, right_alt + 1, 1);
    try std.testing.expectEqual(@as(?Event, null), update(&state, &down, right_alt));
}

test "emits pending state on syn report" {
    var state: State = .{ .key_state = 1, .emitted_state = 0 };
    const syn = inputEvent(ev_syn, syn_report, 0);
    try std.testing.expectEqual(Event.press, update(&state, &syn, right_alt).?);
}

test "finds keyboard event path in proc input devices" {
    const content =
        \\I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
        \\N: Name="AT Translated Set 2 keyboard"
        \\H: Handlers=sysrq kbd event2 leds
        \\
    ;
    const path = findKeyboardDeviceInProcInput(std.testing.allocator, content).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/dev/input/event2", path);
}

test "prefers full keyboard handlers over power button" {
    const content =
        \\I: Bus=0019 Vendor=0000 Product=0001 Version=0000
        \\N: Name="Power Button"
        \\H: Handlers=kbd event0
        \\
        \\I: Bus=0003 Vendor=09da Product=2268 Version=0111
        \\N: Name="Input Device"
        \\H: Handlers=sysrq kbd event2 leds
        \\
    ;
    const path = findKeyboardDeviceInProcInput(std.testing.allocator, content).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/dev/input/event2", path);
}

test "extracts event path from handlers line" {
    const path = eventPathFromHandlers(std.testing.allocator, "sysrq kbd event2 leds").?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/dev/input/event2", path);
}

test "normalizes symlink target into event device path" {
    try std.testing.expectEqualStrings("event2", eventNameFromLinkTarget("../event2").?);
    try std.testing.expectEqualStrings("event3", eventNameFromLinkTarget("/dev/input/event3").?);
    try std.testing.expectEqualStrings("event4", eventNameFromLinkTarget("event4").?);
}
