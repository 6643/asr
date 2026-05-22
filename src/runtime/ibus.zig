const std = @import("std");
const cmd = @import("cmd.zig");

pub const engine_name = "asr";
pub const bus_name = "org.freedesktop.IBus.ASR";
pub const component_name = "asr.xml";
pub const gio_ibus = @import("gio_ibus.zig");
pub const retry_attempts: usize = 20;
pub const retry_delay_ms: i64 = 250;
pub const engine_switch_timeout_ms: i64 = 5000;

pub const component_xml =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<component>
    \\ <name>org.freedesktop.IBus.ASR</name>
    \\ <description>ASR IBus Engine</description>
    \\ <exec>asr</exec>
    \\ <version>0.1.0</version>
    \\ <author>_</author>
    \\ <license>MIT</license>
    \\ <homepage>https://example.invalid/asr</homepage>
    \\ <textdomain>asr</textdomain>
    \\ <engines>
    \\ <engine>
    \\ <name>asr</name>
    \\ <longname>ZH</longname>
    \\ <language>zh</language>
    \\ <license>MIT</license>
    \\ <author>_</author>
    \\ <icon></icon>
    \\ <layout>us</layout>
    \\ <symbol>asr</symbol>
    \\ <description>Commit ASR text through IBus</description>
    \\ <setup></setup>
    \\ <rank>80</rank>
    \\ </engine>
    \\ </engines>
    \\</component>
    \\
;

pub fn resolveComponentPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const home = std.process.Environ.getPosix(environ, "HOME") orelse "/tmp";
    return std.fmt.allocPrint(allocator, "{s}/.local/share/ibus/component/{s}", .{ home, component_name });
}

pub fn installComponent(io: std.Io, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return error.InvalidComponentPath;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = component_xml,
        .flags = .{ .permissions = .fromMode(0o644) },
    });
}

pub fn initRuntime(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) ![]u8 {
    try ensureDaemonRunning(allocator, io);
    const path = try resolveComponentPath(allocator, environ);
    errdefer allocator.free(path);
    const changed = try installComponentIfChanged(allocator, io, path);
    if (changed) refreshCache(allocator, io) catch {};
    const address = try resolveAddress(allocator, io);
    allocator.free(address);
    return path;
}

pub fn switchToAsrInputMethod(allocator: std.mem.Allocator, io: std.Io) !void {
    var attempts: usize = 0;
    while (attempts < retry_attempts) : (attempts += 1) {
        cmd.runDiscard(allocator, io, &.{ "ibus", "engine", engine_name }, engine_switch_timeout_ms) catch |err| {
            if (err != error.CommandFailed) return err;
            sleepMs(io, retry_delay_ms);
            continue;
        };
        return;
    }
    return error.CommandFailed;
}

pub fn resolveAddress(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var attempts: usize = 0;
    while (attempts < retry_attempts) : (attempts += 1) {
        if (readAddress(allocator, io)) |address| {
            if (isValidAddress(address)) return address;
            allocator.free(address);
        } else |_| {}
        sleepMs(io, retry_delay_ms);
    }
    return error.IbusAddressNotFound;
}

fn ensureDaemonRunning(allocator: std.mem.Allocator, io: std.Io) !void {
    if (isDaemonRunning(allocator, io)) return;
    try cmd.runDiscard(allocator, io, &.{ "ibus-daemon", "-xdr" }, engine_switch_timeout_ms);
    var attempts: usize = 0;
    while (attempts < retry_attempts) : (attempts += 1) {
        if (isDaemonRunning(allocator, io)) return;
        sleepMs(io, retry_delay_ms);
    }
    return error.IbusDaemonNotRunning;
}

fn isDaemonRunning(allocator: std.mem.Allocator, io: std.Io) bool {
    const out = cmd.runText(allocator, io, &.{ "pgrep", "-af", "ibus-daemon" }, 1000) catch return false;
    defer allocator.free(out);
    return std.mem.indexOf(u8, out, "ibus-daemon") != null;
}

fn refreshCache(allocator: std.mem.Allocator, io: std.Io) !void {
    try cmd.runDiscard(allocator, io, &.{ "ibus", "write-cache" }, 3000);
    cmd.runDiscard(allocator, io, &.{ "ibus", "restart" }, 3000) catch {};
}

fn readAddress(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const out = try cmd.runText(allocator, io, &.{ "ibus", "address" }, 1000);
    errdefer allocator.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == out.len) return out;
    const copy = try allocator.dupe(u8, trimmed);
    allocator.free(out);
    return copy;
}

fn installComponentIfChanged(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const current = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (current) |bytes| {
        defer allocator.free(bytes);
        if (std.mem.eql(u8, bytes, component_xml)) return false;
    }
    try installComponent(io, path);
    return true;
}

fn isValidAddress(address: []const u8) bool {
    if (address.len == 0) return false;
    if (std.mem.eql(u8, address, "(null)")) return false;
    return std.mem.indexOfScalar(u8, address, ':') != null;
}

fn sleepMs(io: std.Io, milliseconds: i64) void {
    std.Io.sleep(io, .fromMilliseconds(milliseconds), .awake) catch {};
}

pub fn startService(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !*gio_ibus.Service {
    return gio_ibus.start(allocator, io, environ);
}

test "resolves component path from HOME" {
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("HOME", "/home/test");
    const block = try env_map.createPosixBlock(std.testing.allocator, .{});
    defer block.deinit(std.testing.allocator);
    const path = try resolveComponentPath(std.testing.allocator, .{ .block = block });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/test/.local/share/ibus/component/asr.xml", path);
}
