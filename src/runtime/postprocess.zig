const std = @import("std");
const config = @import("../config.zig");
const rectify = @import("../doubao/rectify.zig");
const ibus = @import("ibus.zig");
const wayland_im = @import("wayland_im.zig");
const output = @import("output.zig");

pub const CommitBackend = union(enum) {
    ibus: *ibus.gio_ibus.Service,
    wayland: *wayland_im.Client,

    pub fn commit(backend: CommitBackend, text: []const u8) []const u8 {
        return switch (backend) {
            .ibus => |service| service.commitStatus(text),
            .wayland => |client| client.commit(text),
        };
    }

    pub fn domain(backend: CommitBackend) []const u8 {
        return switch (backend) {
            .ibus => "ibus",
            .wayland => "wayland",
        };
    }
};

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: output.Logger,
    backend: CommitBackend,
    cfg: *const config.Config,
    provider: []const u8,
    rectify_queue: TextQueue,
    commit_queue: TextQueue,
    rectify_thread: ?std.Thread = null,
    commit_thread: ?std.Thread = null,

    pub fn start(
        allocator: std.mem.Allocator,
        io: std.Io,
        logger: output.Logger,
        backend: CommitBackend,
        cfg: *const config.Config,
        provider: []const u8,
    ) !*Pipeline {
        const pipeline = try allocator.create(Pipeline);
        pipeline.* = .{
            .allocator = allocator,
            .io = io,
            .logger = logger,
            .backend = backend,
            .cfg = cfg,
            .provider = provider,
            .rectify_queue = TextQueue.init(allocator, io),
            .commit_queue = TextQueue.init(allocator, io),
        };
        errdefer pipeline.deinit();

        pipeline.rectify_thread = try std.Thread.spawn(.{}, rectifyWorker, .{pipeline});

        pipeline.commit_thread = try std.Thread.spawn(.{}, commitWorker, .{pipeline});

        return pipeline;
    }

    pub fn submitFinal(pipeline: *Pipeline, text: []const u8) void {
        pipeline.rectify_queue.enqueueDup(text) catch |err| {
            pipeline.logger.err("postprocess", "queue final text failed: {s}", .{@errorName(err)});
        };
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
            const corrected = rectify.rectifyText(ctx.allocator, ctx.io, text, ctx.cfg.sami_token, ctx.cfg.device_id) catch null;
            if (corrected) |c| {
                defer ctx.allocator.free(c);
                ctx.logger.info(ctx.provider, "🚀 {s} → {s}", .{ text, c });
                ctx.commit_queue.enqueueDup(c) catch |err| {
                    ctx.logger.err("postprocess", "enqueue commit failed: {s}", .{@errorName(err)});
                };
            } else {
                ctx.logger.info(ctx.provider, "🚀 {s}", .{text});
                ctx.commit_queue.enqueueDup(text) catch |err| {
                    ctx.logger.err("postprocess", "enqueue commit failed: {s}", .{@errorName(err)});
                };
            }
        }
    }

    fn commitWorker(ctx: *Pipeline) void {
        while (ctx.commit_queue.pop()) |text| {
            defer ctx.allocator.free(text);
            const status = ctx.backend.commit(text);
            if (std.mem.startsWith(u8, status, "OK ")) {
                ctx.logger.info(ctx.backend.domain(), "✅", .{});
            } else {
                ctx.logger.err(ctx.backend.domain(), "❌ {s}", .{status});
            }
        }
    }
};

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

    fn enqueueDup(queue: *TextQueue, text: []const u8) !void {
        const copy = try queue.allocator.dupe(u8, text);
        errdefer queue.allocator.free(copy);
        queue.mutex.lockUncancelable(queue.io);
        defer queue.mutex.unlock(queue.io);
        if (queue.closed) return error.QueueClosed;
        try queue.items.append(queue.allocator, copy);
        queue.cond.signal(queue.io);
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

    try queue.enqueueDup("one");
    try queue.enqueueDup("two");

    const first = queue.pop();
    try std.testing.expect(first != null);
    defer std.testing.allocator.free(first.?);
    const second = queue.pop();
    try std.testing.expect(second != null);
    defer std.testing.allocator.free(second.?);

    try std.testing.expectEqualStrings("one", first.?);
    try std.testing.expectEqualStrings("two", second.?);
}

test "commit backend reports provider domain" {
    try std.testing.expectEqualStrings("ibus", (CommitBackend{ .ibus = undefined }).domain());
    try std.testing.expectEqualStrings("wayland", (CommitBackend{ .wayland = undefined }).domain());
}
