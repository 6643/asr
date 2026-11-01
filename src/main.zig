const std = @import("std");
const asr = @import("asr_zig");

/// Routes every `std.log` line (engine and API modules included) through the
/// same sink and format as `runtime.output.Logger`, so `--log-file` sees the
/// whole run and timestamps stay consistent.
pub const std_options: std.Options = .{
    .logFn = asr.runtime.output.globalLogFn,
};

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
            const config_path = resolveConfigPathOrExit(allocator, init.io, init.minimal.environ);
            defer allocator.free(config_path);
            const level: asr.runtime.output.Level = if (opts.debug) .debug else .info;
            asr.runtime.output.installGlobalLogger(allocator, init.io, level, null);
            // One-line failure report, like the app path: a Zig error trace is
            // not a useful message for a CLI.
            runOncePcm(allocator, init.io, opts, pcm_path, config_path, stdout) catch |err| {
                std.debug.print("asr: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            return;
        },
        .app => {
            try stdout.flush();
            const config_path = resolveConfigPathOrExit(allocator, init.io, init.minimal.environ);
            defer allocator.free(config_path);
            var log_file: ?asr.runtime.output.LogFile = null;
            if (opts.log_file) |path| {
                log_file = asr.runtime.output.LogFile.open(path) catch {
                    std.debug.print("asr: cannot open log file {s}\n", .{path});
                    std.process.exit(2);
                };
            }
            defer if (log_file) |*file| file.deinit();
            const level: asr.runtime.output.Level = if (opts.debug) .debug else .info;
            asr.runtime.output.installGlobalLogger(allocator, init.io, level, if (log_file) |*file| file else null);
            // Report failures as one line instead of a Zig error trace: this is
            // the user-facing entry point for compositor and keyboard problems.
            asr.runtime.app.run(allocator, init.io, init.minimal.environ, opts, config_path, if (log_file) |*file| file else null) catch |err| {
                std.debug.print("asr: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
            return;
        },
    }
}

fn resolveConfigPathOrExit(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) []u8 {
    const requested = asr.config.executableConfigPath(allocator, io, environ) catch |err| {
        std.debug.print("asr: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(requested);
    return asr.config.resolveConfigPath(allocator, io, requested) catch |err| {
        std.debug.print("asr: {s}: no config file found; set ASR_CONFIG\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

/// Runs one raw PCM file through the selected engine and prints the result.
/// The caller turns any failure into a single `asr: <error>` line.
fn runOncePcm(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: asr.cli.Options,
    pcm_path: []const u8,
    config_path: []const u8,
    stdout: *std.Io.Writer,
) !void {
    if (opts.engine == .baidu) {
        var cfg = try asr.config.loadBaiduConfig(allocator, io, config_path);
        defer cfg.deinit(allocator);
        const text = try asr.baidu.client.transcribePcmFile(allocator, io, cfg, .{
            .pcm_path = pcm_path,
            .debug = opts.debug,
        });
        if (text) |value| {
            defer allocator.free(value);
            try stdout.print("{s}\n", .{value});
        }
        return;
    }
    var cfg: asr.config.Config = .{ .credential_path = config_path };
    var creds = try asr.config.loadCredentials(allocator, io, cfg.credential_path);
    defer creds.deinit(allocator);
    switch (asr.config.refreshDoubaoCredentials(allocator, io, cfg.credential_path, opts.debug)) {
        .refreshed => {
            std.log.scoped(.doubao).info("credentials refreshed", .{});
            creds.deinit(allocator);
            creds = try asr.config.loadCredentials(allocator, io, cfg.credential_path);
        },
        .failed => |err| std.log.scoped(.doubao).warn("credential refresh failed: {s}; using existing credentials", .{@errorName(err)}),
    }
    cfg = asr.config.withCredentials(cfg, creds);
    if (cfg.device_id.len == 0 or cfg.token.len == 0) return error.MissingCredentials;

    const text = try asr.doubao.client.transcribePcmFile(allocator, io, cfg, .{
        .pcm_path = pcm_path,
        .debug = opts.debug,
    });
    if (text) |value| {
        defer allocator.free(value);
        // `--no-rectify` applies here too: the flag is documented as a global
        // switch, not just an interactive-mode one.
        const corrected = if (opts.rectify)
            try asr.doubao.rectify.rectifyText(allocator, io, value, cfg.sami_token, cfg.device_id)
        else
            null;
        if (corrected) |c| {
            defer allocator.free(c);
            try stdout.print("rectified: {s}\n", .{c});
        } else {
            try stdout.print("{s}\n", .{value});
        }
    }
}
