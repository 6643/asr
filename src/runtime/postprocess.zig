const std = @import("std");
const config = @import("../config.zig");
const rectify = @import("../doubao/rectify.zig");
const wayland_im = @import("wayland_im.zig");
const output = @import("output.zig");

/// Rectification costs a curl round trip (~1.5s), so it only runs when asked
/// for and both credentials are present.
pub fn shouldRectify(enabled: bool, sami_token: []const u8, device_id: []const u8) bool {
    return enabled and sami_token.len > 0 and device_id.len > 0;
}

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    client: *wayland_im.Client,
    cfg: *const config.Config,
    provider: []const u8,
    rectify_enabled: bool,
    rectify_queue: TextQueue,
    commit_queue: TextQueue,
    rectify_thread: ?std.Thread = null,
    commit_thread: ?std.Thread = null,

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        logger: output.Logger,
        client: *wayland_im.Client,
        cfg: *const config.Config,
        provider: []const u8,
        rectify_enabled: bool,
    ) !*Pipeline {
        const pipeline = try allocator.create(Pipeline);
        pipeline.* = .{
            .allocator = allocator,
            .io = io,
            .logger = logger,
            .client = client,
            .cfg = cfg,
            .provider = provider,
            .rectify_enabled = rectify_enabled,
            .rectify_queue = TextQueue.init(allocator, io),
            .commit_queue = TextQueue.init(allocator, io),
        };
        errdefer pipeline.deinit();

        pipeline.rectify_thread = try std.Thread.spawn(.{}, rectifyWorker, .{pipeline});

        pipeline.commit_thread = try std.Thread.spawn(.{}, commitWorker, .{pipeline});

        return pipeline;
    }

    pub fn submitFinal(pipeline: *Pipeline, text: []const u8) void {
        const dropped = pipeline.rectify_queue.enqueueDup(text) catch |err| {
            pipeline.logger.err("postprocess", "queue final text failed: {s}", .{@errorName(err)});
            return;
        };
        if (dropped) |item| {
            defer pipeline.allocator.free(item);
            pipeline.logger.err("postprocess", "rectify queue full; dropped oldest text", .{});
        }
    }

    pub fn deinit(pipeline: *Pipeline) void {
        pipeline.rectify_queue.close();
        pipeline.commit_queue.close();
        if (pipeline.rectify_thread) |thread| thread.join();
        if (pipeline.commit_thread) |thread| thread.join();
        pipeline.rectify_queue.deinit();
        pipeline.commit_queue.deinit();
        pipeline.allocator.destroy(pipeline);
    }

    fn rectifyWorker(ctx: *Pipeline) void {
        while (ctx.rectify_queue.pop()) |text| {
            defer ctx.allocator.free(text);
            if (!shouldRectify(ctx.rectify_enabled, ctx.cfg.sami_token, ctx.cfg.device_id)) {
                ctx.logger.info(ctx.provider, "🚀 {s}", .{text});
                enqueueCommit(ctx, text);
                continue;
            }
            const corrected = rectify.rectifyText(ctx.allocator, ctx.io, text, ctx.cfg.sami_token, ctx.cfg.device_id) catch null;
            if (corrected) |c| {
                defer ctx.allocator.free(c);
                ctx.logger.info(ctx.provider, "🚀 {s} → {s}", .{ text, c });
                enqueueCommit(ctx, c);
            } else {
                ctx.logger.info(ctx.provider, "🚀 {s}", .{text});
                enqueueCommit(ctx, text);
            }
        }
    }

    fn enqueueCommit(ctx: *Pipeline, text: []const u8) void {
        const dropped = ctx.commit_queue.enqueueDup(text) catch |err| {
            ctx.logger.err("postprocess", "enqueue commit failed: {s}", .{@errorName(err)});
            return;
        };
        if (dropped) |item| {
            defer ctx.allocator.free(item);
            ctx.logger.err("postprocess", "commit queue full; dropped oldest text", .{});
        }
    }

    fn commitWorker(ctx: *Pipeline) void {
        while (ctx.commit_queue.pop()) |text| {
            defer ctx.allocator.free(text);
            const status = ctx.client.commit(text);
            if (std.mem.startsWith(u8, status, "OK ")) {
                ctx.logger.info("wayland", "✅", .{});
            } else {
                ctx.logger.err("wayland", "❌ {s}", .{status});
            }
        }
    }
};

/// Unbounded queues would grow without limit if the rectifier or the
/// compositor got stuck, so each queue keeps at most this many texts.
pub const max_pending_texts: usize = 64;

const TextQueue = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    items: std.ArrayList([]u8) = .empty,
    closed: bool = false,

    fn init(allocator: std.mem.Allocator, io: std.Io) TextQueue {
        return .{ .allocator = allocator, .io = io };
    }

    fn deinit(queue: *TextQueue) void {
        queue.mutex.lockUncancelable(queue.io);
        defer queue.mutex.unlock(queue.io);
        for (queue.items.items) |item| queue.allocator.free(item);
        queue.items.deinit(queue.allocator);
        queue.items = .empty;
    }

    fn close(queue: *TextQueue) void {
        queue.mutex.lockUncancelable(queue.io);
        defer {
            queue.cond.broadcast(queue.io);
            queue.mutex.unlock(queue.io);
        }
        queue.closed = true;
    }

    /// Copies `text` into the queue. When the queue is already full the oldest
    /// entry is removed to make room and handed back to the caller, which owns
    /// it (free it after logging): the newest speech matters most.
    fn enqueueDup(queue: *TextQueue, text: []const u8) !?[]u8 {
        const copy = try queue.allocator.dupe(u8, text);
        errdefer queue.allocator.free(copy);
        queue.mutex.lockUncancelable(queue.io);
        defer queue.mutex.unlock(queue.io);
        if (queue.closed) return error.QueueClosed;
        var dropped: ?[]u8 = null;
        if (queue.items.items.len >= max_pending_texts) {
            dropped = queue.items.orderedRemove(0);
        }
        try queue.items.append(queue.allocator, copy);
        queue.cond.signal(queue.io);
        return dropped;
    }

    fn pop(queue: *TextQueue) ?[]u8 {
        queue.mutex.lockUncancelable(queue.io);
        defer queue.mutex.unlock(queue.io);
        while (queue.items.items.len == 0 and !queue.closed) {
            // Cancelable: pipeline deinit close() broadcasts; cancel also wakes workers.
            queue.cond.wait(queue.io, &queue.mutex) catch {
                // Canceled while waiting: re-check closed/items after re-acquiring lock.
                if (queue.closed and queue.items.items.len == 0) return null;
                continue;
            };
        }
        if (queue.items.items.len == 0) return null;
        return queue.items.orderedRemove(0);
    }
};

test "queue preserves fifo order" {
    var queue = TextQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();

    try std.testing.expect(try queue.enqueueDup("one") == null);
    try std.testing.expect(try queue.enqueueDup("two") == null);

    const first = queue.pop();
    try std.testing.expect(first != null);
    defer std.testing.allocator.free(first.?);
    const second = queue.pop();
    try std.testing.expect(second != null);
    defer std.testing.allocator.free(second.?);

    try std.testing.expectEqualStrings("one", first.?);
    try std.testing.expectEqualStrings("two", second.?);
}

test "drops the oldest text when the queue is full" {
    var queue = TextQueue.init(std.testing.allocator, std.testing.io);
    defer queue.deinit();

    var index: usize = 0;
    var buf: [32]u8 = undefined;
    while (index < max_pending_texts + 6) : (index += 1) {
        const text = try std.fmt.bufPrint(&buf, "item-{d}", .{index});
        const dropped = try queue.enqueueDup(text);
        if (index < max_pending_texts) {
            try std.testing.expect(dropped == null);
        } else {
            defer std.testing.allocator.free(dropped.?);
            var expected_buf: [32]u8 = undefined;
            const expected = try std.fmt.bufPrint(&expected_buf, "item-{d}", .{index - max_pending_texts});
            try std.testing.expectEqualStrings(expected, dropped.?);
        }
    }

    try std.testing.expectEqual(max_pending_texts, queue.items.items.len);
    const first = queue.pop();
    try std.testing.expect(first != null);
    defer std.testing.allocator.free(first.?);
    try std.testing.expectEqualStrings("item-6", first.?);
}

test "rectify needs the flag and both credentials" {
    try std.testing.expect(shouldRectify(true, "token", "device"));
    try std.testing.expect(!shouldRectify(false, "token", "device"));
    try std.testing.expect(!shouldRectify(true, "", "device"));
    try std.testing.expect(!shouldRectify(true, "token", ""));
}
