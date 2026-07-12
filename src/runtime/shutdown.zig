const std = @import("std");

/// Process-wide cooperative shutdown. Signal handlers only flip the flag
/// (async-signal-safe); Io tasks poll it and cancel outstanding Select arms.
var requested = std.atomic.Value(bool).init(false);

pub fn request() void {
    requested.store(true, .release);
}

pub fn isRequested() bool {
    return requested.load(.acquire);
}

pub fn installSignalHandlers() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        // No SA_RESTART: leave blocking syscalls interruptible for cancel paths.
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    request();
}

/// Cancelable sleep that returns early when shutdown is requested.
pub fn sleepUntilOr(io: std.Io, milliseconds: i64) void {
    var remaining = milliseconds;
    while (remaining > 0 and !isRequested()) {
        const slice: i64 = @min(remaining, 25);
        std.Io.sleep(io, .fromMilliseconds(slice), .awake) catch return;
        remaining -= slice;
    }
}

/// Canonical short name for cancelable sleeps used across runtime/main.
pub fn sleepMs(io: std.Io, milliseconds: i64) void {
    sleepUntilOr(io, milliseconds);
}

test "shutdown flag starts clear and can be set" {
    // Do not touch process signal handlers in unit tests; only the atomic API.
    // Note: process-global — reset after so other tests are unaffected if any
    // concurrent tests run (tests are sequential in this project).
    const was = isRequested();
    defer if (!was) {
        // Only clear if we set it in this test.
        if (isRequested()) requested.store(false, .release);
    };
    if (!was) {
        try std.testing.expect(!isRequested());
        request();
        try std.testing.expect(isRequested());
        requested.store(false, .release);
        try std.testing.expect(!isRequested());
    }
}
