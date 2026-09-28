const std = @import("std");
const key = @import("../key.zig");
const output = @import("output.zig");

/// One keyboard we are reading events from.
///
/// A device whose reads failed is marked `dead` instead of being unlinked right
/// away: pending read arms hold pointers into the device array, so entries are
/// only dropped at safe points (`compact`).
pub const Device = struct {
    path: []u8,
    file: std.Io.File,
    state: key.State = .{},
    dead: bool = false,
};

/// Why a wait for keyboard input ended without an event.
pub const StopReason = enum { shutdown, rescan };

/// How many keyboards we watch at once. Real desks have one or two; the cap
/// keeps the wait path allocation free and bounds the Select slot buffer.
pub const max_devices: usize = 8;

pub const Outcome = union(enum) { event: DeviceEvent, stop: StopReason };

/// A hotkey event together with the keyboard it came from. The device pointer
/// stays valid while the set is alive; callers must not keep it across a reset
/// of the device list (removals only happen at safe points and never during a
/// recording).
pub const DeviceEvent = struct {
    kind: key.Event,
    device: *Device,
};

/// Supplies the keyboard candidates to re-scan: the app wires this to
/// `key.findKeyboardDevices`. Errors are logged and ignored so a transient
/// failure never kills a running session.
pub const CandidatesFn = *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![][]u8;

/// Every keyboard that can trigger a recording. The set owns the device paths
/// and the open file descriptors; callers only borrow them.
pub const Set = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    devices: std.ArrayList(Device) = .empty,
    /// Device that started the current recording: only its release ends it.
    active_handle: ?std.posix.fd_t = null,
    /// How often the caller re-scans for keyboards while waiting.
    rescan_interval_ms: i64 = 2_000,

    /// Opens every candidate that we may read. Unreadable candidates are logged
    /// and skipped; when nothing is left the caller gets the same "no keyboard"
    /// vs "no permission" split that discovery uses.
    pub fn openAll(
        allocator: std.mem.Allocator,
        io: std.Io,
        logger: output.Logger,
        paths: []const []const u8,
    ) !Set {
        var set: Set = .{ .allocator = allocator, .io = io, .logger = logger };
        errdefer set.closeAll();

        var saw_denied = false;
        for (paths) |path| {
            const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
                if (key.classifyDeviceOpenError(err) == .denied) saw_denied = true;
                logger.err("kbd", "{s}: {s}", .{ path, @errorName(err) });
                continue;
            };
            const owned = try allocator.dupe(u8, path);
            set.devices.append(allocator, .{ .path = owned, .file = file }) catch |err| {
                allocator.free(owned);
                file.close(io);
                return err;
            };
            logger.info("kbd", "{s}", .{path});
        }
        if (set.devices.items.len == 0) return key.deviceSearchFailure(saw_denied);
        return set;
    }

    /// Takes over already-open devices (tests, hot-plug rescan).
    pub fn adopt(allocator: std.mem.Allocator, io: std.Io, logger: output.Logger, devices: []const Device) Set {
        var set: Set = .{ .allocator = allocator, .io = io, .logger = logger };
        set.devices.appendSlice(allocator, devices) catch unreachable;
        return set;
    }

    pub fn closeAll(self: *Set) void {
        for (self.devices.items) |device| {
            // Dead devices had their fd closed when they failed.
            if (!device.dead) device.file.close(self.io);
            self.allocator.free(device.path);
        }
        self.devices.deinit(self.allocator);
        self.devices = .empty;
    }

    pub fn len(self: *const Set) usize {
        var live: usize = 0;
        for (self.devices.items) |device| {
            if (!device.dead) live += 1;
        }
        return live;
    }

    /// Borrowed view of the devices (paths and files stay owned by the set).
    pub fn list(self: *const Set) []const Device {
        return self.devices.items;
    }

    pub fn hasPath(self: *const Set, path: []const u8) bool {
        for (self.devices.items) |device| {
            if (device.dead) continue;
            if (std.mem.eql(u8, device.path, path)) return true;
        }
        return false;
    }

    /// Adds one device, taking ownership of the file descriptor.
    pub fn add(self: *Set, path: []const u8, file: std.Io.File) !void {
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.devices.append(self.allocator, .{ .path = owned, .file = file });
    }

    /// Waits for the next hotkey event from any keyboard.
    ///
    /// "Who pressed it, releases it": the device that reports the press owns the
    /// recording, only its release ends it, and events from other keyboards are
    /// dropped with a debug log. A device that dies is removed from the set; if
    /// it owned the recording the caller still gets a release so a capture can
    /// never be stuck. Rescans add keyboards that appeared later and never
    /// interrupt an active recording.
    pub fn readNextOrShutdown(
        self: *Set,
        key_code: u16,
        is_shutdown: key.ShutdownCheck,
        candidates: ?CandidatesFn,
        ctx: ?*anyopaque,
    ) key.DeviceReadError!Outcome {
        while (true) {
            if (is_shutdown()) return .{ .stop = .shutdown };
            self.compact();

            const watched = @min(self.devices.items.len, max_devices);
            var slots_buffer: [max_devices + 1]Arm = undefined;
            var select = std.Io.Select(Arm).init(self.io, slots_buffer[0 .. watched + 1]);
            var armed: usize = 0;
            for (self.devices.items) |*device| {
                if (device.dead) continue;
                if (armed == watched) {
                    self.logger.err("kbd", "not watching {s}: too many keyboards", .{device.path});
                    continue;
                }
                addDeviceArm(&select, self.io, device, key_code);
                armed += 1;
            }
            addTimerArm(&select, self.io, is_shutdown, self.rescan_interval_ms);

            var rebuild = false;
            while (!rebuild) {
                const first = select.await() catch {
                    select.cancelDiscard();
                    return .{ .stop = .shutdown };
                };
                switch (first) {
                    .device => |arm| {
                        const index = self.indexByHandle(arm.handle) orelse continue;
                        if (arm.result) |event| {
                            switch (event) {
                                .press => {
                                    if (self.active_handle != null) {
                                        self.logIgnored(index);
                                        // Keep watching the ignored keyboard.
                                        addDeviceArm(&select, self.io, &self.devices.items[index], key_code);
                                        continue;
                                    }
                                    self.active_handle = arm.handle;
                                    select.cancelDiscard();
                                    return .{ .event = .{ .kind = .press, .device = &self.devices.items[index] } };
                                },
                                .release => {
                                    const active = self.active_handle orelse {
                                        self.logIgnored(index);
                                        addDeviceArm(&select, self.io, &self.devices.items[index], key_code);
                                        continue;
                                    };
                                    if (active != arm.handle) {
                                        self.logIgnored(index);
                                        addDeviceArm(&select, self.io, &self.devices.items[index], key_code);
                                        continue;
                                    }
                                    self.active_handle = null;
                                    select.cancelDiscard();
                                    return .{ .event = .{ .kind = .release, .device = &self.devices.items[index] } };
                                },
                            }
                        } else |err| {
                            switch (err) {
                                // A canceled read is not a dead device: watch again.
                                error.Interrupted => {
                                    addDeviceArm(&select, self.io, &self.devices.items[index], key_code);
                                    continue;
                                },
                                else => {
                                    const owned_recording = self.active_handle == arm.handle;
                                    self.logRemoved(index, err);
                                    self.killDevice(index);
                                    if (owned_recording) {
                                        self.active_handle = null;
                                        select.cancelDiscard();
                                        return .{ .event = .{ .kind = .release, .device = &self.devices.items[index] } };
                                    }
                                    continue;
                                },
                            }
                        }
                    },
                    .timer => |reason| switch (reason) {
                        .shutdown => {
                            select.cancelDiscard();
                            return .{ .stop = .shutdown };
                        },
                        .rescan => {
                            // Never rebuild the arm set mid-recording: that would
                            // cancel a pending read and could drop the release.
                            if (self.active_handle != null) {
                                addTimerArm(&select, self.io, is_shutdown, self.rescan_interval_ms);
                                continue;
                            }
                            if (self.rescanAddsDevices(candidates, ctx)) {
                                rebuild = true;
                            } else {
                                addTimerArm(&select, self.io, is_shutdown, self.rescan_interval_ms);
                            }
                        },
                    },
                }
            }
            select.cancelDiscard();
        }
    }

    /// Ends the current recording.
    ///
    /// The release is consumed by the capture loop, not by `readNextOrShutdown`,
    /// so the caller has to say when a recording is over. Every keyboard is
    /// drained first: presses that arrived while the owner was recording must
    /// not start a new recording afterwards.
    pub fn endRecording(self: *Set, key_code: u16) void {
        for (self.devices.items) |*device| {
            if (device.dead) continue;
            drainDevice(device.file, &device.state, key_code, self.logger);
        }
        self.active_handle = null;
    }

    /// Opens and adds candidates the set does not know yet. Returns true when
    /// something was added, which tells the caller to rebuild its wait arms.
    pub fn rescanAddsDevices(self: *Set, candidates: ?CandidatesFn, ctx: ?*anyopaque) bool {
        const scan = candidates orelse return false;
        const paths = scan(ctx, self.allocator, self.io) catch |err| {
            self.logger.err("kbd", "rescan failed: {s}", .{@errorName(err)});
            return false;
        };
        defer key.freeDeviceList(self.allocator, paths);

        var added = false;
        for (paths) |path| {
            if (self.hasPath(path)) continue;
            if (self.len() >= max_devices) {
                self.logger.err("kbd", "not watching {s}: too many keyboards", .{path});
                continue;
            }
            const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| {
                self.logger.err("kbd", "{s}: {s}", .{ path, @errorName(err) });
                continue;
            };
            self.add(path, file) catch |err| {
                file.close(self.io);
                self.logger.err("kbd", "{s}: {s}", .{ path, @errorName(err) });
                continue;
            };
            self.logger.info("kbd", "added {s}", .{path});
            added = true;
        }
        return added;
    }

    fn indexByHandle(self: *const Set, handle: std.posix.fd_t) ?usize {
        for (self.devices.items, 0..) |device, index| {
            if (device.file.handle == handle) return index;
        }
        return null;
    }

    /// Stops using a device without unlinking it: pending arms may still hold
    /// pointers into the device array. `compact` drops the entries later.
    fn killDevice(self: *Set, index: usize) void {
        const device = &self.devices.items[index];
        if (device.dead) return;
        device.dead = true;
        device.file.close(self.io);
    }

    /// Drops dead devices. Only called when no read arm is pending.
    fn compact(self: *Set) void {
        var index: usize = 0;
        while (index < self.devices.items.len) {
            if (!self.devices.items[index].dead) {
                index += 1;
                continue;
            }
            const device = self.devices.orderedRemove(index);
            self.allocator.free(device.path);
        }
    }

    fn logIgnored(self: *const Set, index: usize) void {
        self.logger.debug("kbd", "ignored event from {s}", .{self.devices.items[index].path});
    }

    fn logRemoved(self: *const Set, index: usize, err: key.DeviceReadError) void {
        self.logger.err("kbd", "{s}: {s}; removed", .{ self.devices.items[index].path, @errorName(err) });
    }
};

const DeviceArm = struct {
    handle: std.posix.fd_t,
    result: key.DeviceReadError!key.Event,
};

const Arm = union(enum) {
    device: DeviceArm,
    timer: StopReason,
};

const ArmSelect = std.Io.Select(Arm);

const DeviceArmArgs = struct {
    io: std.Io,
    file: std.Io.File,
    state: *key.State,
    key_code: u16,
};

fn deviceArmTask(args: DeviceArmArgs) DeviceArm {
    return .{
        .handle = args.file.handle,
        .result = key.readNextDeviceEvent(args.io, args.file, args.state, args.key_code),
    };
}

/// Resolves to `.shutdown` as soon as shutdown is requested, `.rescan` every
/// `interval_ms` so the caller can look for new keyboards.
fn timerTask(io: std.Io, is_shutdown: key.ShutdownCheck, interval_ms: i64) StopReason {
    const start_ms = std.Io.Clock.real.now(io).toMilliseconds();
    while (true) {
        if (is_shutdown()) return .shutdown;
        if (std.Io.Clock.real.now(io).toMilliseconds() - start_ms >= interval_ms) return .rescan;
        std.Io.sleep(io, .fromMilliseconds(25), .awake) catch return .shutdown;
    }
}

fn addDeviceArm(select: *ArmSelect, io: std.Io, device: *Device, key_code: u16) void {
    const args = DeviceArmArgs{ .io = io, .file = device.file, .state = &device.state, .key_code = key_code };
    select.concurrent(.device, deviceArmTask, .{args}) catch {
        select.async(.device, deviceArmTask, .{args});
    };
}

fn addTimerArm(select: *ArmSelect, io: std.Io, is_shutdown: key.ShutdownCheck, interval_ms: i64) void {
    select.concurrent(.timer, timerTask, .{ io, is_shutdown, interval_ms }) catch {
        select.async(.timer, timerTask, .{ io, is_shutdown, interval_ms });
    };
}

/// Reads everything already buffered on one keyboard without blocking: events
/// that piled up while another keyboard owned the recording.
fn drainDevice(file: std.Io.File, state: *key.State, key_code: u16, logger: output.Logger) void {
    const fd = file.handle;
    const system = std.posix.system;
    const orig_flags = system.fcntl(fd, system.F.GETFL, @as(usize, 0));
    if (orig_flags < 0) return;
    const nonblock_flag = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = system.fcntl(fd, system.F.SETFL, @as(usize, @intCast(orig_flags)) | nonblock_flag);
    var buf: [key.input_event_size]u8 = undefined;
    var drained: usize = 0;
    while (true) {
        const rc = system.read(fd, &buf, buf.len);
        if (rc <= 0) break;
        _ = key.update(state, buf[0..@as(usize, @intCast(rc))], key_code);
        drained += 1;
    }
    _ = system.fcntl(fd, system.F.SETFL, @as(usize, @intCast(orig_flags)));
    if (drained > 0) logger.debug("kbd", "drained {d} buffered events", .{drained});
}

/// Plays the role of a keyboard device in tests: writing to the returned write
/// fd makes the read fd ready, closing it looks like an unplug, and an empty
/// pipe blocks exactly like a keyboard nobody is touching.
pub const FakeDevice = struct {
    file: std.Io.File,
    write_fd: std.posix.fd_t,

    pub fn init() !FakeDevice {
        var fds: [2]i32 = undefined;
        const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
        if (std.posix.errno(rc) != .SUCCESS) return error.PipeFailed;
        return .{ .file = .{ .handle = fds[0], .flags = .{ .nonblocking = false } }, .write_fd = fds[1] };
    }

    pub fn send(self: *const FakeDevice, event_type: u16, code: u16, value: u32) void {
        const event = key.inputEvent(event_type, code, value);
        _ = std.posix.system.write(self.write_fd, &event, event.len);
    }

    /// Sends a key press (value 1) or release (value 0).
    pub fn sendKey(self: *const FakeDevice, code: u16, value: u32) void {
        self.send(key.ev_key, code, value);
    }

    /// Simulates the device disappearing: the read side sees end of stream.
    pub fn unplug(self: *const FakeDevice) void {
        _ = std.posix.system.close(self.write_fd);
    }
};

/// Path label for a fake device; the set only uses it for logging and identity.
pub fn fakePath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/fake/{s}", .{name});
}

test "adopts devices and reports their paths" {
    const allocator = std.testing.allocator;
    const logger: output.Logger = .{ .io = std.testing.io, .level = .err };

    var fake = try FakeDevice.init();
    defer fake.unplug();
    const path = try fakePath(allocator, "a");

    var set = Set.adopt(allocator, std.testing.io, logger, &.{
        .{ .path = path, .file = fake.file },
    });
    defer set.closeAll();

    try std.testing.expectEqual(@as(usize, 1), set.len());
    try std.testing.expect(set.hasPath("/fake/a"));
    try std.testing.expect(!set.hasPath("/dev/input/event99"));
}

test "openAll skips unreadable candidates and logs them" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const good = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "good.event" });
    defer allocator.free(good);
    var created = try std.Io.Dir.cwd().createFile(std.testing.io, good, .{});
    created.close(std.testing.io);

    const log_path = "/tmp/asr-keyboard-set.log";
    var log_file = try output.LogFile.open(log_path);
    defer log_file.deinit();
    const logger: output.Logger = .{ .io = std.testing.io, .level = .debug, .log_file = &log_file };

    var set = try Set.openAll(allocator, std.testing.io, logger, &.{ good, "/tmp/asr-missing-keyboard" });
    defer set.closeAll();

    try std.testing.expectEqual(@as(usize, 1), set.len());
    try std.testing.expect(set.hasPath(good));

    const logged = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, allocator, .limited(8192));
    defer allocator.free(logged);
    try std.testing.expect(std.mem.indexOf(u8, logged, "asr-missing-keyboard") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "good.event") != null);
}

test "openAll reports when nothing could be opened" {
    const allocator = std.testing.allocator;
    const logger: output.Logger = .{ .io = std.testing.io, .level = .err };
    try std.testing.expectError(
        error.KeyboardDeviceNotFound,
        Set.openAll(allocator, std.testing.io, logger, &.{"/tmp/asr-missing-keyboard"}),
    );
}

test "closeAll releases the devices" {
    const allocator = std.testing.allocator;
    const logger: output.Logger = .{ .io = std.testing.io, .level = .err };

    var fake = try FakeDevice.init();
    defer fake.unplug();
    const path = try fakePath(allocator, "b");

    var set = Set.adopt(allocator, std.testing.io, logger, &.{
        .{ .path = path, .file = fake.file },
    });
    set.closeAll();

    try std.testing.expectEqual(@as(usize, 0), set.len());
}

fn neverShutdown() bool {
    return false;
}

fn alwaysShutdown() bool {
    return true;
}

var shutdown_call_limit: usize = 0;
var shutdown_call_count: usize = 0;

/// Flips to shutdown after the timer task has polled a few times, so the test
/// covers "shutdown arrives while we are waiting".
fn shutdownAfterPolls() bool {
    shutdown_call_count += 1;
    return shutdown_call_count > shutdown_call_limit;
}

const RescanCtx = struct {
    paths: []const []const u8,
};

fn rescanCandidates(ctx: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!([][]u8) {
    _ = io;
    const source: *const RescanCtx = @ptrCast(@alignCast(ctx.?));
    const paths = try allocator.alloc([]u8, source.paths.len);
    errdefer allocator.free(paths);
    for (source.paths, 0..) |path, index| paths[index] = try allocator.dupe(u8, path);
    return paths;
}

/// Builds a set with two fake keyboards and hands back their paths.
fn twoFakeKeyboards(allocator: std.mem.Allocator, logger: output.Logger, a: *FakeDevice, b: *FakeDevice) !Set {
    const path_a = try fakePath(allocator, "a");
    const path_b = try fakePath(allocator, "b");
    return Set.adopt(allocator, std.testing.io, logger, &.{
        .{ .path = path_a, .file = a.file },
        .{ .path = path_b, .file = b.file },
    });
}

test "stops immediately when shutdown is already requested" {
    const allocator = std.testing.allocator;
    var a = try FakeDevice.init();
    defer a.unplug();
    var b = try FakeDevice.init();
    defer b.unplug();

    var set = try twoFakeKeyboards(allocator, .{ .io = std.testing.io, .level = .err }, &a, &b);
    defer set.closeAll();

    const outcome = try set.readNextOrShutdown(key.right_alt, alwaysShutdown, null, null);
    try std.testing.expectEqual(StopReason.shutdown, outcome.stop);
}

test "stops when shutdown arrives while waiting" {
    const allocator = std.testing.allocator;
    var a = try FakeDevice.init();
    defer a.unplug();
    var b = try FakeDevice.init();
    defer b.unplug();

    var set = try twoFakeKeyboards(allocator, .{ .io = std.testing.io, .level = .err }, &a, &b);
    defer set.closeAll();

    shutdown_call_limit = 2;
    shutdown_call_count = 0;

    const outcome = try set.readNextOrShutdown(key.right_alt, shutdownAfterPolls, null, null);
    try std.testing.expectEqual(StopReason.shutdown, outcome.stop);
    try std.testing.expect(shutdown_call_count > 2);
}

test "reports a press from any keyboard" {
    const allocator = std.testing.allocator;
    var a = try FakeDevice.init();
    defer a.unplug();
    var b = try FakeDevice.init();
    defer b.unplug();

    var set = try twoFakeKeyboards(allocator, .{ .io = std.testing.io, .level = .err }, &a, &b);
    defer set.closeAll();

    b.sendKey(key.right_alt, 1);

    const outcome = try set.readNextOrShutdown(key.right_alt, neverShutdown, null, null);
    try std.testing.expectEqual(key.Event.press, outcome.event.kind);
}

test "ignores other keyboards while a recording is owned" {
    const allocator = std.testing.allocator;
    var a = try FakeDevice.init();
    defer a.unplug();
    var b = try FakeDevice.init();
    defer b.unplug();

    const log_path = "/tmp/asr-keyboard-owned.log";
    var log_file = try output.LogFile.open(log_path);
    defer log_file.deinit();
    const logger: output.Logger = .{ .io = std.testing.io, .level = .debug, .log_file = &log_file };

    var set = try twoFakeKeyboards(allocator, logger, &a, &b);
    defer set.closeAll();

    // a owns the recording
    a.sendKey(key.right_alt, 1);
    const press = try set.readNextOrShutdown(key.right_alt, neverShutdown, null, null);
    try std.testing.expectEqual(key.Event.press, press.event.kind);
    try std.testing.expectEqual(a.file.handle, set.active_handle.?);

    // b presses while a owns the recording: ignored, so the wait keeps blocking
    // until the (simulated) shutdown instead of reporting b's press.
    b.sendKey(key.right_alt, 1);
    shutdown_call_limit = 2;
    shutdown_call_count = 0;
    const ignored = try set.readNextOrShutdown(key.right_alt, shutdownAfterPolls, null, null);
    try std.testing.expectEqual(StopReason.shutdown, ignored.stop);

    const logged = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, allocator, .limited(8192));
    defer allocator.free(logged);
    try std.testing.expect(std.mem.indexOf(u8, logged, "ignored event from /fake/b") != null);

    // b releases and a releases: only a's release may end it
    b.sendKey(key.right_alt, 0);
    a.sendKey(key.right_alt, 0);

    const release = try set.readNextOrShutdown(key.right_alt, neverShutdown, null, null);
    try std.testing.expectEqual(key.Event.release, release.event.kind);
    try std.testing.expect(set.active_handle == null);
}

test "a dead keyboard that owns the recording ends it and is dropped" {
    const allocator = std.testing.allocator;
    var a = try FakeDevice.init();
    defer a.unplug();
    var b = try FakeDevice.init();
    defer b.unplug();

    var set = try twoFakeKeyboards(allocator, .{ .io = std.testing.io, .level = .err }, &a, &b);
    defer set.closeAll();

    a.sendKey(key.right_alt, 1);
    const press = try set.readNextOrShutdown(key.right_alt, neverShutdown, null, null);
    try std.testing.expectEqual(key.Event.press, press.event.kind);

    // unplugging a ends the recording instead of hanging in "recording"
    a.unplug();
    const release = try set.readNextOrShutdown(key.right_alt, neverShutdown, null, null);
    try std.testing.expectEqual(key.Event.release, release.event.kind);
    try std.testing.expect(set.active_handle == null);
    try std.testing.expectEqual(@as(usize, 1), set.len());
    try std.testing.expect(!set.hasPath("/fake/a"));
    try std.testing.expect(set.hasPath("/fake/b"));
}

test "rescan adds new keyboards once and ignores failures" {
    const allocator = std.testing.allocator;
    var a = try FakeDevice.init();
    defer a.unplug();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const new_device = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "new.event" });
    defer allocator.free(new_device);
    var created = try std.Io.Dir.cwd().createFile(std.testing.io, new_device, .{});
    created.close(std.testing.io);

    const log_path = "/tmp/asr-keyboard-rescan.log";
    var log_file = try output.LogFile.open(log_path);
    defer log_file.deinit();
    const logger: output.Logger = .{ .io = std.testing.io, .level = .debug, .log_file = &log_file };

    const path_a = try fakePath(allocator, "a");
    var set = Set.adopt(allocator, std.testing.io, logger, &.{
        .{ .path = path_a, .file = a.file },
    });
    defer set.closeAll();

    var ctx = RescanCtx{ .paths = &.{ new_device, "/tmp/asr-missing-keyboard", new_device } };
    try std.testing.expect(set.rescanAddsDevices(rescanCandidates, &ctx));

    try std.testing.expectEqual(@as(usize, 2), set.len());
    try std.testing.expect(set.hasPath(new_device));
    try std.testing.expect(set.hasPath("/fake/a"));

    // nothing new the second time
    try std.testing.expect(!set.rescanAddsDevices(rescanCandidates, &ctx));
    try std.testing.expectEqual(@as(usize, 2), set.len());

    const logged = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, log_path, allocator, .limited(8192));
    defer allocator.free(logged);
    try std.testing.expect(std.mem.indexOf(u8, logged, "added ") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "asr-missing-keyboard") != null);
}
