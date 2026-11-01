//! Shared streaming result state and the waiter that both engines use.
//!
//! Both engines resolve a recording the same way: interim results are
//! forwarded straight through, the last final text is kept until the session
//! ends, and an error or the end of the session wakes the waiter. Only the
//! wire protocol differs, so that part stays in each client.

const std = @import("std");
const finish_grace = @import("runtime/finish_grace.zig");

/// What `finish` resolved to. `text` and `err` own their buffers.
pub const Finish = union(enum) {
    none,
    text: []const u8,
    err: []const u8,
};

/// Events that change the resolution. Interim and VAD events never do, so
/// callers route them around this type.
pub const Event = union(enum) {
    /// Takes ownership of the text buffer.
    final: []const u8,
    /// Takes ownership of the message buffer.
    err: []const u8,
    session_finished,
};

pub const Resolution = enum { pending, final, session_finished, err };

pub const State = struct {
    final_text: ?[]const u8 = null,
    final_seen: bool = false,
    error_message: ?[]const u8 = null,
    session_finished: bool = false,
    reader_closed: bool = false,

    pub fn deinit(state: *State, allocator: std.mem.Allocator) void {
        if (state.final_text) |text| allocator.free(text);
        if (state.error_message) |message| allocator.free(message);
        state.* = .{};
    }

    pub fn resolution(state: *const State) Resolution {
        if (state.error_message != null) return .err;
        if (state.final_text != null) return .final;
        if (state.session_finished or state.reader_closed) return .session_finished;
        return .pending;
    }

    /// Hands the resolved result to the caller, transferring ownership of its
    /// buffer. A final or error is only handed out once.
    pub fn take(state: *State) Finish {
        return switch (state.resolution()) {
            .final => blk: {
                const text = state.final_text orelse break :blk .none;
                state.final_text = null;
                break :blk .{ .text = text };
            },
            .err => blk: {
                const message = state.error_message orelse break :blk .none;
                state.error_message = null;
                break :blk .{ .err = message };
            },
            .pending, .session_finished => .none,
        };
    }

    /// Applies one event, taking ownership of the buffers inside it.
    pub fn apply(state: *State, allocator: std.mem.Allocator, event: Event) Resolution {
        switch (event) {
            .session_finished => state.session_finished = true,
            .final => |text| {
                state.final_seen = true;
                if (state.final_text) |previous| allocator.free(previous);
                state.final_text = text;
            },
            .err => |message| {
                if (state.error_message) |previous| allocator.free(previous);
                state.error_message = message;
                return .err;
            },
        }
        return state.resolution();
    }
};

/// A `State` plus the mutex and condition variable the read thread and the
/// capture thread use to hand results over. The engine clients embed one.
pub const Waiter = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    state: State = .{},

    pub fn deinit(waiter: *Waiter, allocator: std.mem.Allocator) void {
        waiter.mutex.lockUncancelable(waiter.io);
        defer waiter.mutex.unlock(waiter.io);
        waiter.state.deinit(allocator);
    }

    /// The read loop is gone; nothing more will arrive.
    pub fn markReaderClosed(waiter: *Waiter) void {
        waiter.mutex.lockUncancelable(waiter.io);
        defer {
            waiter.cond.broadcast(waiter.io);
            waiter.mutex.unlock(waiter.io);
        }
        waiter.state.reader_closed = true;
    }

    /// Records an event and wakes anyone waiting on the resolution.
    pub fn record(waiter: *Waiter, allocator: std.mem.Allocator, event: Event) void {
        waiter.mutex.lockUncancelable(waiter.io);
        defer {
            waiter.cond.broadcast(waiter.io);
            waiter.mutex.unlock(waiter.io);
        }
        _ = waiter.state.apply(allocator, event);
    }

    /// Records an error unless the session already produced a final result:
    /// a final answer is not invalidated by a later transport hiccup.
    pub fn recordErrorMessage(waiter: *Waiter, allocator: std.mem.Allocator, message: []const u8) void {
        waiter.mutex.lockUncancelable(waiter.io);
        defer {
            waiter.cond.broadcast(waiter.io);
            waiter.mutex.unlock(waiter.io);
        }
        if (waiter.state.final_seen or waiter.state.final_text != null) return;
        const copy = allocator.dupe(u8, message) catch return;
        if (waiter.state.error_message) |previous| allocator.free(previous);
        waiter.state.error_message = copy;
    }

    pub fn markFinalSeen(waiter: *Waiter) void {
        waiter.mutex.lockUncancelable(waiter.io);
        defer {
            waiter.cond.broadcast(waiter.io);
            waiter.mutex.unlock(waiter.io);
        }
        waiter.state.final_seen = true;
    }

    pub fn hasFinal(waiter: *Waiter) bool {
        waiter.mutex.lockUncancelable(waiter.io);
        defer waiter.mutex.unlock(waiter.io);
        return waiter.state.final_seen;
    }

    /// True once the session can no longer accept audio.
    pub fn abortAudio(waiter: *Waiter) bool {
        waiter.mutex.lockUncancelable(waiter.io);
        defer waiter.mutex.unlock(waiter.io);
        return waiter.state.error_message != null or
            waiter.state.reader_closed or
            waiter.state.session_finished;
    }

    /// A read failure after a local stop or after a final result is expected
    /// noise, not a session error.
    pub fn ignoresReadError(waiter: *Waiter, stopped: bool, err: anyerror) bool {
        if (stopped) return true;
        if (err != error.ReadFailed) return false;
        waiter.mutex.lockUncancelable(waiter.io);
        defer waiter.mutex.unlock(waiter.io);
        return waiter.state.final_seen;
    }

    /// Whether a late final result is still worth waiting for.
    pub fn shouldWaitGrace(waiter: *Waiter, grace_ms: i64) bool {
        waiter.mutex.lockUncancelable(waiter.io);
        defer waiter.mutex.unlock(waiter.io);
        return finish_grace.shouldWaitGrace(grace_ms, waiter.state.reader_closed, waiter.state.error_message != null);
    }

    pub fn take(waiter: *Waiter) Finish {
        waiter.mutex.lockUncancelable(waiter.io);
        defer waiter.mutex.unlock(waiter.io);
        return waiter.state.take();
    }

    /// Waits up to `timeout_ms` for the session to resolve, then hands back
    /// whatever is resolved at that moment.
    pub fn waitForFinish(waiter: *Waiter, timeout_ms: i64) Finish {
        const SelectResult = union(enum) {
            done: void,
            timeout: void,
        };
        var slots: [2]SelectResult = undefined;
        var select = std.Io.Select(SelectResult).init(waiter.io, &slots);

        select.concurrent(.done, waitUntilResolved, .{waiter}) catch {
            select.async(.done, waitUntilResolved, .{waiter});
        };
        select.concurrent(.timeout, finishTimeoutSleep, .{ waiter.io, timeout_ms }) catch {
            select.async(.timeout, finishTimeoutSleep, .{ waiter.io, timeout_ms });
        };

        _ = select.await() catch {};
        select.cancelDiscard();
        return waiter.take();
    }
};

/// Block until the session is terminal (cancelable). A mid-hold final keeps
/// `final_text` but is not terminal: more speech may still be recognised.
fn waitUntilResolved(waiter: *Waiter) void {
    waiter.mutex.lockUncancelable(waiter.io);
    defer waiter.mutex.unlock(waiter.io);

    while (true) {
        if (waiter.state.error_message != null) return;
        if (waiter.state.session_finished or waiter.state.reader_closed) return;
        waiter.cond.wait(waiter.io, &waiter.mutex) catch return;
    }
}

fn finishTimeoutSleep(io: std.Io, timeout_ms: i64) void {
    std.Io.sleep(io, .fromMilliseconds(timeout_ms), .awake) catch {};
}

test "keeps final text after the reader closed" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);

    const text = try allocator.dupe(u8, "实时识别。");
    try std.testing.expectEqual(
        Resolution.final,
        state.apply(allocator, .{ .final = text }),
    );
    state.reader_closed = true;
    try std.testing.expectEqual(Resolution.final, state.resolution());
    try std.testing.expect(state.final_seen);
    try std.testing.expectEqualStrings("实时识别。", state.final_text.?);
}

test "final text does not mask a later error" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);

    const text = try allocator.dupe(u8, "语音识别测试。");
    _ = state.apply(allocator, .{ .final = text });
    const message = try allocator.dupe(u8, "SessionFailed");
    try std.testing.expectEqual(Resolution.err, state.apply(allocator, .{ .err = message }));

    switch (state.take()) {
        .err => |actual| {
            defer allocator.free(actual);
            try std.testing.expectEqualStrings("SessionFailed", actual);
        },
        else => return error.TestExpectedError,
    }
}

test "pending state owns its buffers until taken" {
    const allocator = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(allocator);

    try std.testing.expectEqual(Resolution.pending, state.resolution());
    try std.testing.expect(state.take() == .none);

    const text = try allocator.dupe(u8, "第一段。");
    _ = state.apply(allocator, .{ .final = text });
    const first = state.take();
    try std.testing.expectEqualStrings("第一段。", first.text);
    allocator.free(first.text);
    // Taking twice must not hand out the same buffer.
    try std.testing.expect(state.take() == .none);
}

test "wait for finish resolves when the session finished after an earlier final" {
    var waiter: Waiter = .{ .io = std.testing.io };
    defer waiter.deinit(std.testing.allocator);
    waiter.state.final_seen = true;
    waiter.state.session_finished = true;

    const started = std.Io.Timestamp.now(waiter.io, .real).toMilliseconds();
    const finish = waiter.waitForFinish(1_000);
    const elapsed = std.Io.Timestamp.now(waiter.io, .real).toMilliseconds() - started;
    try std.testing.expect(finish == .none);
    try std.testing.expect(elapsed < 200);
}

test "wait for finish keeps a final text until the session ends" {
    const allocator = std.testing.allocator;
    var waiter: Waiter = .{ .io = std.testing.io };
    defer waiter.deinit(allocator);
    waiter.state.final_text = try allocator.dupe(u8, "第一段。");
    waiter.state.final_seen = true;

    const started = std.Io.Timestamp.now(waiter.io, .real).toMilliseconds();
    const finish = waiter.waitForFinish(80);
    const elapsed = std.Io.Timestamp.now(waiter.io, .real).toMilliseconds() - started;
    switch (finish) {
        .text => |text| {
            defer allocator.free(text);
            try std.testing.expectEqualStrings("第一段。", text);
        },
        else => return error.TestExpectedText,
    }
    try std.testing.expect(elapsed >= 60);
}

test "wait for finish times out when the server never resolves" {
    var waiter: Waiter = .{ .io = std.testing.io };
    defer waiter.deinit(std.testing.allocator);

    const started = std.Io.Timestamp.now(waiter.io, .real).toMilliseconds();
    const finish = waiter.waitForFinish(80);
    const elapsed = std.Io.Timestamp.now(waiter.io, .real).toMilliseconds() - started;
    try std.testing.expect(finish == .none);
    try std.testing.expect(elapsed >= 60);
    try std.testing.expect(elapsed < 500);
}

test "reader close and errors are reported to the waiter" {
    const allocator = std.testing.allocator;
    var waiter: Waiter = .{ .io = std.testing.io };
    defer waiter.deinit(allocator);

    try std.testing.expect(!waiter.abortAudio());
    waiter.recordErrorMessage(allocator, "ReadFailed");
    try std.testing.expect(waiter.abortAudio());
    try std.testing.expect(waiter.ignoresReadError(false, error.ReadFailed) == false);
    try std.testing.expect(waiter.ignoresReadError(true, error.ReadFailed));
}

test "a final result suppresses later transport errors" {
    const allocator = std.testing.allocator;
    var waiter: Waiter = .{ .io = std.testing.io };
    defer waiter.deinit(allocator);

    waiter.markFinalSeen();
    waiter.recordErrorMessage(allocator, "ReadFailed");
    try std.testing.expect(waiter.state.error_message == null);
    try std.testing.expect(waiter.ignoresReadError(false, error.ReadFailed));
}
