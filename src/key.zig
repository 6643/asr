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

pub const DeviceReadError = error{
    KeyboardDeviceDisconnected,
    EndOfStream,
    ReadFailed,
    /// Blocking read was interrupted by a signal or Io cancelation.
    /// Callers should check shutdown flags and either exit or retry.
    Interrupted,
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

    var saw_denied = false;
    const content = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/bus/input/devices", allocator, .limited(1024 * 1024));
    defer allocator.free(content);
    if (findKeyboardDeviceInProcInput(allocator, content)) |path| {
        switch (openDeviceState(io, path)) {
            .usable => return path,
            .denied => saw_denied = true,
            .missing => {},
        }
        allocator.free(path);
    }
    if (findKeyboardDeviceFromSymlinkDirs(allocator, io)) |path| {
        switch (openDeviceState(io, path)) {
            .usable => return path,
            .denied => saw_denied = true,
            .missing => {},
        }
        allocator.free(path);
    }
    return deviceSearchFailure(saw_denied);
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

pub fn waitForRelease(reader: *std.Io.Reader, state: *State, key_code: u16) !void {
    while (true) {
        const event = try readNextEvent(reader, state, key_code);
        if (event == .release) return;
    }
}

/// Predicate polled by Select arms that race against keyboard I/O.
pub const ShutdownCheck = *const fn () bool;

/// Read the next press/release for `key_code` via cancelable `Io` streaming read.
pub fn readNextDeviceEvent(
    io: std.Io,
    file: std.Io.File,
    state: *State,
    key_code: u16,
) DeviceReadError!Event {
    var buf: [input_event_size]u8 = undefined;
    while (true) {
        try readInputEvent(io, file, &buf);
        if (update(state, &buf, key_code)) |event| return event;
    }
}

pub fn waitForDeviceRelease(
    io: std.Io,
    file: std.Io.File,
    state: *State,
    key_code: u16,
) DeviceReadError!void {
    while (true) {
        const event = try readNextDeviceEvent(io, file, state, key_code);
        if (event == .release) return;
    }
}

pub const WaitOutcome = enum {
    released,
    shutdown,
    timed_out,
};

/// Decides how a hold ends; null means "keep waiting". A release or a shutdown
/// request always wins over the hold deadline.
pub fn holdStopReason(released: bool, stop: bool, elapsed_ms: i64, max_hold_ms: i64) ?WaitOutcome {
    if (released) return .released;
    if (stop) return .shutdown;
    if (max_hold_ms > 0 and elapsed_ms >= max_hold_ms) return .timed_out;
    return null;
}

/// Wait for key release, or stop early when `is_shutdown` becomes true, the read
/// is canceled, or the hold exceeds `max_hold_ms` (`<= 0` disables the cap).
pub fn waitForDeviceReleaseOrShutdown(
    io: std.Io,
    file: std.Io.File,
    state: *State,
    key_code: u16,
    is_shutdown: ShutdownCheck,
    max_hold_ms: i64,
) DeviceReadError!WaitOutcome {
    const start_ms = std.Io.Clock.real.now(io).toMilliseconds();
    while (true) {
        const deadline = remainingHoldMs(io, start_ms, max_hold_ms);
        const step = try waitNextStepOrStop(io, file, state, key_code, is_shutdown, deadline);
        const elapsed = std.Io.Clock.real.now(io).toMilliseconds() - start_ms;
        const outcome = switch (step) {
            .event => |event| holdStopReason(event == .release, false, elapsed, max_hold_ms),
            .stop => |reason| holdStopReason(false, reason == .shutdown, elapsed, max_hold_ms) orelse switch (reason) {
                .shutdown => WaitOutcome.shutdown,
                .timed_out => WaitOutcome.timed_out,
            },
        };
        if (outcome) |value| return value;
    }
}

/// Milliseconds left before the hold cap, or null when the cap is disabled.
fn remainingHoldMs(io: std.Io, start_ms: i64, max_hold_ms: i64) ?i64 {
    if (max_hold_ms <= 0) return null;
    return max_hold_ms - (std.Io.Clock.real.now(io).toMilliseconds() - start_ms);
}

const StopReason = enum { shutdown, timed_out };

const NextStep = union(enum) {
    event: Event,
    stop: StopReason,
};

/// Block until the next target-key event, or return `null` when stop is requested
/// (shutdown or Select cancelation).
pub fn waitNextDeviceEventOrShutdown(
    io: std.Io,
    file: std.Io.File,
    state: *State,
    key_code: u16,
    is_shutdown: ShutdownCheck,
) DeviceReadError!?Event {
    const step = try waitNextStepOrStop(io, file, state, key_code, is_shutdown, null);
    return switch (step) {
        .event => |event| event,
        .stop => null,
    };
}

fn waitNextStepOrStop(
    io: std.Io,
    file: std.Io.File,
    state: *State,
    key_code: u16,
    is_shutdown: ShutdownCheck,
    deadline_ms: ?i64,
) DeviceReadError!NextStep {
    if (is_shutdown()) return .{ .stop = .shutdown };

    const SelectResult = union(enum) {
        key: DeviceReadError!Event,
        stop: StopReason,
    };
    var slots: [2]SelectResult = undefined;
    var select = std.Io.Select(SelectResult).init(io, &slots);

    const key_args = ReadNextArgs{
        .io = io,
        .file = file,
        .state = state,
        .key_code = key_code,
    };
    select.concurrent(.key, readNextDeviceEventTask, .{key_args}) catch {
        select.async(.key, readNextDeviceEventTask, .{key_args});
    };
    select.concurrent(.stop, pollStopTask, .{ io, is_shutdown, deadline_ms }) catch {
        select.async(.stop, pollStopTask, .{ io, is_shutdown, deadline_ms });
    };

    const first = select.await() catch {
        // Select itself canceled: treat as shutdown wake.
        select.cancelDiscard();
        return .{ .stop = .shutdown };
    };
    // Cancel the loser; discard any late key result (no owned resources).
    select.cancelDiscard();

    return switch (first) {
        .key => |result| .{ .event = try result },
        .stop => |reason| .{ .stop = reason },
    };
}

const ReadNextArgs = struct {
    io: std.Io,
    file: std.Io.File,
    state: *State,
    key_code: u16,
};

fn readNextDeviceEventTask(args: ReadNextArgs) DeviceReadError!Event {
    return readNextDeviceEvent(args.io, args.file, args.state, args.key_code);
}

fn pollStopTask(io: std.Io, is_shutdown: ShutdownCheck, deadline_ms: ?i64) StopReason {
    const start_ms = std.Io.Clock.real.now(io).toMilliseconds();
    while (true) {
        if (is_shutdown()) return .shutdown;
        if (deadline_ms) |limit| {
            if (std.Io.Clock.real.now(io).toMilliseconds() - start_ms >= limit) return .timed_out;
        }
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch return .shutdown;
    }
}

fn readInputEvent(io: std.Io, file: std.Io.File, buf: *[input_event_size]u8) DeviceReadError!void {
    var offset: usize = 0;
    while (offset < buf.len) {
        const n = readDeviceBytes(io, file, buf[offset..]) catch |err| return err;
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

fn readDeviceBytes(io: std.Io, file: std.Io.File, dest: []u8) DeviceReadError!usize {
    if (dest.len == 0) return 0;
    // Prefer cancelable Io streaming read so Select cancel / task cancel wakes us.
    const n = file.readStreaming(io, &.{dest}) catch |err| {
        return mapReadStreamingError(err);
    };
    return n;
}

fn mapReadStreamingError(err: anyerror) DeviceReadError {
    return switch (err) {
        error.Canceled => error.Interrupted,
        error.EndOfStream => error.EndOfStream,
        error.IsDir,
        error.NotOpenForReading,
        error.WouldBlock,
        error.InputOutput,
        error.SystemResources,
        error.SocketUnconnected,
        error.ConnectionResetByPeer,
        error.AccessDenied,
        error.LockViolation,
        error.Unexpected,
        => error.ReadFailed,
        else => error.ReadFailed,
    };
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

/// How a candidate keyboard device responded to being opened.
pub const DeviceOpen = enum { usable, missing, denied };

pub fn classifyDeviceOpenError(err: anyerror) DeviceOpen {
    return switch (err) {
        error.AccessDenied => .denied,
        else => .missing,
    };
}

pub fn openDeviceState(io: std.Io, path: []const u8) DeviceOpen {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| return classifyDeviceOpenError(err);
    file.close(io);
    return .usable;
}

/// Distinguishes "no keyboard at all" from "keyboards exist but we may not
/// read them": the fixes are different (plug one in vs join the input group).
pub fn deviceSearchFailure(saw_denied: bool) error{ KeyboardDeviceNotFound, KeyboardPermissionDenied } {
    return if (saw_denied) error.KeyboardPermissionDenied else error.KeyboardDeviceNotFound;
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

test "waits for release on the same event reader" {
    const down = inputEvent(ev_key, right_alt, 1);
    const other = inputEvent(ev_key, right_alt + 1, 1);
    const up = inputEvent(ev_key, right_alt, 0);
    const bytes = down ++ other ++ up;

    var reader: std.Io.Reader = .fixed(&bytes);
    var state: State = .{};

    try std.testing.expectEqual(Event.press, try readNextEvent(&reader, &state, right_alt));
    try waitForRelease(&reader, &state, right_alt);
    try std.testing.expectEqual(@as(u32, 0), state.key_state);
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

test "device read error set includes Interrupted for cancel/signal wakeups" {
    const err: DeviceReadError = error.Interrupted;
    try std.testing.expect(err == error.Interrupted);
}

test "maps Io cancelation to Interrupted" {
    try std.testing.expectEqual(DeviceReadError.Interrupted, mapReadStreamingError(error.Canceled));
    try std.testing.expectEqual(DeviceReadError.EndOfStream, mapReadStreamingError(error.EndOfStream));
    try std.testing.expectEqual(DeviceReadError.ReadFailed, mapReadStreamingError(error.InputOutput));
}

test "classifies device open errors" {
    try std.testing.expectEqual(DeviceOpen.denied, classifyDeviceOpenError(error.AccessDenied));
    try std.testing.expectEqual(DeviceOpen.missing, classifyDeviceOpenError(error.FileNotFound));
    try std.testing.expectEqual(DeviceOpen.missing, classifyDeviceOpenError(error.IsDir));
}

test "unreadable input device is reported as denied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "dev", .{ .permissions = .fromMode(0o000) });
    file.close(std.testing.io);
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "dev" });
    defer std.testing.allocator.free(path);

    if (openDeviceState(std.testing.io, path) == .usable) return error.SkipZigTest; // root 下权限位无效

    try std.testing.expectEqual(DeviceOpen.denied, openDeviceState(std.testing.io, path));
}

test "device search failure names the permission problem" {
    try std.testing.expectEqual(error.KeyboardPermissionDenied, deviceSearchFailure(true));
    try std.testing.expectEqual(error.KeyboardDeviceNotFound, deviceSearchFailure(false));
}

test "hold stop reason prefers release, then shutdown, then the deadline" {
    try std.testing.expectEqual(WaitOutcome.released, holdStopReason(true, false, 0, 1000).?);
    try std.testing.expectEqual(WaitOutcome.shutdown, holdStopReason(false, true, 0, 1000).?);
    try std.testing.expectEqual(WaitOutcome.timed_out, holdStopReason(false, false, 1000, 1000).?);
    try std.testing.expectEqual(WaitOutcome.timed_out, holdStopReason(false, false, 1500, 1000).?);
    try std.testing.expect(holdStopReason(false, false, 1000, 0) == null); // 0 = 不限时
    try std.testing.expect(holdStopReason(false, false, 999, 1000) == null);
}
