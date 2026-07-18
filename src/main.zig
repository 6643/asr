const std = @import("std");
const asr = @import("asr_zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const opts = asr.cli.optionsFromArgs(args);
    switch (opts.mode) {
        .ibus_xml => {
            try stdout.writeAll(asr.runtime.ibus.component_xml);
            return;
        },
        .ibus_service => {
            asr.runtime.app.installSignalHandlers();
            const service = try asr.runtime.ibus.startService(allocator, init.io, init.minimal.environ);
            defer {
                service.stop();
                allocator.destroy(service);
            }
            while (!asr.runtime.app.isShutdownRequested()) {
                service.iterate();
                // Cancelable slice so Ctrl+C is observed within ~25ms.
                asr.runtime.shutdown.sleepMs(init.io, 25);
            }
            return;
        },
        .once_pcm => |pcm_path| {
            var cfg: asr.config.Config = .{};
            var creds = try asr.config.loadCredentials(allocator, init.io, cfg.credential_path);
            defer creds.deinit(allocator);
            const refresh_ok = blk: {
                const result = asr.doubao.credentials.refreshFile(allocator, init.io, cfg.credential_path, opts.debug) catch |err| {
                    std.log.warn("doubao credential refresh failed: {s}; using existing credentials", .{@errorName(err)});
                    break :blk false;
                };
                break :blk asr.doubao.credentials.refreshSucceeded(result);
            };
            if (refresh_ok) {
                std.log.info("doubao credentials refreshed", .{});
                creds.deinit(allocator);
                creds = try asr.config.loadCredentials(allocator, init.io, cfg.credential_path);
            }
            cfg = asr.config.withCredentials(cfg, creds);
            if (cfg.device_id.len == 0 or cfg.token.len == 0) return error.MissingCredentials;

            const text = try asr.doubao.client.transcribePcmFile(allocator, init.io, cfg, .{
                .pcm_path = pcm_path,
                .debug = opts.debug,
            });
            if (text) |value| {
                defer allocator.free(value);
                const corrected = try asr.doubao.rectify.rectifyText(allocator, init.io, value, cfg.sami_token, cfg.device_id);
                if (corrected) |c| {
                    defer allocator.free(c);
                    try stdout.print("rectified: {s}\n", .{c});
                } else {
                    try stdout.print("{s}\n", .{value});
                }
            }
            return;
        },
        .app => {
            try stdout.flush();
            try asr.runtime.app.run(allocator, init.io, init.minimal.environ, opts.debug);
            return;
        },
    }
}
