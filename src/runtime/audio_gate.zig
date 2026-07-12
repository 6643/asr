const std = @import("std");

pub const SendFn = *const fn (ctx: ?*anyopaque, chunk: []const u8) anyerror!void;

/// Hard cap for pre-session speech buffer (matches capture fallback budget).
pub const max_buffered_audio_bytes: usize = 64 * 1024 * 1024;

pub const AudioGate = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    mode: Mode = .drop,
    buffered_audio: std.ArrayList(u8) = .empty,
    max_buffered_bytes: usize = max_buffered_audio_bytes,

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
            .buffer => try appendBuffered(gate, chunk),
            .open => try send_fn(ctx, chunk),
        }
    }

    fn appendBuffered(gate: *AudioGate, chunk: []const u8) !void {
        const room = if (gate.buffered_audio.items.len >= gate.max_buffered_bytes)
            @as(usize, 0)
        else
            gate.max_buffered_bytes - gate.buffered_audio.items.len;
        if (room == 0) return;
        const take = @min(chunk.len, room);
        try gate.buffered_audio.appendSlice(gate.allocator, chunk[0..take]);
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

test "buffers speech from the start when open is delayed by session boot" {
    const allocator = std.testing.allocator;
    var recorder = Recorder.init(allocator);
    defer recorder.deinit();

    var gate = AudioGate.init(allocator, std.testing.io);
    defer gate.deinit();

    // Hot path: buffer immediately so session handshake never drops speech.
    gate.beginBuffering();
    try gate.handleChunk("early", @ptrCast(&recorder), Recorder.send);
    try gate.handleChunk("speech", @ptrCast(&recorder), Recorder.send);
    try gate.openAndFlush(@ptrCast(&recorder), Recorder.send);
    try gate.handleChunk("!", @ptrCast(&recorder), Recorder.send);

    try std.testing.expectEqualStrings("earlyspeech!", recorder.bytes.items);
}

test "buffer mode drops bytes once max_buffered_bytes is reached" {
    const allocator = std.testing.allocator;
    var recorder = Recorder.init(allocator);
    defer recorder.deinit();

    var gate = AudioGate.init(allocator, std.testing.io);
    defer gate.deinit();
    gate.max_buffered_bytes = 4;

    gate.beginBuffering();
    try gate.handleChunk("abc", @ptrCast(&recorder), Recorder.send);
    try gate.handleChunk("def", @ptrCast(&recorder), Recorder.send);
    try gate.openAndFlush(@ptrCast(&recorder), Recorder.send);

    try std.testing.expectEqualStrings("abcd", recorder.bytes.items);
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
