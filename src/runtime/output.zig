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

/// `struct tm` as glibc and musl lay it out; only `tm_gmtoff` is read.
const c_tm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};

extern "c" fn localtime_r(timep: *const c_long, result: *c_tm) ?*c_tm;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn tzset() void;

fn timestamp(io: std.Io) [12]u8 {
    const now = std.Io.Clock.real.now(io);
    const raw_seconds = now.toSeconds();
    const raw_milliseconds = now.toMilliseconds();
    const seconds: i64 = if (raw_seconds < 0) 0 else raw_seconds;
    const milliseconds: u16 = if (raw_milliseconds < 0)
        0
    else
        @intCast(@mod(raw_milliseconds, 1000));
    return formatTimeOfDayShifted(seconds, milliseconds, localOffsetSeconds(seconds));
}

/// The machine's UTC offset at `epoch_seconds`, so log lines carry local wall
/// clock time. libc applies `TZ` (including DST); 0 (UTC) when it cannot answer.
fn localOffsetSeconds(epoch_seconds: i64) i32 {
    var time: c_long = @intCast(epoch_seconds);
    var result: c_tm = .{};
    const tm = localtime_r(&time, &result) orelse return 0;
    return @intCast(tm.tm_gmtoff);
}

/// `HH:MM:SS.mmm` for `epoch_seconds` in a zone `offset_seconds` east of UTC.
/// Only the time of day is printed, so the day itself is normalized away.
fn formatTimeOfDayShifted(epoch_seconds: i64, milliseconds: u16, offset_seconds: i32) [12]u8 {
    const seconds_in_day: i64 = 24 * 60 * 60;
    const shifted = @mod(epoch_seconds + @as(i64, offset_seconds), seconds_in_day);
    const seconds: u64 = @intCast(shifted);
    var out: [12]u8 = undefined;
    _ = std.fmt.bufPrint(
        &out,
        "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
        .{
            seconds / 3600,
            (seconds % 3600) / 60,
            seconds % 60,
            milliseconds,
        },
    ) catch unreachable;
    return out;
}

pub fn keyWait(logger: Logger) void {
    logger.debug("kbd", "wait down RightAlt", .{});
}

/// Key phase the app wants to log. Kept here (instead of importing the evdev
/// key module) so the logger stays a leaf with no runtime dependencies.
pub const KeyEvent = enum { press, release };

pub fn keyEvent(logger: Logger, event: KeyEvent) void {
    switch (event) {
        .press => logger.info("kbd", "down RightAlt", .{}),
        .release => logger.info("kbd", "up RightAlt", .{}),
    }
}

test "formats timestamp" {
    try std.testing.expectEqual(@as(usize, 12), timestamp(std.testing.io).len);
}

test "formats time of day with zero padding" {
    try std.testing.expectEqualStrings("00:00:00.000", &formatTimeOfDayShifted(0, 0, 0));
    try std.testing.expectEqualStrings("01:01:01.007", &formatTimeOfDayShifted(3661, 7, 0));
    try std.testing.expectEqualStrings("23:59:59.999", &formatTimeOfDayShifted(86399, 999, 0));
}

test "shifts the time of day by a local utc offset" {
    const hour: i32 = 3600;
    // 1970-01-01T00:00:00Z is 08:00 in UTC+8 and 19:00 the day before in UTC-5.
    try std.testing.expectEqualStrings("08:00:00.000", &formatTimeOfDayShifted(0, 0, 8 * hour));
    try std.testing.expectEqualStrings("19:00:00.000", &formatTimeOfDayShifted(0, 0, -5 * hour));
    // Midnight rolls over the day instead of printing 24:00.
    try std.testing.expectEqualStrings("00:00:00.500", &formatTimeOfDayShifted(86399, 500, 1));
    try std.testing.expectEqualStrings("00:59:59.000", &formatTimeOfDayShifted(86399, 0, hour));
}

test "log timestamps follow the TZ environment" {
    const saved = std.c.getenv("TZ");
    // POSIX TZ strings invert the sign: UTC-8 is UTC+8.
    _ = setenv("TZ", "UTC-8", 1);
    tzset();
    defer {
        if (saved) |value| {
            _ = setenv("TZ", value, 1);
        } else {
            _ = unsetenv("TZ");
        }
        tzset();
    }

    try std.testing.expectEqual(@as(i32, 8 * 3600), localOffsetSeconds(0));
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
