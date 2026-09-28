const std = @import("std");
const key = @import("../key.zig");
const output = @import("output.zig");

/// One keyboard we are reading events from.
pub const Device = struct {
    path: []u8,
    file: std.Io.File,
    state: key.State = .{},
};

/// Every keyboard that can trigger a recording. The set owns the device paths
/// and the open file descriptors; callers only borrow them.
pub const Set = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    devices: std.ArrayList(Device) = .empty,
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
            device.file.close(self.io);
            self.allocator.free(device.path);
        }
        self.devices.deinit(self.allocator);
        self.devices = .empty;
    }

    pub fn len(self: *const Set) usize {
        return self.devices.items.len;
    }

    /// Borrowed view of the devices (paths and files stay owned by the set).
    pub fn list(self: *const Set) []const Device {
        return self.devices.items;
    }

    pub fn hasPath(self: *const Set, path: []const u8) bool {
        for (self.devices.items) |device| {
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
};

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
