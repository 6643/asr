const std = @import("std");

pub const Level = enum(u8) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
};

pub const Logger = struct {
    io: std.Io,
    level: Level = .info,

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
        var file_writer = if (level == .err)
            std.Io.File.stderr().writer(logger.io, &buffer)
        else
            std.Io.File.stdout().writer(logger.io, &buffer);
        file_writer.interface.print("{s} [{s}] " ++ fmt ++ "\n", .{ timestamp(logger.io), domain } ++ args) catch {};
        file_writer.interface.flush() catch {};
    }
};

fn timestamp(io: std.Io) [23]u8 {
    const now = std.Io.Clock.real.now(io);
    const raw_seconds = now.toSeconds();
    const raw_milliseconds = now.toMilliseconds();
    const seconds: u64 = if (raw_seconds < 0) 0 else @intCast(raw_seconds);
    const milliseconds: u16 = if (raw_milliseconds < 0)
        0
    else
        @intCast(@mod(raw_milliseconds, 1000));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const day_secs = epoch_seconds.getDaySeconds();
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var out: [23]u8 = undefined;
    _ = std.fmt.bufPrint(
        &out,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
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
    try std.testing.expectEqual(@as(usize, 23), timestamp(std.testing.io).len);
}
