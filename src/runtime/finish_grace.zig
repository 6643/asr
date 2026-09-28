const std = @import("std");

/// Extra time to wait for a final result after `finish` already timed out on
/// `finish_timeout_ms`: a slow server may still deliver the last sentence,
/// and closing the session discards it.
pub const default_grace_ms: i64 = 2_000;

/// Only a live, error-free session is worth waiting on any longer.
pub fn shouldWaitGrace(grace_ms: i64, reader_closed: bool, has_error: bool) bool {
    return grace_ms > 0 and !reader_closed and !has_error;
}

test "grace window only applies while the session is alive" {
    try std.testing.expect(shouldWaitGrace(2000, false, false));
    try std.testing.expect(!shouldWaitGrace(2000, true, false));
    try std.testing.expect(!shouldWaitGrace(2000, false, true));
    try std.testing.expect(!shouldWaitGrace(0, false, false));
}
