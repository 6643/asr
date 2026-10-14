const std = @import("std");

pub const SendFn = *const fn (ctx: ?*anyopaque, chunk: []const u8) anyerror!void;

/// Holds captured audio back until the prompt moment. Every chunk before
/// `open` is dropped: the wait for the session and the prompt itself must not
/// reach the engine. `sawFirstChunk` reports that the recorder really is
/// streaming (PipeWire links the source a moment after the spawn), which is
/// what makes the prompt a truthful "you can speak" signal.
pub const AudioGate = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    mode: Mode = .drop,
    first_chunk_seen: std.atomic.Value(bool) = .init(false),

    const Mode = enum {
        drop,
        open,
    };

    pub fn init(io: std.Io) AudioGate {
        return .{ .io = io };
    }

    pub fn sawFirstChunk(gate: *AudioGate) bool {
        return gate.first_chunk_seen.load(.acquire);
    }

    pub fn open(gate: *AudioGate) void {
        gate.mutex.lockUncancelable(gate.io);
        defer gate.mutex.unlock(gate.io);
        gate.mode = .open;
    }

    pub fn handleChunk(gate: *AudioGate, chunk: []const u8, ctx: ?*anyopaque, send_fn: SendFn) !void {
        gate.first_chunk_seen.store(true, .release);
        gate.mutex.lockUncancelable(gate.io);
        defer gate.mutex.unlock(gate.io);
        switch (gate.mode) {
            .drop => return,
            .open => try send_fn(ctx, chunk),
        }
    }
};

test "drops chunks until open and then sends them live" {
    const allocator = std.testing.allocator;
    var recorder = Recorder.init(allocator);
    defer recorder.deinit();

    var gate = AudioGate.init(std.testing.io);

    try gate.handleChunk("before the prompt", @ptrCast(&recorder), Recorder.send);
    gate.open();
    try gate.handleChunk("after the prompt", @ptrCast(&recorder), Recorder.send);

    try std.testing.expectEqualStrings("after the prompt", recorder.bytes.items);
}

test "notices the first chunk while still dropping it" {
    var gate = AudioGate.init(std.testing.io);

    try std.testing.expect(!gate.sawFirstChunk());
    try gate.handleChunk("early", null, Recorder.discard);
    try std.testing.expect(gate.sawFirstChunk());
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

    fn discard(ctx: ?*anyopaque, chunk: []const u8) !void {
        _ = ctx;
        _ = chunk;
    }
};
