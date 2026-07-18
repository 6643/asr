const config = @import("../config.zig");
const doubao = @import("../doubao/client.zig");
const baidu = @import("../baidu/client.zig");

pub const Kind = enum { baidu, doubao };

pub const Config = union(Kind) {
    baidu: config.BaiduConfig,
    doubao: config.Config,
};

pub const StreamOptions = struct {
    debug: bool = false,
    on_interim: ?*const fn (ctx: ?*const anyopaque, text: []const u8) void = null,
    interim_ctx: ?*const anyopaque = null,
    on_final: ?*const fn (ctx: ?*const anyopaque, text: []const u8) void = null,
    final_ctx: ?*const anyopaque = null,
};

pub const StreamFinish = union(enum) {
    none,
    text: []const u8,
    err: []const u8,
};

pub const Session = union(Kind) {
    baidu: baidu.StreamingSession,
    doubao: doubao.StreamingSession,

    pub fn init(
        allocator: @import("std").mem.Allocator,
        io: @import("std").Io,
        cfg: Config,
        options: StreamOptions,
    ) !Session {
        return switch (cfg) {
            .baidu => |value| .{ .baidu = try baidu.StreamingSession.init(allocator, io, value, .{
                .debug = options.debug,
                .on_interim = options.on_interim,
                .interim_ctx = options.interim_ctx,
                .on_final = options.on_final,
                .final_ctx = options.final_ctx,
            }) },
            .doubao => |value| .{ .doubao = try doubao.StreamingSession.init(allocator, io, value, .{
                .debug = options.debug,
                .on_interim = options.on_interim,
                .interim_ctx = options.interim_ctx,
                .on_final = options.on_final,
                .final_ctx = options.final_ctx,
            }) },
        };
    }

    pub fn start(session: *Session) !void {
        switch (session.*) {
            .baidu => |*value| try value.start(),
            .doubao => |*value| try value.start(),
        }
    }

    pub fn deinit(session: *Session) void {
        switch (session.*) {
            .baidu => |*value| value.deinit(),
            .doubao => |*value| value.deinit(),
        }
    }

    pub fn sendChunk(session: *Session, chunk: []const u8) !void {
        switch (session.*) {
            .baidu => |*value| try value.sendChunk(chunk),
            .doubao => |*value| try value.sendChunk(chunk),
        }
    }

    pub fn finish(session: *Session) !StreamFinish {
        return switch (session.*) {
            .baidu => |*value| mapFinish(baidu.StreamFinish, try value.finish()),
            .doubao => |*value| mapFinish(doubao.StreamFinish, try value.finish()),
        };
    }

    pub fn finishAfterStreamFailure(session: *Session) StreamFinish {
        return switch (session.*) {
            .baidu => |*value| mapFinish(baidu.StreamFinish, value.finishAfterStreamFailure()),
            .doubao => |*value| mapFinish(doubao.StreamFinish, value.finishAfterStreamFailure()),
        };
    }

    pub fn hasFinalEvent(session: *Session) bool {
        return switch (session.*) {
            .baidu => |*value| value.hasFinalEvent(),
            .doubao => |*value| value.hasFinalEvent(),
        };
    }
};

fn mapFinish(comptime T: type, value: T) StreamFinish {
    return switch (value) {
        .none => .none,
        .text => |text| .{ .text = text },
        .err => |message| .{ .err = message },
    };
}

test "maps provider session finish values" {
    try @import("std").testing.expectEqual(StreamFinish.none, mapFinish(doubao.StreamFinish, .none));
    try @import("std").testing.expectEqualStrings("ok", (mapFinish(doubao.StreamFinish, .{ .text = "ok" })).text);
}
