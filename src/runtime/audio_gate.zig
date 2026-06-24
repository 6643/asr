const std = @import("std");

pub const SendFn = *const fn (ctx: ?*anyopaque, chunk: []const u8) anyerror!void;

pub const AudioGate = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    mode: Mode = .drop,
    buffered_audio: std.ArrayList(u8) = .empty,

    const Mode = enum {
        drop,
        buffer,
        open,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) AudioGate {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(gate: *AudioGate) void {
        gate.buffered_audio.deinit(gate.allocator);
    }

    pub fn beginBuffering(gate: *AudioGate) void {
        gate.mutex.lockUncancelable(gate.io);
        defer gate.mutex.unlock(gate.io);
        if (gate.mode == .drop) gate.mode = .buffer;
    }

    pub fn openAndFlush(gate: *AudioGate, ctx: ?*anyopaque, send_fn: SendFn) !void {
        gate.mutex.lockUncancelable(gate.io);
        defer gate.mutex.unlock(gate.io);
        gate.mode = .open;
        if (gate.buffered_audio.items.len > 0) {
            try send_fn(ctx, gate.buffered_audio.items);
            gate.buffered_audio.items.len = 0;
        }
    }

    pub fn handleChunk(gate: *AudioGate, chunk: []const u8, ctx: ?*anyopaque, send_fn: SendFn) !void {
        gate.mutex.lockUncancelable(gate.io);
        defer gate.mutex.unlock(gate.io);
        switch (gate.mode) {
            .drop => return,
            .buffer => try gate.buffered_audio.appendSlice(gate.allocator, chunk),
            .open => try send_fn(ctx, chunk),
        }
    }
};

test "drops prompt audio then flushes buffered speech before live chunks" {
    const allocator = std.testing.allocator;
    var recorder = Recorder.init(allocator);
    defer recorder.deinit();

    var gate = AudioGate.init(allocator, std.testing.io);
    defer gate.deinit();

    try gate.handleChunk("prompt", @ptrCast(&recorder), Recorder.send);
    gate.beginBuffering();
    try gate.handleChunk("ni", @ptrCast(&recorder), Recorder.send);
    try gate.handleChunk("hao", @ptrCast(&recorder), Recorder.send);
    try gate.openAndFlush(@ptrCast(&recorder), Recorder.send);
    try gate.handleChunk("!", @ptrCast(&recorder), Recorder.send);

    try std.testing.expectEqualStrings("nihao!", recorder.bytes.items);
}

const Recorder = struct {
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    fn deinit(recorder: *Recorder) void {
        recorder.bytes.deinit(recorder.allocator);
    }

    fn send(ctx: ?*anyopaque, chunk: []const u8) !void {
        const recorder = @as(*Recorder, @ptrCast(@alignCast(ctx orelse return error.MissingRecorder)));
        try recorder.bytes.appendSlice(recorder.allocator, chunk);
    }
};
