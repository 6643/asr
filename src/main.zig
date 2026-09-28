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
    const opts = asr.cli.optionsFromArgs(args) catch |err| {
        try stdout.print("asr: {s}\n{s}", .{ @errorName(err), asr.cli.usage_text });
        try stdout.flush();
        std.process.exit(2);
    };
    switch (opts.mode) {
        .help => {
            try stdout.writeAll(asr.cli.usage_text);
            return;
        },
        .once_pcm => |pcm_path| {
            if (opts.engine == .baidu) {
                var cfg = try asr.config.loadBaiduConfig(allocator, init.io, asr.config.default_baidu_credential_path);
                defer cfg.deinit(allocator);
                const text = try asr.baidu.client.transcribePcmFile(allocator, init.io, cfg, .{
                    .pcm_path = pcm_path,
                    .debug = opts.debug,
                });
                if (text) |value| {
                    defer allocator.free(value);
                    try stdout.print("{s}\n", .{value});
                }
                return;
            }
            var cfg: asr.config.Config = .{};
            var creds = try asr.config.loadCredentials(allocator, init.io, cfg.credential_path);
            defer creds.deinit(allocator);
            switch (asr.config.refreshDoubaoCredentials(allocator, init.io, cfg.credential_path, opts.debug)) {
                .refreshed => {
                    std.log.info("doubao credentials refreshed", .{});
                    creds.deinit(allocator);
                    creds = try asr.config.loadCredentials(allocator, init.io, cfg.credential_path);
                },
                .failed => |err| std.log.warn("doubao credential refresh failed: {s}; using existing credentials", .{@errorName(err)}),
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
            var log_file: ?asr.runtime.output.LogFile = null;
            if (opts.log_file) |path| {
                log_file = asr.runtime.output.LogFile.open(path) catch {
                    std.debug.print("asr: cannot open log file {s}\n", .{path});
                    std.process.exit(2);
                };
            }
            defer if (log_file) |*file| file.deinit();
            // Report failures as one line instead of a Zig error trace: this is
            // the user-facing entry point for compositor and keyboard problems.
            asr.runtime.app.run(allocator, init.io, init.minimal.environ, opts, if (log_file) |*file| file else null) catch |err| {
                std.debug.print("asr: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            return;
        },
    }
}
