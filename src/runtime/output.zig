const std = @import("std");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
};

/// Append-only log sink. `--log-file` must never truncate an earlier run's log
/// (a plain shell redirect to a file does), so the fd is opened with O_APPEND.
pub const LogFile = struct {
    fd: std.posix.fd_t,

    pub fn open(path: []const u8) !LogFile {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        }, 0o644);
        return .{ .fd = fd };
    }

    pub fn writeLine(log_file: *LogFile, line: []const u8) void {
        var written: usize = 0;
        while (written < line.len) {
            const rc = std.posix.system.write(log_file.fd, line.ptr + written, line.len - written);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return;
                    written += @intCast(rc);
                },
                .INTR => continue,
                else => return,
            }
        }
    }

    pub fn deinit(log_file: *LogFile) void {
        _ = std.posix.system.close(log_file.fd);
    }
};

pub const Logger = struct {
    io: std.Io,
    level: Level = .info,
    /// When set, every line goes here instead of stdout/stderr.
    log_file: ?*LogFile = null,

    pub fn info(logger: Logger, domain: []const u8, comptime fmt: []const u8, args: anytype) void {
        logger.write(.info, domain, fmt, args);
    }

    pub fn debug(logger: Logger, domain: []const u8, comptime fmt: []const u8, args: anytype) void {
        logger.write(.debug, domain, fmt, args);
    }

    pub fn err(logger: Logger, domain: []const u8, comptime fmt: []const u8, args: anytype) void {
        logger.write(.err, domain, fmt, args);
    }

    pub fn write(logger: Logger, level: Level, domain: []const u8, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) > @intFromEnum(logger.level)) return;
        var buffer: [1024]u8 = undefined;
        if (logger.log_file) |log_file| {
            const line = std.fmt.bufPrint(&buffer, "{s} [{s}] " ++ fmt ++ "\n", .{ timestamp(logger.io), domain } ++ args) catch return;
            log_file.writeLine(line);
            return;
        }
        var file_writer = if (level == .err)
            std.Io.File.stderr().writer(logger.io, &buffer)
        else
            std.Io.File.stdout().writer(logger.io, &buffer);
        file_writer.interface.print("{s} [{s}] " ++ fmt ++ "\n", .{ timestamp(logger.io), domain } ++ args) catch {};
        file_writer.interface.flush() catch {};
    }
};

fn timestamp(io: std.Io) [12]u8 {
    const now = std.Io.Clock.real.now(io);
    const raw_seconds = now.toSeconds();
    const raw_milliseconds = now.toMilliseconds();
    const seconds: u64 = if (raw_seconds < 0) 0 else @intCast(raw_seconds);
    const milliseconds: u16 = if (raw_milliseconds < 0)
        0
    else
        @intCast(@mod(raw_milliseconds, 1000));
    return formatTimeOfDay(seconds, milliseconds);
}

fn formatTimeOfDay(seconds: u64, milliseconds: u16) [12]u8 {
    const day_secs = (std.time.epoch.EpochSeconds{ .secs = seconds }).getDaySeconds();
    var out: [12]u8 = undefined;
    _ = std.fmt.bufPrint(
        &out,
        "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
        .{
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
            milliseconds,
        },
    ) catch unreachable;
    return out;
}

pub fn keyWait(logger: Logger) void {
    logger.debug("kbd", "wait down RightAlt", .{});
}

pub fn keyEvent(logger: Logger, event: @import("../key.zig").Event) void {
    switch (event) {
        .press => logger.info("kbd", "down RightAlt", .{}),
        .release => logger.info("kbd", "up RightAlt", .{}),
    }
}

test "formats timestamp" {
    try std.testing.expectEqual(@as(usize, 12), timestamp(std.testing.io).len);
}

test "formats time of day with zero padding" {
    try std.testing.expectEqualStrings("00:00:00.000", &formatTimeOfDay(0, 0));
    try std.testing.expectEqualStrings("01:01:01.007", &formatTimeOfDay(3661, 7));
    try std.testing.expectEqualStrings("23:59:59.999", &formatTimeOfDay(86399, 999));
}

fn tempLogPath(tmp: *std.testing.TmpDir) ![]u8 {
    return std.fs.path.join(std.testing.allocator, &.{ ".zig-cache/tmp", tmp.sub_path[0..], "asr.log" });
}

test "log file appends every line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempLogPath(&tmp);
    defer std.testing.allocator.free(path);

    var first = try LogFile.open(path);
    first.writeLine("one\n");
    first.deinit();
    var second = try LogFile.open(path);
    second.writeLine("two\n");
    second.deinit();

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("one\ntwo\n", contents);
}

test "logger writes to the log file instead of the terminal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tempLogPath(&tmp);
    defer std.testing.allocator.free(path);

    var log_file = try LogFile.open(path);
    const logger = Logger{ .io = std.testing.io, .level = .debug, .log_file = &log_file };
    logger.info("app", "hello {d}", .{7});
    logger.debug("app", "ignored at info level? no, debug is on", .{});
    log_file.deinit();

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "[app] hello 7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "[app] ignored at info level? no, debug is on\n") != null);
}
